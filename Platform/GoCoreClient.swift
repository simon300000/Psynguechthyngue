import Foundation
import PsyCore

#if canImport(Mobilebridge)
    import Mobilebridge

    /// The actor intentionally performs gomobile calls synchronously. This
    /// tiny thread-safe handle lets a Task cancellation handler interrupt a
    /// blocked native sync/read without waiting to enter the actor executor.
    private final class MobilebridgeCancellationHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var core: MobilebridgeCore?

        func install(_ value: MobilebridgeCore) {
            lock.lock()
            core = value
            lock.unlock()
        }

        func clear(_ expected: MobilebridgeCore) {
            lock.lock()
            if core === expected { core = nil }
            lock.unlock()
        }

        func requestCancellation() {
            lock.lock()
            let active = core
            lock.unlock()
            active?.requestCancel()
        }
    }

    actor MobileSyncthingCoreClient: CoreClient {
        private static let maximumSnapshotAttempts = 3
        private static let maximumReadRangeLength = 1 << 20
        private static let maximumPersistableGeneration = UInt64(Int64.max)

        private let identityStore: any CoreIdentityStoring
        private nonisolated let cancellationHandle = MobilebridgeCancellationHandle()
        private var core: MobilebridgeCore?
        private var coreParentDirectory: URL?
        private var deviceID: DeviceID?
        private var legacyRunning = false
        private var explicitSession: CoreExplicitSessionBinding?
        private var explicitSessionReceipt: CoreExplicitSessionReceipt?
        private var networkTransferBaseline: CoreNetworkTransferTotals?
        private var lastCompletedNetworkTotals: CoreNetworkTransferTotals?
        private var generation: UInt64 = 0

        init(identityStore: any CoreIdentityStoring) {
            self.identityStore = identityStore
        }

        private func preparedCore(
            configurationDirectory: URL,
            dataDirectory: URL
        ) throws -> MobilebridgeCore {
            let configurationDirectory = configurationDirectory.standardizedFileURL
            let dataDirectory = dataDirectory.standardizedFileURL
            let configurationParent = configurationDirectory.deletingLastPathComponent()
            let dataParent = dataDirectory.deletingLastPathComponent()
            guard configurationParent == dataParent,
                configurationDirectory.lastPathComponent == "Config",
                dataDirectory.lastPathComponent == "Data"
            else {
                throw CoreClientError.coreRejected("invalid_core_directories")
            }
            if let core {
                guard coreParentDirectory == configurationParent,
                    deviceID != nil
                else {
                    throw CoreClientError.coreRejected("invalid_core_directories")
                }
                return core
            }

            let storedIdentity = try identityStore.load()
            guard
                let creation = MobilebridgeNewCoreCreation(
                    configurationParent.path,
                    storedIdentity ?? Data()
                )
            else {
                throw CoreClientError.coreRejected("core_creation_failed")
            }
            let creationFailureCode = creation.failureCode()
            guard let candidate = creation.createdCore() else {
                throw CoreClientError.coreRejected(
                    Self.sanitizedCoreCreationFailureCode(creationFailureCode)
                )
            }
            guard creationFailureCode.isEmpty else {
                do {
                    try candidate.close()
                } catch {
                    throw CoreClientError.coreRejected("startup_cleanup_failed")
                }
                throw CoreClientError.invalidResponse("core_creation_result")
            }
            do {
                if storedIdentity == nil {
                    guard let generatedIdentity = candidate.identityBlob(),
                        !generatedIdentity.isEmpty
                    else {
                        throw CoreIdentityStoreError.emptyIdentity
                    }
                    try identityStore.saveIfAbsent(generatedIdentity)
                }
                let parsedDeviceID = try CoreSessionBridgeContract.validateCandidateDeviceID(
                    candidate.deviceID()
                )
                core = candidate
                coreParentDirectory = configurationParent
                deviceID = parsedDeviceID
                cancellationHandle.install(candidate)
                return candidate
            } catch {
                let failure = error
                do {
                    try candidate.close()
                } catch {
                    throw CoreClientError.coreRejected("startup_cleanup_failed")
                }
                throw failure
            }
        }

        private static func sanitizedCoreCreationFailureCode(_ code: String) -> String {
            switch code {
            case "core_in_use", "identity_rejected", "invalid_core_directories",
                "core_state_unavailable":
                code
            default:
                "core_creation_failed"
            }
        }

        private func openExplicitSession(
            configurationDirectory: URL,
            dataDirectory: URL,
            binding: CoreExplicitSessionBinding,
            command: String
        ) throws -> CoreExplicitSessionReceipt {
            guard !legacyRunning else {
                throw CoreClientError.coreRejected("session_conflict")
            }
            if let explicitSession {
                guard explicitSession == binding,
                    let explicitSessionReceipt
                else {
                    throw CoreClientError.coreRejected("session_conflict")
                }
                return explicitSessionReceipt
            }

            let candidate = try preparedCore(
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory
            )
            let requestID = UUID().uuidString.lowercased()
            let request = BridgeSessionCommandRequest.open(
                requestID: requestID,
                command: command,
                binding: binding
            )
            do {
                let requestText = try encodedBoundRequest(
                    request,
                    binding: binding,
                    folder: binding.folderID.map(CoreSessionRequestFolderBinding.exact) ?? .absent
                )
                let transferBaseline =
                    binding.mode != .configuration
                    ? try rawNetworkTransferTotals(using: candidate)
                    : nil
                let response = candidate.commandJSON(requestText)
                let validated = try CoreSessionBridgeContract.validateLifecycleResponse(
                    response,
                    requestID: requestID,
                    command: command,
                    lifecycle: .running,
                    binding: binding
                )
                guard let deviceID else {
                    throw CoreClientError.invalidResponse("session_device_id")
                }
                _ = try CoreSessionBridgeContract.validateCandidateDeviceID(
                    candidate.deviceID(),
                    expected: deviceID
                )
                let receipt = try CoreExplicitSessionReceipt(
                    binding: binding,
                    deviceID: deviceID,
                    generation: validated.generation,
                    configurationRevision: validated.configurationRevision
                )
                explicitSession = binding
                explicitSessionReceipt = receipt
                networkTransferBaseline = transferBaseline
                if binding.mode != .configuration { lastCompletedNetworkTotals = nil }
                return receipt
            } catch {
                let primary = error
                let cleanup = terminalDrainAndClose(candidate)
                if cleanup.stopFailed || cleanup.closeFailed {
                    throw CoreClientError.coreRejected("session_cleanup_failed")
                }
                throw primary
            }
        }

        private func encodedRequest<Request: Encodable>(_ request: Request) throws -> String {
            let data = try JSONEncoder().encode(request)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CoreClientError.invalidResponse("request_encoding")
            }
            return text
        }

        private func encodedBoundRequest<Request: Encodable>(
            _ request: Request,
            binding: CoreExplicitSessionBinding?,
            folder: CoreSessionRequestFolderBinding,
            commandConfigurationRevision: String? = nil
        ) throws -> String {
            let text = try encodedRequest(request)
            try CoreSessionBridgeContract.validateRequestBinding(
                text,
                binding: binding,
                folder: folder,
                commandConfigurationRevision: commandConfigurationRevision
            )
            return text
        }

        private func terminalDrainAndClose(
            _ candidate: MobilebridgeCore,
            networkBinding: CoreExplicitSessionBinding? = nil,
            networkBaseline: CoreNetworkTransferTotals? = nil
        ) -> (stopFailed: Bool, closeFailed: Bool, networkTotals: CoreNetworkTransferTotals?) {
            var stopFailed = false
            var closeFailed = false
            var networkTotals: CoreNetworkTransferTotals?
            do {
                try candidate.stop()
            } catch {
                stopFailed = true
            }
            if let networkBinding, let networkBaseline,
                let current = try? rawNetworkTransferTotals(using: candidate)
            {
                networkTotals = try? validatedNetworkSessionDelta(
                    current: current,
                    baseline: networkBaseline,
                    binding: networkBinding
                )
            }
            do {
                try candidate.close()
            } catch {
                closeFailed = true
            }
            clearCoreState(candidate)
            lastCompletedNetworkTotals = closeFailed ? nil : networkTotals
            return (stopFailed, closeFailed, lastCompletedNetworkTotals)
        }

        private func clearCoreState(_ candidate: MobilebridgeCore) {
            cancellationHandle.clear(candidate)
            if core === candidate { core = nil }
            coreParentDirectory = nil
            deviceID = nil
            legacyRunning = false
            explicitSession = nil
            explicitSessionReceipt = nil
            networkTransferBaseline = nil
        }

        func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
            guard explicitSession == nil else {
                throw CoreClientError.coreRejected("session_conflict")
            }
            let candidate = try preparedCore(
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory
            )
            guard let deviceID else {
                throw CoreClientError.invalidResponse("device_id")
            }
            if legacyRunning {
                return deviceID
            }
            do {
                let transferBaseline = try rawNetworkTransferTotals(using: candidate)
                try candidate.start()
                legacyRunning = true
                networkTransferBaseline = transferBaseline
                lastCompletedNetworkTotals = nil
                return deviceID
            } catch {
                let failure = error
                let cleanup = terminalDrainAndClose(candidate)
                if cleanup.stopFailed || cleanup.closeFailed {
                    throw CoreClientError.coreRejected("startup_cleanup_failed")
                }
                if let failure = failure as? CoreClientError { throw failure }
                throw CoreClientError.coreRejected("start_failed")
            }
        }

        func openConfigurationSession(
            configurationDirectory: URL,
            dataDirectory: URL,
            sessionID: UUID
        ) async throws -> CoreExplicitSessionReceipt {
            let binding = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
            return try openExplicitSession(
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory,
                binding: binding,
                command: "openConfiguration"
            )
        }

        func openNetworkSession(
            configurationDirectory: URL,
            dataDirectory: URL,
            sessionID: UUID,
            plan: CoreNetworkSessionPlan
        ) async throws -> CoreExplicitSessionReceipt {
            let binding = CoreExplicitSessionBinding.network(sessionID: sessionID, plan: plan)
            return try openExplicitSession(
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory,
                binding: binding,
                command: "openNetworkSession"
            )
        }

        func openPendingFolderObservationSession(
            configurationDirectory: URL,
            dataDirectory: URL,
            sessionID: UUID,
            plan: PendingFolderObservationPlan
        ) async throws -> CoreExplicitSessionReceipt {
            let binding = CoreExplicitSessionBinding.pendingFolderObservation(
                sessionID: sessionID,
                plan: plan
            )
            return try openExplicitSession(
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory,
                binding: binding,
                command: "openPendingFolderObservationSession"
            )
        }

        func capturePendingFolderObservation() async throws
            -> PendingFolderObservationCaptureReceipt
        {
            guard let core,
                let deviceID,
                let binding = explicitSession,
                binding.mode == .pendingFolderObservation
            else {
                throw CoreClientError.coreRejected("wrong_session_mode")
            }
            let requestID = UUID().uuidString.lowercased()
            let request = BridgeSessionCommandRequest.capture(
                requestID: requestID,
                command: "capturePendingFolderObservation",
                binding: binding
            )
            let response = core.commandJSON(
                try encodedBoundRequest(
                    request,
                    binding: binding,
                    folder: .exact(binding.folderID!)
                )
            )
            let capture =
                try CoreSessionBridgeContract
                .validatePendingFolderObservationCaptureResponse(
                    response,
                    requestID: requestID,
                    binding: binding
                )
            _ = try CoreSessionBridgeContract.validateCandidateDeviceID(
                core.deviceID(),
                expected: deviceID
            )
            explicitSessionReceipt = try CoreExplicitSessionReceipt(
                binding: binding,
                deviceID: deviceID,
                generation: capture.generation,
                configurationRevision: capture.configurationRevision
            )
            return capture
        }

        func openPendingFolderDiscoverySession(
            configurationDirectory: URL,
            dataDirectory: URL,
            sessionID: UUID,
            plan: PendingFolderDiscoveryPlan
        ) async throws -> CoreExplicitSessionReceipt {
            let binding = CoreExplicitSessionBinding.pendingFolderDiscovery(
                sessionID: sessionID,
                plan: plan
            )
            return try openExplicitSession(
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory,
                binding: binding,
                command: "openPendingFolderDiscoverySession"
            )
        }

        func capturePendingFolderDiscovery() async throws
            -> PendingFolderDiscoveryCaptureReceipt
        {
            guard let core,
                let deviceID,
                let binding = explicitSession,
                binding.mode == .pendingFolderDiscovery
            else {
                throw CoreClientError.coreRejected("wrong_session_mode")
            }
            let requestID = UUID().uuidString.lowercased()
            let request = BridgeSessionCommandRequest.capture(
                requestID: requestID,
                command: "capturePendingFolderDiscovery",
                binding: binding
            )
            let response = core.commandJSON(
                try encodedBoundRequest(
                    request,
                    binding: binding,
                    folder: .absent
                )
            )
            let capture =
                try CoreSessionBridgeContract
                .validatePendingFolderDiscoveryCaptureResponse(
                    response,
                    requestID: requestID,
                    binding: binding
                )
            _ = try CoreSessionBridgeContract.validateCandidateDeviceID(
                core.deviceID(),
                expected: deviceID
            )
            explicitSessionReceipt = try CoreExplicitSessionReceipt(
                binding: binding,
                deviceID: deviceID,
                generation: capture.generation,
                configurationRevision: capture.configurationRevision
            )
            return capture
        }

        func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
            guard let core,
                let deviceID,
                let binding = explicitSession,
                explicitSessionReceipt != nil
            else {
                throw CoreClientError.coreRejected("no_active_session")
            }
            let requestID = UUID().uuidString.lowercased()
            let request = BridgeSessionCommandRequest.close(
                requestID: requestID,
                binding: binding
            )
            do {
                let response = core.commandJSON(
                    try encodedBoundRequest(
                        request,
                        binding: binding,
                        folder: .absent
                    )
                )
                let validated = try CoreSessionBridgeContract.validateLifecycleResponse(
                    response,
                    requestID: requestID,
                    command: "closeSession",
                    lifecycle: .stopped,
                    binding: binding
                )
                let receipt = try CoreExplicitSessionReceipt(
                    binding: binding,
                    deviceID: deviceID,
                    generation: validated.generation,
                    configurationRevision: validated.configurationRevision
                )
                if binding.mode != .configuration {
                    guard let baseline = networkTransferBaseline else {
                        throw CoreClientError.invalidResponse("network_transfer_baseline")
                    }
                    let current = try rawNetworkTransferTotals(using: core)
                    lastCompletedNetworkTotals = try validatedNetworkSessionDelta(
                        current: current,
                        baseline: baseline,
                        binding: binding
                    )
                }
                // A lifecycle-stopped session is not a terminal Core close.
                // Every CoreRuntime entry point creates a fresh client, so
                // retaining this adapter's process-global gomobile singleton
                // here would make the next owner fail NewCore with core-in-use.
                let cleanup = terminalDrainAndClose(
                    core,
                    networkBinding: binding.mode != .configuration ? binding : nil,
                    networkBaseline: binding.mode != .configuration
                        ? networkTransferBaseline : nil
                )
                guard !cleanup.closeFailed else {
                    throw CoreClientError.coreRejected("session_cleanup_failed")
                }
                return receipt
            } catch {
                let primary = error
                let cleanup = terminalDrainAndClose(
                    core,
                    networkBinding: binding.mode != .configuration ? binding : nil,
                    networkBaseline: binding.mode != .configuration
                        ? networkTransferBaseline : nil
                )
                // Stop may report the strict final counter reconciliation
                // failure after native I/O is already drained. A successful
                // terminal Close proves the singleton was released.
                if cleanup.closeFailed {
                    throw CoreClientError.coreRejected("session_cleanup_failed")
                }
                throw primary
            }
        }

        func stop() async throws {
            guard let core else { return }
            let wasMeasuringNetwork = networkTransferBaseline != nil
            let measuringBinding = explicitSession
            var stopFailed = false
            var closeFailed = false
            var stoppedTotals: CoreNetworkTransferTotals?
            do {
                try core.stop()
            } catch {
                stopFailed = true
            }
            if let baseline = networkTransferBaseline,
                let current = try? rawNetworkTransferTotals(using: core)
            {
                if let measuringBinding, measuringBinding.mode != .configuration {
                    stoppedTotals = try? validatedNetworkSessionDelta(
                        current: current,
                        baseline: baseline,
                        binding: measuringBinding
                    )
                } else {
                    stoppedTotals = current.delta(since: baseline)
                }
            }
            do {
                try core.close()
            } catch {
                closeFailed = true
            }
            clearCoreState(core)
            if wasMeasuringNetwork {
                lastCompletedNetworkTotals = closeFailed ? nil : stoppedTotals
            }
            if closeFailed { throw CoreClientError.coreRejected("close_failed") }
            if stopFailed { throw CoreClientError.coreRejected("stop_failed") }
        }

        nonisolated func requestCancellation() {
            cancellationHandle.requestCancellation()
        }

        func networkTransferTotals() async throws -> CoreNetworkTransferTotals? {
            guard let core else { return lastCompletedNetworkTotals }
            if explicitSession?.mode == .configuration { return nil }
            if !legacyRunning, explicitSession == nil { return lastCompletedNetworkTotals }
            guard let baseline = networkTransferBaseline else {
                throw CoreClientError.invalidResponse("network_transfer_baseline")
            }
            let current = try rawNetworkTransferTotals(using: core)
            if let binding = explicitSession, binding.mode != .configuration {
                return try validatedNetworkSessionDelta(
                    current: current,
                    baseline: baseline,
                    binding: binding
                )
            }
            guard let delta = current.delta(since: baseline), delta.totalBytes != nil else {
                throw CoreClientError.invalidResponse("network_transfer_counter")
            }
            return delta
        }

        func snapshot() async throws -> CoreSnapshot {
            guard let core, legacyRunning || explicitSession != nil else {
                throw CoreClientError.notRunning
            }
            for _ in 0..<Self.maximumSnapshotAttempts {
                do {
                    return try snapshotAttempt(using: core)
                } catch BridgeQueryRestart.consistencyChanged {
                    continue
                }
            }
            throw CoreClientError.invalidResponse("query_consistency")
        }

        func readRange(_ request: CoreReadRangeRequest) async throws -> Data {
            guard let core else { throw CoreClientError.notRunning }
            guard explicitSession?.mode != .pendingFolderObservation,
                explicitSession?.mode != .pendingFolderDiscovery
            else {
                throw CoreClientError.coreRejected("wrong_session_mode")
            }
            guard request.offset >= 0,
                (0...Self.maximumReadRangeLength).contains(request.length)
            else {
                throw CoreClientError.coreRejected("invalid_range")
            }
            guard request.contentVersion.count == 32 else {
                throw CoreClientError.coreRejected("invalid_base_version")
            }
            guard !request.itemID.isEmpty else {
                throw CoreClientError.coreRejected("invalid_item_id")
            }

            let bridgeRequest = BridgeReadRangeRequest(
                schemaVersion: 1,
                requestID: UUID().uuidString.lowercased(),
                sessionID: explicitSession?.sessionIDString,
                taskID: explicitSession?.taskIDString,
                planDigest: explicitSession?.planDigest,
                expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                networkOperation: explicitSession?.networkOperation?.rawValue,
                folderID: request.folderID.rawValue,
                itemID: request.itemID,
                path: request.relativePath,
                contentVersion: request.contentVersion,
                offset: request.offset,
                length: request.length
            )
            let requestText = try encodedBoundRequest(
                bridgeRequest,
                binding: explicitSession,
                folder: .exact(request.folderID)
            )
            let response = core.readRangeJSON(requestText)
            let envelope: BridgeEnvelope<BridgeReadRangePayload> = try decodeEnvelope(
                response,
                expectedRequestID: bridgeRequest.requestID,
                expectedKind: "readRange"
            )
            guard let payload = envelope.payload, payload.data.count == request.length else {
                throw CoreClientError.invalidResponse("read_range_payload")
            }
            return payload.data
        }

        private func snapshotAttempt(using core: MobilebridgeCore) throws -> CoreSnapshot {
            let requestID = UUID().uuidString.lowercased()
            let request = try JSONEncoder().encode(
                BridgeSnapshotRequest(schemaVersion: 1, requestID: requestID)
            )
            guard let requestText = String(data: request, encoding: .utf8) else {
                throw CoreClientError.invalidResponse("request_encoding")
            }
            let response = core.snapshotJSON(requestText)
            guard let expectedDeviceID = deviceID else {
                throw CoreClientError.invalidResponse("snapshot_device_id")
            }
            try CoreSessionBridgeContract.validateSnapshotResponse(
                response,
                requestID: requestID,
                binding: explicitSession,
                expectedDeviceID: expectedDeviceID
            )
            let envelope: BridgeEnvelope<BridgeSnapshotPayload> = try decodeEnvelope(
                response,
                expectedRequestID: requestID,
                expectedKind: "snapshot"
            )
            guard let payload = envelope.payload,
                let localDeviceID = DeviceID(rawValue: payload.deviceID)
            else {
                throw CoreClientError.invalidResponse("snapshot_payload")
            }
            guard localDeviceID == deviceID else {
                throw CoreClientError.invalidResponse("snapshot_device_id")
            }
            try validateSnapshotSession(payload, localDeviceID: localDeviceID)

            let devices = try payload.devices.map { try $0.record() }
            let configuredDeviceIDs = Set(devices.map(\.id))
            guard configuredDeviceIDs.count == devices.count,
                configuredDeviceIDs.contains(localDeviceID)
            else {
                throw CoreClientError.invalidResponse("snapshot_device_identity")
            }
            let bridgeFolderIDs = try payload.folders.map { folder -> FolderID in
                guard let folderID = FolderID(rawValue: folder.folderID) else {
                    throw CoreClientError.invalidResponse("folder_id")
                }
                return folderID
            }
            guard Set(bridgeFolderIDs).count == bridgeFolderIDs.count else {
                throw CoreClientError.invalidResponse("folder_id")
            }
            let folders = try zip(payload.folders, bridgeFolderIDs).map { bridge, folderID in
                try bridge.record(
                    localDeviceID: localDeviceID,
                    configuredDeviceIDs: configuredDeviceIDs,
                    runtimeStatusAvailable: CoreSessionSnapshotScope.hasRuntimeStatus(
                        folderID: folderID,
                        binding: explicitSession
                    )
                )
            }
            let pendingDevices = try payload.pendingDevices.map { try $0.record() }
            let pendingFolders = try payload.pendingFolders.map { try $0.record() }
            let suppressedPendingDevices = try (payload.suppressedPendingDevices ?? []).map {
                try $0.record()
            }
            let suppressedPendingFolders = try (payload.suppressedPendingFolders ?? []).map {
                try $0.record()
            }
            let suppressedPendingStateAvailable = payload.suppressedPendingStateAvailable ?? false
            let suppressedPendingDevicesTruncated = payload.suppressedPendingDevicesTruncated ?? false
            let suppressedPendingFoldersTruncated = payload.suppressedPendingFoldersTruncated ?? false
            let pendingDeviceObservationScope: PendingDeviceObservationScope
            if let parsed = PendingDeviceObservationScope(
                rawValue: payload.pendingDeviceObservationScope
            ) {
                pendingDeviceObservationScope = parsed
            } else if explicitSession?.mode == .configuration,
                payload.pendingDeviceObservationScope == "unavailable_in_configuration_session"
            {
                pendingDeviceObservationScope = .unavailable
            } else {
                throw CoreClientError.invalidResponse("pending_device_scope")
            }
            guard pendingDeviceObservationScope != .unavailable || pendingDevices.isEmpty else {
                throw CoreClientError.invalidResponse("pending_device_availability")
            }
            guard payload.pendingFoldersAvailable || (pendingFolders.isEmpty && !payload.pendingFoldersTruncated) else {
                throw CoreClientError.invalidResponse("pending_folder_availability")
            }
            guard pendingDevices.count <= 512,
                Set(pendingDevices.map(\.deviceID)).count == pendingDevices.count,
                pendingDevices.allSatisfy({
                    $0.deviceID != localDeviceID && !configuredDeviceIDs.contains($0.deviceID)
                })
            else {
                throw CoreClientError.invalidResponse("pending_device_identity")
            }
            guard pendingFolders.count <= 512,
                Set(pendingFolders.map(\.id)).count == pendingFolders.count,
                pendingFolders.allSatisfy({
                    $0.offeringDeviceID != localDeviceID
                        && configuredDeviceIDs.contains($0.offeringDeviceID)
                }),
                explicitSession?.mode == nil
                    || explicitSession?.mode == .configuration
                    || explicitSession?.mode == .pendingFolderDiscovery
                    || pendingFolders.allSatisfy({ $0.folderID == explicitSession?.folderID }),
                explicitSession?.mode != .pendingFolderDiscovery
                    || pendingFolders.allSatisfy({
                        $0.offeringDeviceID == explicitSession?.offeringDeviceID
                    })
            else {
                throw CoreClientError.invalidResponse("pending_folder_identity")
            }
            guard
                suppressedPendingStateAvailable
                    || (suppressedPendingDevices.isEmpty
                        && suppressedPendingFolders.isEmpty
                        && !suppressedPendingDevicesTruncated
                        && !suppressedPendingFoldersTruncated)
            else {
                throw CoreClientError.invalidResponse("suppressed_pending_availability")
            }
            let suppressedDeviceIDs = Set(suppressedPendingDevices.map(\.deviceID))
            guard suppressedPendingDevices.count <= 512,
                suppressedDeviceIDs.count == suppressedPendingDevices.count,
                suppressedPendingDevices.allSatisfy({
                    $0.deviceID != localDeviceID && !configuredDeviceIDs.contains($0.deviceID)
                }),
                Set(pendingDevices.map(\.deviceID)).isDisjoint(with: suppressedDeviceIDs)
            else {
                throw CoreClientError.invalidResponse("suppressed_pending_device_identity")
            }
            let suppressedFolderIDs = Set(suppressedPendingFolders.map(\.id))
            guard suppressedPendingFolders.count <= 512,
                suppressedFolderIDs.count == suppressedPendingFolders.count,
                suppressedPendingFolders.allSatisfy({
                    $0.offeringDeviceID != localDeviceID
                        && configuredDeviceIDs.contains($0.offeringDeviceID)
                }),
                suppressedPendingFolders.allSatisfy({ suppressed in
                    !pendingFolders.contains(where: {
                        $0.folderID == suppressed.folderID
                            && $0.offeringDeviceID == suppressed.offeringDeviceID
                    })
                })
            else {
                throw CoreClientError.invalidResponse("suppressed_pending_folder_identity")
            }
            var bridgeItems: [BridgeItem] = []
            let queriedFolderIDs = try CoreSessionSnapshotScope.itemFolderIDs(
                configuredFolderIDs: bridgeFolderIDs,
                binding: explicitSession
            )
            for folderID in queriedFolderIDs {
                bridgeItems.append(
                    contentsOf: try queryFolderItems(
                        folderID: folderID.rawValue,
                        expectedGeneration: payload.generation,
                        using: core
                    )
                )
            }

            let snapshotGeneration = try nextGeneration(upstream: payload.generation)
            let (items, tombstones) = try Self.records(
                from: bridgeItems,
                generation: snapshotGeneration
            )
            guard let generatedAt = Self.bridgeDate(payload.generatedAt) else {
                throw CoreClientError.invalidResponse("snapshot_timestamp")
            }
            return CoreSnapshot(
                generation: snapshotGeneration,
                generatedAt: generatedAt,
                configurationRevision: payload.configurationRevision,
                localDeviceID: localDeviceID,
                devices: devices,
                folders: folders,
                items: items,
                tombstones: tombstones,
                pendingDevices: pendingDevices,
                pendingFolders: pendingFolders,
                pendingDeviceObservationScope: pendingDeviceObservationScope,
                pendingFoldersAvailable: payload.pendingFoldersAvailable,
                pendingFoldersTruncated: payload.pendingFoldersTruncated,
                suppressedPendingDevices: suppressedPendingDevices,
                suppressedPendingFolders: suppressedPendingFolders,
                suppressedPendingStateAvailable: suppressedPendingStateAvailable,
                suppressedPendingDevicesTruncated: suppressedPendingDevicesTruncated,
                suppressedPendingFoldersTruncated: suppressedPendingFoldersTruncated
            )
        }

        private func validateSnapshotSession(
            _ payload: BridgeSnapshotPayload,
            localDeviceID: DeviceID
        ) throws {
            guard payload.lifecycle == "running", payload.running else {
                throw CoreClientError.invalidResponse("snapshot_lifecycle")
            }
            guard let binding = explicitSession else {
                guard payload.session == nil else {
                    throw CoreClientError.invalidResponse("snapshot_session")
                }
                return
            }
            guard let session = payload.session,
                session.matches(binding),
                payload.generation > 0,
                let revision = payload.configurationRevision,
                Self.isLowercaseSHA256Hex(revision),
                binding.mode == .configuration
                    || revision == binding.expectedConfigurationRevision
            else {
                throw CoreClientError.invalidResponse("snapshot_session")
            }
            explicitSessionReceipt = try CoreExplicitSessionReceipt(
                binding: binding,
                deviceID: localDeviceID,
                generation: payload.generation,
                configurationRevision: revision
            )
        }

        private func rawNetworkTransferTotals(
            using core: MobilebridgeCore
        ) throws -> CoreNetworkTransferTotals {
            let requestID = UUID().uuidString.lowercased()
            let request = try JSONEncoder().encode(
                BridgeSnapshotRequest(schemaVersion: 1, requestID: requestID)
            )
            guard let requestText = String(data: request, encoding: .utf8) else {
                throw CoreClientError.invalidResponse("request_encoding")
            }
            let response = core.networkTransferTotalsJSON(requestText)
            let envelope: BridgeEnvelope<BridgeNetworkTransferTotalsPayload> = try decodeEnvelope(
                response,
                expectedRequestID: requestID,
                expectedKind: "networkTransferTotals"
            )
            guard let payload = envelope.payload,
                payload.receivedBytes >= 0,
                payload.sentBytes >= 0
            else {
                throw CoreClientError.invalidResponse("network_transfer_payload")
            }
            let totals = CoreNetworkTransferTotals(
                receivedBytes: payload.receivedBytes,
                sentBytes: payload.sentBytes,
                budgetLimited: payload.budgetLimited,
                budgetLimitBytes: payload.budgetLimitBytes,
                budgetUsedBytes: payload.budgetUsedBytes,
                budgetExhausted: payload.budgetExhausted
            )
            guard totals.totalBytes != nil, totals.hasCoherentBudgetState else {
                throw CoreClientError.invalidResponse("network_transfer_overflow")
            }
            return totals
        }

        private func validatedNetworkSessionDelta(
            current: CoreNetworkTransferTotals,
            baseline: CoreNetworkTransferTotals,
            binding: CoreExplicitSessionBinding
        ) throws -> CoreNetworkTransferTotals {
            guard binding.mode != .configuration,
                let maximumNetworkBytes = binding.maximumNetworkBytes,
                let delta = current.delta(since: baseline),
                delta.matchesNetworkSessionBudget(
                    maximumNetworkBytes: maximumNetworkBytes
                )
            else {
                throw CoreClientError.invalidResponse("network_transfer_counter")
            }
            return delta
        }

        private func queryFolderItems(
            folderID: String,
            expectedGeneration: UInt64,
            using core: MobilebridgeCore
        ) throws -> [BridgeItem] {
            var cursor: String?
            var changeCursor: String?
            var requestedCursors: Set<String> = []
            var items: [BridgeItem] = []

            while true {
                let cursorKey = cursor ?? ""
                guard requestedCursors.insert(cursorKey).inserted else {
                    throw CoreClientError.invalidResponse("query_cursor_cycle")
                }
                let request = BridgeItemsQueryRequest(
                    schemaVersion: 1,
                    requestID: UUID().uuidString.lowercased(),
                    sessionID: explicitSession?.sessionIDString,
                    taskID: explicitSession?.taskIDString,
                    planDigest: explicitSession?.planDigest,
                    expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                    maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                    networkOperation: explicitSession?.networkOperation?.rawValue,
                    query: "items",
                    folderID: folderID,
                    scope: "global",
                    cursor: cursor,
                    limit: 200,
                    includeDeleted: true
                )
                guard let typedFolderID = FolderID(rawValue: folderID) else {
                    throw CoreClientError.invalidResponse("folder_id")
                }
                let requestText = try encodedBoundRequest(
                    request,
                    binding: explicitSession,
                    folder: .exact(typedFolderID)
                )
                let response = core.queryJSON(requestText)
                let envelope: BridgeEnvelope<BridgeItemsQueryPayload> = try decodeEnvelope(
                    response,
                    expectedRequestID: request.requestID,
                    expectedKind: "query"
                )
                guard let payload = envelope.payload,
                    payload.query == "items",
                    payload.folderID == folderID,
                    payload.scope == "global",
                    !payload.changeCursor.isEmpty,
                    !payload.cursorConsistency.isEmpty
                else {
                    throw CoreClientError.invalidResponse("query_payload")
                }
                guard payload.generation == expectedGeneration else {
                    throw BridgeQueryRestart.consistencyChanged
                }
                if let changeCursor {
                    guard payload.changeCursor == changeCursor else {
                        throw BridgeQueryRestart.consistencyChanged
                    }
                } else {
                    changeCursor = payload.changeCursor
                }
                guard
                    payload.items.allSatisfy({ item in
                        item.folderID == folderID
                            && item.generation == payload.generation
                            && item.changeCursor == payload.changeCursor
                            && item.source == "global"
                    })
                else {
                    throw CoreClientError.invalidResponse("query_item_identity")
                }
                items.append(contentsOf: payload.items)

                if payload.scanLimited, !payload.hasMore {
                    throw CoreClientError.invalidResponse("query_scan_limit")
                }
                guard payload.hasMore else { return items }
                guard let nextCursor = payload.nextCursor,
                    !nextCursor.isEmpty,
                    nextCursor != cursor
                else {
                    throw CoreClientError.invalidResponse("query_next_cursor")
                }
                cursor = nextCursor
            }
        }

        private func nextGeneration(upstream: UInt64) throws -> UInt64 {
            guard upstream <= Self.maximumPersistableGeneration else {
                throw CoreClientError.invalidResponse("generation_range")
            }
            if upstream > generation {
                generation = upstream
                return generation
            }
            guard generation < Self.maximumPersistableGeneration else {
                throw CoreClientError.invalidResponse("generation_exhausted")
            }
            generation += 1
            return generation
        }

        func execute(_ command: CoreCommand) async throws {
            guard let core, legacyRunning || explicitSession != nil else {
                throw CoreClientError.notRunning
            }
            guard explicitSession?.mode != .pendingFolderObservation,
                explicitSession?.mode != .pendingFolderDiscovery
            else {
                throw CoreClientError.coreRejected("wrong_session_mode")
            }
            let commandConfigurationRevision =
                try CoreSessionBridgeContract
                .commandConfigurationRevision(for: command, binding: explicitSession)
            let request = BridgeCommandRequest(
                schemaVersion: 1,
                requestID: command.id.uuidString.lowercased(),
                command: command.kind.rawValue,
                sessionID: explicitSession?.sessionIDString,
                taskID: explicitSession?.taskIDString,
                planDigest: explicitSession?.planDigest,
                expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                networkOperation: explicitSession?.networkOperation?.rawValue,
                commandConfigurationRevision: commandConfigurationRevision,
                folderID: command.folderID?.rawValue,
                itemID: command.itemID,
                arguments: command.arguments
            )
            let requestFolderBinding: CoreSessionRequestFolderBinding
            if let target = explicitSession?.folderID {
                requestFolderBinding = .ifPresentMatches(target)
            } else {
                requestFolderBinding = .unconstrained
            }
            let requestText = try encodedBoundRequest(
                request,
                binding: explicitSession,
                folder: requestFolderBinding,
                commandConfigurationRevision: commandConfigurationRevision
            )
            let response = core.commandJSON(requestText)
            let envelope: BridgeEnvelope<BridgeCommandPayload> = try decodeEnvelope(
                response,
                expectedRequestID: request.requestID,
                expectedKind: "command",
                expectsMutationFailureMetadata: command.isFileProviderMutation,
                recoveryErrorCodesOnly: command.isCoreMutationRecoveryDisposal
            )
            if explicitSession != nil {
                guard let payload = envelope.payload,
                    payload.command == command.kind.rawValue,
                    payload.lifecycle == "running",
                    payload.generation.map({ $0 > 0 }) == true,
                    payload.configurationRevision.map(Self.isLowercaseSHA256Hex) == true
                else {
                    throw CoreClientError.invalidResponse("command_session_payload")
                }
                // A durable ledger replay can legitimately return the business
                // response produced by an older explicit session. It contains
                // no ephemeral binding by contract, and its historical revision
                // is not authoritative for the currently open session. Refresh
                // configuration-session state from the live snapshot instead.
                if explicitSession?.mode == .configuration {
                    _ = try snapshotAttempt(using: core)
                }
            }
            if command.isCoreMutationRecoveryDisposal {
                guard let payload = envelope.payload,
                    payload.command == command.kind.rawValue,
                    payload.lifecycle == "running",
                    payload.disposition == "disposed",
                    payload.recoveryID == command.arguments["recoveryID"],
                    payload.receiptHash.map(Self.isLowercaseSHA256Hex) == true
                else {
                    throw CoreClientError.invalidResponse("recovery_disposition")
                }
            }
        }

        func mutationRecoveries(after cursor: String?, limit: Int) async throws
            -> CoreMutationRecoveryPage
        {
            guard let core else { throw CoreClientError.notRunning }
            guard explicitSession?.mode != .pendingFolderObservation,
                explicitSession?.mode != .pendingFolderDiscovery
            else {
                throw CoreClientError.coreRejected("wrong_session_mode")
            }
            let request: CoreMutationRecoveryQueryRequest
            do {
                request = try CoreMutationRecoveryQueryRequest(
                    requestID: UUID().uuidString.lowercased(),
                    cursor: cursor,
                    limit: limit
                )
            } catch {
                throw CoreClientError.coreRejected("invalid_query")
            }
            let bridgeRequest = BridgeRecoveryQueryRequest(
                schemaVersion: request.schemaVersion,
                requestID: request.requestID,
                sessionID: explicitSession?.sessionIDString,
                taskID: explicitSession?.taskIDString,
                planDigest: explicitSession?.planDigest,
                expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                networkOperation: explicitSession?.networkOperation?.rawValue,
                query: request.query,
                cursor: request.cursor,
                limit: request.limit
            )
            let requestText = try encodedBoundRequest(
                bridgeRequest,
                binding: explicitSession,
                folder: .absent
            )
            let response = core.queryJSON(requestText)
            let envelope: BridgeEnvelope<BridgeRecoveryQueryPayload> = try decodeEnvelope(
                response,
                expectedRequestID: bridgeRequest.requestID,
                expectedKind: "query",
                recoveryErrorCodesOnly: true
            )
            guard let payload = envelope.payload, payload.query == "recoveries" else {
                throw CoreClientError.invalidResponse("recovery_query_payload")
            }
            let recoveries: [CoreMutationRecoverySummary]
            do {
                recoveries = try payload.recoveries.map { try $0.summary() }
                if payload.hasMore, payload.nextCursor == cursor {
                    throw CoreMutationRecoveryValidationError.invalidPage
                }
                return try CoreMutationRecoveryPage(
                    recoveries: recoveries,
                    nextCursor: payload.nextCursor,
                    hasMore: payload.hasMore
                )
            } catch {
                throw CoreClientError.invalidResponse("recovery_query_payload")
            }
        }

        func exportMutationRecovery(
            _ summary: CoreMutationRecoverySummary,
            exportID: UUID,
            outputName: String
        ) async throws {
            guard let core else { throw CoreClientError.notRunning }
            let arguments: [String: String]
            do {
                arguments = try CoreMutationRecoveryExportBuilder.arguments(
                    for: summary,
                    exportID: exportID,
                    outputName: outputName
                )
            } catch {
                throw CoreClientError.coreRejected("invalid_recovery_export")
            }
            let request = BridgeCommandRequest(
                schemaVersion: 1,
                requestID: exportID.uuidString.lowercased(),
                command: "exportRecovery",
                sessionID: explicitSession?.sessionIDString,
                taskID: explicitSession?.taskIDString,
                planDigest: explicitSession?.planDigest,
                expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                networkOperation: explicitSession?.networkOperation?.rawValue,
                commandConfigurationRevision: nil,
                folderID: nil,
                itemID: nil,
                arguments: arguments
            )
            let requestText = try encodedBoundRequest(
                request,
                binding: explicitSession,
                folder: .absent
            )
            let response = core.commandJSON(requestText)
            let envelope: BridgeEnvelope<BridgeCommandPayload> = try decodeEnvelope(
                response,
                expectedRequestID: request.requestID,
                expectedKind: "command",
                recoveryErrorCodesOnly: true
            )
            guard let payload = envelope.payload,
                payload.command == request.command,
                payload.lifecycle == "running",
                payload.generation.map({ $0 > 0 }) == true,
                payload.configurationRevision.map(Self.isLowercaseSHA256Hex) == true,
                payload.disposition == "exported",
                payload.recoveryID == summary.recoveryID,
                payload.receiptHash.map(Self.isLowercaseSHA256Hex) == true
            else {
                throw CoreClientError.invalidResponse("recovery_export_receipt")
            }
        }

        func discardMutationRecoveryExport(_ exportID: UUID, requestID: UUID) async throws {
            guard let core else { throw CoreClientError.notRunning }
            let requestIDText = requestID.uuidString.lowercased()
            let exportIDText = exportID.uuidString.lowercased()
            let request = BridgeCommandRequest(
                schemaVersion: 1,
                requestID: requestIDText,
                command: "discardRecoveryExport",
                sessionID: explicitSession?.sessionIDString,
                taskID: explicitSession?.taskIDString,
                planDigest: explicitSession?.planDigest,
                expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                networkOperation: explicitSession?.networkOperation?.rawValue,
                commandConfigurationRevision: nil,
                folderID: nil,
                itemID: nil,
                arguments: ["exportID": exportIDText]
            )
            let requestText = try encodedBoundRequest(
                request,
                binding: explicitSession,
                folder: .absent
            )
            let response = core.commandJSON(requestText)
            let envelope: BridgeEnvelope<BridgeCommandPayload> = try decodeEnvelope(
                response,
                expectedRequestID: request.requestID,
                expectedKind: "command",
                recoveryErrorCodesOnly: true
            )
            guard let payload = envelope.payload,
                payload.command == request.command,
                payload.lifecycle == "running",
                payload.generation.map({ $0 > 0 }) == true,
                payload.configurationRevision.map(Self.isLowercaseSHA256Hex) == true,
                payload.disposition == "discarded",
                payload.recoveryID == exportIDText,
                payload.receiptHash.map(Self.isLowercaseSHA256Hex) == true
            else {
                throw CoreClientError.invalidResponse("recovery_export_cleanup_receipt")
            }
        }

        func acknowledgeCommand(_ id: UUID) async throws {
            guard let core else { throw CoreClientError.notRunning }
            let requestID = id.uuidString.lowercased()
            let response = core.acknowledgeCommand(requestID)
            let envelope: BridgeEnvelope<BridgeCommandAcknowledgementPayload> = try decodeEnvelope(
                response,
                expectedRequestID: requestID,
                expectedKind: "commandAcknowledgement"
            )
            guard envelope.payload?.acknowledged == true else {
                throw CoreClientError.invalidResponse("command_acknowledgement")
            }
        }

        func acknowledgeReconciledCommand(
            _ command: CoreCommand,
            proof: CoreMutationReconciliationProof
        ) async throws {
            guard command.isFileProviderMutation,
                proof.snapshotGeneration > 0,
                proof.ownerEpoch > 0,
                proof.stateDigest.count == 32
            else {
                throw CoreClientError.invalidResponse("reconciliation_proof")
            }
            try acknowledgeReconciledCommand(
                command,
                proofKind: CoreMutationReconciliationProof.kind,
                snapshotGeneration: proof.snapshotGeneration,
                ownerEpoch: proof.ownerEpoch,
                stateDigest: proof.stateDigest
            )
        }

        func acknowledgeReconciledConfigurationCommand(
            _ command: CoreCommand,
            proof: CoreConfigurationReconciliationProof
        ) async throws {
            guard command.isConfigurationReconciliationCommand,
                proof.snapshotGeneration > 0,
                proof.ownerEpoch > 0,
                proof.stateDigest.count == 32
            else {
                throw CoreClientError.invalidResponse("configuration_reconciliation_proof")
            }
            try acknowledgeReconciledCommand(
                command,
                proofKind: CoreConfigurationReconciliationProof.kind,
                snapshotGeneration: proof.snapshotGeneration,
                ownerEpoch: proof.ownerEpoch,
                stateDigest: proof.stateDigest
            )
        }

        private func acknowledgeReconciledCommand(
            _ command: CoreCommand,
            proofKind: String,
            snapshotGeneration: UInt64,
            ownerEpoch: UInt64,
            stateDigest: Data
        ) throws {
            guard let core else { throw CoreClientError.notRunning }
            let commandConfigurationRevision =
                try CoreSessionBridgeContract
                .commandConfigurationRevision(for: command, binding: explicitSession)
            let commandRequest = BridgeCommandRequest(
                schemaVersion: 1,
                requestID: command.id.uuidString.lowercased(),
                command: command.kind.rawValue,
                sessionID: explicitSession?.sessionIDString,
                taskID: explicitSession?.taskIDString,
                planDigest: explicitSession?.planDigest,
                expectedConfigurationRevision: explicitSession?.expectedConfigurationRevision,
                maximumNetworkBytes: explicitSession?.maximumNetworkBytes,
                networkOperation: explicitSession?.networkOperation?.rawValue,
                commandConfigurationRevision: commandConfigurationRevision,
                folderID: command.folderID?.rawValue,
                itemID: command.itemID,
                arguments: command.arguments
            )
            let commandFolderBinding: CoreSessionRequestFolderBinding
            if let target = explicitSession?.folderID {
                commandFolderBinding = .ifPresentMatches(target)
            } else {
                commandFolderBinding = .unconstrained
            }
            _ = try encodedBoundRequest(
                commandRequest,
                binding: explicitSession,
                folder: commandFolderBinding,
                commandConfigurationRevision: commandConfigurationRevision
            )
            let request = BridgeReconciledCommandAcknowledgementRequest(
                schemaVersion: 1,
                requestID: commandRequest.requestID,
                command: commandRequest,
                proof: .init(
                    kind: proofKind,
                    snapshotGeneration: snapshotGeneration,
                    ownerEpoch: ownerEpoch,
                    stateDigest: stateDigest.map { String(format: "%02x", $0) }.joined()
                )
            )
            let data = try JSONEncoder().encode(request)
            guard let requestText = String(data: data, encoding: .utf8) else {
                throw CoreClientError.invalidResponse("request_encoding")
            }
            let response = core.acknowledgeReconciledCommandJSON(requestText)
            let envelope: BridgeEnvelope<BridgeReconciledCommandAcknowledgementPayload> =
                try decodeEnvelope(
                    response,
                    expectedRequestID: request.requestID,
                    expectedKind: "reconciledCommandAcknowledgement"
                )
            guard envelope.payload?.acknowledged == true,
                envelope.payload.map({ Self.isLowercaseSHA256Hex($0.proofReceipt) }) == true
            else {
                throw CoreClientError.invalidResponse("reconciled_command_acknowledgement")
            }
        }

        private func decodeEnvelope<Payload: Decodable>(
            _ response: String,
            expectedRequestID: String,
            expectedKind: String,
            expectsMutationFailureMetadata: Bool = false,
            recoveryErrorCodesOnly: Bool = false
        ) throws -> BridgeEnvelope<Payload> {
            guard let data = response.data(using: .utf8) else {
                throw CoreClientError.invalidResponse("response_encoding")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope: BridgeEnvelope<Payload>
            do {
                envelope = try decoder.decode(BridgeEnvelope<Payload>.self, from: data)
            } catch {
                throw CoreClientError.invalidResponse("envelope")
            }
            guard envelope.schemaVersion == 1,
                envelope.requestID == expectedRequestID,
                envelope.kind == expectedKind
            else {
                throw CoreClientError.invalidResponse("envelope_identity")
            }
            guard envelope.ok else {
                let code: String
                if recoveryErrorCodesOnly {
                    guard
                        let validated = envelope.error.flatMap({
                            CoreMutationRecoveryStableCode.validated($0.code)
                        })
                    else {
                        throw CoreClientError.invalidResponse("recovery_error_code")
                    }
                    code = validated
                } else {
                    code =
                        envelope.error.flatMap { error in
                            if error.code
                                == CoreBridgeFailureClassifier.networkByteLimitReachedCode
                            {
                                return CoreBridgeFailureClassifier.validatedOperationalCode(
                                    error.code,
                                    responseKind: expectedKind
                                )
                            }
                            return Self.safeBridgeCode(error.code)
                        } ?? "unknown_core_error"
                }
                throw CoreBridgeFailureClassifier.failure(
                    code: code,
                    mutationPhase: envelope.error?.mutationPhase,
                    mutationAmbiguous: envelope.error?.mutationAmbiguous,
                    expectsMutationMetadata: expectsMutationFailureMetadata
                )
            }
            return envelope
        }

        private static func records(
            from bridgeItems: [BridgeItem],
            generation: UInt64
        ) throws -> ([IndexedItem], [IndexTombstone]) {
            var seenItemIDs: Set<String> = []
            var seenPaths: Set<String> = []
            var items: [IndexedItem] = []
            var tombstones: [IndexTombstone] = []
            items.reserveCapacity(bridgeItems.count)

            for bridgeItem in bridgeItems {
                guard Self.isSafeItemID(bridgeItem.itemID),
                    let folderID = FolderID(rawValue: bridgeItem.folderID),
                    Self.isSafeRelativePath(bridgeItem.relativePath),
                    bridgeItem.name == bridgeItem.relativePath.split(separator: "/").last.map(String.init),
                    bridgeItem.parentID?.isEmpty != true,
                    bridgeItem.parentID != bridgeItem.itemID,
                    bridgeItem.size >= 0,
                    bridgeItem.remoteReplicaCount >= 0,
                    bridgeItem.remoteReplicaCount >= (bridgeItem.connectedRemoteDeviceIDs?.count ?? 0),
                    seenItemIDs.insert(bridgeItem.itemID).inserted,
                    seenPaths.insert(folderID.rawValue + "\u{0}" + bridgeItem.relativePath).inserted
                else {
                    throw CoreClientError.invalidResponse("query_item")
                }

                if bridgeItem.tombstone {
                    tombstones.append(
                        IndexTombstone(itemID: bridgeItem.itemID, generation: generation)
                    )
                    continue
                }
                guard bridgeItem.contentVersion.count == 32,
                    bridgeItem.metadataVersion.count == 32,
                    let modifiedAt = Self.bridgeDate(bridgeItem.modifiedAt),
                    let declaredAvailability = FileAvailability(rawValue: bridgeItem.availability)
                else {
                    throw CoreClientError.invalidResponse("query_item_metadata")
                }
                if declaredAvailability == .local, !bridgeItem.localPresent {
                    throw CoreClientError.invalidResponse("query_item_availability")
                }
                if declaredAvailability == .remoteOnly,
                    bridgeItem.localPresent || bridgeItem.remoteReplicaCount == 0
                {
                    throw CoreClientError.invalidResponse("query_item_availability")
                }

                items.append(
                    IndexedItem(
                        id: bridgeItem.itemID,
                        folderID: folderID,
                        parentID: bridgeItem.parentID,
                        relativePath: bridgeItem.relativePath,
                        isDirectory: bridgeItem.directory,
                        size: bridgeItem.size,
                        modifiedAt: modifiedAt,
                        contentVersion: bridgeItem.contentVersion,
                        metadataVersion: bridgeItem.metadataVersion,
                        availability: bridgeItem.symlink ? .error : declaredAvailability,
                        isPinned: bridgeItem.pinned,
                        hasUnuploadedChanges: bridgeItem.unuploaded,
                        remoteReplicaCount: bridgeItem.remoteReplicaCount,
                        generation: generation
                    )
                )
            }
            return (items, tombstones)
        }

        fileprivate static func bridgeDate(_ value: String) -> Date? {
            try? Date(value, strategy: .iso8601)
        }

        private static func isSafeItemID(_ value: String) -> Bool {
            let bytes = value.utf8
            guard (1...128).contains(bytes.count) else { return false }
            return bytes.allSatisfy { byte in
                (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || (48...57).contains(byte)
                    || byte == 45
                    || byte == 95
            }
        }

        private static func isSafeRelativePath(_ value: String) -> Bool {
            guard (1...4096).contains(value.utf8.count),
                !value.hasPrefix("/"),
                !value.contains("\\")
            else { return false }
            return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
                guard !component.isEmpty,
                    component != ".",
                    component != "..",
                    component.utf8.count <= 255
                else { return false }
                return component.unicodeScalars.allSatisfy { scalar in
                    scalar != ":" && !CharacterSet.controlCharacters.contains(scalar)
                }
            }
        }

        private static func safeBridgeCode(_ value: String) -> String? {
            let bytes = Array(value.utf8)
            guard (1...64).contains(bytes.count),
                let first = bytes.first,
                (97...122).contains(first)
            else { return nil }
            return bytes.dropFirst().allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
            } ? value : nil
        }

        private static func isLowercaseSHA256Hex(_ value: String) -> Bool {
            value.utf8.count == 64
                && value.utf8.allSatisfy { byte in
                    (48...57).contains(byte) || (97...102).contains(byte)
                }
        }

    }

    private enum BridgeQueryRestart: Error {
        case consistencyChanged
    }

    private struct BridgeSnapshotRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
    }

    private struct BridgeSessionCommandRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
        var command: String
        var sessionID: String
        var taskID: String?
        var planDigest: String?
        var expectedConfigurationRevision: String?
        var maximumNetworkBytes: String?
        var networkOperation: String?
        var folderID: String?
        var offeringDeviceID: String?

        static func open(
            requestID: String,
            command: String,
            binding: CoreExplicitSessionBinding
        ) -> Self {
            Self(
                schemaVersion: 1,
                requestID: requestID,
                command: command,
                sessionID: binding.sessionIDString,
                taskID: binding.taskIDString,
                planDigest: binding.planDigest,
                expectedConfigurationRevision: binding.expectedConfigurationRevision,
                maximumNetworkBytes: binding.maximumNetworkBytes,
                networkOperation: binding.networkOperation?.rawValue,
                folderID: binding.folderID?.rawValue,
                offeringDeviceID: binding.offeringDeviceID?.rawValue
            )
        }

        static func capture(
            requestID: String,
            command: String,
            binding: CoreExplicitSessionBinding
        ) -> Self {
            Self(
                schemaVersion: 1,
                requestID: requestID,
                command: command,
                sessionID: binding.sessionIDString,
                taskID: binding.taskIDString,
                planDigest: binding.planDigest,
                expectedConfigurationRevision: binding.expectedConfigurationRevision,
                maximumNetworkBytes: binding.maximumNetworkBytes,
                networkOperation: binding.networkOperation?.rawValue,
                folderID: binding.folderID?.rawValue,
                offeringDeviceID: binding.offeringDeviceID?.rawValue
            )
        }

        static func close(
            requestID: String,
            binding: CoreExplicitSessionBinding
        ) -> Self {
            Self(
                schemaVersion: 1,
                requestID: requestID,
                command: "closeSession",
                sessionID: binding.sessionIDString,
                taskID: binding.taskIDString,
                planDigest: binding.planDigest,
                expectedConfigurationRevision: binding.expectedConfigurationRevision,
                maximumNetworkBytes: binding.maximumNetworkBytes,
                networkOperation: binding.networkOperation?.rawValue,
                folderID: nil,
                offeringDeviceID: nil
            )
        }
    }

    private struct BridgeCommandRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
        var command: String
        var sessionID: String?
        var taskID: String?
        var planDigest: String?
        var expectedConfigurationRevision: String?
        var maximumNetworkBytes: String?
        var networkOperation: String?
        var commandConfigurationRevision: String?
        var folderID: String?
        var itemID: String?
        var arguments: [String: String]
    }

    private struct BridgeReconciledCommandAcknowledgementRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
        var command: BridgeCommandRequest
        var proof: BridgeMutationReconciliationProof
    }

    private struct BridgeMutationReconciliationProof: Encodable {
        var kind: String
        var snapshotGeneration: UInt64
        var ownerEpoch: UInt64
        var stateDigest: String
    }

    private struct BridgeItemsQueryRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
        var sessionID: String?
        var taskID: String?
        var planDigest: String?
        var expectedConfigurationRevision: String?
        var maximumNetworkBytes: String?
        var networkOperation: String?
        var query: String
        var folderID: String
        var scope: String
        var cursor: String?
        var limit: Int
        var includeDeleted: Bool
    }

    private struct BridgeRecoveryQueryRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
        var sessionID: String?
        var taskID: String?
        var planDigest: String?
        var expectedConfigurationRevision: String?
        var maximumNetworkBytes: String?
        var networkOperation: String?
        var query: String
        var cursor: String?
        var limit: Int
    }

    private struct BridgeReadRangeRequest: Encodable {
        var schemaVersion: Int
        var requestID: String
        var sessionID: String?
        var taskID: String?
        var planDigest: String?
        var expectedConfigurationRevision: String?
        var maximumNetworkBytes: String?
        var networkOperation: String?
        var folderID: String
        var itemID: String
        var path: String
        var contentVersion: Data
        var offset: Int64
        var length: Int
    }

    private struct BridgeReadRangePayload: Decodable {
        var data: Data
    }

    private struct BridgeNetworkTransferTotalsPayload: Decodable {
        var receivedBytes: Int64
        var sentBytes: Int64
        var budgetLimited: Bool
        var budgetLimitBytes: Int64
        var budgetUsedBytes: Int64
        var budgetExhausted: Bool

        init(from decoder: any Decoder) throws {
            let dynamic = try decoder.container(keyedBy: BridgeAnyCodingKey.self)
            let expected: Set<String> = [
                "receivedBytes", "sentBytes", "budgetLimited", "budgetLimitBytes",
                "budgetUsedBytes", "budgetExhausted",
            ]
            guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "unexpected network transfer totals payload"
                    )
                )
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            receivedBytes = try values.decode(Int64.self, forKey: .receivedBytes)
            sentBytes = try values.decode(Int64.self, forKey: .sentBytes)
            budgetLimited = try values.decode(Bool.self, forKey: .budgetLimited)
            budgetLimitBytes = try values.decode(Int64.self, forKey: .budgetLimitBytes)
            budgetUsedBytes = try values.decode(Int64.self, forKey: .budgetUsedBytes)
            budgetExhausted = try values.decode(Bool.self, forKey: .budgetExhausted)
        }

        private enum CodingKeys: String, CodingKey {
            case receivedBytes
            case sentBytes
            case budgetLimited
            case budgetLimitBytes
            case budgetUsedBytes
            case budgetExhausted
        }
    }

    private struct BridgeEnvelope<Payload: Decodable>: Decodable {
        var schemaVersion: Int
        var requestID: String
        var kind: String
        var ok: Bool
        var payload: Payload?
        var error: BridgeResponseError?
    }

    private struct BridgeResponseError: Decodable {
        var code: String
        var mutationPhase: String?
        var mutationAmbiguous: Bool?
    }

    private struct BridgeCommandPayload: Decodable {
        var command: String?
        var lifecycle: String?
        var generation: UInt64?
        var configurationRevision: String?
        var disposition: String?
        var recoveryID: String?
        var receiptHash: String?
    }

    private struct BridgeRecoveryQueryPayload: Decodable {
        var query: String
        var recoveries: [BridgeMutationRecovery]
        var nextCursor: String?
        var hasMore: Bool

        init(from decoder: any Decoder) throws {
            let dynamic = try decoder.container(keyedBy: BridgeAnyCodingKey.self)
            let keys = Set(dynamic.allKeys.map(\.stringValue))
            guard keys.isSubset(of: ["query", "recoveries", "nextCursor", "hasMore"]),
                keys.contains("query"),
                keys.contains("recoveries"),
                keys.contains("hasMore")
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unexpected recovery payload")
                )
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            query = try values.decode(String.self, forKey: .query)
            recoveries = try values.decode([BridgeMutationRecovery].self, forKey: .recoveries)
            nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
            hasMore = try values.decode(Bool.self, forKey: .hasMore)
        }

        private enum CodingKeys: String, CodingKey {
            case query
            case recoveries
            case nextCursor
            case hasMore
        }
    }

    private struct BridgeMutationRecovery: Decodable {
        var recoveryID: String
        var folderID: String
        var commandKind: String
        var relativePath: String
        var payloadKind: String
        var digest: String
        var bytes: Int64
        var createdAt: String
        var status: String

        init(from decoder: any Decoder) throws {
            let dynamic = try decoder.container(keyedBy: BridgeAnyCodingKey.self)
            let expected: Set<String> = [
                "recoveryID", "folderID", "commandKind", "relativePath", "payloadKind",
                "digest", "bytes", "createdAt", "status",
            ]
            guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unexpected recovery record")
                )
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            recoveryID = try values.decode(String.self, forKey: .recoveryID)
            folderID = try values.decode(String.self, forKey: .folderID)
            commandKind = try values.decode(String.self, forKey: .commandKind)
            relativePath = try values.decode(String.self, forKey: .relativePath)
            payloadKind = try values.decode(String.self, forKey: .payloadKind)
            digest = try values.decode(String.self, forKey: .digest)
            bytes = try values.decode(Int64.self, forKey: .bytes)
            createdAt = try values.decode(String.self, forKey: .createdAt)
            status = try values.decode(String.self, forKey: .status)
        }

        func summary() throws -> CoreMutationRecoverySummary {
            guard let folderID = FolderID(rawValue: folderID),
                let commandKind = CoreCommandKind(rawValue: commandKind),
                let payloadKind = CoreMutationRecoveryPayloadKind(rawValue: payloadKind),
                let createdAt = MobileSyncthingCoreClient.bridgeDate(createdAt),
                let status = CoreMutationRecoveryStatus(rawValue: status)
            else {
                throw CoreMutationRecoveryValidationError.invalidPage
            }
            return try CoreMutationRecoverySummary(
                recoveryID: recoveryID,
                folderID: folderID,
                commandKind: commandKind,
                relativePath: relativePath,
                payloadKind: payloadKind,
                digest: digest,
                bytes: bytes,
                createdAt: createdAt,
                status: status
            )
        }

        private enum CodingKeys: String, CodingKey {
            case recoveryID
            case folderID
            case commandKind
            case relativePath
            case payloadKind
            case digest
            case bytes
            case createdAt
            case status
        }
    }

    private struct BridgeAnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct BridgeCommandAcknowledgementPayload: Decodable {
        var acknowledged: Bool
        var removed: Bool
    }

    private struct BridgeReconciledCommandAcknowledgementPayload: Decodable {
        var acknowledged: Bool
        var removed: Bool
        var proofReceipt: String
    }

    private struct BridgeSnapshotPayload: Decodable {
        var generation: UInt64
        var generatedAt: String
        var deviceID: String
        var lifecycle: String
        var running: Bool
        var session: BridgeSessionDescriptor?
        var configurationRevision: String?
        var devices: [BridgeDevice]
        var folders: [BridgeFolder]
        var pendingDevices: [BridgePendingDevice]
        var pendingFolders: [BridgePendingFolder]
        var pendingDeviceObservationScope: String
        var pendingFoldersAvailable: Bool
        var pendingFoldersTruncated: Bool
        var suppressedPendingDevices: [BridgeSuppressedPendingDevice]?
        var suppressedPendingFolders: [BridgeSuppressedPendingFolder]?
        var suppressedPendingStateAvailable: Bool?
        var suppressedPendingDevicesTruncated: Bool?
        var suppressedPendingFoldersTruncated: Bool?
    }

    private struct BridgeSessionDescriptor: Decodable {
        var sessionID: String
        var mode: String
        var folderID: String?
        var offeringDeviceID: String?
        var taskID: String?
        var planDigest: String?
        var expectedConfigurationRevision: String?
        var maximumNetworkBytes: String?
        var networkOperation: String?

        init(from decoder: any Decoder) throws {
            let dynamic = try decoder.container(keyedBy: BridgeAnyCodingKey.self)
            let keys = Set(dynamic.allKeys.map(\.stringValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try values.decode(String.self, forKey: .sessionID)
            mode = try values.decode(String.self, forKey: .mode)
            let common: Set<String> = ["sessionID", "mode"]
            let network: Set<String> = [
                "folderID", "taskID", "planDigest", "expectedConfigurationRevision",
                "maximumNetworkBytes", "networkOperation",
            ]
            let observation = network.subtracting(["networkOperation"])
            let expectedKeys: Set<String>
            switch mode {
            case "configuration":
                expectedKeys = common
            case "network":
                expectedKeys = common.union(network)
            case "pendingFolderObservation":
                expectedKeys = common.union(observation).union(["offeringDeviceID"])
            case "pendingFolderDiscovery":
                expectedKeys = common.union(observation.subtracting(["folderID"]))
                    .union(["offeringDeviceID"])
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "invalid session descriptor"
                    )
                )
            }
            guard keys == expectedKeys
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid session descriptor")
                )
            }
            folderID = try values.decodeIfPresent(String.self, forKey: .folderID)
            offeringDeviceID = try values.decodeIfPresent(
                String.self,
                forKey: .offeringDeviceID
            )
            taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
            planDigest = try values.decodeIfPresent(String.self, forKey: .planDigest)
            expectedConfigurationRevision = try values.decodeIfPresent(
                String.self,
                forKey: .expectedConfigurationRevision
            )
            maximumNetworkBytes = try values.decodeIfPresent(
                String.self,
                forKey: .maximumNetworkBytes
            )
            networkOperation = try values.decodeIfPresent(String.self, forKey: .networkOperation)
        }

        func matches(_ binding: CoreExplicitSessionBinding) -> Bool {
            sessionID == binding.sessionIDString
                && mode == binding.mode.rawValue
                && folderID == binding.folderID?.rawValue
                && offeringDeviceID == binding.offeringDeviceID?.rawValue
                && taskID == binding.taskIDString
                && planDigest == binding.planDigest
                && expectedConfigurationRevision == binding.expectedConfigurationRevision
                && maximumNetworkBytes == binding.maximumNetworkBytes
                && networkOperation == binding.networkOperation?.rawValue
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID
            case mode
            case folderID
            case offeringDeviceID
            case taskID
            case planDigest
            case expectedConfigurationRevision
            case maximumNetworkBytes
            case networkOperation
        }
    }

    private struct BridgeItemsQueryPayload: Decodable {
        var query: String
        var folderID: String
        var scope: String
        var generation: UInt64
        var changeCursor: String
        var items: [BridgeItem]
        var nextCursor: String?
        var hasMore: Bool
        var scanLimited: Bool
        var cursorConsistency: String
    }

    private struct BridgeDevice: Decodable {
        var deviceID: String
        var name: String
        var addresses: [String]
        var paused: Bool
        var connected: Bool
        var lastSeen: String?
        var uploadBytesPerSecond: Int64
        var downloadBytesPerSecond: Int64
        var pendingBytes: Int64

        func record() throws -> DeviceRecord {
            guard let id = DeviceID(rawValue: deviceID),
                uploadBytesPerSecond >= 0,
                downloadBytesPerSecond >= 0,
                pendingBytes >= 0
            else {
                throw CoreClientError.invalidResponse("device_id")
            }
            let parsedLastSeen: Date?
            if let lastSeen {
                guard let value = MobileSyncthingCoreClient.bridgeDate(lastSeen) else {
                    throw CoreClientError.invalidResponse("device_timestamp")
                }
                parsedLastSeen = value
            } else {
                parsedLastSeen = nil
            }
            let state: DeviceConnectionState
            if paused {
                state = .paused
            } else if connected {
                state = .connected
            } else {
                state = .disconnected
            }
            return DeviceRecord(
                id: id,
                name: name,
                addresses: addresses,
                state: state,
                isPaused: paused,
                lastSeen: parsedLastSeen,
                uploadBytesPerSecond: uploadBytesPerSecond,
                downloadBytesPerSecond: downloadBytesPerSecond,
                pendingBytes: pendingBytes
            )
        }
    }

    private struct BridgePendingDevice: Decodable {
        var deviceID: String
        var label: String
        var lastSeen: String
        var offerVersion: String
        var unverifiedIdentity: Bool
        var requiresExplicitAcceptance: Bool

        func record() throws -> PendingDeviceOffer {
            guard let id = DeviceID(rawValue: deviceID),
                let parsedLastSeen = MobileSyncthingCoreClient.bridgeDate(lastSeen)
            else {
                throw CoreClientError.invalidResponse("pending_device")
            }
            do {
                return try PendingDeviceOffer(
                    deviceID: id,
                    label: label,
                    lastSeen: parsedLastSeen,
                    offerVersion: offerVersion,
                    unverifiedIdentity: unverifiedIdentity,
                    requiresExplicitAcceptance: requiresExplicitAcceptance
                )
            } catch {
                throw CoreClientError.invalidResponse("pending_device_contract")
            }
        }
    }

    private struct BridgePendingFolder: Decodable {
        var folderID: String
        var label: String
        var offeringDeviceID: String
        var lastSeen: String
        var offerVersion: String
        var receiveEncrypted: Bool
        var remoteEncrypted: Bool
        var requiresManagedLocalPath: Bool
        var requiresExplicitDeviceSelection: Bool
        var evidenceSource: PendingFolderOffer.EvidenceSource
        var requiresNetworkRevalidation: Bool

        init(from decoder: any Decoder) throws {
            let dynamic = try decoder.container(keyedBy: BridgeAnyCodingKey.self)
            let keys = Set(dynamic.allKeys.map(\.stringValue))
            let baseKeys: Set<String> = [
                "folderID", "label", "offeringDeviceID", "lastSeen", "offerVersion",
                "receiveEncrypted", "remoteEncrypted", "requiresManagedLocalPath",
                "requiresExplicitDeviceSelection",
            ]
            let evidenceKeys: Set<String> = [
                "evidenceSource", "requiresNetworkRevalidation",
            ]
            guard keys == baseKeys || keys == baseKeys.union(evidenceKeys) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "invalid pending-folder evidence shape"
                    )
                )
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            folderID = try values.decode(String.self, forKey: .folderID)
            label = try values.decode(String.self, forKey: .label)
            offeringDeviceID = try values.decode(String.self, forKey: .offeringDeviceID)
            lastSeen = try values.decode(String.self, forKey: .lastSeen)
            offerVersion = try values.decode(String.self, forKey: .offerVersion)
            receiveEncrypted = try values.decode(Bool.self, forKey: .receiveEncrypted)
            remoteEncrypted = try values.decode(Bool.self, forKey: .remoteEncrypted)
            requiresManagedLocalPath = try values.decode(
                Bool.self,
                forKey: .requiresManagedLocalPath
            )
            requiresExplicitDeviceSelection = try values.decode(
                Bool.self,
                forKey: .requiresExplicitDeviceSelection
            )
            if keys == baseKeys {
                evidenceSource = .durableSummary
                requiresNetworkRevalidation = true
            } else {
                evidenceSource = try values.decode(
                    PendingFolderOffer.EvidenceSource.self,
                    forKey: .evidenceSource
                )
                requiresNetworkRevalidation = try values.decode(
                    Bool.self,
                    forKey: .requiresNetworkRevalidation
                )
            }
        }

        func record() throws -> PendingFolderOffer {
            guard let parsedFolderID = FolderID(rawValue: folderID),
                let parsedDeviceID = DeviceID(rawValue: offeringDeviceID),
                let parsedLastSeen = MobileSyncthingCoreClient.bridgeDate(lastSeen)
            else {
                throw CoreClientError.invalidResponse("pending_folder")
            }
            do {
                return try PendingFolderOffer(
                    folderID: parsedFolderID,
                    label: label,
                    offeringDeviceID: parsedDeviceID,
                    lastSeen: parsedLastSeen,
                    offerVersion: offerVersion,
                    receiveEncrypted: receiveEncrypted,
                    remoteEncrypted: remoteEncrypted,
                    requiresManagedLocalPath: requiresManagedLocalPath,
                    requiresExplicitDeviceSelection: requiresExplicitDeviceSelection,
                    evidenceSource: evidenceSource,
                    requiresNetworkRevalidation: requiresNetworkRevalidation
                )
            } catch {
                throw CoreClientError.invalidResponse("pending_folder_contract")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case folderID
            case label
            case offeringDeviceID
            case lastSeen
            case offerVersion
            case receiveEncrypted
            case remoteEncrypted
            case requiresManagedLocalPath
            case requiresExplicitDeviceSelection
            case evidenceSource
            case requiresNetworkRevalidation
        }
    }

    private struct BridgeSuppressedPendingDevice: Decodable {
        var deviceID: String
        var suppressionVersion: String

        func record() throws -> SuppressedPendingDevice {
            guard let parsedDeviceID = DeviceID(rawValue: deviceID) else {
                throw CoreClientError.invalidResponse("suppressed_pending_device")
            }
            do {
                return try SuppressedPendingDevice(
                    deviceID: parsedDeviceID,
                    suppressionVersion: suppressionVersion
                )
            } catch {
                throw CoreClientError.invalidResponse("suppressed_pending_device_contract")
            }
        }
    }

    private struct BridgeSuppressedPendingFolder: Decodable {
        var folderID: String
        var offeringDeviceID: String
        var suppressionVersion: String

        func record() throws -> SuppressedPendingFolder {
            guard let parsedFolderID = FolderID(rawValue: folderID),
                let parsedDeviceID = DeviceID(rawValue: offeringDeviceID)
            else {
                throw CoreClientError.invalidResponse("suppressed_pending_folder")
            }
            do {
                return try SuppressedPendingFolder(
                    folderID: parsedFolderID,
                    offeringDeviceID: parsedDeviceID,
                    suppressionVersion: suppressionVersion
                )
            } catch {
                throw CoreClientError.invalidResponse("suppressed_pending_folder_contract")
            }
        }
    }

    private struct BridgeFolder: Decodable {
        var folderID: String
        var label: String
        var path: String
        var type: String
        var paused: Bool
        var deviceIDs: [String]
        var rescanIntervalS: Int?
        var state: String?
        var stateChangedAt: String?
        var completionPercent: Double
        var pendingUploadBytes: Int64
        var pendingDownloadBytes: Int64
        var error: String?

        func record(
            localDeviceID: DeviceID,
            configuredDeviceIDs: Set<DeviceID>,
            runtimeStatusAvailable: Bool
        ) throws -> FolderRecord {
            guard let id = FolderID(rawValue: folderID) else {
                throw CoreClientError.invalidResponse("folder_id")
            }
            guard completionPercent.isFinite,
                (0...100).contains(completionPercent),
                pendingUploadBytes >= 0,
                pendingDownloadBytes >= 0
            else {
                throw CoreClientError.invalidResponse("folder_runtime_status")
            }
            if !runtimeStatusAvailable {
                guard state?.isEmpty != false,
                    stateChangedAt?.isEmpty != false,
                    completionPercent == 0,
                    pendingUploadBytes == 0,
                    pendingDownloadBytes == 0,
                    error?.isEmpty != false
                else {
                    throw CoreClientError.invalidResponse("folder_runtime_scope")
                }
            }
            let parsedDeviceIDs = try deviceIDs.map { rawValue -> DeviceID in
                guard let value = DeviceID(rawValue: rawValue) else {
                    throw CoreClientError.invalidResponse("folder_device_ids")
                }
                return value
            }
            guard Set(parsedDeviceIDs).count == parsedDeviceIDs.count,
                parsedDeviceIDs.contains(localDeviceID),
                parsedDeviceIDs.allSatisfy(configuredDeviceIDs.contains)
            else {
                throw CoreClientError.invalidResponse("folder_device_ids")
            }
            let remoteDeviceIDs =
                parsedDeviceIDs
                .filter { $0 != localDeviceID }
                .sorted { $0.rawValue < $1.rawValue }
            let folderType: FolderType
            switch type.lowercased() {
            case "sendreceive": folderType = .sendReceive
            case "sendonly": folderType = .sendOnly
            case "receiveonly": folderType = .receiveOnly
            case "receiveencrypted": folderType = .receiveEncrypted
            default: throw CoreClientError.invalidResponse("folder_type")
            }
            return FolderRecord(
                id: id,
                label: label,
                localPath: path,
                type: folderType,
                isPaused: paused,
                deviceIDs: remoteDeviceIDs,
                rescanIntervalS: rescanIntervalS,
                pendingUploadBytes: pendingUploadBytes,
                pendingDownloadBytes: pendingDownloadBytes,
                error: error?.isEmpty == false ? "folder_status_error" : nil
            )
        }
    }

    private struct BridgeItem: Decodable {
        var itemID: String
        var folderID: String
        var parentID: String?
        var relativePath: String
        var name: String
        var directory: Bool
        var symlink: Bool
        var size: Int64
        var modifiedAt: String
        var version: String
        var contentVersion: Data
        var metadataVersion: Data
        var availability: String
        var localPresent: Bool
        var remoteReplicaCount: Int
        // Go's zero-value slice is encoded as null when no replica is connected.
        var connectedRemoteDeviceIDs: [String]?
        var pinned: Bool
        var unuploaded: Bool
        var tombstone: Bool
        var sequence: Int64
        var changeCursor: String
        var generation: UInt64
        var source: String
    }
#endif

enum PlatformCoreBootstrap {
    static var coreRevision: String {
        #if canImport(Mobilebridge)
            MobilebridgeCoreRevision()
        #else
            "unavailable"
        #endif
    }

    static func install() async {
        #if canImport(Mobilebridge)
            let accessGroup = Bundle.main.object(forInfoDictionaryKey: "PsyKeychainAccessGroup") as? String
            await CoreRuntime.shared.installClientFactory {
                MobileSyncthingCoreClient(
                    identityStore: KeychainCoreIdentityStore(accessGroup: accessGroup)
                )
            }
        #endif
    }
}
