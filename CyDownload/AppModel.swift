import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var repos: [String] = []
    var selectedRepo = RepoStore.placeholder
    var logText = ""
    var progress: TransferProgress = .idle
    var isLoadingRepo = false
    var isDownloading = false
    var darkMode: Bool {
        didSet { UserDefaults.standard.set(darkMode, forKey: Self.darkModeKey) }
    }
    var showNewRepo = false
    var confirmDelete = false
    var presentedRepo: RepoSnapshot?
    var alertMessage: String?

    var isBusy: Bool { isLoadingRepo || isDownloading }

    var canUseSelection: Bool {
        !isBusy && selectedRepo != RepoStore.placeholder && repos.contains(selectedRepo)
    }

    private let downloader: RepoDownloading
    private let reposFile: URL
    private static let darkModeKey = "appearance/darkMode"
    private static let maxIndexBytes = 64 * 1024 * 1024
    private static let maxPackageBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let maxLogBytes = 200_000
    private let releasePaths = [
        "Release",
        "dists/stable/main/binary-iphoneos-arm/Release",
    ]
    private let packagePaths = [
        "Packages.bz2",
        "dists/stable/main/binary-iphoneos-arm/Packages.bz2",
        "Packages.gz",
        "dists/stable/main/binary-iphoneos-arm/Packages.gz",
        "Packages",
        "dists/stable/main/binary-iphoneos-arm/Packages",
    ]

    init(downloader: RepoDownloading = CydiaClient(), reposFile: URL? = nil) {
        self.downloader = downloader
        self.reposFile = reposFile ?? RepoStore.fileURL
        darkMode = UserDefaults.standard.bool(forKey: Self.darkModeKey)
        repos = RepoStore.load(from: self.reposFile)
    }

    func log(_ message: String) {
        if !logText.isEmpty {
            logText += "\n"
        }
        logText += message

        if logText.utf8.count > Self.maxLogBytes {
            let lines = logText.split(separator: "\n", omittingEmptySubsequences: false)
            var kept: [Substring] = []
            var size = 0
            for line in lines.reversed() {
                size += line.utf8.count + 1
                if size > Self.maxLogBytes / 2 { break }
                kept.append(line)
            }
            logText = kept.reversed().joined(separator: "\n")
        }
    }

    func addRepo(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !repos.contains(trimmed) {
            repos.append(trimmed)
        }
        selectedRepo = trimmed
        persistRepos()
    }

    func deleteSelectedRepo() {
        guard canUseSelection, let index = repos.firstIndex(of: selectedRepo) else { return }
        let removed = repos.remove(at: index)
        if presentedRepo?.repo.url == removed {
            presentedRepo = nil
        }
        selectedRepo = RepoStore.placeholder
        persistRepos()
    }

    func openSelectedRepo() async {
        guard canUseSelection else { return }
        let repoURL = selectedRepo

        guard RepoURL.isSupported(repoURL) else {
            log("Invalid repository URL: \(repoURL)")
            alertMessage = "“\(repoURL)” is not a valid http or https repository URL."
            return
        }

        presentedRepo = nil
        isLoadingRepo = true
        defer {
            isLoadingRepo = false
            progress = .idle
        }

        log("Getting repo information...")
        var releaseText = ""
        var foundRelease = false
        for path in releasePaths {
            guard let url = RepoURL.resolve(base: repoURL, path: path),
                  let data = try? await download(url, maxBytes: Self.maxIndexBytes) else {
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            if RepoParser.looksLikeHTML(text) {
                continue
            }
            releaseText = text
            foundRelease = true
            log("Done")
            break
        }
        if !foundRelease {
            log("No Release file could be found, repo information will be blank")
        }

        log("Getting package list...")
        for path in packagePaths {
            guard selectedRepo == repoURL else { return }
            guard let url = RepoURL.resolve(base: repoURL, path: path),
                  let data = try? await download(url, maxBytes: Self.maxIndexBytes) else {
                continue
            }

            let filename = (path as NSString).lastPathComponent
            let text: String
            if path.hasSuffix("bz2") || path.hasSuffix("gz") {
                if let unpacked = ArchiveDecoder.decompress(data, path: path) {
                    text = String(decoding: unpacked, as: UTF8.self)
                } else if let plain = RepoParser.plainTextIndex(from: data) {
                    text = plain
                } else {
                    log("Error extracting \(filename)")
                    continue
                }
            } else {
                text = String(decoding: data, as: UTF8.self)
                if RepoParser.looksLikeHTML(text) {
                    log("The server returned a web page instead of \(filename)")
                    continue
                }
            }

            let packages = RepoParser.parsePackages(text)
            guard selectedRepo == repoURL else { return }

            log("Done")
            let repo = RepoParser.parseRelease(releaseText, url: repoURL, hadReleaseFile: foundRelease)
            presentedRepo = RepoSnapshot(repo: repo, sections: RepoParser.sections(from: packages))
            return
        }

        log("Not a valid Cydia repository!")
    }

    func downloadPackage(_ package: Package, from repoURL: String, to directory: URL) async -> String {
        guard !isBusy else {
            return "Please wait for the current task to finish."
        }
        guard !package.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("Download failed: the package has no download filename")
            return "This package has no download link."
        }
        guard let url = RepoURL.resolve(base: repoURL, path: package.filename) else {
            log("Download failed: invalid package URL")
            return "The package download link is invalid."
        }

        let filename = debFilename(package)
        let destination = directory.appendingPathComponent(filename)
        log("Downloading \(filename)")
        isDownloading = true
        progress = .indeterminate
        defer {
            isDownloading = false
            progress = .idle
        }

        let started = directory.startAccessingSecurityScopedResource()
        defer {
            if started {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await downloader.downloadFile(
                from: url,
                to: destination,
                maxBytes: Self.maxPackageBytes,
                progress: progressHandler()
            )
            log("Download complete: \(filename)")
            return "Download complete!"
        } catch {
            let message = error.localizedDescription
            log("Download failed: \(message)")
            return "Download failed! \(message)"
        }
    }

    private func download(_ url: URL, maxBytes: Int) async throws -> Data {
        try await downloader.download(url, maxBytes: maxBytes, progress: progressHandler())
    }

    private func progressHandler() -> (TransferProgress) -> Void {
        { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.isBusy else { return }
                self.progress = update
            }
        }
    }

    private func persistRepos() {
        do {
            try RepoStore.save(repos, to: reposFile)
        } catch {
            alertMessage = "Could not save repositories: \(error.localizedDescription)"
        }
    }

    private func debFilename(_ package: Package) -> String {
        let identifier = package.packageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = package.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = "\(identifier.isEmpty ? "package" : identifier)_\(version.isEmpty ? "unknown" : version).deb"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-~"))
        var cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? scalar : "_"
        }))
        while cleaned.contains("__") {
            cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
        }
        return cleaned
    }
}
