import Foundation

enum CompanionSection: String, CaseIterable, Identifiable {
    case overview
    case setup
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .setup:
            "Setup"
        case .activity:
            "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "rectangle.3.group.bubble.left"
        case .setup:
            "slider.horizontal.3"
        case .activity:
            "waveform.path.ecg"
        }
    }

    var summary: String {
        switch self {
        case .overview:
            "Companion health, quick actions, and addresses."
        case .setup:
            "Repo, node runtime, and daemon launch details."
        case .activity:
            "Recent daemon output, errors, and connection state."
        }
    }
}
