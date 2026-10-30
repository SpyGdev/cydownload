import Foundation

enum RepoStore {
    static let placeholder = "Select a Repository"

    static var fileURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cydownload", isDirectory: true)
        return directory.appendingPathComponent("repos.ini")
    }

    static func load(from url: URL = fileURL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let repo = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repo.isEmpty, seen.insert(repo).inserted else { return nil }
            return repo
        }
    }

    static func save(_ repos: [String], to url: URL = fileURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = repos.map { $0 + "\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
