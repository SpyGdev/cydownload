import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var packageSelection: String?
    @State private var search = ""
    @State private var downloading = false
    @State private var pickingFolder = false
    @State private var downloadAlert: String?
    @State private var showLog = false
    @State private var versionSelection = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            repositorySidebar
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
        .sheet(isPresented: $model.showNewRepo) {
            NewRepoSheet { model.addRepo($0) }
        }
        .confirmationDialog(
            "Remove this repository?",
            isPresented: $model.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                model.deleteSelectedRepo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(model.selectedRepo.repoHost)” will be removed from the sidebar. Downloaded packages are not deleted.")
        }
        .alert("CyDownload", isPresented: modelAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert("Download", isPresented: downloadAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadAlert ?? "")
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            handleFolder(result)
        }
        .onChange(of: model.selectedRepo) { _, newValue in
            if model.presentedRepo?.repo.url != newValue {
                model.presentedRepo = nil
                packageSelection = nil
                search = ""
                versionSelection = ""
            }
        }
        .onChange(of: model.presentedRepo?.id) { _, _ in
            packageSelection = nil
            search = ""
            versionSelection = ""
        }
    }

    private var repositorySidebar: some View {
        VStack(spacing: 0) {
            List(selection: repoSelection) {
                ForEach(model.repos, id: \.self) { repo in
                    repositoryRow(repo)
                        .tag(repo)
                }
            }
            .listStyle(.sidebar)
            .disabled(model.isBusy)
            .overlay {
                if model.repos.isEmpty {
                    ContentUnavailableView(
                        "No Repositories",
                        systemImage: "server.rack",
                        description: Text("Use + to add one.")
                    )
                }
            }

            Divider()
            sidebarControls
        }
        .navigationTitle("Repositories")
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
    }

    private func repositoryRow(_ repo: String) -> some View {
        HStack(spacing: 8) {
            Label(repo.repoHost, systemImage: "server.rack")
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.isLoadingRepo && model.selectedRepo == repo {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .help(repo)
        .contextMenu {
            Button("Show Packages") {
                model.selectedRepo = repo
                Task { await model.openSelectedRepo() }
            }
            .disabled(model.isBusy)
            Button("Copy URL") {
                copy(repo)
            }
            Divider()
            Button("Remove", role: .destructive) {
                model.selectedRepo = repo
                model.confirmDelete = true
            }
        }
    }

    private var sidebarControls: some View {
        HStack(spacing: 2) {
            sidebarButton("plus", help: "Add Repository") {
                model.showNewRepo = true
            }
            .disabled(model.isBusy)
            .accessibilityLabel("Add Repository")

            sidebarButton("minus", help: "Remove Repository") {
                model.confirmDelete = true
            }
            .disabled(!model.canUseSelection)
            .accessibilityLabel("Remove Repository")

            Spacer()

            sidebarButton(model.darkMode ? "sun.max" : "moon", help: model.darkMode ? "Use Light Appearance" : "Use Dark Appearance") {
                model.darkMode.toggle()
            }
            .accessibilityLabel("Dark Mode")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func sidebarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .help(help)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let snapshot = activeSnapshot {
            packageBrowser(snapshot)
        } else if model.isBusy {
            loadingPane
        } else if model.canUseSelection {
            promptPane(
                title: model.selectedRepo.repoHost,
                symbol: "shippingbox",
                message: model.selectedRepo,
                button: "Show Packages",
                action: { Task { await model.openSelectedRepo() } }
            )
        } else if model.repos.isEmpty {
            promptPane(
                title: "Add a Repository",
                symbol: "plus",
                message: "Saved repositories appear in the sidebar.",
                button: "Add Repository",
                action: { model.showNewRepo = true }
            )
        } else {
            ContentUnavailableView(
                "Choose a Repository",
                systemImage: "server.rack",
                description: Text("Select one in the sidebar, then show its packages.")
            )
            .navigationTitle("CyDownload")
        }
    }

    private func packageBrowser(_ snapshot: RepoSnapshot) -> some View {
        HStack(spacing: 0) {
            PackageListColumn(snapshot: snapshot, search: $search, selection: $packageSelection)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                .disabled(downloading)

            if let package = selectedPackage(in: snapshot) {
                Divider()
                PackageInspector(
                    package: package,
                    versions: selectedGroup(in: snapshot)?.versions ?? [package],
                    selectedVersion: versionBinding(in: snapshot),
                    downloading: downloading,
                    onDownload: { pickingFolder = true }
                )
                .frame(width: 320)
            }
        }
        .navigationTitle(snapshot.repo.displayName)
        .navigationSubtitle(packageCountLabel(snapshot))
    }

    private var loadingPane: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(lastLogLine)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .navigationTitle(model.selectedRepo.repoHost)
    }

    private func promptPane(title: String, symbol: String, message: String, button: String, action: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        }
        .navigationTitle(title == "Add a Repository" || title == "Choose a Repository" ? "CyDownload" : title)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.progress != .idle {
                    statusProgress
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    showLog.toggle()
                } label: {
                    Image(systemName: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .help("Show activity log")
                .accessibilityLabel("Activity Log")
                .popover(isPresented: $showLog, arrowEdge: .bottom) {
                    ActivityLogPopover(text: model.logText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var statusProgress: some View {
        switch model.progress {
        case .idle:
            EmptyView()
        case .indeterminate:
            ProgressView()
                .controlSize(.small)
        case .fraction(let value):
            ProgressView(value: value, total: 1)
                .controlSize(.small)
                .frame(width: 96)
        }
    }

    private var repoSelection: Binding<String?> {
        Binding(
            get: { model.selectedRepo == RepoStore.placeholder ? nil : model.selectedRepo },
            set: { model.selectedRepo = $0 ?? RepoStore.placeholder }
        )
    }

    private var activeSnapshot: RepoSnapshot? {
        guard let snapshot = model.presentedRepo, snapshot.repo.url == model.selectedRepo else { return nil }
        return snapshot
    }

    private var lastLogLine: String {
        let trimmed = model.logText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(whereSeparator: \.isNewline).last else { return "Ready" }
        return String(last)
    }

    private var statusLine: String {
        if model.isBusy || downloading || model.progress != .idle {
            return lastLogLine
        }
        if activeSnapshot != nil, packageSelection == nil {
            return "Select a package"
        }
        if let snapshot = activeSnapshot, let package = selectedPackage(in: snapshot) {
            return package.displayName
        }
        return model.logText.isEmpty ? "Ready" : lastLogLine
    }

    private func packageCountLabel(_ snapshot: RepoSnapshot) -> String {
        let count = snapshot.sections.reduce(0) { $0 + $1.packages.count }
        return count == 1 ? "1 package" : "\(count) packages"
    }

    private func selectedGroup(in snapshot: RepoSnapshot) -> PackageGroup? {
        guard let packageSelection else { return nil }
        return snapshot.sections.flatMap(\.packages).first { $0.id == packageSelection }
    }

    private func selectedPackage(in snapshot: RepoSnapshot) -> Package? {
        guard let group = selectedGroup(in: snapshot) else { return nil }
        return group.versions.first { $0.version == versionSelection } ?? group.latest
    }

    private func versionBinding(in snapshot: RepoSnapshot) -> Binding<String> {
        Binding(
            get: {
                if let group = selectedGroup(in: snapshot),
                   group.versions.contains(where: { $0.version == versionSelection }) {
                    return versionSelection
                }
                return selectedGroup(in: snapshot)?.latest.version ?? ""
            },
            set: { versionSelection = $0 }
        )
    }

    private var modelAlertPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }

    private var downloadAlertPresented: Binding<Bool> {
        Binding(
            get: { downloadAlert != nil },
            set: { if !$0 { downloadAlert = nil } }
        )
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handleFolder(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if error is CancellationError { return }
            if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return }
            downloadAlert = error.localizedDescription
        case .success(let urls):
            guard let directory = urls.first,
                  let snapshot = activeSnapshot,
                  let package = selectedPackage(in: snapshot) else { return }
            downloading = true
            let repoURL = snapshot.repo.url
            Task {
                downloadAlert = await model.downloadPackage(package, from: repoURL, to: directory)
                downloading = false
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 980, height: 640)
}
