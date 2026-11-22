import XCTest

/// Remote-controlled driver for real-device acceptance runs (not part of the
/// normal suite: skipped unless `PSY_DEVICE_DRIVER=1` is in the runner's
/// environment, e.g. `TEST_RUNNER_PSY_DEVICE_DRIVER=1 xcodebuild test …`).
///
/// The Mac drops `cmd-<seq>.json` into the runner's Documents directory with
/// `xcrun devicectl device copy to --domain-type appDataContainer`; the driver
/// executes it and writes `res-<seq>.json` (+ optional PNG / tree text), which
/// the Mac copies back. No network is involved, so no Local Network prompt for
/// the runner. See `Docs/REWRITE/notes/accept-ipad/README.md`.
@MainActor
final class DeviceDriverUITests: XCTestCase {
    private let appBundleID = "moe.simon3k.Psynguechthyngue"

    struct Command: Decodable {
        var op: String
        var bundle: String?
        var id: String?
        var label: String?
        var text: String?
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var seconds: Double?
        var name: String?
        var args: [String]?
        var env: [String: String]?
    }

    func testDriver() throws {
        guard ProcessInfo.processInfo.environment["PSY_DEVICE_DRIVER"] == "1" else {
            throw XCTSkip("device driver disabled")
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        // The runner container survives reinstalls: drop the previous run's
        // commands so they are not replayed (sequence numbers restart at 1).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        where name.hasPrefix("cmd-") || name.hasPrefix("res-") || name.hasPrefix("shot-") || name.hasPrefix("tree-") {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
        }
        try "ready \(Date())".write(to: docs.appendingPathComponent("driver-ready.txt"), atomically: true, encoding: .utf8)
        var current = XCUIApplication(bundleIdentifier: appBundleID)
        var seq = 0
        let deadline = Date().addingTimeInterval(4 * 3600)
        while Date() < deadline {
            let next = seq + 1
            let url = docs.appendingPathComponent("cmd-\(next).json")
            guard let data = try? Data(contentsOf: url) else {
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }
            seq = next
            var out: [String: Any] = ["seq": seq, "ok": true]
            do {
                let cmd = try JSONDecoder().decode(Command.self, from: data)
                if cmd.op == "quit" { write(out, seq, docs); return }
                try run(cmd, app: &current, docs: docs, seq: seq, out: &out)
            } catch {
                out["ok"] = false
                out["error"] = "\(error)"
            }
            write(out, seq, docs)
        }
    }

    private func write(_ out: [String: Any], _ seq: Int, _ docs: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
            try? data.write(to: docs.appendingPathComponent("res-\(seq).json"))
        }
    }

    struct DriverError: Error, CustomStringConvertible { let description: String }

    private func element(_ cmd: Command, in app: XCUIApplication) throws -> XCUIElement {
        let q = app.descendants(matching: .any)
        let e: XCUIElement
        if let id = cmd.id {
            e = q.matching(identifier: id).firstMatch
        } else if let label = cmd.label {
            e = q.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists
                ? q.matching(NSPredicate(format: "label == %@", label)).firstMatch
                : q.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        } else {
            throw DriverError(description: "need id or label")
        }
        guard e.waitForExistence(timeout: cmd.seconds ?? 5) else { throw DriverError(description: "not found") }
        return e
    }

    private func run(_ cmd: Command, app: inout XCUIApplication, docs: URL, seq: Int, out: inout [String: Any]) throws {
        switch cmd.op {
        case "use":            // switch target app without launching
            app = XCUIApplication(bundleIdentifier: cmd.bundle ?? appBundleID)
        case "launch":
            app = XCUIApplication(bundleIdentifier: cmd.bundle ?? appBundleID)
            if let args = cmd.args { app.launchArguments = args }
            if let env = cmd.env { app.launchEnvironment = env }
            app.launch()
        case "activate":
            app = XCUIApplication(bundleIdentifier: cmd.bundle ?? appBundleID)
            app.activate()
        case "terminate":
            XCUIApplication(bundleIdentifier: cmd.bundle ?? appBundleID).terminate()
        case "home":
            XCUIDevice.shared.press(.home)
        case "orientation":
            XCUIDevice.shared.orientation = cmd.name == "portrait" ? .portrait : .landscapeLeft
        case "appearance":
            XCUIDevice.shared.appearance = cmd.name == "dark" ? .dark : .light
        case "tap":
            try element(cmd, in: app).tap()
        case "longpress":
            try element(cmd, in: app).press(forDuration: cmd.seconds ?? 1.2)
        case "tapxy":
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: cmd.x ?? 0, dy: cmd.y ?? 0)).tap()
        case "longpressxy":
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: cmd.x ?? 0, dy: cmd.y ?? 0)).press(forDuration: cmd.seconds ?? 1.2)
        case "drag":
            let o = app.coordinate(withNormalizedOffset: .zero)
            o.withOffset(CGVector(dx: cmd.x ?? 0, dy: cmd.y ?? 0))
                .press(forDuration: 0.1, thenDragTo: o.withOffset(CGVector(dx: cmd.x2 ?? 0, dy: cmd.y2 ?? 0)))
        case "type":
            if cmd.id != nil || cmd.label != nil {
                let e = try element(cmd, in: app)
                e.tap()
                e.typeText(cmd.text ?? "")
            } else {
                app.typeText(cmd.text ?? "")
            }
        case "clear":
            let e = try element(cmd, in: app)
            e.tap()
            if let v = e.value as? String, !v.isEmpty {
                e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 2))
            }
        case "swipe":
            let e = (cmd.id != nil || cmd.label != nil) ? try element(cmd, in: app) : app
            switch cmd.name {
            case "down": e.swipeDown()
            case "left": e.swipeLeft()
            case "right": e.swipeRight()
            default: e.swipeUp()
            }
        case "alert":          // tap a button in a springboard (system) alert
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let b = sb.buttons[cmd.label ?? "Allow"]
            guard b.waitForExistence(timeout: cmd.seconds ?? 5) else { throw DriverError(description: "no alert button") }
            b.tap()
        case "exists":
            let e: XCUIElement? = try? element(cmd, in: app)
            out["exists"] = e != nil
            if let e { out["label"] = e.label; out["value"] = "\(e.value ?? "")"; out["frame"] = "\(e.frame)" }
        case "wait":
            Thread.sleep(forTimeInterval: cmd.seconds ?? 1)
        case "screenshot":
            let shot = (cmd.bundle == "screen") ? XCUIScreen.main.screenshot() : XCUIScreen.main.screenshot()
            let file = "shot-\(seq)-\(cmd.name ?? "s").png"
            try shot.pngRepresentation.write(to: docs.appendingPathComponent(file))
            out["file"] = file
        case "tree":
            let file = "tree-\(seq).txt"
            try app.debugDescription.write(to: docs.appendingPathComponent(file), atomically: true, encoding: .utf8)
            out["file"] = file
        case "state":
            out["state"] = app.state.rawValue
        default:
            throw DriverError(description: "unknown op \(cmd.op)")
        }
    }
}
