import Foundation

enum RepoParser {
    static func parseRelease(_ text: String, url: String, hadReleaseFile: Bool) -> RepoInfo {
        var repo = RepoInfo(url: url)
        guard hadReleaseFile else {
            repo.origin = url
            return repo
        }

        var lastKey: String?
        for line in lines(stripBOM(text)) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let key = lastKey else { continue }
                let value = line.trimmingCharacters(in: .whitespaces)
                appendReleaseValue(value, for: key, to: &repo)
                continue
            }
            guard let (key, value) = field(line) else {
                lastKey = nil
                continue
            }
            lastKey = key
            switch key {
            case "origin": repo.origin = value
            case "label": repo.label = value
            case "suite": repo.suite = value
            case "version": repo.version = value
            case "codename": repo.codename = value
            case "architectures": repo.architectures = value
            case "components": repo.components = value
            case "description": repo.description = value
            default: break
            }
        }
        return repo
    }

    static func parsePackages(_ text: String) -> [Package] {
        var packages: [Package] = []
        var current = Package()
        var hasField = false
        var lastKey: String?

        func flush() {
            if hasField {
                packages.append(current)
                current = Package()
                hasField = false
            }
            lastKey = nil
        }

        for line in lines(stripBOM(text)) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }

            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let key = lastKey else { continue }
                let value = line.trimmingCharacters(in: .whitespaces)
                appendPackageValue(value, for: key, to: &current)
                continue
            }

            guard let (key, value) = field(line) else {
                lastKey = nil
                continue
            }
            hasField = true
            lastKey = key
            setPackageValue(value, for: key, to: &current)
        }

        flush()
        return packages
    }

    static func sections(from packages: [Package]) -> [SectionNode] {
        var grouped: [String: [String: [Package]]] = [:]
        for (index, package) in packages.enumerated() {
            let section = package.section.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = section.isEmpty ? "Uncategorized" : section
            let identity: String
            if !package.packageID.isEmpty {
                identity = package.packageID
            } else if !package.displayName.isEmpty {
                identity = package.displayName
            } else {
                identity = "unknown-\(index)"
            }
            grouped[name, default: [:]][identity, default: []].append(package)
        }

        return grouped.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { section in
            let groups = grouped[section, default: [:]].map { identity, versions -> PackageGroup in
                let sorted = versions.sorted { VersionCompare.isNewer($0.version, than: $1.version) }
                var seen = Set<String>()
                let unique = sorted.filter { seen.insert($0.version).inserted }
                return PackageGroup(id: "\(section)|\(identity)", versions: unique)
            }.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return SectionNode(name: section, packages: groups)
        }
    }

    /// URLSession may transparently decode a `Content-Encoding: gzip` response,
    /// so a `.gz` package list can arrive as plain text. Accept it only when it
    /// really looks like a Debian package index.
    static func plainTextIndex(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        guard !looksLikeHTML(text) else { return nil }
        let hasPackageField = text.split(whereSeparator: \.isNewline).contains { line in
            line.hasPrefix("Package:") || line.hasPrefix("package:")
        }
        return hasPackageField ? text : nil
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.drop(while: \.isWhitespace).prefix(512).lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.hasPrefix("<head")
            || head.hasPrefix("<?xml")
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Parses a Debian control field. Keys are case-insensitive and a tab or
    /// space after the colon is accepted.
    private static func field(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rawKey = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty else { return nil }
        let key = rawKey.lowercased()

        var value = line[line.index(after: colon)...]
        if let first = value.first, first == " " || first == "\t" {
            value = value.dropFirst()
        }
        return (key, value.trimmingCharacters(in: .whitespaces))
    }

    private static func setPackageValue(_ value: String, for key: String, to package: inout Package) {
        switch key {
        case "package": package.packageID = value
        case "version": package.version = value
        case "section": package.section = value
        case "maintainer": package.maintainer = value
        case "depends": package.depends = value
        case "architecture": package.architecture = value
        case "filename": package.filename = value
        case "size": package.size = value
        case "installed-size": package.installedSize = value
        case "md5sum": package.md5sum = value
        case "description": package.description = value
        case "name": package.name = value
        case "author": package.author = value
        case "website": package.website = value
        case "depiction": package.depiction = value
        case "tag": package.tags = value
        default: break
        }
    }

    private static func appendPackageValue(_ value: String, for key: String, to package: inout Package) {
        switch key {
        case "description":
            package.description = join(package.description, value, separator: "\n")
        case "tag":
            package.tags = join(package.tags, value, separator: ", ")
        case "depends":
            package.depends = join(package.depends, value, separator: " ")
        case "maintainer":
            package.maintainer = join(package.maintainer, value, separator: " ")
        case "author":
            package.author = join(package.author, value, separator: " ")
        case "name":
            package.name = join(package.name, value, separator: " ")
        default:
            break
        }
    }

    private static func appendReleaseValue(_ value: String, for key: String, to repo: inout RepoInfo) {
        switch key {
        case "description":
            repo.description = join(repo.description, value, separator: "\n")
        case "label":
            repo.label = join(repo.label, value, separator: " ")
        default:
            break
        }
    }

    private static func join(_ existing: String, _ value: String, separator: String) -> String {
        if existing.isEmpty { return value }
        if value.isEmpty { return existing }
        return existing + separator + value
    }
}
