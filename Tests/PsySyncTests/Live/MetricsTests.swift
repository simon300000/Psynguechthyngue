import Foundation
import Testing
@testable import PsySync

@Suite struct TrafficRateMeterTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let peer = DeviceID(rawValue: "PEER")

    func sample(_ dt: TimeInterval, _ i: Int64, _ o: Int64, device: (Int64, Int64)? = nil) -> TrafficSample {
        TrafficSample(at: t0.addingTimeInterval(dt), inBytesTotal: i, outBytesTotal: o,
                      devices: device.map { [peer: DeviceTraffic(inBytesTotal: $0.0, outBytesTotal: $0.1, connectionCount: 1)] } ?? [:])
    }

    @Test func firstSampleHasNoRate() {
        var m = TrafficRateMeter()
        let unchanged = m.add(sample(0, 1000, 1000))
        #expect(unchanged == false)
        #expect(m.total == .zero)
    }

    @Test func rateIsBytesPerSecondBetweenSamples() {
        var m = TrafficRateMeter()
        m.add(sample(0, 0, 0, device: (0, 0)))
        let changed = m.add(sample(2, 4_000_000, 1_000, device: (4_000_000, 1_000)))
        #expect(changed)
        #expect(m.total == TransferRate(inPerSecond: 2_000_000, outPerSecond: 500))
        #expect(m.devices[peer] == TransferRate(inPerSecond: 2_000_000, outPerSecond: 500))
    }

    @Test func smoothsBurstsButDropsToZeroWhenIdle() {
        var m = TrafficRateMeter(smoothing: 0.5)
        m.add(sample(0, 0, 0))
        m.add(sample(1, 1000, 0))       // 1000 B/s
        m.add(sample(2, 4000, 0))       // 3000 B/s → blended 2000
        #expect(m.total.inPerSecond == 2000)
        m.add(sample(3, 4000, 0))       // idle → 0 at once
        #expect(m.total.inPerSecond == 0)
        #expect(m.total.isIdle)
    }

    @Test func counterResetGivesZeroNotNegative() {
        var m = TrafficRateMeter()
        m.add(sample(0, 10_000, 10_000))
        m.add(sample(1, 50, 20_000))     // engine restarted: in went down
        #expect(m.total.inPerSecond == 0)
        #expect(m.total.outPerSecond == 10_000)
    }

    @Test func ignoresSamplesTooCloseTogether() {
        var m = TrafficRateMeter(minimumInterval: 0.5)
        m.add(sample(0, 0, 0))
        let unchanged = m.add(sample(0.1, 1_000_000, 0))
        #expect(unchanged == false)
        #expect(m.total == .zero)
        m.add(sample(1, 1000, 0))
        #expect(m.total.inPerSecond == 1000)
    }

    @Test func newDeviceStartsAtZeroAndDisappearsWhenGone() {
        var m = TrafficRateMeter()
        m.add(sample(0, 0, 0))
        m.add(sample(1, 100, 0, device: (100, 0)))
        #expect(m.devices[peer] == .zero)
        m.add(sample(2, 300, 0, device: (300, 0)))
        #expect(m.devices[peer]?.inPerSecond == 200)
        m.add(sample(3, 300, 0))
        #expect(m.devices[peer] == nil)
        m.reset()
        #expect(m.last == nil && m.total == .zero)
    }
}

@Suite struct MetricsMappingTests {
    @Test func trafficFromRecordedConnections() throws {
        let dto = try RESTCoding.decoder().decode(ConnectionsStatsDTO.self, from: Fixtures.data("connections.json"))
        let s = MetricsMapping.traffic(dto, excluding: nil)
        #expect(s.inBytesTotal == 328 && s.outBytesTotal == 383)
        let peer = DeviceID(rawValue: "XAWZI5G-MSFFZBK-AS3Z2WO-3JAY3K7-HH6C6MB-TJJSYT2-SYN76BW-4QXLUQ7")
        #expect(s.devices[peer] == DeviceTraffic(inBytesTotal: 328, outBytesTotal: 383, connectionCount: 3))
        #expect(s.at == SyncthingDate.parse("2026-11-21T15:29:47+08:00"))
    }

