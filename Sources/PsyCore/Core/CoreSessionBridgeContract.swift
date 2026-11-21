import Foundation

public enum CoreExplicitSessionLifecycle: String, Hashable, Sendable {
    case running
    case stopped
}

public struct CoreSessionLifecycleResponse: Hashable, Sendable {
    public let generation: UInt64
    public let configurationRevision: String
}

public enum CoreSessionRequestFolderBinding: Hashable, Sendable {
    case absent
    case exact(FolderID)
    case ifPresentMatches(FolderID)
    case unconstrained
}

/// Strict validation for the untyped `CommandJSON` lifecycle boundary. Keeping
/// it in PsyCore makes the contract testable without linking a gomobile binary.
public enum CoreSessionBridgeContract {
    /// Verifies the flattened explicit-session fields immediately before an
    /// untyped JSON request crosses the bridge. This covers business commands,
    /// queries, and reads in addition to lifecycle requests, and prevents a new
    /// request shape from silently omitting or substituting a plan field.
    public static func validateRequestBinding(
        _ request: String,
        binding: CoreExplicitSessionBinding?,
        folder: CoreSessionRequestFolderBinding,
        commandConfigurationRevision: String? = nil
    ) throws {
        guard let data = request.data(using: .utf8) else {
            throw CoreClientError.invalidResponse("session_request_encoding")
        }
        let document: StrictJSONValue
        do {
            document = try StrictJSONDocument.parse(data)
        } catch {
            throw CoreClientError.invalidResponse("session_request")
        }
        guard let object = document.objectEntries,
            integer(object, "schemaVersion") == 1,
            string(object, "requestID")?.isEmpty == false
        else {
            throw CoreClientError.invalidResponse("session_request_identity")
        }

        let scopedEphemeralKeys: Set<String> = [
            "sessionID", "taskID", "planDigest", "expectedConfigurationRevision",
            "maximumNetworkBytes",
        ]
        let networkEphemeralKeys = scopedEphemeralKeys.union(["networkOperation"])
        let allEphemeralKeys = networkEphemeralKeys
        let presentEphemeralKeys = keys(object).intersection(allEphemeralKeys)
        switch binding?.mode {
        case nil:
            guard presentEphemeralKeys.isEmpty else {
                throw CoreClientError.invalidResponse("session_request_binding")
            }
        case .configuration:
            guard presentEphemeralKeys == ["sessionID"],
                string(object, "sessionID") == binding?.sessionIDString
            else {
                throw CoreClientError.invalidResponse("session_request_binding")
            }
        case .network:
            guard presentEphemeralKeys == networkEphemeralKeys,
                string(object, "sessionID") == binding?.sessionIDString,
                string(object, "taskID") == binding?.taskIDString,
                string(object, "planDigest") == binding?.planDigest,
                string(object, "expectedConfigurationRevision")
                    == binding?.expectedConfigurationRevision,
                string(object, "maximumNetworkBytes") == binding?.maximumNetworkBytes,
                string(object, "networkOperation") == binding?.networkOperation?.rawValue
            else {
                throw CoreClientError.invalidResponse("session_request_binding")
            }
        case .pendingFolderObservation:
            guard presentEphemeralKeys == scopedEphemeralKeys,
                string(object, "sessionID") == binding?.sessionIDString,
                string(object, "taskID") == binding?.taskIDString,
                string(object, "planDigest") == binding?.planDigest,
                string(object, "expectedConfigurationRevision")
                    == binding?.expectedConfigurationRevision,
                string(object, "maximumNetworkBytes") == binding?.maximumNetworkBytes
            else {
                throw CoreClientError.invalidResponse("session_request_binding")
            }
        case .pendingFolderDiscovery:
            guard presentEphemeralKeys == scopedEphemeralKeys,
                string(object, "sessionID") == binding?.sessionIDString,
                string(object, "taskID") == binding?.taskIDString,
                string(object, "planDigest") == binding?.planDigest,
                string(object, "expectedConfigurationRevision")
                    == binding?.expectedConfigurationRevision,
                string(object, "maximumNetworkBytes") == binding?.maximumNetworkBytes
            else {
                throw CoreClientError.invalidResponse("session_request_binding")
            }
        }

        switch folder {
        case .absent:
            guard value(object, "folderID") == nil else {
                throw CoreClientError.invalidResponse("session_request_folder")
            }
        case .exact(let folderID):
            guard string(object, "folderID") == folderID.rawValue else {
                throw CoreClientError.invalidResponse("session_request_folder")
            }
        case .ifPresentMatches(let folderID):
            guard
                value(object, "folderID") == nil
                    || string(object, "folderID") == folderID.rawValue
            else {
                throw CoreClientError.invalidResponse("session_request_folder")
            }
        case .unconstrained:
            guard value(object, "folderID") == nil || string(object, "folderID") != nil else {
                throw CoreClientError.invalidResponse("session_request_folder")
            }
        }

        if let commandConfigurationRevision {
            guard CoreSessionDigest.isLowercaseSHA256(commandConfigurationRevision),
                string(object, "commandConfigurationRevision")
                    == commandConfigurationRevision
            else {
                throw CoreClientError.invalidResponse(
                    "command_configuration_revision_request"
                )
            }
        } else if value(object, "commandConfigurationRevision") != nil {
            throw CoreClientError.invalidResponse(
                "command_configuration_revision_request"
            )
        }

        if binding?.mode == .pendingFolderObservation {
            try validatePendingFolderObservationRequestShape(object, binding: binding!)
        } else if binding?.mode == .pendingFolderDiscovery {
            try validatePendingFolderDiscoveryRequestShape(object, binding: binding!)
        } else if value(object, "offeringDeviceID") != nil {
            throw CoreClientError.invalidResponse("session_request_device")
        }
    }

