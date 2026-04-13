import SwiftUI

struct CompanionSetupPane: View {
    @Bindable var store: CompanionStore
    @State private var isShowingAdvancedSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CompanionSectionCard("Companion Setup", systemImage: "slider.horizontal.3") {
                Text("This Mac app launches the local phone daemon and points it at the T3 runtime already configured on this machine.")
                    .foregroundStyle(.secondary)

                if let message = store.settingsMessage {
                    CompanionInlineMessage(message: message, tint: .green)
                }

                if let error = store.settingsError {
                    CompanionInlineMessage(message: error, tint: .red)
                }

                VStack(alignment: .leading, spacing: 14) {
                    setupPathRow(
                        title: "Anywhere repo",
                        value: store.repoRootPath,
                        placeholder: "Choose the repo that contains the daemon",
                        actionTitle: "Choose Anywhere repo"
                    ) {
                        store.chooseRepoRoot()
                    }

                    setupTextFieldRow(
                        title: "T3 companion repo",
                        placeholder: "/Users/you/projects/t3code-companion",
                        text: $store.t3Settings.companionRepoPath,
                        actionTitle: "Choose T3 companion repo"
                    ) {
                        store.chooseT3CompanionDirectory()
                    }

                    setupTextFieldRow(
                        title: "T3 state directory",
                        placeholder: "~/.t3",
                        text: $store.t3Settings.baseDir,
                        actionTitle: "Choose T3 state directory"
                    ) {
                        store.chooseT3BaseDirectory()
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $isShowingAdvancedSettings) {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("Node binary") {
                            TextField("Path to node", text: $store.nodeBinaryPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                                .onSubmit {
                                    store.persistNodePath()
                                }
                        }

                        HStack(spacing: 16) {
                            LabeledContent("Host") {
                                TextField("127.0.0.1", text: $store.t3Settings.host)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                            }

                            LabeledContent("Port") {
                                TextField(
                                    "3773",
                                    value: $store.t3Settings.port,
                                    format: .number
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            }
                        }

                        Toggle("Auto-start T3 server if it is not already running", isOn: $store.t3Settings.autoStartServer)
                            .toggleStyle(.checkbox)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Launch command")
                                .font(.headline)

                            Text(store.launchCommandPreview)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.quaternary.opacity(0.16))
                                )
                        }
                    }
                    .padding(.top, 8)
                }

                HStack {
                    Text("Changes are saved to the local daemon and reused when pairing the phone.")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Save Changes") {
                        Task {
                            store.persistNodePath()
                            await store.saveT3Settings()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func setupPathRow(
        title: String,
        value: String,
        placeholder: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(value.isEmpty ? placeholder : value)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                folderButton(title: actionTitle, action: action)
            }
            .frame(maxWidth: 520)
        }
    }

    private func setupTextFieldRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)

                folderButton(title: actionTitle, action: action)
            }
            .frame(maxWidth: 520)
        }
    }

    private func folderButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "folder")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .help(title)
        .accessibilityLabel(title)
    }
}
