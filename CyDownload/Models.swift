import Foundation

struct RepoInfo: Equatable {
    var url: String
    var origin: String = ""
    var label: String = ""
    var suite: String = ""
    var version: String = ""
    var codename: String = ""
    var architectures: String = ""
    var components: String = ""
    var description: String = ""

    var displayName: String {
        origin.isEmpty ? url : origin
    }
}

struct Package: Equatable, Identifiable {
    var packageID: String = ""
    var version: String = ""
    var section: String = ""
    var maintainer: String = ""
    var depends: String = ""
    var architecture: String = ""
    var filename: String = ""
    var size: String = ""
    var installedSize: String = ""
    var md5sum: String = ""
    var description: String = ""
    var name: String = ""
    var author: String = ""
    var website: String = ""
    var depiction: String = ""
    var tags: String = ""

    var id: String { "\(packageID)_\(version)" }

    var displayName: String {
        name.isEmpty ? packageID : name
    }

    var isCommercial: Bool {
        tags.lowercased().contains("cydia::commercial")
    }
}

struct PackageGroup: Equatable, Identifiable {
    let id: String
    let versions: [Package]

    var latest: Package { versions.first ?? Package() }
    var displayName: String { latest.displayName }
}

struct SectionNode: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let packages: [PackageGroup]
}

struct RepoSnapshot: Identifiable {
    let id = UUID()
    let repo: RepoInfo
    let sections: [SectionNode]
}

enum TransferProgress: Equatable {
    case idle
    case indeterminate
    case fraction(Double)
}

/// Debian version ordering, including epochs and the special `~` sort marker.
enum VersionCompare {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = split(lhs)
        let right = split(rhs)

        if left.epoch != right.epoch {
            return left.epoch < right.epoch ? .orderedAscending : .orderedDescending
        }
        let upstream = comparePart(left.upstream, right.upstream)
        if upstream != .orderedSame {
            return upstream
        }
        return comparePart(left.revision, right.revision)
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedDescending
    }

    private static func split(_ version: String) -> (epoch: Int, upstream: String, revision: String) {
        var epoch = 0
        var rest = version

        if let colon = version.firstIndex(of: ":"), let value = Int(version[..<colon]) {
            epoch = max(0, value)
            rest = String(version[version.index(after: colon)...])
        }

        if let dash = rest.lastIndex(of: "-") {
            return (epoch, String(rest[..<dash]), String(rest[rest.index(after: dash)...]))
        }
        return (epoch, rest, "")
    }

    private static func comparePart(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = Array(lhs)
        let right = Array(rhs)
        var i = 0
        var j = 0

        while i < left.count || j < right.count {
            while (i < left.count && !left[i].isNumber) || (j < right.count && !right[j].isNumber) {
                let l: Character? = i < left.count && !left[i].isNumber ? left[i] : nil
                let r: Character? = j < right.count && !right[j].isNumber ? right[j] : nil
                let lOrder = order(l)
                let rOrder = order(r)
                if lOrder != rOrder {
                    return lOrder < rOrder ? .orderedAscending : .orderedDescending
                }
                if l != nil { i += 1 }
                if r != nil { j += 1 }
            }

            var lNumber = 0
            var rNumber = 0
            while i < left.count, left[i].isNumber {
                lNumber = lNumber * 10 + (left[i].wholeNumberValue ?? 0)
                i += 1
            }
            while j < right.count, right[j].isNumber {
                rNumber = rNumber * 10 + (right[j].wholeNumberValue ?? 0)
                j += 1
            }
            if lNumber != rNumber {
                return lNumber < rNumber ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    /// Debian sorts `~` before the end of a string, the end before anything else,
    /// and letters before punctuation.
    private static func order(_ character: Character?) -> Int {
        guard let character else { return 0 }
        if character == "~" { return -1 }
        let ascii = Int(character.asciiValue ?? 0)
        return character.isLetter ? ascii : ascii + 256
    }
}

enum RepoURL {
    /// Resolves a repository-relative path, including absolute URLs and `../` segments.
    static func resolve(base: String, path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if let absolute = URL(string: trimmedPath), absolute.scheme != nil {
            return absolute
        }

        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }
        let normalizedBase = trimmedBase.hasSuffix("/") ? trimmedBase : trimmedBase + "/"
        guard let baseURL = URL(string: normalizedBase) else { return nil }

        var relative = trimmedPath.hasPrefix("/") ? String(trimmedPath.dropFirst()) : trimmedPath
        while relative.hasPrefix("./") {
            relative.removeFirst(2)
        }

        if let direct = URL(string: relative, relativeTo: baseURL) {
            return direct.absoluteURL
        }

        let encoded = relative.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let text = String(segment)
            if text == "." || text == ".." { return text }
            return text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
        }.joined(separator: "/")
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    static func isSupported(_ string: String) -> Bool {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }
}

extension String {
    var repoHost: String {
        if let host = URLComponents(string: self)?.host, !host.isEmpty {
            return host
        }
        if let host = URL(string: self)?.host, !host.isEmpty {
            return host
        }
        return self
    }
}

func bytesToHuman(_ sizeText: String) -> String {
    guard let bytes = Double(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)), bytes >= 0 else {
        return "Unknown"
    }
    if bytes < 1024 {
        return "\(Int(bytes)) B"
    }
    let kilobytes = bytes / 1024
    if kilobytes < 1024 {
        return String(format: "%.2f KB", kilobytes)
    }
    let megabytes = kilobytes / 1024
    if megabytes < 1024 {
        return String(format: "%.2f MB", megabytes)
    }
    return String(format: "%.2f GB", megabytes / 1024)
}
