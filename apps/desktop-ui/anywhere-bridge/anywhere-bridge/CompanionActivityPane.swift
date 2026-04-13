import SwiftUI

struct CompanionActivityPane: View {
    let store: CompanionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error = store.lastError, store.daemonState != .online {
                CompanionSectionCard("Current Issue", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error)
                            .foregroundStyle(.orange)

                        if let pid = store.existingDaemonPID {
                            let command = store.existingDaemonCommand ?? "unknown"

                            Text("Process \(pid) is listening on port 4242 (\(command)).")
                                .foregroundStyle(.secondary)

                            Button("Kill Existing Daemon") {
                                store.killExistingDaemon()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
            }

            CompanionSectionCard("Daemon Activity", systemImage: "waveform.path.ecg") {
                if store.daemonEvents.isEmpty {
                    CompanionEmptyState(
                        title: "No Recent Events",
                        message: "Launch the daemon to see process output and connection events here."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.daemonEvents, id: \.self) { event in
                            Text(event)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(.quaternary.opacity(0.12))
                                )
                        }
                    }
                }
            }
        }
    }
}
