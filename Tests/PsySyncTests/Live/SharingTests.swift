import Foundation
import Testing
@testable import PsySync

/// Device names and pending folders, following upstream Syncthing:
/// - a configured device with an empty name takes the name from its Hello;
/// - a pending folder whose ID exists here is shared with the device, not added.
@Suite struct DeviceNamingTests {
    let id = FakeSyncEngine.sampleIDs[0]

    @Test func newDeviceTakesTypedThenReportedNameElseEmpty() {
        #expect(DeviceNaming.nameForNewDevice(entered: "  Desk  ", reported: "peer-name") == "Desk")
        #expect(DeviceNaming.nameForNewDevice(entered: "", reported: " peer-name ") == "peer-name")
        #expect(DeviceNaming.nameForNewDevice(entered: "  ", reported: nil) == "")
        #expect(DeviceNaming.nameForNewDevice(entered: "", reported: "") == "")
    }

    @Test func idPrefixIsAPlaceholder() {
        #expect(DeviceNaming.isPlaceholder("", for: id))
        #expect(DeviceNaming.isPlaceholder(id.short, for: id))
        #expect(!DeviceNaming.isPlaceholder("Desk", for: id))
        #expect(!DeviceNaming.isPlaceholder(FakeSyncEngine.sampleIDs[1].short, for: id))
    }

    @Test func adoptsRemoteNameOnlyOverPlaceholders() {
        #expect(DeviceNaming.adoptedName(current: "", remote: "peer-b", for: id) == "peer-b")
        // Migration: earlier versions stored the ID prefix.
        #expect(DeviceNaming.adoptedName(current: id.short, remote: "peer-b", for: id) == "peer-b")
        // A name the user chose stays.
        #expect(DeviceNaming.adoptedName(current: "Desk", remote: "peer-b", for: id) == nil)
        #expect(DeviceNaming.adoptedName(current: id.short, remote: "", for: id) == nil)
        #expect(DeviceNaming.adoptedName(current: id.short, remote: nil, for: id) == nil)
    }

    @Test func displayNameFallsBackToIDPrefix() {
        #expect(Device(id: id, name: "").displayName == id.short)
        #expect(Device(id: id, name: "Desk").displayName == "Desk")
    }
}

@Suite struct PendingFolderOfferTests {
    let a = FakeSyncEngine.sampleIDs[0]
    let b = FakeSyncEngine.sampleIDs[1]
    let fid = FolderID(rawValue: "shared-00001")

    @Test func classifiesOffers() {
        let existing = Folder(id: fid, label: "Local", contentMode: .onDemand, devices: [a])
        let fromB = PendingFolder(folderID: fid, label: "Remote", offeredBy: b, receivedAt: Date())
        let fromA = PendingFolder(folderID: fid, label: "Remote", offeredBy: a, receivedAt: Date())
        let other = PendingFolder(folderID: FolderID(rawValue: "other-00001"), label: "Other", offeredBy: b, receivedAt: Date())
        #expect(fromB.offer(in: [existing]) == .joinExisting(existing))
        #expect(fromA.offer(in: [existing]) == .alreadyShared(existing))
        #expect(other.offer(in: [existing]) == .newFolder)
        #expect(other.offer(in: []) == .newFolder)
        // A repeated offer from a device the folder is shared with is not shown.
        #expect([fromB, fromA, other].actionable(given: [existing]).map(\.id) == [fromB.id, other.id])
    }