    @Test func trafficSkipsSelfAndCountsDisconnectedAsZero() throws {
        let json = #"""
        {"connections":{"ME":{"connected":true,"inBytesTotal":1,"outBytesTotal":1},
                        "OFF":{"connected":false,"inBytesTotal":7,"outBytesTotal":9,"primary":null,"secondary":null}},
         "total":{"at":"0001-01-01T00:00:00Z","inBytesTotal":8,"outBytesTotal":10}}
        """#
        let dto = try RESTCoding.decoder().decode(ConnectionsStatsDTO.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 42)
        let s = MetricsMapping.traffic(dto, excluding: DeviceID(rawValue: "ME"), now: now)
        #expect(s.devices.keys.map(\.rawValue) == ["OFF"])
        #expect(s.devices[DeviceID(rawValue: "OFF")]?.connectionCount == 0)
        #expect(s.at == now)   // zero time → read time
    }

    @Test func systemInfoFromRecordedStatus() throws {
        let dto = try RESTCoding.decoder().decode(SystemStatusDetailDTO.self, from: Fixtures.data("system_status.json"))
        let info = MetricsMapping.systemInfo(dto, version: "v2.1.6")
        #expect(info.version == "v2.1.6")
        #expect(info.uptime == 28 && info.goroutines == 61)
        #expect(info.memoryAllocBytes == 2_705_792 && info.memorySysBytes == 14_956_824)
        #expect(info.syncListeners.map(\.address) == ["tcp://127.0.0.1:28412"])
        #expect(info.relayListeners.isEmpty && !info.relayConnected)
        #expect(info.startedAt == SyncthingDate.parse("2026-11-21T15:29:19+08:00"))
    }

    @Test func systemInfoDiscoveryAndRelays() throws {
        let json = #"""
        {"uptime":90,"discoveryEnabled":true,
         "discoveryStatus":{"global@https://d/v2/":{"error":"timeout"},"IPv4 local":{"error":null}},
         "connectionServiceStatus":{"dynamic+https://relays.syncthing.net/endpoint":{"error":null,"lanAddresses":[],"wanAddresses":["relay://1.2.3.4:22067"]},
                                    "tcp://0.0.0.0:22001":{"error":"bind: address in use","lanAddresses":null,"wanAddresses":null}}}
        """#
        let info = MetricsMapping.systemInfo(try RESTCoding.decoder().decode(SystemStatusDetailDTO.self, from: Data(json.utf8)), version: "v")
        #expect(info.discovery.map(\.method) == ["IPv4 local", "global@https://d/v2/"])
        #expect(info.discoveryWorking == 1)
        #expect(info.relayConnected)
        #expect(info.syncListeners.first?.error == "bind: address in use")
    }

    @Test func folderDetailsFromStatusAndStats() throws {
        let db = try RESTCoding.decoder().decode(DBCountsDTO.self, from: Data(#"""
        {"globalFiles":20000,"globalDirectories":201,"globalSymlinks":0,"globalDeleted":100100,"globalBytes":2000000,
         "localFiles":19000,"localDirectories":201,"localSymlinks":0,"localDeleted":100100,"localBytes":1900000,
         "needBytes":100000,"needTotalItems":1000}
        """#.utf8))
        let stats = try RESTCoding.decoder().decode(FolderStatsDetailDTO.self, from: Data(#"""
        {"lastScan":"2026-11-23T06:00:00+08:00","lastFile":{"at":"2026-11-23T06:01:00+08:00","filename":"d001/f000101.txt","deleted":true}}
        """#.utf8))
        let d = MetricsMapping.folderDetails(db, stats: stats)
        #expect(d.global == .init(files: 20000, directories: 201, symlinks: 0, deleted: 100_100, bytes: 2_000_000))
        #expect(d.local.files == 19000 && d.needItems == 1000)
        #expect(d.lastFile?.rawValue == "d001/f000101.txt" && d.lastFileDeleted)
        #expect(d.lastScan == SyncthingDate.parse("2026-11-23T06:00:00+08:00"))
        // Never scanned / nothing synced yet: upstream zero time and empty name.
        let empty = MetricsMapping.folderDetails(DBCountsDTO(), stats: try RESTCoding.decoder().decode(FolderStatsDetailDTO.self, from: Data(#"""
        {"lastScan":"0001-01-01T00:00:00Z","lastFile":{"at":"0001-01-01T00:00:00Z","filename":"","deleted":false}}
        """#.utf8)))
        #expect(empty.lastScan == nil && empty.lastFile == nil && empty.lastFileAt == nil)
    }
}

@Suite struct MetricsFormatTests {
    let en = Locale(identifier: "en_US")

    @Test func rates() {
        #expect(MetricsFormat.rate(0, locale: en) == "0 bytes/s")
        #expect(MetricsFormat.rate(0.4, locale: en) == MetricsFormat.rate(0, locale: en))
        #expect(MetricsFormat.rate(.nan, locale: en) == MetricsFormat.rate(0, locale: en))
        #expect(MetricsFormat.rate(1_500_000, locale: en) == "1.5 MB/s")
        #expect(MetricsFormat.rate(256_000, locale: en) == "256 kB/s")
    }

    @Test func durations() {
        #expect(MetricsFormat.duration(42, locale: en) == "42 sec")
        #expect(MetricsFormat.duration(3 * 3600 + 25 * 60 + 9, locale: en) == "3 hr, 25 min")
        #expect(MetricsFormat.duration(2 * 86_400 + 3600, locale: en) == "2 days, 1 hr")
        #expect(MetricsFormat.duration(-5, locale: en) == "0 sec")
    }

    @Test func counts() {
        #expect(MetricsFormat.count(120_000, locale: en) == "120,000")
        #expect(MetricsFormat.bytes(-1, locale: en) == MetricsFormat.bytes(0, locale: en))
    }
}

@Suite struct FakeEngineMetricsTests {
    @Test func fakeTrafficGrowsForConnectedDevicesOnly() async throws {
        let engine = FakeSyncEngine(named: "populated")
        let a = try await engine.traffic()
        try await Task.sleep(for: .milliseconds(300))
        let b = try await engine.traffic()
        #expect(a.devices.count == 1)
        #expect(b.inBytesTotal > a.inBytesTotal)
        var m = TrafficRateMeter()
        m.add(a)
        m.add(b)
        #expect(abs(m.total.inPerSecond - FakeSyncEngine.fakeRate.inPerSecond) < FakeSyncEngine.fakeRate.inPerSecond * 0.2)
        let info = try await engine.systemInfo()
        #expect(info.relayConnected && info.discoveryWorking == 3)
        let details = try await engine.folderDetails(FolderID(rawValue: "docum-ents1"))
        #expect(details.global.files > 0 && details.global.bytes == 5_000_000)
    }
}
