import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct CompanionOverviewPane: View {
    let store: CompanionStore

    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CompanionSectionCard("Anywhere Bridge", systemImage: "desktopcomputer.and.iphone") {
                Text("The Mac app stays thin: it launches the phone daemon, keeps the T3 connection settings in reach, and gives the phone client a trusted local address.")
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    CompanionMetricCard(
                        title: "Daemon",
                        value: store.daemonState.rawValue.capitalized,
                        detail: store.lastError ?? "Ready to monitor the local service.",
                        tint: daemonStateTint(store.daemonState)
                    )

                    CompanionMetricCard(
                        title: "T3",
                        value: store.daemonHealth?.codexAuth.capitalized ?? "Unknown",
                        detail: store.daemonHealth?.provider?.label ?? "Launch the daemon to check the runtime.",
                        tint: .blue
                    )

                    CompanionMetricCard(
                        title: "Mobile Address",
                        value: store.mobileBridgeURL?.absoluteString ?? "Unavailable",
                        detail: "Use this address from the phone client on your LAN.",
                        tint: .orange
                    )

                    CompanionMetricCard(
                        title: "Paired Phones",
                        value: "\(store.pairedClients.count)",
                        detail: store.pairedClients.isEmpty ? "Create a QR ticket to pair a phone." : "Phones trusted by this bridge.",
                        tint: .mint
                    )
                }
            }

            CompanionSectionCard("Quick Actions", systemImage: "bolt.fill") {
                HStack {
                    Button("Launch Daemon") {
                        store.launchDaemon()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.daemonState == .online || store.daemonState == .starting)

                    Button("Stop Daemon") {
                        store.stopDaemon()
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.daemonState == .offline)

                    Button("Refresh") {
                        store.refreshNow()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                if let pid = store.existingDaemonPID {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Another daemon is already using port 4242.")
                            .foregroundStyle(.secondary)

                        Text("Process \(pid) · \(store.existingDaemonCommand ?? "unknown")")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button("Kill Existing Daemon") {
                            store.killExistingDaemon()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }

                HStack {
                    Button("Open Local API") {
                        store.openLocalBridge()
                    }

                    Button("Open Mobile Address") {
                        store.openMobileAddress()
                    }
                    .disabled(store.mobileBridgeURL == nil)
                }
            }

            CompanionSectionCard("Phone Pairing", systemImage: "qrcode") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Scan this from the phone client to trust this Mac. Pairing tickets are short-lived; the paired phone credential lasts 30 days.")
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 18) {
                        if let ticket = store.pairingTicket {
                            CompanionQRCodeView(payload: ticket.qrPayload)

                            VStack(alignment: .leading, spacing: 10) {
                                CompanionStatusBadge(title: "QR Ready", color: .green)

                                Text("Phone access expires \(ticket.credentialExpiresAt).")
                                    .foregroundStyle(.secondary)

                                Text("QR ticket expires \(ticket.expiresAt).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Button("Copy Pairing Payload") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(ticket.qrPayload, forType: .string)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(store.isCreatingPairingTicket ? "Creating..." : "New QR") {
                                        store.createPairingTicket()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.daemonState != .online || store.isCreatingPairingTicket)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                CompanionStatusBadge(title: "Not Paired", color: .orange)

                                Text("Create a QR ticket from this Mac before pairing a phone.")
                                    .foregroundStyle(.secondary)

                                Button(store.isCreatingPairingTicket ? "Creating..." : "Create QR Pairing") {
                                    store.createPairingTicket()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.daemonState != .online || store.isCreatingPairingTicket)
                            }
                        }
                    }

                    if let message = store.pairingMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }

                    if let error = store.pairingError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if !store.pairedClients.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Paired phones")
                                .font(.headline)

                            ForEach(store.pairedClients) { client in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(client.name)
                                            .font(.subheadline.weight(.semibold))

                                        Text("Trusted until \(client.expiresAt)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button("Remove") {
                                        store.revokePairingClient(client)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CompanionQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = Self.makeQRCodeImage(from: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Phone pairing QR code")
            } else {
                Text("QR unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func makeQRCodeImage(from value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else {
            return nil
        }

        let representation = NSCIImageRep(ciImage: outputImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct CompanionMenuBarOverview: View {
    let store: CompanionStore
    let mainWindowID: String

    @Environment(\.openWindow) private var openWindow

    private let compactColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Anywhere Bridge")
                    .font(.headline)

                Text("Quick actions for the local bridge.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("Launch the daemon, copy the LAN address, and pair a phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 10) {
                CompanionCompactMetricCard(
                    title: "Daemon",
                    value: store.daemonState.rawValue.capitalized,
                    detail: store.lastError ?? "Service status",
                    tint: daemonStateTint(store.daemonState)
                )

                CompanionCompactMetricCard(
                    title: "T3",
                    value: store.daemonHealth?.codexAuth.capitalized ?? "Unknown",
                    detail: store.daemonHealth?.provider?.label ?? "Runtime status",
                    tint: .blue
                )

                CompanionCompactMetricCard(
                    title: "Mobile",
                    value: store.mobileBridgeURL?.host() ?? "Unavailable",
                    detail: store.mobileBridgeURL == nil ? "No LAN address" : "Phone address ready",
                    tint: .orange
                )

                CompanionCompactMetricCard(
                    title: "Phones",
                    value: "\(store.pairedClients.count)",
                    detail: store.pairedClients.isEmpty ? "Not paired" : "Trusted clients",
                    tint: .mint
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Actions")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    Button(store.daemonState == .online || store.daemonState == .starting ? "Stop Daemon" : "Launch Daemon") {
                        if store.daemonState == .online || store.daemonState == .starting {
                            store.stopDaemon()
                        } else {
                            store.launchDaemon()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Refresh") {
                        store.refreshNow()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("Local API") {
                        store.openLocalBridge()
                    }
                    .buttonStyle(.bordered)

                    Button("Mobile") {
                        store.openMobileAddress()
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.mobileBridgeURL == nil)
                }
            }

            Divider()

            Button {
                openWindow(id: mainWindowID)
            } label: {
                Label("Open Anywhere Bridge", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 380)
    }
}

private struct CompanionCompactMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompanionStatusBadge(title: title, color: tint)

            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary.opacity(0.14))
        )
    }
}
