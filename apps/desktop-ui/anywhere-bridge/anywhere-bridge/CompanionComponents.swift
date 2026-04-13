import SwiftUI

struct CompanionSectionCard<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.title3)
                .fontWeight(.semibold)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct CompanionMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompanionStatusBadge(title: title, color: tint)

            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(3)

            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.quaternary.opacity(0.16))
        )
    }
}

struct CompanionStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

struct CompanionEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.quaternary.opacity(0.12))
        )
    }
}

struct CompanionInlineMessage: View {
    let message: String
    let tint: Color

    var body: some View {
        Text(message)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(tint.opacity(0.08))
            )
    }
}

func daemonStateTint(_ state: DaemonConnectionState) -> Color {
    switch state {
    case .online:
        .green
    case .starting:
        .blue
    case .misconfigured:
        .orange
    case .offline:
        .secondary
    }
}