    /// Returns only the durable enqueue-time precondition that Go permits on
    /// configuration mutation commands. It never derives a value from the
    /// active session receipt or snapshot.
    public static func commandConfigurationRevision(
        for command: CoreCommand,
        binding: CoreExplicitSessionBinding?
    ) throws -> String? {
        guard binding?.mode == .configuration else { return nil }
        if command.kind == .acceptFolder || command.kind == .ignorePendingFolder {
            guard let proofID = command.arguments["observationProofID"], !proofID.isEmpty else {
                throw CoreClientError.coreRejected("network_observation_required")
            }
            guard CoreSessionDigest.isCanonicalStableVersion(proofID) else {
                throw CoreClientError.coreRejected("invalid_request")
            }
            guard
                command.arguments["offeringDeviceID"].flatMap(DeviceID.init(rawValue:))?
                    .rawValue == command.arguments["offeringDeviceID"],
                command.arguments["offerVersion"].map(
                    CoreSessionDigest.isCanonicalStableVersion
                ) == true
            else {
                throw CoreClientError.coreRejected("invalid_request")
            }
        }
        guard command.requiresGoConfigurationWireRevisionFence else {
            if command.kind == .ignorePendingFolder,
                command.arguments["observationProofID"] != nil
            {
                guard let revision = command.commandConfigurationRevision,
                    CoreSessionDigest.isLowercaseSHA256(revision)
                else {
                    throw CoreClientError.coreRejected("invalid_request")
                }
                return revision
            }
            // Swift may retain the same enqueue-time revision as an app-side
            // safety precondition for suppression commands. Go's wire
            // contract requires that field to be absent for those commands.
            return nil
        }
        guard let revision = command.commandConfigurationRevision,
            CoreSessionDigest.isLowercaseSHA256(revision)
        else {
            throw CoreClientError.coreRejected("invalid_request")
        }
        return revision
    }

    public static func validateCandidateDeviceID(
        _ rawValue: String,
        expected: DeviceID? = nil
    ) throws -> DeviceID {
        guard let parsed = DeviceID(rawValue: rawValue), parsed.rawValue == rawValue else {
            throw CoreClientError.invalidResponse("session_device_id")
        }
        if let expected, parsed != expected {
            throw CoreClientError.invalidResponse("session_device_id")
        }
        return parsed
    }

    public static func validateLifecycleResponse(
        _ response: String,
        requestID: String,
        command: String,
        lifecycle: CoreExplicitSessionLifecycle,
        binding: CoreExplicitSessionBinding
    ) throws -> CoreSessionLifecycleResponse {
        guard let data = response.data(using: .utf8) else {
            throw CoreClientError.invalidResponse("session_response_encoding")
        }
        let document: StrictJSONValue
        do {
            document = try StrictJSONDocument.parse(data)
        } catch {
            throw CoreClientError.invalidResponse("session_envelope")
        }
        guard let envelope = document.objectEntries else {
            throw CoreClientError.invalidResponse("session_envelope")
        }
        guard integer(envelope, "schemaVersion") == 1,
            string(envelope, "requestID") == requestID,
            string(envelope, "kind") == "command",
            let ok = boolean(envelope, "ok")
        else {
            throw CoreClientError.invalidResponse("session_envelope_identity")
        }

        if !ok {
            guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "error"],
                let error = value(envelope, "error")?.objectEntries,
                keys(error) == ["code", "message"],
                string(error, "message") != nil,
                let code = string(error, "code"),
                stableLifecycleErrorCodes.contains(code)
            else {
                throw CoreClientError.invalidResponse("session_error_envelope")
            }
            throw CoreClientError.coreRejected(code)
        }

        guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "payload"],
            let payload = value(envelope, "payload")?.objectEntries
        else {
            throw CoreClientError.invalidResponse("session_envelope")
        }

        let commonKeys: Set<String> = [
            "command", "lifecycle", "generation", "sessionID", "sessionMode",
            "configurationRevision",
        ]
        let networkKeys: Set<String> = [
            "folderID", "taskID", "planDigest", "expectedConfigurationRevision",
            "maximumNetworkBytes", "networkOperation",
        ]
        let observationKeys = networkKeys.subtracting(["networkOperation"])
        let expectedKeys: Set<String>
        switch binding.mode {
        case .configuration:
            expectedKeys = commonKeys
        case .network:
            expectedKeys = commonKeys.union(networkKeys)
        case .pendingFolderObservation:
            expectedKeys = commonKeys.union(observationKeys).union(["offeringDeviceID"])
        case .pendingFolderDiscovery:
            expectedKeys = commonKeys.union(observationKeys.subtracting(["folderID"]))
                .union(["offeringDeviceID"])
        }
        guard keys(payload) == expectedKeys,
            string(payload, "command") == command,
            string(payload, "lifecycle") == lifecycle.rawValue,
            string(payload, "sessionID") == binding.sessionIDString,
            string(payload, "sessionMode") == binding.mode.rawValue,
            let generation = unsignedInteger(value(payload, "generation")),
            generation > 0,
            let configurationRevision = string(payload, "configurationRevision"),
            CoreSessionDigest.isLowercaseSHA256(configurationRevision)
        else {
            throw CoreClientError.invalidResponse("session_payload")
        }

        switch binding.mode {
        case .configuration:
            break
        case .network:
            guard string(payload, "folderID") == binding.folderID?.rawValue,
                string(payload, "taskID") == binding.taskIDString,
                string(payload, "planDigest") == binding.planDigest,
                string(payload, "expectedConfigurationRevision")
                    == binding.expectedConfigurationRevision,
                string(payload, "maximumNetworkBytes") == binding.maximumNetworkBytes,
                string(payload, "networkOperation") == binding.networkOperation?.rawValue,
                configurationRevision == binding.expectedConfigurationRevision
            else {
                throw CoreClientError.invalidResponse("session_scope_payload")
            }
        case .pendingFolderObservation:
            guard string(payload, "folderID") == binding.folderID?.rawValue,
                string(payload, "offeringDeviceID") == binding.offeringDeviceID?.rawValue,
                string(payload, "taskID") == binding.taskIDString,
                string(payload, "planDigest") == binding.planDigest,
                string(payload, "expectedConfigurationRevision")
                    == binding.expectedConfigurationRevision,
                string(payload, "maximumNetworkBytes") == binding.maximumNetworkBytes,
                configurationRevision == binding.expectedConfigurationRevision
            else {
                throw CoreClientError.invalidResponse("session_scope_payload")
            }
        case .pendingFolderDiscovery:
            guard value(payload, "folderID") == nil,
                string(payload, "offeringDeviceID") == binding.offeringDeviceID?.rawValue,
                string(payload, "taskID") == binding.taskIDString,
                string(payload, "planDigest") == binding.planDigest,
                string(payload, "expectedConfigurationRevision")
                    == binding.expectedConfigurationRevision,
                string(payload, "maximumNetworkBytes") == binding.maximumNetworkBytes,
                configurationRevision == binding.expectedConfigurationRevision
            else {
                throw CoreClientError.invalidResponse("session_scope_payload")
            }
        }

        return CoreSessionLifecycleResponse(
            generation: generation,
            configurationRevision: configurationRevision
        )
    }

    /// Validates the complete capture receipt and its durable proof before any
    /// proof identifier can be handed to a later configuration command.
    public static func validatePendingFolderObservationCaptureResponse(
        _ response: String,
        requestID: String,
        binding: CoreExplicitSessionBinding,
        now: Date = .now,
        clockTolerance: TimeInterval = 1
    ) throws -> PendingFolderObservationCaptureReceipt {
        guard binding.mode == .pendingFolderObservation,
            clockTolerance >= 0,
            clockTolerance.isFinite,
            let data = response.data(using: .utf8)
        else {
            throw CoreClientError.invalidResponse("observation_capture_binding")
        }
        let document: StrictJSONValue
        do {
            document = try StrictJSONDocument.parse(data)
        } catch {
            throw CoreClientError.invalidResponse("observation_capture_envelope")
        }
        guard let envelope = document.objectEntries,
            integer(envelope, "schemaVersion") == 1,
            string(envelope, "requestID") == requestID,
            string(envelope, "kind") == "command",
            let ok = boolean(envelope, "ok")
        else {
            throw CoreClientError.invalidResponse("observation_capture_envelope")
        }
        if !ok {
            guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "error"],
                let error = value(envelope, "error")?.objectEntries,
                keys(error) == ["code", "message"],
                string(error, "message") != nil,
                let code = string(error, "code"),
                stableObservationCaptureErrorCodes.contains(code)
            else {
                throw CoreClientError.invalidResponse("observation_capture_error")
            }
            throw CoreClientError.coreRejected(code)
        }

        let expectedPayloadKeys: Set<String> = [
            "command", "lifecycle", "generation", "configurationRevision",
            "sessionID", "sessionMode", "folderID", "offeringDeviceID", "taskID",
            "planDigest", "expectedConfigurationRevision", "maximumNetworkBytes",
            "pendingFolderObservation",
        ]
        guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "payload"],
            let payload = value(envelope, "payload")?.objectEntries,
            keys(payload) == expectedPayloadKeys,
            string(payload, "command") == "capturePendingFolderObservation",
            string(payload, "lifecycle") == CoreExplicitSessionLifecycle.running.rawValue,
            string(payload, "sessionID") == binding.sessionIDString,
            string(payload, "sessionMode") == binding.mode.rawValue,
            string(payload, "folderID") == binding.folderID?.rawValue,
            string(payload, "offeringDeviceID") == binding.offeringDeviceID?.rawValue,
            string(payload, "taskID") == binding.taskIDString,
            string(payload, "planDigest") == binding.planDigest,
            string(payload, "expectedConfigurationRevision")
                == binding.expectedConfigurationRevision,
            string(payload, "maximumNetworkBytes") == binding.maximumNetworkBytes,
            let generation = unsignedInteger(value(payload, "generation")),
            generation > 0,
            let configurationRevision = string(payload, "configurationRevision"),
            configurationRevision == binding.expectedConfigurationRevision,
            let proofEntries = value(payload, "pendingFolderObservation")?.objectEntries
        else {
            throw CoreClientError.invalidResponse("observation_capture_payload")
        }

        let proof = try validatedPendingFolderObservationProof(
            proofEntries,
            binding: binding,
            now: now,
            clockTolerance: clockTolerance
        )
        return PendingFolderObservationCaptureReceipt(
            generation: generation,
            configurationRevision: configurationRevision,
            proof: proof
        )
    }

    /// Validates a bounded, redacted discovery batch. A successful receipt is
    /// display evidence only; it deliberately carries no observation proof ID
    /// and therefore cannot authorize a folder decision.
    public static func validatePendingFolderDiscoveryCaptureResponse(
        _ response: String,
        requestID: String,
        binding: CoreExplicitSessionBinding,
        now: Date = .now,
        clockTolerance: TimeInterval = 1
    ) throws -> PendingFolderDiscoveryCaptureReceipt {
        guard binding.mode == .pendingFolderDiscovery,
            clockTolerance >= 0,
            clockTolerance.isFinite,
            let data = response.data(using: .utf8)
        else {
            throw CoreClientError.invalidResponse("discovery_capture_binding")
        }
        let document: StrictJSONValue
        do {
            document = try StrictJSONDocument.parse(data)
        } catch {
            throw CoreClientError.invalidResponse("discovery_capture_envelope")
        }
        guard let envelope = document.objectEntries,
            integer(envelope, "schemaVersion") == 1,
            string(envelope, "requestID") == requestID,
            string(envelope, "kind") == "command",
            let ok = boolean(envelope, "ok")
        else {
            throw CoreClientError.invalidResponse("discovery_capture_envelope")
        }
        if !ok {
            guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "error"],
                let error = value(envelope, "error")?.objectEntries,
                keys(error) == ["code", "message"],
                string(error, "message") != nil,
                let code = string(error, "code"),
                stableDiscoveryCaptureErrorCodes.contains(code)
            else {
                throw CoreClientError.invalidResponse("discovery_capture_error")
            }
            throw CoreClientError.coreRejected(code)
        }

        let expectedPayloadKeys: Set<String> = [
            "command", "lifecycle", "generation", "configurationRevision",
            "sessionID", "sessionMode", "offeringDeviceID", "taskID",
            "planDigest", "expectedConfigurationRevision", "maximumNetworkBytes",
            "pendingFolderDiscovery",
        ]
        guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "payload"],
            let payload = value(envelope, "payload")?.objectEntries,
            keys(payload) == expectedPayloadKeys,
            string(payload, "command") == "capturePendingFolderDiscovery",
            string(payload, "lifecycle") == CoreExplicitSessionLifecycle.running.rawValue,
            string(payload, "sessionID") == binding.sessionIDString,
            string(payload, "sessionMode") == binding.mode.rawValue,
            value(payload, "folderID") == nil,
            string(payload, "offeringDeviceID") == binding.offeringDeviceID?.rawValue,
            string(payload, "taskID") == binding.taskIDString,
            string(payload, "planDigest") == binding.planDigest,
            string(payload, "expectedConfigurationRevision")
                == binding.expectedConfigurationRevision,
            string(payload, "maximumNetworkBytes") == binding.maximumNetworkBytes,
            let generation = unsignedInteger(value(payload, "generation")),
            generation > 0,
            let configurationRevision = string(payload, "configurationRevision"),
            configurationRevision == binding.expectedConfigurationRevision,
            let batch = value(payload, "pendingFolderDiscovery")?.objectEntries
        else {
            throw CoreClientError.invalidResponse("discovery_capture_payload")
        }

        let validated = try validatedPendingFolderDiscoveryBatch(
            batch,
            binding: binding,
            now: now,
            clockTolerance: clockTolerance
        )
        return PendingFolderDiscoveryCaptureReceipt(
            generation: generation,
            configurationRevision: configurationRevision,
            offeringDeviceID: validated.offeringDeviceID,
            connectionEpoch: validated.connectionEpoch,
            observedAt: validated.observedAt,
            offers: validated.offers,
            truncated: validated.truncated
        )
    }

    /// Pre-validates the session-bearing part of SnapshotJSON with the same
    /// duplicate-key rejecting parser as lifecycle responses. The larger
    /// snapshot payload remains decoded by the platform adapter afterward.
    public static func validateSnapshotResponse(
        _ response: String,
        requestID: String,
        binding: CoreExplicitSessionBinding?,
        expectedDeviceID: DeviceID
    ) throws {
        guard let data = response.data(using: .utf8) else {
            throw CoreClientError.invalidResponse("snapshot_response_encoding")
        }
        let document: StrictJSONValue
        do {
            document = try StrictJSONDocument.parse(data)
        } catch {
            throw CoreClientError.invalidResponse("snapshot_envelope")
        }
        guard let envelope = document.objectEntries,
            integer(envelope, "schemaVersion") == 1,
            string(envelope, "requestID") == requestID,
            string(envelope, "kind") == "snapshot",
            let ok = boolean(envelope, "ok")
        else {
            throw CoreClientError.invalidResponse("snapshot_envelope_identity")
        }
        // Error classification remains on the existing generic bridge path;
        // parsing here still guarantees duplicate keys cannot influence it.
        guard ok else { return }
        guard keys(envelope) == ["schemaVersion", "requestID", "kind", "ok", "payload"],
            let payload = value(envelope, "payload")?.objectEntries,
            string(payload, "deviceID") == expectedDeviceID.rawValue,
            string(payload, "lifecycle") == "running",
            boolean(payload, "running") == true,
            unsignedInteger(value(payload, "generation")).map({ $0 > 0 }) == true
        else {
            throw CoreClientError.invalidResponse("snapshot_session_payload")
        }

        guard let binding else {
            guard value(payload, "session") == nil,
                string(payload, "configurationRevision").map(
                    CoreSessionDigest.isLowercaseSHA256
                ) ?? true
            else {
                throw CoreClientError.invalidResponse("snapshot_session_payload")
            }
            return
        }
        guard let revision = string(payload, "configurationRevision"),
            CoreSessionDigest.isLowercaseSHA256(revision)
        else {
            throw CoreClientError.invalidResponse("snapshot_session_payload")
        }
        guard let session = value(payload, "session")?.objectEntries else {
            throw CoreClientError.invalidResponse("snapshot_session_payload")
        }
        let common: Set<String> = ["sessionID", "mode"]
        let network: Set<String> = [
            "folderID", "taskID", "planDigest", "expectedConfigurationRevision",
            "maximumNetworkBytes", "networkOperation",
        ]
        let observation = network.subtracting(["networkOperation"])
        let expectedSessionKeys: Set<String>
        switch binding.mode {
        case .configuration:
            expectedSessionKeys = common
        case .network:
            expectedSessionKeys = common.union(network)
        case .pendingFolderObservation:
            expectedSessionKeys = common.union(observation).union(["offeringDeviceID"])
        case .pendingFolderDiscovery:
            expectedSessionKeys = common.union(observation.subtracting(["folderID"]))
                .union(["offeringDeviceID"])
        }
        guard keys(session) == expectedSessionKeys,
            string(session, "sessionID") == binding.sessionIDString,
            string(session, "mode") == binding.mode.rawValue
        else {
            throw CoreClientError.invalidResponse("snapshot_session_payload")
        }
        if binding.mode != .configuration {
            guard string(session, "folderID") == binding.folderID?.rawValue,
                (binding.mode != .pendingFolderObservation
                    && binding.mode != .pendingFolderDiscovery)
                    || string(session, "offeringDeviceID")
                        == binding.offeringDeviceID?.rawValue,
                string(session, "taskID") == binding.taskIDString,
                string(session, "planDigest") == binding.planDigest,
                string(session, "expectedConfigurationRevision")
                    == binding.expectedConfigurationRevision,
                string(session, "maximumNetworkBytes") == binding.maximumNetworkBytes,
                binding.mode != .network
                    || string(session, "networkOperation")
                        == binding.networkOperation?.rawValue,
                revision == binding.expectedConfigurationRevision
            else {
                throw CoreClientError.invalidResponse("snapshot_session_payload")
            }
        }
    }

    // Exact, public lifecycle failures emitted by CommandJSON's validation,
    // session preflight, runtime start/close, and outer panic boundary. Business
    // command codes intentionally do not cross this lifecycle-only allowlist.
    private static let stableLifecycleErrorCodes: Set<String> = [
        "cancelled",
        "configuration_not_initialized",
        "configuration_revision_mismatch",
        "configuration_verify_failed",
        "configuration_version_mismatch",
        "core_closed",
        "core_unavailable",
        "device_not_found",
        "device_paused",
        "folder_state_conflict",
        "invalid_device_id",
        "invalid_folder_id",
        "folder_not_found",
        "folder_paused",
        "internal_error",
        "invalid_request",
        "invalid_request_id",
        "invalid_session",
        "no_active_session",
        "operation_not_allowed",
        "operation_scope_mismatch",
        "plan_digest_mismatch",
        "session_close_failed",
        "session_conflict",
        "session_scope_mismatch",
        "session_start_failed",
        "unsupported_command",
        "unsupported_schema",
    ]

    private static let stableObservationCaptureErrorCodes = stableLifecycleErrorCodes.union([
        "core_not_running",
        "network_byte_limit_reached",
        "observation_proof_store_full",
        "observation_proof_store_unavailable",
        "pending_folder_not_found",
        "pending_folder_observation_pending",
        "pending_state_unavailable",
        "wrong_session_mode",
    ])

    private static let stableDiscoveryCaptureErrorCodes = stableLifecycleErrorCodes.union([
        "core_not_running",
        "network_byte_limit_reached",
        "pending_folder_discovery_pending",
        "pending_folder_discovery_store_unavailable",
        "wrong_session_mode",
    ])

    private static func validatePendingFolderObservationRequestShape(
        _ object: [(String, StrictJSONValue)],
        binding: CoreExplicitSessionBinding
    ) throws {
        let common: Set<String> = [
            "schemaVersion", "requestID", "command", "sessionID", "taskID", "planDigest",
            "expectedConfigurationRevision", "maximumNetworkBytes",
        ]
        guard let command = string(object, "command") else {
            throw CoreClientError.invalidResponse("observation_request_command")
        }
        let expectedKeys: Set<String>
        switch command {
        case "openPendingFolderObservationSession", "capturePendingFolderObservation":
            expectedKeys = common.union(["folderID", "offeringDeviceID"])
            guard string(object, "folderID") == binding.folderID?.rawValue,
                string(object, "offeringDeviceID") == binding.offeringDeviceID?.rawValue
            else {
                throw CoreClientError.invalidResponse("observation_request_scope")
            }
        case "closeSession", "ping":
            expectedKeys = common
        default:
            throw CoreClientError.invalidResponse("observation_request_command")
        }
        guard keys(object) == expectedKeys else {
            throw CoreClientError.invalidResponse("observation_request_shape")
        }
    }

    private static func validatePendingFolderDiscoveryRequestShape(
        _ object: [(String, StrictJSONValue)],
        binding: CoreExplicitSessionBinding
    ) throws {
        let common: Set<String> = [
            "schemaVersion", "requestID", "command", "sessionID", "taskID", "planDigest",
            "expectedConfigurationRevision", "maximumNetworkBytes",
        ]
        guard let command = string(object, "command") else {
            throw CoreClientError.invalidResponse("discovery_request_command")
        }
        let expectedKeys: Set<String>
        switch command {
        case "openPendingFolderDiscoverySession", "capturePendingFolderDiscovery":
            expectedKeys = common.union(["offeringDeviceID"])
            guard value(object, "folderID") == nil,
                string(object, "offeringDeviceID") == binding.offeringDeviceID?.rawValue
            else {
                throw CoreClientError.invalidResponse("discovery_request_scope")
            }
        case "closeSession", "ping":
            expectedKeys = common
        default:
            throw CoreClientError.invalidResponse("discovery_request_command")
        }
        guard keys(object) == expectedKeys else {
            throw CoreClientError.invalidResponse("discovery_request_shape")
        }
    }

    private struct ValidatedPendingFolderDiscoveryBatch {
        let offeringDeviceID: DeviceID
        let connectionEpoch: String
        let observedAt: Date
        let offers: [PendingFolderDiscoveryOffer]
        let truncated: Bool
    }

    private static func validatedPendingFolderDiscoveryBatch(
        _ batch: [(String, StrictJSONValue)],
        binding: CoreExplicitSessionBinding,
        now: Date,
        clockTolerance: TimeInterval
    ) throws -> ValidatedPendingFolderDiscoveryBatch {
        let expectedKeys: Set<String> = [
            "offeringDeviceID", "connectionEpoch", "observedAt", "offers", "truncated",
        ]
        guard keys(batch) == expectedKeys,
            let deviceValue = string(batch, "offeringDeviceID"),
            let offeringDeviceID = DeviceID(rawValue: deviceValue),
            offeringDeviceID.rawValue == deviceValue,
            offeringDeviceID == binding.offeringDeviceID,
            let connectionEpoch = string(batch, "connectionEpoch"),
            CoreSessionDigest.isCanonicalStableVersion(connectionEpoch),
            let observedAtValue = string(batch, "observedAt"),
            let observedAt = canonicalProofTimestamp(observedAtValue),
            observedAt.date.timeIntervalSince(now) <= clockTolerance,
            now.timeIntervalSince(observedAt.date)
                <= PendingFolderDiscoveryCaptureReceipt.maximumObservationAge + clockTolerance,
            let rawOffers = array(batch, "offers"),
            rawOffers.count <= PendingFolderDiscoveryCaptureReceipt.maximumOffers,
            let truncated = boolean(batch, "truncated")
        else {
            throw CoreClientError.invalidResponse("discovery_batch")
        }

        let offerKeys: Set<String> = [
            "folderID", "offeringDeviceID", "label", "lastSeen", "offerVersion",
            "receiveEncrypted", "remoteEncrypted", "connectionEpoch", "observedAt",
        ]
        var folderIDs = Set<FolderID>()
        var offers: [PendingFolderDiscoveryOffer] = []
        offers.reserveCapacity(rawOffers.count)
        for rawOffer in rawOffers {
            guard let offer = rawOffer.objectEntries,
                keys(offer) == offerKeys,
                let folderValue = string(offer, "folderID"),
                let folderID = FolderID(rawValue: folderValue),
                folderID.rawValue == folderValue,
                folderIDs.insert(folderID).inserted,
                string(offer, "offeringDeviceID") == deviceValue,
                let label = string(offer, "label"),
                label.utf8.count <= 256,
                label.trimmingCharacters(in: .whitespacesAndNewlines) == label,
                label.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                }),
                let lastSeenValue = string(offer, "lastSeen"),
                let lastSeen = canonicalProofTimestamp(lastSeenValue),
                let offerVersion = string(offer, "offerVersion"),
                CoreSessionDigest.isCanonicalStableVersion(offerVersion),
                let receiveEncrypted = boolean(offer, "receiveEncrypted"),
                let remoteEncrypted = boolean(offer, "remoteEncrypted"),
                string(offer, "connectionEpoch") == connectionEpoch,
                string(offer, "observedAt") == observedAtValue
            else {
                throw CoreClientError.invalidResponse("discovery_offer")
            }
            let expectedOfferVersion = CoreSessionDigest.stableVersion([
                "pending-folder-v1",
                folderValue,
                label,
                deviceValue,
                lastSeenValue,
                String(receiveEncrypted),
                String(remoteEncrypted),
            ])
            guard offerVersion == expectedOfferVersion else {
                throw CoreClientError.invalidResponse("discovery_offer_integrity")
            }
            offers.append(
                PendingFolderDiscoveryOffer(
                    folderID: folderID,
                    offeringDeviceID: offeringDeviceID,
                    label: label,
                    lastSeen: lastSeen.date,
                    offerVersion: offerVersion,
                    receiveEncrypted: receiveEncrypted,
                    remoteEncrypted: remoteEncrypted,
                    connectionEpoch: connectionEpoch,
                    observedAt: observedAt.date
                )
            )
        }
        return ValidatedPendingFolderDiscoveryBatch(
            offeringDeviceID: offeringDeviceID,
            connectionEpoch: connectionEpoch,
            observedAt: observedAt.date,
            offers: offers,
            truncated: truncated
        )
    }

    private static func validatedPendingFolderObservationProof(
        _ proof: [(String, StrictJSONValue)],
        binding: CoreExplicitSessionBinding,
        now: Date,
        clockTolerance: TimeInterval
    ) throws -> PendingFolderObservationProof {
        let expectedKeys: Set<String> = [
            "proofID", "folderID", "offeringDeviceID", "offerVersion", "label", "lastSeen",
            "receiveEncrypted", "remoteEncrypted", "configurationRevision",
            "observationSessionID", "connectionEpoch", "observedAt", "expiresAt",
        ]
        guard keys(proof) == expectedKeys,
            let proofID = string(proof, "proofID"),
            let folderValue = string(proof, "folderID"),
            let folderID = FolderID(rawValue: folderValue),
            folderID.rawValue == folderValue,
            let deviceValue = string(proof, "offeringDeviceID"),
            let offeringDeviceID = DeviceID(rawValue: deviceValue),
            offeringDeviceID.rawValue == deviceValue,
            let offerVersion = string(proof, "offerVersion"),
            let label = string(proof, "label"),
            label.utf8.count <= 256,
            label.trimmingCharacters(in: .whitespacesAndNewlines) == label,
            label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            let lastSeenValue = string(proof, "lastSeen"),
            let lastSeen = canonicalProofTimestamp(lastSeenValue),
            let receiveEncrypted = boolean(proof, "receiveEncrypted"),
            let remoteEncrypted = boolean(proof, "remoteEncrypted"),
            let configurationRevision = string(proof, "configurationRevision"),
            CoreSessionDigest.isLowercaseSHA256(configurationRevision),
            let observationSessionID = string(proof, "observationSessionID"),
            let connectionEpoch = string(proof, "connectionEpoch"),
            let observedAtValue = string(proof, "observedAt"),
            let observedAt = canonicalProofTimestamp(observedAtValue),
            let expiresAtValue = string(proof, "expiresAt"),
            let expiresAt = canonicalProofTimestamp(expiresAtValue),
            CoreSessionDigest.isCanonicalStableVersion(proofID),
            CoreSessionDigest.isCanonicalStableVersion(offerVersion),
            CoreSessionDigest.isCanonicalStableVersion(connectionEpoch),
            folderID == binding.folderID,
            offeringDeviceID == binding.offeringDeviceID,
            configurationRevision == binding.expectedConfigurationRevision,
            observationSessionID == binding.sessionIDString
        else {
            throw CoreClientError.invalidResponse("observation_proof")
        }

        let (ttl, ttlOverflow) = expiresAt.nanosecondsSince1970.subtractingReportingOverflow(
            observedAt.nanosecondsSince1970
        )
        guard !ttlOverflow,
            ttl == Int64(PendingFolderObservationProof.timeToLive * 1_000_000_000),
            observedAt.date.timeIntervalSince(now) <= clockTolerance,
            now.timeIntervalSince(expiresAt.date) <= clockTolerance
        else {
            throw CoreClientError.invalidResponse("observation_proof_time")
        }

        let expectedOfferVersion = CoreSessionDigest.stableVersion([
            "pending-folder-v1",
            folderValue,
            label,
            deviceValue,
            lastSeenValue,
            String(receiveEncrypted),
            String(remoteEncrypted),
        ])
        let expectedProofID = CoreSessionDigest.stableVersion([
            "pending-folder-observation-proof-v1",
            folderValue,
            deviceValue,
            offerVersion,
            label,
            lastSeenValue,
            String(receiveEncrypted),
            String(remoteEncrypted),
            configurationRevision,
            observationSessionID,
            connectionEpoch,
            observedAtValue,
            expiresAtValue,
        ])
        guard offerVersion == expectedOfferVersion, proofID == expectedProofID else {
            throw CoreClientError.invalidResponse("observation_proof_integrity")
        }

        return PendingFolderObservationProof(
            proofID: proofID,
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            offerVersion: offerVersion,
            label: label,
            lastSeen: lastSeen.date,
            lastSeenWireValue: lastSeenValue,
            receiveEncrypted: receiveEncrypted,
            remoteEncrypted: remoteEncrypted,
            configurationRevision: configurationRevision,
            observationSessionID: observationSessionID,
            connectionEpoch: connectionEpoch,
            observedAt: observedAt.date,
            observedAtWireValue: observedAtValue,
            expiresAt: expiresAt.date,
            expiresAtWireValue: expiresAtValue
        )
    }

    private struct CanonicalProofTimestamp {
        let date: Date
        let nanosecondsSince1970: Int64
    }

    private static func canonicalProofTimestamp(
        _ value: String
    ) -> CanonicalProofTimestamp? {
        guard value.last == "Z" else { return nil }
        let body = String(value.dropLast())
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        let whole = String(pieces[0])
        let bytes = Array(whole.utf8)
        guard bytes.count == 19,
            bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
            bytes[13] == 58, bytes[16] == 58,
            bytes.enumerated().allSatisfy({ index, byte in
                [4, 7, 10, 13, 16].contains(index) || (48...57).contains(byte)
            })
        else { return nil }

        var fractionalNanoseconds: Int64 = 0
        if pieces.count == 2 {
            let fraction = pieces[1]
            guard (1...9).contains(fraction.utf8.count),
                fraction.utf8.allSatisfy({ (48...57).contains($0) }),
                fraction.last != "0",
                let parsed = Int64(fraction)
            else { return nil }
            fractionalNanoseconds = parsed
            for _ in fraction.utf8.count..<9 {
                fractionalNanoseconds *= 10
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = false
        guard let wholeDate = formatter.date(from: whole),
            formatter.string(from: wholeDate) == whole
        else { return nil }
        let seconds = Int64(wholeDate.timeIntervalSince1970)
        let (baseNanoseconds, multiplyOverflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        let (nanoseconds, addOverflow) = baseNanoseconds.addingReportingOverflow(
            fractionalNanoseconds
        )
        guard !multiplyOverflow, !addOverflow else { return nil }
        return CanonicalProofTimestamp(
            date: Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000),
            nanosecondsSince1970: nanoseconds
        )
    }

    private static func keys(_ entries: [(String, StrictJSONValue)]) -> Set<String> {
        Set(entries.map(\.0))
    }

    private static func value(
        _ entries: [(String, StrictJSONValue)],
        _ key: String
    ) -> StrictJSONValue? {
        entries.first(where: { $0.0 == key })?.1
    }

    private static func string(
        _ entries: [(String, StrictJSONValue)],
        _ key: String
    ) -> String? {
        guard case .string(let result) = value(entries, key) else { return nil }
        return result
    }

    private static func boolean(
        _ entries: [(String, StrictJSONValue)],
        _ key: String
    ) -> Bool? {
        guard case .boolean(let result) = value(entries, key) else { return nil }
        return result
    }

    private static func array(
        _ entries: [(String, StrictJSONValue)],
        _ key: String
    ) -> [StrictJSONValue]? {
        guard case .array(let result) = value(entries, key) else { return nil }
        return result
    }

    private static func integer(
        _ entries: [(String, StrictJSONValue)],
        _ key: String
    ) -> UInt64? {
        unsignedInteger(value(entries, key))
    }

    private static func unsignedInteger(_ value: StrictJSONValue?) -> UInt64? {
        guard case .number(let text) = value else { return nil }
        guard !text.hasPrefix("-"), !text.contains("."), !text.contains("e"), !text.contains("E") else {
            return nil
        }
        return UInt64(text)
    }
}
