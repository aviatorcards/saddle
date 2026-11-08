import Foundation

/// Reads `Host` entries from an OpenSSH client config (`~/.ssh/config`).
///
/// OpenSSH keeps the first value it obtains for each keyword, so a keyword that
/// appears before a `Host` block wins over the same keyword inside that block.
/// Wildcard patterns are not imported as connections, but they still contribute
/// options to concrete aliases they match. `Match` blocks and `Include` files are
/// skipped. Private keys aren't readable from the sandbox, so `IdentityFile` is
/// only recorded as a hint for the user to import the key.
nonisolated enum SSHConfigImporter {
    static func profiles(fromConfig text: String) -> [ConnectionProfile] {
        let blocks = parse(text)
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for pattern in block.patterns where isConcrete(pattern) && seen.insert(pattern).inserted {
                aliases.append(pattern)
            }
        }

        return aliases.compactMap { alias in
            var draft = Draft(host: alias)
            for block in blocks where block.applies(to: alias) {
                for (key, value) in block.options {
                    draft.apply(key, value)
                }
            }
            guard !draft.host.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var profile = ConnectionProfile()
            profile.name = alias
            profile.host = draft.host
            if let user = draft.user { profile.username = user }
            if let port = draft.port { profile.port = port }
            if let identity = draft.identity {
                profile.authMethod = .privateKey
                profile.privateKeyName = (identity as NSString).lastPathComponent
            }
            return profile.isValid ? profile : nil
        }
    }

    // MARK: Parsing

    private struct Block {
        /// Keywords before the first `Host` apply to every alias.
        var isGlobal: Bool
        var patterns: [String]
        var options: [(key: String, value: String)]

        func applies(to alias: String) -> Bool {
            if isGlobal { return true }
            let negated = patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
            if negated.contains(where: { glob($0, alias) }) { return false }
            let positive = patterns.filter { !$0.hasPrefix("!") }
            return positive.contains { glob($0, alias) }
        }
    }

    private struct Draft {
        var host: String
        var user: String?
        var port: Int?
        var identity: String?
        private var seen: Set<String> = []

        mutating func apply(_ key: String, _ value: String) {
            guard seen.insert(key).inserted else { return }
            switch key {
            case "hostname": host = value
            case "user": user = value
            case "port":
                if let port = Int(value), (1...65535).contains(port) { self.port = port }
            case "identityfile": identity = value
            default: seen.remove(key)
            }
        }
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = [Block(isGlobal: true, patterns: [], options: [])]
        var inMatch = false

        for rawLine in logicalLines(in: text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let separator = line.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? line.endIndex
            let key = line[..<separator].lowercased()
            let value = line[separator...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "host":
                inMatch = false
                blocks.append(Block(isGlobal: false, patterns: tokens(in: value), options: []))
            case "match":
                inMatch = true
            default:
                guard !inMatch, var block = blocks.last else { continue }
                block.options.append((key: String(key), value: value))
                blocks[blocks.count - 1] = block
            }
        }
        return blocks
    }

    /// Joins lines that end in an unquoted trailing backslash.
    private static func logicalLines(in text: String) -> [String] {
        var lines: [String] = []
        var pending = ""
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("\\"), !trimmed.hasSuffix("\\\\") {
                pending += trimmed.dropLast()
                continue
            }
            lines.append(pending + raw)
            pending = ""
        }
        if !pending.isEmpty { lines.append(pending) }
        return lines
    }

    private static func tokens(in value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace)
            .flatMap { $0.split(separator: ",") }
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
    }

    /// OpenSSH-style `*` and `?` match. Patterns are compared as written.
    static func glob(_ pattern: String, _ value: String) -> Bool {
        func match(_ pattern: ArraySlice<Character>, _ value: ArraySlice<Character>) -> Bool {
            if pattern.isEmpty { return value.isEmpty }
            if pattern.first == "*" {
                let rest = pattern.dropFirst()
                if match(rest, value) { return true }
                if let first = value.first, first != "\0" {
                    return match(pattern, value.dropFirst())
                }
                return false
            }
            guard let valueChar = value.first, let patternChar = pattern.first else { return false }
            guard patternChar == "?" || patternChar == valueChar else { return false }
            return match(pattern.dropFirst(), value.dropFirst())
        }
        return match(ArraySlice(pattern), ArraySlice(value))
    }
}
