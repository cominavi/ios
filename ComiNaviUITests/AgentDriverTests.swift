import XCTest

/// A long-lived XCUITest driver that an agent controls one command at a time.
///
/// `Scripts/sim/cominavi-sim driver start` runs this test once with
/// `AGENT_DRIVER_DIR` (passed as `TEST_RUNNER_AGENT_DRIVER_DIR`) pointing at a
/// host directory. The test writes `ready`, then serves command files:
///
/// - The host writes `inbox/<seq>.cmd` (one command line, written atomically).
/// - The driver answers in `outbox/<seq>.json`:
///   `{"ok":true,"ms":123,"result":"..."}` or `{"ok":false,"ms":..,"error":".."}`.
///
/// Elements are resolved from one accessibility snapshot per attempt and
/// tapped by coordinate. This avoids XCUITest's per-query idle waits, which
/// can take tens of seconds while the map keeps rendering.
///
/// Without `AGENT_DRIVER_DIR` the test is skipped, so ordinary UI-test runs
/// are unaffected. See docs/simulator-automation.md.
final class AgentDriverTests: XCTestCase {
    private static let bundleID = "llc.mikunet.cominavi.debug"
    private static let defaultArguments = [
        "-cominavi-ui-testing-hide-debugger",
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
    ]

    private var app: XCUIApplication!
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())
    /// XCTest issues raised while a command runs. They become that command's
    /// error instead of failing (and ending) the long-lived test.
    private var commandIssues: [String] = []

    override func record(_ issue: XCTIssue) {
        commandIssues.append(issue.compactDescription)
    }

    @MainActor
    func testServe() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENT_DRIVER_DIR"] else {
            throw XCTSkip("AGENT_DRIVER_DIR is not set; the agent driver only runs from cominavi-sim")
        }
        continueAfterFailure = true
        directory = URL(fileURLWithPath: path)
        let inbox = directory.appendingPathComponent("inbox")
        let outbox = directory.appendingPathComponent("outbox")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outbox, withIntermediateDirectories: true)

        // Attach to the app without relaunching it; `launch` relaunches.
        app = XCUIApplication(bundleIdentifier: Self.bundleID)
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            .write(to: directory.appendingPathComponent("ready"), options: .atomic)

        var running = true
        while running {
            let names = (try? fileManager.contentsOfDirectory(atPath: inbox.path)) ?? []
            let pending = names.filter { $0.hasSuffix(".cmd") }.sorted {
                (Int($0.dropLast(4)) ?? 0) < (Int($1.dropLast(4)) ?? 0)
            }
            if pending.isEmpty {
                Thread.sleep(forTimeInterval: 0.03)
                continue
            }
            for name in pending {
                let file = inbox.appendingPathComponent(name)
                // Strip only the host's framing newline: `type` payloads keep
                // leading, trailing and space-only text.
                var line = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if line.hasSuffix("\n") { line.removeLast() }
                if line.hasSuffix("\r") { line.removeLast() }
                try? fileManager.removeItem(at: file)
                let start = Date()
                var response: [String: Any]
                commandIssues.removeAll()
                do {
                    let result = try execute(line, stop: &running)
                    response = commandIssues.isEmpty
                        ? ["ok": true, "result": result]
                        : ["ok": false, "error": commandIssues.joined(separator: "\n")]
                } catch {
                    response = ["ok": false, "error": String(describing: error)]
                }
                response["ms"] = Int(Date().timeIntervalSince(start) * 1000)
                response["command"] = line
                let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                let tmp = outbox.appendingPathComponent(".\(name).tmp")
                try data.write(to: tmp)
                try? fileManager.removeItem(at: outbox.appendingPathComponent(String(name.dropLast(4)) + ".json"))
                try fileManager.moveItem(at: tmp, to: outbox.appendingPathComponent(String(name.dropLast(4)) + ".json"))
                if !running { break }
            }
        }
        try? fileManager.removeItem(at: directory.appendingPathComponent("ready"))
    }

    // MARK: - Commands

    private struct DriverError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private func execute(_ line: String, stop: inout Bool) throws -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let command = words.first else { throw DriverError("empty command") }
        let rest = words.dropFirst()
        /// Everything after the first `count` words, with original spacing.
        func tail(after count: Int) -> String {
            var remainder = Substring(line)
            for _ in 0 ..< count {
                remainder = remainder.drop(while: { $0 == " " }).drop(while: { $0 != " " })
            }
            return String(remainder.dropFirst())
        }

        switch command {
        case "ping":
            return "pong"
        case "stop":
            stop = true
            return "stopping"
        case "attach":
            // `cominavi-sim driver cmd launch` starts the app with simctl, then
            // attaches here. That skips XCUITest's launch-time idle wait, which
            // can take 25 s or more while the app keeps animating.
            // A fresh handle per poll: a handle created before the process
            // existed can keep reporting `notRunning`.
            let start = Date()
            var activated = false
            while Date().timeIntervalSince(start) < 30 {
                app = XCUIApplication(bundleIdentifier: Self.bundleID)
                switch app.state {
                case .runningForeground:
                    return "attached"
                case .runningBackground, .runningBackgroundSuspended:
                    // Right after `driver start` the test runner can be in front.
                    if !activated, Date().timeIntervalSince(start) > 2 {
                        app.activate()
                        activated = true
                    }
                default:
                    // On the first launch after `driver start`, XCUITest can
                    // keep reporting `notRunning` for an app simctl already
                    // launched. Relaunch through XCUITest with the same
                    // arguments (`attach` receives them from cominavi-sim).
                    if Date().timeIntervalSince(start) > 3 {
                        app.terminate()
                        app.launchArguments = Self.defaultArguments + rest
                        app.launch()
                        guard app.wait(for: .runningForeground, timeout: 30) else {
                            throw DriverError("the app did not reach the foreground")
                        }
                        return "attached (relaunched through XCUITest)"
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw DriverError("the app is not in the foreground (state \(app.state.rawValue))")
        case "xcui-launch":
            app.terminate()
            app = XCUIApplication(bundleIdentifier: Self.bundleID)
            app.launchArguments = Self.defaultArguments + rest
            app.launch()
            guard app.wait(for: .runningForeground, timeout: 30) else {
                throw DriverError("app did not reach the foreground")
            }
            return "launched"
        case "activate":
            app.activate()
            return "activated"
        case "terminate":
            app.terminate()
            return "terminated"
        case "url":
            guard let url = URL(string: tail(after: 1)), url.scheme != nil else {
                throw DriverError("usage: url <url>")
            }
            // Opens through the app, so no SpringBoard "Open in" confirmation.
            app.open(url)
            return "opened \(url.absoluteString)"
        case "tap":
            let (frame, description) = try resolve(rest, timeout: 5)
            tap(at: CGPoint(x: frame.midX, y: frame.midY))
            return "tapped \(description) at \(Int(frame.midX)),\(Int(frame.midY))"
        case "tap-point":
            guard rest.count == 2, let x = Double(rest[rest.startIndex]),
                  let y = Double(rest[rest.startIndex + 1])
            else { throw DriverError("usage: tap-point <x> <y>") }
            tap(at: CGPoint(x: x, y: y))
            return "tapped \(Int(x)),\(Int(y))"
        case "long-press":
            let (frame, description) = try resolve(rest, timeout: 5)
            coordinate(CGPoint(x: frame.midX, y: frame.midY)).press(forDuration: 1.0)
            return "long-pressed \(description)"
        case "type":
            try requireKeyboardFocus()
            app.typeText(tail(after: 1))
            return "typed"
        case "key":
            // return | delete | escape | tab
            let keys: [String: String] = [
                "return": "\n", "enter": "\n", "delete": XCUIKeyboardKey.delete.rawValue,
                "escape": XCUIKeyboardKey.escape.rawValue, "tab": "\t",
            ]
            guard let key = rest.first.flatMap({ keys[$0] }) else {
                throw DriverError("usage: key return|delete|escape|tab")
            }
            try requireKeyboardFocus()
            app.typeText(key)
            return "pressed \(rest.first!)"
        case "swipe":
            let direction = rest.first ?? "up"
            let size = app.frame.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let delta: CGVector = switch direction {
            case "up": CGVector(dx: 0, dy: -size.height * 0.35)
            case "down": CGVector(dx: 0, dy: size.height * 0.35)
            case "left": CGVector(dx: -size.width * 0.35, dy: 0)
            case "right": CGVector(dx: size.width * 0.35, dy: 0)
            default: throw DriverError("usage: swipe up|down|left|right")
            }
            coordinate(center).press(
                forDuration: 0.05,
                thenDragTo: coordinate(CGPoint(x: center.x + delta.dx, y: center.y + delta.dy))
            )
            return "swiped \(direction)"
        case "wait":
            let (selector, timeout) = splitTimeout(rest, default: 10)
            let (_, description) = try resolve(selector, timeout: timeout)
            return "found \(description)"
        case "gone":
            let (selector, timeout) = splitTimeout(rest, default: 10)
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                // A malformed selector is an error, never a successful "gone".
                if try find(selector, in: snapshot()) == nil { return "gone" }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
            throw DriverError("still present after \(timeout)s: \(selector.joined(separator: " "))")
        case "tree":
            var lines: [String] = []
            flatten(try snapshot(), into: &lines, all: rest.first == "--all")
            return lines.joined(separator: "\n")
        case "shot":
            let path = tail(after: 1)
            guard !path.isEmpty else { throw DriverError("usage: shot <host path>") }
            try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
            return path
        case "alert":
            return describeAlerts()
        case "alert-tap":
            return try tapAlertButton(tail(after: 1))
        case "state":
            let states = ["unknown", "notRunning", "runningBackgroundSuspended", "runningBackground", "runningForeground"]
            let raw = Int(app.state.rawValue)
            return states.indices.contains(raw) ? states[raw] : "\(raw)"
        case "orientation":
            switch rest.first {
            case "portrait": XCUIDevice.shared.orientation = .portrait
            case "left": XCUIDevice.shared.orientation = .landscapeLeft
            case "right": XCUIDevice.shared.orientation = .landscapeRight
            default: throw DriverError("usage: orientation portrait|left|right")
            }
            return "orientation \(rest.first!)"
        case "home":
            XCUIDevice.shared.press(.home)
            return "home"
        default:
            throw DriverError("unknown command \(command); see docs/simulator-automation.md")
        }
    }

    @MainActor
    private func requireKeyboardFocus() throws {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
        guard focused.count > 0 else {
            throw DriverError("no element has keyboard focus; tap a text field first")
        }
    }

    // MARK: - Element resolution

    @MainActor
    private func snapshot() throws -> any XCUIElementSnapshot {
        try app.snapshot()
    }

    /// Selector forms: `id <identifier>`, `label <label>`, `text <substring>`.
    /// The remainder after the kind keeps its spaces.
    @MainActor
    private func find(_ selector: some Collection<String>, in root: any XCUIElementSnapshot) throws -> (any XCUIElementSnapshot)? {
        guard let kind = selector.first, selector.count >= 2 else {
            throw DriverError("selector must be id|label|text <value>")
        }
        let value = selector.dropFirst().joined(separator: " ")
        let matches: (any XCUIElementSnapshot) -> Bool = switch kind {
        case "id": { $0.identifier == value }
        case "label": { $0.label == value }
        case "text": { $0.label.localizedCaseInsensitiveContains(value) }
        default: throw DriverError("selector kind must be id, label or text")
        }
        var stack: [any XCUIElementSnapshot] = [root]
        var fallback: (any XCUIElementSnapshot)?
        while let node = stack.popLast() {
            if matches(node), !node.frame.isEmpty {
                // Prefer a hittable-looking element on screen.
                if app.frame.intersects(node.frame) { return node }
                fallback = fallback ?? node
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return fallback
    }

    @MainActor
    private func resolve(_ selector: some Collection<String>, timeout: TimeInterval) throws -> (CGRect, String) {
        let deadline = Date().addingTimeInterval(timeout)
        let text = selector.joined(separator: " ")
        repeat {
            if let node = try find(selector, in: snapshot()) {
                return (node.frame, "\(name(of: node.elementType)) \(text)")
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        throw DriverError("not found after \(timeout)s: \(text)")
    }

    private func splitTimeout(_ words: ArraySlice<String>, default value: TimeInterval) -> ([String], TimeInterval) {
        if words.count > 2, let last = words.last, let seconds = TimeInterval(last) {
            return (Array(words.dropLast()), seconds)
        }
        return (Array(words), value)
    }

    @MainActor
    private func coordinate(_ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    @MainActor
    private func tap(at point: CGPoint) {
        coordinate(point).tap()
    }

    // MARK: - Alerts

    @MainActor
    private func alertSources() -> [(String, XCUIApplication)] {
        [("app", app), ("springboard", XCUIApplication(bundleIdentifier: "com.apple.springboard"))]
    }

    @MainActor
    private func describeAlerts() -> String {
        var lines: [String] = []
        for (source, owner) in alertSources() {
            for alert in owner.alerts.allElementsBoundByIndex where alert.exists {
                let buttons = alert.buttons.allElementsBoundByIndex.map(\.label)
                lines.append("\(source): \"\(alert.label)\" buttons=\(buttons)")
            }
        }
        return lines.isEmpty ? "no alerts" : lines.joined(separator: "\n")
    }

    @MainActor
    private func tapAlertButton(_ label: String) throws -> String {
        for (source, owner) in alertSources() {
            for alert in owner.alerts.allElementsBoundByIndex where alert.exists {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return "tapped \(source) alert button \(label)"
                }
            }
        }
        throw DriverError("no alert button labelled \(label)")
    }

    // MARK: - Tree output

    /// Same line shape as Scripts/sim/ax-flatten.py, so agents read one format.
    @MainActor
    private func flatten(_ node: any XCUIElementSnapshot, into lines: inout [String], all: Bool) {
        let interactive: Set<XCUIElement.ElementType> = [
            .button, .textField, .searchField, .secureTextField, .switch, .slider,
            .cell, .link, .tab, .radioButton, .toggle, .popUpButton, .menuItem,
        ]
        let value = (node.value as? CustomStringConvertible)?.description ?? ""
        let frame = node.frame
        let interesting = !node.label.isEmpty || !value.isEmpty || !node.identifier.isEmpty
            || interactive.contains(node.elementType)
        if all || (interesting && frame.width > 0 && frame.height > 0) {
            var parts = [name(of: node.elementType)]
            if !node.label.isEmpty { parts.append(quoted(node.label)) }
            if !value.isEmpty { parts.append("value=" + quoted(value)) }
            if !node.identifier.isEmpty { parts.append("id=" + node.identifier) }
            if node.isSelected { parts.append("selected") }
            if !node.isEnabled { parts.append("disabled") }
            parts.append(String(
                format: "@ %g,%g %gx%g  center=(%g,%g)",
                frame.minX.rounded(), frame.minY.rounded(), frame.width.rounded(), frame.height.rounded(),
                frame.midX.rounded(), frame.midY.rounded()
            ))
            lines.append(parts.joined(separator: " "))
        }
        for child in node.children {
            flatten(child, into: &lines, all: all)
        }
    }

    private func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private func name(of type: XCUIElement.ElementType) -> String {
        let names: [XCUIElement.ElementType: String] = [
            .application: "Application", .window: "Window", .other: "Other", .group: "Group",
            .button: "Button", .staticText: "StaticText", .textField: "TextField",
            .searchField: "SearchField", .secureTextField: "SecureTextField", .image: "Image",
            .cell: "Cell", .link: "Link", .switch: "Switch", .toggle: "Toggle", .slider: "Slider",
            .scrollView: "ScrollView", .table: "Table", .collectionView: "CollectionView",
            .navigationBar: "NavigationBar", .tabBar: "TabBar", .tab: "Tab", .toolbar: "Toolbar",
            .alert: "Alert", .sheet: "Sheet", .radioButton: "RadioButton", .popUpButton: "PopUpButton",
            .menuItem: "MenuItem", .map: "Map", .keyboard: "Keyboard", .key: "Key",
            .progressIndicator: "ProgressIndicator", .activityIndicator: "ActivityIndicator",
            .webView: "WebView", .segmentedControl: "SegmentedControl", .picker: "Picker",
        ]
        return names[type] ?? "Element\(type.rawValue)"
    }
}
