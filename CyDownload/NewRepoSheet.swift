import SwiftUI

struct NewRepoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var urlFocused: Bool
    @State private var url = "http://"
    var onSave: (String) -> Void

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        RepoURL.isSupported(trimmedURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Repository")
                    .font(.title2)
                Text("Enter the address of a Cydia or APT repository. Select it in the sidebar to load its packages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Repository URL", text: $url, prompt: Text("https://example.com"))
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onSubmit(add)

                if !trimmedURL.isEmpty, !isValid {
                    Text("Enter a complete http:// or https:// address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    add()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { urlFocused = true }
    }

    private func add() {
        guard isValid else { return }
        onSave(trimmedURL)
        dismiss()
    }
}
