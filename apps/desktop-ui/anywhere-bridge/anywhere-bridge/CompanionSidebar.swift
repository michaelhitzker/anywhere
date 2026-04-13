import SwiftUI

struct CompanionSidebar: View {
    let selection: Binding<CompanionSection?>
    let store: CompanionStore

    var body: some View {
        List(selection: selection) {
            Section("Bridge") {
                sidebarRow(.overview, subtitle: overviewSubtitle)
                sidebarRow(.setup, subtitle: setupSubtitle)
                sidebarRow(.activity, subtitle: "\(store.daemonEvents.count) recent events")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Bridge")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                CompanionStatusBadge(
                    title: store.daemonState.rawValue.capitalized,
                    color: daemonStateTint(store.daemonState)
                )

                if let mobileBridgeURL = store.mobileBridgeURL {
                    Text(mobileBridgeURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                } else {
                    Text("Mobile address will appear once the Mac has a LAN address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    private var overviewSubtitle: String {
        if let health = store.daemonHealth {
            return "Daemon online, auth \(health.codexAuth)"
        }

        return "Daemon \(store.daemonState.rawValue)"
    }

    private var setupSubtitle: String {
        guard !store.repoRootPath.isEmpty else {
            return "Repo root still needed"
        }

        return URL(fileURLWithPath: store.repoRootPath).lastPathComponent
    }

    @ViewBuilder
    private func sidebarRow(_ section: CompanionSection, subtitle: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: section.systemImage)
        }
        .tag(section)
    }
}