    @Test func sharingOnlyAddsTheDevice() {
        let existing = Folder(id: fid, label: "Local", type: .sendReceive, location: .managed, contentMode: .onDemand, devices: [a], paused: false)
        let joined = existing.sharing(with: b)
        #expect(joined.devices == [a, b])
        #expect(joined.label == existing.label && joined.location == existing.location
                && joined.contentMode == existing.contentMode && joined.type == existing.type)
        #expect(joined.sharing(with: b) == joined)
    }

    @Test func joinPatchKeepsOtherDeviceEntries() throws {
        let config = #"""
        {"id":"shared-00001","label":"Local","path":"/x","type":"sendreceive","paused":false,
         "devices":[{"deviceID":"\#(a.rawValue)","introducedBy":"","encryptionPassword":"pw"}]}
        """#
        let patch = try #require(try LiveSyncEngine.joinedDevicesPatch(folderConfig: Data(config.utf8), device: b))
        let obj = try #require(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(Set(obj.keys) == ["devices"])   // nothing but the device list
        let devices = try #require(obj["devices"] as? [[String: Any]])
        #expect(devices.map { $0["deviceID"] as? String } == [a.rawValue, b.rawValue])
        #expect(devices[0]["encryptionPassword"] as? String == "pw")
        // Already shared: no PATCH.
        #expect(try LiveSyncEngine.joinedDevicesPatch(folderConfig: Data(config.utf8), device: a) == nil)
    }

    @Test func fakeEngineJoinsExistingFolder() async throws {
        let engine = FakeSyncEngine(named: "pending-existing")
        let pending = try #require(try await engine.pendingFolders().first { $0.offeredBy == b })
        let before = try #require(try await engine.folders().first)
        try await engine.acceptPendingFolder(pending, as: before.sharing(with: b))
        let folders = try await engine.folders()
        #expect(folders.count == 1)
        #expect(folders[0].devices == [a, b])
        #expect(folders[0].contentMode == .onDemand && folders[0].label == "Shared Notes")
        #expect(try await engine.pendingFolders().allSatisfy { $0.offeredBy != b })
    }
}

extension LiveSyncEngineTests {
    @Test func acceptingAnExistingFolderOnlySharesIt() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let a = DeviceIDCodec.random(), b = DeviceIDCodec.random()
        let id = FolderID(rawValue: "join-00001")
        try await h.engine.addFolder(Folder(id: id, label: "Local", contentMode: .onDemand, devices: [a]))
        let before = try #require(h.fake.folder(id.rawValue))
        let ignoresBefore = h.fake.ignoreLines(id.rawValue)
        let posts = StubURLProtocol.requests(authority: h.authority).filter { $0.method == "POST" && $0.path == "/rest/config/folders" }.count

        let pending = PendingFolder(folderID: id, label: "Remote", offeredBy: b, receivedAt: Date())
        // What the app passes is ignored for an existing folder.
        try await h.engine.acceptPendingFolder(pending, as: Folder(id: id, label: "Remote", contentMode: .everything))

        let after = try #require(h.fake.folder(id.rawValue))
        #expect(after.devices.map(\.deviceID) == before.devices.map(\.deviceID) + [b.rawValue])
        #expect(after.path == before.path && after.label == "Local" && after.type == before.type)
        #expect(h.fake.ignoreLines(id.rawValue) == ignoresBefore)
        let requests = StubURLProtocol.requests(authority: h.authority)
        #expect(requests.filter { $0.method == "POST" && $0.path == "/rest/config/folders" }.count == posts)
        let patches = requests.filter { $0.method == "PATCH" && $0.path == "/rest/config/folders/\(id.rawValue)" }
        #expect(patches.count == 1)
        let body = try #require(patches.first?.body)
        #expect(Set((try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]).keys) == ["devices"])
        #expect(try await h.engine.folders().first { $0.id == id }?.contentMode == .onDemand)

        // A repeated offer changes nothing.
        try await h.engine.acceptPendingFolder(pending, as: Folder(id: id, label: "Remote"))
        #expect(StubURLProtocol.requests(authority: h.authority).filter { $0.method == "PATCH" && $0.path.hasPrefix("/rest/config/folders/") }.count == 1)
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func acceptingAnUnknownFolderAddsIt() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let b = DeviceIDCodec.random()
        let id = FolderID(rawValue: "new-00001")
        try await h.engine.acceptPendingFolder(PendingFolder(folderID: id, label: "Remote", offeredBy: b, receivedAt: Date()),
                                               as: Folder(id: id, label: "Mine"))
        let added = try #require(h.fake.folder(id.rawValue))
        #expect(added.label == "Mine" && added.devices.map(\.deviceID).contains(b.rawValue))
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func connectedDeviceReplacesPlaceholderName() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let migrated = DeviceIDCodec.random(), named = DeviceIDCodec.random()
        h.fake.addDeviceConfig(DeviceConfigDTO(deviceID: migrated.rawValue, name: migrated.short, addresses: ["dynamic"],
                                               paused: false, introducer: false, autoAcceptFolders: false))
        h.fake.addDeviceConfig(DeviceConfigDTO(deviceID: named.rawValue, name: "Desk", addresses: ["dynamic"],
                                               paused: false, introducer: false, autoAcceptFolders: false))
        try await h.engine.start(context: .foreground)
        h.fake.pushEvents(#"[{"id":1,"type":"DeviceConnected","data":{"id":"\#(migrated.rawValue)","deviceName":"peer-b","addr":"1.2.3.4:22000","type":"tcp-client"}},{"id":2,"type":"DeviceConnected","data":{"id":"\#(named.rawValue)","deviceName":"peer-c","addr":"1.2.3.5:22000","type":"tcp-client"}}]"#)
        var name = ""
        for _ in 0..<100 {
            name = h.fake.device(migrated)?.name ?? ""
            if name == "peer-b" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(name == "peer-b")
        #expect(h.fake.device(named)?.name == "Desk")
        try await h.engine.stop(deadline: .seconds(1))
    }
}

@Suite struct DeviceConnectedNameTests {
    @Test func deviceConnectedCarriesReportedName() throws {
        let json = #"{"id":1,"type":"DeviceConnected","data":{"id":"D","deviceName":"peer-b","addr":"1.2.3.4:22000","type":"tcp-client"}}"#
        let actions = EventTranslator.translate(try RESTCoding.decoder().decode(RawEventDTO.self, from: Data(json.utf8)))
        #expect(actions.contains(.adoptRemoteName(DeviceID(rawValue: "D"), "peer-b")))
        let anonymous = #"{"id":1,"type":"DeviceConnected","data":{"id":"D","addr":"1.2.3.4:22000"}}"#
        #expect(!EventTranslator.translate(try RESTCoding.decoder().decode(RawEventDTO.self, from: Data(anonymous.utf8)))
            .contains { if case .adoptRemoteName = $0 { true } else { false } })
    }
}
