import XCTest

/// Manual acceptance driver for the REAL embedded engine (no fixture).
/// Skipped unless the runner gets `PSY_ACCEPT=1` (xcodebuild:
/// `TEST_RUNNER_PSY_ACCEPT=1`). Steps come from `PSY_ACCEPT_STEPS`, one per
/// line, so a host-side script can interleave app actions with peer actions:
///
///     launch [args…]        launch (keeps state; English UI)
///     activate              bring the app to the foreground without relaunching
///     terminate
///     useApp [bundleID]     drive another app (Files) / back to this app
///     tapCell <text> / longPress <text> / typeKeys <text>
///     tap <id>              tap element with accessibility identifier
///     tapLabel <text>       tap first button / element whose label contains text
///     wait <id> [s]         wait for identifier (default 60 s)
///     waitLabel <text> [s]  wait for any element whose label contains text
///     gone <id|text> [s]    wait until it disappears
///     tab <label>           switch tab
///     switch <id> on|off    set a switch
///     assertSwitch <id> on|off
///     type <id> <text>      tap field, select all, type text (+ return)
///     editor <id> <text>    replace TextEditor contents (\n allowed)
///     assertValue <id> <text>  element value contains text
///     scrollTo <id>         scroll until visible
///     back                  navigation back
///     swipeUp / swipeDown
///     sleep <s>
///     shot <name>           screenshot → $PSY_ACCEPT_OUT/<name>.png (and attachment)
///     dump <name>           accessibility tree → $PSY_ACCEPT_OUT/<name>.txt
final class AcceptanceDriverUITests: PsyUITestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testRunAcceptanceSteps() throws {
        try XCTSkipUnless(env["PSY_ACCEPT"] == "1", "acceptance driver: set TEST_RUNNER_PSY_ACCEPT=1")
        app = XCUIApplication()
        let steps = (env["PSY_ACCEPT_STEPS"] ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for (n, line) in steps.enumerated() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let cmd = parts[0], rest = parts.count > 1 ? parts[1] : ""
            print("[accept] step \(n + 1): \(line)")
            try run(cmd, rest)
        }
    }

    private func split2(_ s: String) -> (String, String) {
        let p = s.split(separator: " ", maxSplits: 1).map(String.init)
        return (p.first ?? "", p.count > 1 ? p[1] : "")
    }

    /// "<target> [seconds]" where the target may contain spaces.
    private func targetAndTimeout(_ s: String, _ fallback: TimeInterval = 60) -> (String, TimeInterval) {
        if let r = s.range(of: " ", options: .backwards), let t = TimeInterval(s[r.upperBound...]) {
            return (String(s[..<r.lowerBound]), t)
        }
        return (s, fallback)
    }

    private func run(_ cmd: String, _ rest: String) throws {
        switch cmd {
        case "launch":
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                + rest.split(separator: " ").map(String.init)
            app.launch()
        case "activate": app.activate()
        case "useApp":
            // e.g. `useApp com.apple.DocumentsApp` (Files); `useApp` alone → this app.
            app = rest.isEmpty ? XCUIApplication() : XCUIApplication(bundleIdentifier: rest)
            if rest.isEmpty { app.activate() } else { app.launch() }
        case "tapCell":
            // Files app items: tap a cell / any element whose label contains text.
            let e = app.cells.matching(NSPredicate(format: "label CONTAINS %@", rest)).firstMatch
            let target = e.waitForExistence(timeout: 15) ? e : anyLabel(rest)
            XCTAssertTrue(target.waitForExistence(timeout: 15), "missing cell \(rest)")
            target.tap()
        case "longPress":
            let e = app.cells.matching(NSPredicate(format: "label CONTAINS %@", rest)).firstMatch
            let target = e.waitForExistence(timeout: 15) ? e : anyLabel(rest)
            XCTAssertTrue(target.waitForExistence(timeout: 15), "missing \(rest)")
            target.press(forDuration: 1.2)
        case "typeKeys": app.typeText(rest.replacingOccurrences(of: "\\n", with: "\n"))
        case "terminate": app.terminate()
        case "tap":
            let e = el(rest)
            for _ in 0..<6 where !e.waitForExistence(timeout: 3) { app.swipeUp() }
            XCTAssertTrue(e.waitForExistence(timeout: 20), "missing \(rest)")
            scrollTo(e)
            e.tap()
        case "tapLabel":
            let e = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", rest)).firstMatch
            for _ in 0..<6 where !e.waitForExistence(timeout: 2) && !anyLabel(rest).exists { app.swipeUp() }
            let target = e.exists ? e : anyLabel(rest)
            XCTAssertTrue(target.waitForExistence(timeout: 10), "missing label \(rest)")
            scrollTo(target)
            target.tap()
        case "wait":
            let (id, t) = targetAndTimeout(rest)
            XCTAssertTrue(el(id).waitForExistence(timeout: t), "timeout waiting for \(id)")
        case "waitLabel":
            let (label, t) = targetAndTimeout(rest)
            XCTAssertTrue(anyLabel(label).waitForExistence(timeout: t), "timeout waiting for label \(label)")
        case "gone":
            let (target, t) = targetAndTimeout(rest)
            let e = el(target).exists ? el(target) : anyLabel(target)
            XCTAssertTrue(waitGone(e, timeout: t), "still present: \(target)")
        case "tab": tab(rest)
        case "switch", "assertSwitch":
            let (id, want) = split2(rest)
            let s = app.switches[id]
            for _ in 0..<6 where !s.waitForExistence(timeout: 3) { app.swipeUp() }
            XCTAssertTrue(s.waitForExistence(timeout: 15), "switch \(id)")
            scrollTo(s)
            let on = (s.value as? String) == "1"
            if cmd == "assertSwitch" {
                XCTAssertEqual(on, want == "on", "\(id) is \(on ? "on" : "off")")
            } else if on != (want == "on") {
                tapSwitch(id)
                let exp = expectation(for: NSPredicate(format: "value == %@", want == "on" ? "1" : "0"), evaluatedWith: s)
                XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 10), .completed, "\(id) did not turn \(want)")
            }
        case "type":
            let (id, text) = split2(rest)
            let f = el(id)
            for _ in 0..<6 where !f.waitForExistence(timeout: 3) { app.swipeUp() }
            XCTAssertTrue(f.waitForExistence(timeout: 15), "field \(id)")
            scrollTo(f)
            f.tap()
            f.press(forDuration: 1.0)
            if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
            f.typeText(XCUIKeyboardKey.delete.rawValue)
            f.typeText(text + "\n")
        case "editor":
            let (id, text) = split2(rest)
            let f = el(id)
            XCTAssertTrue(f.waitForExistence(timeout: 15), "editor \(id)")
            f.tap()
            let existing = (f.value as? String) ?? ""
            f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
            f.typeText(text.replacingOccurrences(of: "\\n", with: "\n"))
        case "assertValue":
            let (id, want) = split2(rest)
            let f = el(id)
            for _ in 0..<6 where !f.waitForExistence(timeout: 3) { app.swipeUp() }
            XCTAssertTrue(((f.value as? String) ?? "").contains(want), "\(id) value is \(String(describing: f.value))")
        case "scrollTo": scrollTo(el(rest))
        case "back":
            let b = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(b.waitForExistence(timeout: 5))
            b.tap()
        case "swipeUp": app.swipeUp()
        case "swipeDown": app.swipeDown()
        case "sleep": Thread.sleep(forTimeInterval: TimeInterval(rest) ?? 1)
        case "shot":
            let shot = XCUIScreen.main.screenshot()
            let a = XCTAttachment(screenshot: shot); a.name = rest; a.lifetime = .keepAlways; add(a)
            if let dir = env["PSY_ACCEPT_OUT"] {
                try shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(rest).png"))
            }
        case "dump":
            if let dir = env["PSY_ACCEPT_OUT"] {
                try app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(rest).txt"), atomically: true, encoding: .utf8)
            }
        default:
            XCTFail("unknown step \(cmd)")
        }
    }
}
