import Foundation

/// Adds OpenPush to an existing extension class by inserting whole lines and
/// nothing else, so every byte of the developer's code outside them is kept.
///
/// What it inserts, each at an anchor it must find first:
/// - `import OpenPushNSE` after the last import;
/// - a stored handler property at the top of the class;
/// - `if openPush.handleIfOpenPush(…) { return }` first in `didReceive`;
/// - `if openPush.serviceExtensionTimeWillExpireIfHandling() { return }` first
///   in `serviceExtensionTimeWillExpire`, or that whole override — passing on
///   to `super` — when the class has none.
/// Any anchor it cannot find leaves the file untouched.
struct SharePatcher {
    enum Outcome: Equatable {
        case patched(text: String, insertedLines: [Int])
        case alreadyShared
        case anchorsMissing([String])
    }

    let className: String
    let appGroup: String

    func patch(_ source: String) -> Outcome {
        // Already OpenPush's: shared before, or a handler written by hand.
        if source.contains("handleIfOpenPush(") || source.contains("OpenPushNotificationServiceHandler") {
            return .alreadyShared
        }
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        var lines = source.components(separatedBy: newline)

        guard let classLine = lines.firstIndex(where: declaresClass),
              let classEnd = closingLine(of: classLine, in: lines) else {
            return .anchorsMissing(["class \(className) with its opening brace on the same line"])
        }
        // Only the principal class's own body is searched, and conditional
        // compilation inside it is never guessed at.
        let body = (classLine + 1)..<classEnd
        if lines[body].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#if") }) {
            return .anchorsMissing(["#if blocks inside class \(className)"])
        }
        var missing: [String] = []
        let receive = bodyStart(of: #"func\s+didReceive\s*\("#, in: lines, within: body)
        let signature = receive.map { lines[$0.function...$0.body].joined(separator: " ") }
        let request = signature.flatMap { capture(#"didReceive\s*\(\s*_\s+(\w+)\s*:"#, in: $0) }
        let handler = signature.flatMap {
            capture(#"withContentHandler\s+(\w+)\s*:"#, in: $0)
                ?? (capture(#"(withContentHandler)\s*:"#, in: $0))
        }
        if receive == nil || request == nil || handler == nil {
            missing.append("override func didReceive(_:withContentHandler:) with its body's brace ending a line")
        }
        let expireMarker = #"func\s+serviceExtensionTimeWillExpire\s*\(\s*\)"#
        let expire = bodyStart(of: expireMarker, in: lines, within: body)
        let expireDeclared = lines[body].contains { matches(expireMarker, stripComment($0)) }
        if expire == nil && expireDeclared {
            missing.append("override func serviceExtensionTimeWillExpire() with its body's brace ending a line")
        }
        guard missing.isEmpty, let receive, let request, let handler else { return .anchorsMissing(missing) }

        let classIndent = indentation(lines[classLine])
        let unit = indentUnit(lines, after: classLine, classIndent: classIndent)
        let member = classIndent + unit
        let property = source.range(of: #"\bopenPush\b"#, options: .regularExpression) == nil
            ? "openPush" : "openPushHandler"

        // Inserted bottom-up, so the earlier anchors keep their indices.
        var insertions: [(after: Int, lines: [String])] = []
        insertions.append((receive.body, [indentation(lines[receive.function]) + unit
            + "if \(property).handleIfOpenPush(\(request), withContentHandler: \(handler)) { return }"]))
        if let expire {
            insertions.append((expire.body, [indentation(lines[expire.function]) + unit
                + "if \(property).serviceExtensionTimeWillExpireIfHandling() { return }"]))
        }
        var block = [
            member + "private let \(property) = OpenPushNotificationServiceHandler(options: {",
            member + unit + "var options = OpenPushNotificationServiceHandler.Options()",
            member + unit + "options.appGroup = \(SwiftLiteral.string(appGroup))",
            member + unit + "return options",
            member + "}())",
        ]
        if expire == nil {
            block += [
                "",
                member + "override func serviceExtensionTimeWillExpire() {",
                member + unit + "if \(property).serviceExtensionTimeWillExpireIfHandling() { return }",
                member + unit + "super.serviceExtensionTimeWillExpire()",
                member + "}",
            ]
        }
        insertions.append((classLine, block + [""]))
        if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "import OpenPushNSE" }) {
            insertions.append((lastTopLevelImport(in: lines, before: classLine) ?? -1, ["import OpenPushNSE"]))
        }

        var inserted: [Int] = []
        for insertion in insertions.sorted(by: { $0.after > $1.after }) {
            lines.insert(contentsOf: insertion.lines, at: insertion.after + 1)
            inserted = inserted.map { $0 > insertion.after ? $0 + insertion.lines.count : $0 }
                + (0..<insertion.lines.count).map { insertion.after + 1 + $0 }
        }
        return .patched(text: lines.joined(separator: newline), insertedLines: inserted.sorted())
    }

    /// The instructions written to `.openpush/share.patch` when anchors are missing.
    func instructions(file: String, missing: [String]) -> String {
        """
        # OpenPush could not insert its lines into \(file) automatically.
        # Not found: \(missing.joined(separator: "; ")).
        # Add these to the extension class \(className) by hand, then run apply again.

        import OpenPushNSE

        // In the class body:
        private let openPush = OpenPushNotificationServiceHandler(options: {
            var options = OpenPushNotificationServiceHandler.Options()
            options.appGroup = \(SwiftLiteral.string(appGroup))
            return options
        }())

        // First line of didReceive(_:withContentHandler:):
        if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }

        // First line of serviceExtensionTimeWillExpire():
        if openPush.serviceExtensionTimeWillExpireIfHandling() { return }

        """
    }

    /// For an Objective-C extension: OpenPush's handler is a Swift API, so it
    /// goes in a Swift subclass that hands every other push to the original.
    func objectiveCInstructions(target: String, file: String, infoPlist: String?) -> String {
        """
        # \(target)'s principal class \(className) (\(file)) is Objective-C, and OpenPush's
        # handler is a Swift API, so setup does not edit it. Add OpenPush beside it with
        # a Swift subclass, then run apply again:
        #
        # 1. Give \(target) a bridging header (SWIFT_OBJC_BRIDGING_HEADER) that imports
        #    \(className)'s header.
        # 2. Add this Swift file to \(target):

        import OpenPushNSE
        import UserNotifications

        final class OpenPushNotificationService: \(className) {
            private let openPush = OpenPushNotificationServiceHandler(options: {
                var options = OpenPushNotificationServiceHandler.Options()
                options.appGroup = \(SwiftLiteral.string(appGroup))
                return options
            }())

            override func didReceive(
                _ request: UNNotificationRequest,
                withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
            ) {
                if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }
                super.didReceive(request, withContentHandler: contentHandler)
            }

            override func serviceExtensionTimeWillExpire() {
                if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
                super.serviceExtensionTimeWillExpire()
            }
        }

        # 3. In \(infoPlist ?? "the extension's Info.plist"), set NSExtensionPrincipalClass to
        #    $(PRODUCT_MODULE_NAME).OpenPushNotificationService.

        """
    }

    // MARK: - Anchors

    private func declaresClass(_ line: String) -> Bool {
        let code = stripComment(line)
        guard code.range(of: #"(^|\s)class\s+\#(className)\b"#, options: .regularExpression) != nil else { return false }
        return code.trimmingCharacters(in: .whitespaces).hasSuffix("{")
    }

    /// The line declaring `marker` (a pattern) within `range`, and the line
    /// whose brace opens its body.
    private func bodyStart(of marker: String, in lines: [String], within range: Range<Int>) -> (function: Int, body: Int)? {
        guard let function = range.first(where: { matches(marker, stripComment(lines[$0])) }) else { return nil }
        for index in function..<min(range.upperBound, function + 12) {
            let code = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            if code.hasSuffix("{") { return (function, index) }
            if code.contains("{") { return nil }
        }
        return nil
    }

    /// The line where the brace opened on `start` closes, counting braces
    /// outside string literals and comments.
    private func closingLine(of start: Int, in lines: [String]) -> Int? {
        var depth = 0
        for index in start..<lines.count {
            var inString = false
            var escaped = false
            var previous: Character = " "
            for character in lines[index] {
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "/" && previous == "/" {
                    break
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
                previous = character
            }
        }
        return nil
    }

    /// The last import at file level, outside any `#if` block.
    private func lastTopLevelImport(in lines: [String], before end: Int) -> Int? {
        var depth = 0
        var last: Int?
        for index in 0..<end {
            let code = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("#if") { depth += 1 }
            else if code.hasPrefix("#endif") { depth = max(0, depth - 1) }
            else if depth == 0, matches(#"^(@\w+\s+)*import\s"#, code) { last = index }
        }
        return last
    }

    private func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func stripComment(_ line: String) -> String {
        line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
    }

    private func indentation(_ line: String) -> String { String(line.prefix { $0 == " " || $0 == "\t" }) }

    private func indentUnit(_ lines: [String], after classLine: Int, classIndent: String) -> String {
        for line in lines[(classLine + 1)...] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = indentation(line)
            if indent.count > classIndent.count { return String(indent.dropFirst(classIndent.count)) }
            break
        }
        return "    "
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
