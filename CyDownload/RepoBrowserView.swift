import SwiftUI

struct PackageListColumn: View {
    let snapshot: RepoSnapshot
    @Binding var search: String
    @Binding var selection: String?

    private var sections: [SectionNode] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.sections }
        return snapshot.sections.compactMap { section in
            let packages = section.packages.filter { group in
                group.displayName.localizedCaseInsensitiveContains(query)
                    || group.latest.packageID.localizedCaseInsensitiveContains(query)
            }
            guard !packages.isEmpty else { return nil }
            return SectionNode(name: section.name, packages: packages)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section(section.name) {
                    ForEach(section.packages) { group in
                        HStack(spacing: 8) {
                            Text(group.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(group.latest.version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(group.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $search, prompt: "Search")
        .overlay {
            if sections.isEmpty {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No Packages", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }
}

struct PackageInspector: View {
    let package: Package
    let versions: [Package]
    @Binding var selectedVersion: String
    var downloading: Bool
    var onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if package.isCommercial {
                        Label("Commercial package. Download isn’t available.", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    details
                    if !package.description.isEmpty {
                        Text(package.description)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(package.displayName)
                    .font(.title3)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !package.packageID.isEmpty, package.packageID != package.displayName {
                    Text(package.packageID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Button {
                onDownload()
            } label: {
                Label(downloading ? "Downloading…" : "Download", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canDownload)
            .help(package.isCommercial ? "Commercial packages can’t be downloaded." : "Save the .deb to a folder")
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            detailRow("Version") {
                if versions.count > 1 {
                    Picker("Version", selection: $selectedVersion) {
                        ForEach(versions) { version in
                            Text(version.version.isEmpty ? "Unknown" : version.version).tag(version.version)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(downloading)
                } else {
                    Text(package.version.isEmpty ? "Unknown" : package.version)
                        .textSelection(.enabled)
                }
            }
            if !package.maintainer.isEmpty {
                detailRow("Maintainer") { Text(package.maintainer).textSelection(.enabled) }
            }
            detailRow("Size") { Text(bytesToHuman(package.size)) }
            if !package.architecture.isEmpty {
                detailRow("Architecture") { Text(package.architecture).textSelection(.enabled) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canDownload: Bool {
        !downloading
            && !package.isCommercial
            && !package.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func detailRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ActivityLogPopover: View {
    var text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No activity yet." : text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(width: 420, height: 240)
    }
}
