import Foundation

/// Reads `Host` entries from an OpenSSH client config (`~/.ssh/config`).
///
/// Only concrete aliases are imported; wildcard patterns, `Match` blocks, and options
/// Saddle doesn't use are skipped. Private keys aren't readable from the sandbox, so
/// `IdentityFile` is only recorded as a hint for the user to import the key.
enum SSHConfigImporter {
    static func profiles(fromConfig text: String) -> [ConnectionProfile] {
        var finished: [ConnectionProfile] = []
        var current: [ConnectionProfile] = []
        var inMatchBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Options are "Key value" or "Key=value".
            let separator = line.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? line.endIndex
            let key = line[..<separator].lowercased()
            let value = line[separator...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "host":
                finished += current
                inMatchBlock = false
                current = value.split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .map { alias in
                        var profile = ConnectionProfile()
                        profile.name = alias
                        profile.host = alias
                        return profile
                    }
            case "match":
                finished += current
                current = []
                inMatchBlock = true
            default:
                guard !inMatchBlock else { continue }
                for index in current.indices {
                    switch key {
                    case "hostname": current[index].host = value
                    case "user": current[index].username = value
                    case "port": current[index].port = Int(value) ?? 22
                    case "identityfile":
                        current[index].authMethod = .privateKey
                        current[index].privateKeyName = (value as NSString).lastPathComponent
                    default: break
                    }
                }
            }
        }
        return (finished + current).filter(\.isValid)
    }
}
