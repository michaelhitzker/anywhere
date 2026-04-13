import SwiftUI

enum PhoneTheme {
    static let backgroundTop = Color(red: 0.06, green: 0.09, blue: 0.14)
    static let backgroundBottom = Color(red: 0.02, green: 0.03, blue: 0.06)
    static let surface = Color.white.opacity(0.08)
    static let surfaceStrong = Color.white.opacity(0.12)
    static let line = Color.white.opacity(0.10)
    static let accent = Color(red: 0.32, green: 0.74, blue: 0.92)
    static let accentStrong = Color(red: 0.18, green: 0.55, blue: 0.88)
    static let success = Color(red: 0.38, green: 0.84, blue: 0.55)
    static let warning = Color(red: 0.96, green: 0.71, blue: 0.30)
    static let danger = Color(red: 0.98, green: 0.42, blue: 0.44)
    static let muted = Color.white.opacity(0.68)
}

struct PhoneBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PhoneTheme.backgroundTop, PhoneTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [PhoneTheme.accent.opacity(0.28), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 320
            )

            RadialGradient(
                colors: [PhoneTheme.success.opacity(0.18), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 280
            )
        }
        .ignoresSafeArea()
    }
}

struct PhoneSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.white)

            content
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PhoneTheme.surface)
                .stroke(PhoneTheme.line, lineWidth: 1)
        )
    }
}

struct PhoneStatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.16), in: Capsule())
    }
}

struct PhoneInlineMessage: View {
    let message: String
    let tint: Color

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

struct PhoneEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PhoneTheme.surfaceStrong)
        )
    }
}

struct PhoneTextFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(PhoneTheme.surfaceStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PhoneTheme.line, lineWidth: 1)
            )
            .foregroundStyle(.white)
    }
}

extension View {
    func phoneFieldStyle() -> some View {
        modifier(PhoneTextFieldStyle())
    }
}

func phoneTaskStatusTint(_ status: String) -> Color {
    switch status {
    case "done":
        PhoneTheme.success
    case "running":
        PhoneTheme.accent
    case "queued":
        PhoneTheme.warning
    default:
        PhoneTheme.muted
    }
}

func phoneRunStatusTint(_ status: String) -> Color {
    switch status {
    case "succeeded":
        PhoneTheme.success
    case "failed", "canceled":
        PhoneTheme.danger
    case "building", "installing", "launching":
        PhoneTheme.accent
    case "queued":
        PhoneTheme.warning
    default:
        PhoneTheme.muted
    }
}
