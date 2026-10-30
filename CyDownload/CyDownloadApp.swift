import SwiftUI

@main
struct CyDownloadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("CyDownload") {
            ContentView()
                .environment(model)
                .preferredColorScheme(model.darkMode ? .dark : .light)
                .frame(minWidth: 920, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Repository…") {
                    model.showNewRepo = true
                }
                .keyboardShortcut("n")
                .disabled(model.isBusy)
            }
            CommandGroup(after: .newItem) {
                Button("Show Packages") {
                    Task { await model.openSelectedRepo() }
                }
                .keyboardShortcut("o")
                .disabled(!model.canUseSelection || model.presentedRepo?.repo.url == model.selectedRepo)
                Button("Reload Packages") {
                    Task { await model.openSelectedRepo() }
                }
                .keyboardShortcut("r")
                .disabled(!model.canUseSelection)
                Divider()
                Button("Remove Repository…") {
                    model.confirmDelete = true
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!model.canUseSelection)
            }
            CommandGroup(after: .sidebar) {
                Toggle("Dark Mode", isOn: Binding(
                    get: { model.darkMode },
                    set: { model.darkMode = $0 }
                ))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
