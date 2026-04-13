import SwiftUI

struct CompanionDetailView: View {
    let section: CompanionSection
    let store: CompanionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                switch section {
                case .overview:
                    CompanionOverviewPane(store: store)
                case .setup:
                    CompanionSetupPane(store: store)
                case .activity:
                    CompanionActivityPane(store: store)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text(section.summary)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                CompanionStatusBadge(
                    title: store.daemonState.rawValue.capitalized,
                    color: daemonStateTint(store.daemonState)
                )

                if let health = store.daemonHealth {
                    CompanionStatusBadge(title: "T3: \(health.codexAuth)", color: .blue)
                }

                if store.localBridgeURL != nil {
                    CompanionStatusBadge(title: "Phone Bridge Ready", color: .green)
                }
            }
        }
    }
}
