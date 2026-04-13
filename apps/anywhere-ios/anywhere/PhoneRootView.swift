import AVFoundation
import SwiftUI

struct PhoneRootView: View {
    let store: PhoneCompanionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    @State private var isThreadsPresented = false

    var body: some View {
        NavigationStack {
            if store.hasPairingCredential {
                PhoneChatView(
                    store: store,
                    isSettingsPresented: $isSettingsPresented,
                    isThreadsPresented: $isThreadsPresented
                )
            } else {
                PhonePairingGateView(store: store)
            }
        }
        .task {
            store.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }

            Task {
                await store.resumeActiveRun()
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                PhoneSettingsView(store: store)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isThreadsPresented) {
            NavigationStack {
                PhoneThreadsView(store: store)
            }
            .preferredColorScheme(.dark)
        }
        .tint(PhoneTheme.accent)
    }
}

private struct PhonePairingGateView: View {
    let store: PhoneCompanionStore

    var body: some View {
        ZStack {
            PhoneBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pair your Mac")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)

                        Text("Scan the pairing QR from Anywhere Bridge before starting tasks. The paired credential lasts 30 days.")
                            .font(.body)
                            .foregroundStyle(PhoneTheme.muted)
                    }

                    PhoneSectionCard("QR Pairing", systemImage: "qrcode.viewfinder") {
                        VStack(alignment: .leading, spacing: 12) {
                            PhoneQRCodeScannerView(
                                onCode: { code in
                                    store.pairWithScannedQRCodePayload(code)
                                },
                                onError: { message in
                                    store.pairingError = message
                                }
                            )
                            .frame(minHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(PhoneTheme.line, lineWidth: 1)
                            )

                            Text("Point the camera at the QR code shown in Anywhere Bridge on your Mac.")
                                .font(.footnote)
                                .foregroundStyle(PhoneTheme.muted)

                            DisclosureGroup("Paste pairing payload") {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextEditor(text: Binding(
                                        get: { store.pairingPayloadText },
                                        set: { store.pairingPayloadText = $0 }
                                    ))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .frame(minHeight: 96)
                                    .phoneFieldStyle()

                                    Button("Pair Phone") {
                                        store.pairWithQRCodePayload()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(PhoneTheme.accentStrong)
                                    .disabled(store.pairingPayloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    Text("Use the Mac app's Copy Pairing Payload action if camera scanning is not available.")
                                        .font(.footnote)
                                        .foregroundStyle(PhoneTheme.muted)
                                }
                                .padding(.top, 6)
                            }
                            .tint(.white)

                            if let message = store.pairingMessage {
                                PhoneInlineMessage(message: message, tint: PhoneTheme.success)
                            }

                            if let error = store.pairingError {
                                PhoneInlineMessage(message: error, tint: PhoneTheme.danger)
                            }
                        }
                    }

                    PhoneSectionCard("Mac Discovery", systemImage: "network") {
                        VStack(alignment: .leading, spacing: 10) {
                            if store.isScanningLAN {
                                Text("Looking for Anywhere Bridge on the local network.")
                                    .foregroundStyle(PhoneTheme.muted)
                            } else if store.isDiscovering {
                                Text("Searching for nearby Macs.")
                                    .foregroundStyle(PhoneTheme.muted)
                            } else if store.discoveredCompanions.isEmpty {
                                Text("Open Anywhere Bridge on your Mac and create a pairing QR.")
                                    .foregroundStyle(PhoneTheme.muted)
                            } else {
                                ForEach(store.discoveredCompanions) { companion in
                                    Text(companion.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)

                                    Text(companion.host)
                                        .font(.footnote)
                                        .foregroundStyle(PhoneTheme.muted)
                                }
                            }

                            if let discoveryError = store.discoveryError {
                                PhoneInlineMessage(message: discoveryError, tint: PhoneTheme.warning)
                            }

                            if let lanScanError = store.lanScanError {
                                PhoneInlineMessage(message: lanScanError, tint: PhoneTheme.warning)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Pairing")
        .toolbarTitleDisplayMode(.inline)
    }
}

private struct PhoneQRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> PhoneQRCodeScannerViewController {
        PhoneQRCodeScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ uiViewController: PhoneQRCodeScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: PhoneQRCodeScannerViewController, coordinator: ()) {
        uiViewController.stopScanning()
    }
}

private final class PhoneQRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScannedCode = false

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    func stopScanning() {
        guard session.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    private func prepareCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureScanner()
                    } else {
                        self?.onError("Camera access is required to scan the pairing QR code.")
                    }
                }
            }
        case .denied, .restricted:
            onError("Camera access is required to scan the pairing QR code.")
        @unknown default:
            onError("Camera access is unavailable on this device.")
        }
    }

    private func configureScanner() {
        guard !session.isRunning else { return }

        guard let device = AVCaptureDevice.default(for: .video) else {
            onError("No camera is available for QR pairing on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let metadataOutput = AVCaptureMetadataOutput()

            session.beginConfiguration()
            session.sessionPreset = .high

            guard session.canAddInput(input), session.canAddOutput(metadataOutput) else {
                session.commitConfiguration()
                onError("The camera cannot scan pairing QR codes on this device.")
                return
            }

            session.addInput(input)
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)

            if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                metadataOutput.metadataObjectTypes = [.qr]
            }

            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer

            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        } catch {
            onError("The camera could not start QR pairing.")
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScannedCode,
              let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadata.type == .qr,
              let code = metadata.stringValue else {
            return
        }

        hasScannedCode = true
        stopScanning()
        onCode(code)
    }
}

private struct PhoneChatView: View {
    private static let bottomAnchorID = "phone-chat-bottom"

    let store: PhoneCompanionStore
    @Binding var isSettingsPresented: Bool
    @Binding var isThreadsPresented: Bool
    @State private var selectedDiffRequest: PhoneDiffRequest?
    @State private var undoConfirmationTask: PhoneCompanionTask?
    @State private var isUndoConfirmationPresented = false
    @State private var isRunLogPresented = false
    @State private var connectionNotice: PhoneConnectionNotice?
    @State private var lastConnectionNoticeKey = ""

    private var selectedProject: PhoneCompanionProject? {
        store.selectedProject
    }

    private var chatScrollIdentity: String {
        if store.projects.isEmpty {
            return "no-projects"
        }

        if let task = store.selectedTask {
            return "thread-\(task.id)"
        }

        return "new-thread-\(store.selectedProjectID)"
    }

    private var chatScrollRevision: String {
        let task = store.selectedTask
        return [
            chatScrollIdentity,
            task?.updatedAt ?? "",
            "\(task?.messages.count ?? 0)",
            "\(task?.changedFiles.count ?? 0)",
            task?.status ?? "",
            store.taskError ?? "",
            store.runError ?? "",
            store.activeRun?.id ?? "",
            store.activeRun?.updatedAt ?? ""
        ].joined(separator: "|")
    }

    private var isSearchingForMac: Bool {
        if store.needsOffNetworkTransport {
            return false
        }

        return !store.hasResolvedConnection &&
        (store.isDiscovering || store.isScanningLAN || store.isRefreshing || store.connectionError == nil)
    }

    private var connectionNoticeKey: String {
        guard store.hasResolvedConnection else { return "" }
        return connectedBridgeName
    }

    private var connectedBridgeName: String {
        store.connectedCompanionName ?? store.daemonHostLabel
    }

    var body: some View {
        ZStack {
            PhoneBackground()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.needsOffNetworkTransport {
                            PhoneEmptyState(
                                title: "Mac is not reachable from here",
                                message: store.offNetworkTransportMessage
                            )
                        } else if isSearchingForMac {
                            PhoneMacSearchState()
                        } else if store.projects.isEmpty {
                            PhoneEmptyState(
                                title: "No synced projects",
                                message: "Open Anywhere Bridge on your Mac and sync a T3 Code project before starting a thread."
                            )
                        } else if let task = store.selectedTask {
                            PhoneThreadDetailView(
                                task: task,
                                store: store,
                                onOpenDiff: { file in
                                    selectedDiffRequest = PhoneDiffRequest(taskID: task.id, file: file)
                                },
                                onUndo: {
                                    undoConfirmationTask = task
                                    isUndoConfirmationPresented = true
                                }
                            )
                        } else {
                            PhoneEmptyState(
                                title: "What do you want to build?",
                                message: "Send a message below to start a fresh T3 Code thread on your Mac."
                            )
                        }

                        if let taskError = store.taskError {
                            PhoneInlineMessage(message: taskError, tint: PhoneTheme.danger)
                        }

                        if let runError = store.runError {
                            PhoneInlineMessage(message: runError, tint: PhoneTheme.danger)
                        }

                        if let activeRun = store.activeRun {
                            PhoneRunStatusBanner(
                                run: activeRun,
                                onInfo: {
                                    isRunLogPresented = true
                                },
                                onCancel: {
                                    store.cancelActiveRun()
                                }
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                }
                .id(chatScrollIdentity)
                .task(id: chatScrollIdentity) {
                    await scrollToBottom(proxy, animated: false)
                }
                .onChange(of: chatScrollRevision) { _, _ in
                    Task {
                        await scrollToBottom(proxy, animated: true)
                    }
                }
            }

            if let connectionNotice {
                VStack {
                    PhoneConnectionToast(name: connectionNotice.name)
                        .padding(.top, 12)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
                .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.24), value: connectionNotice)
        .onAppear {
            updateConnectionNotice(for: connectionNoticeKey)
        }
        .onChange(of: connectionNoticeKey) { _, newValue in
            updateConnectionNotice(for: newValue)
        }
        .navigationTitle("Chat")
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            PhoneChatComposerBar(store: store)
        }
        .sheet(item: $selectedDiffRequest) { request in
            NavigationStack {
                PhoneDiffView(store: store, request: request)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isRunLogPresented) {
            NavigationStack {
                PhoneRunLogView(store: store)
            }
            .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            "Undo the latest T3 Code turn?",
            isPresented: $isUndoConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let undoConfirmationTask {
                Button("Undo latest turn", role: .destructive) {
                    store.undoLatestTurn(taskID: undoConfirmationTask.id)
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This asks T3 Code to revert the thread to the previous checkpoint.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isThreadsPresented = true
                } label: {
                    Image(systemName: "text.bubble")
                        .accessibilityLabel("Threads")
                }
            }

            ToolbarItem(placement: .principal) {
                projectMenu
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.selectedTask != nil {
                    Button {
                        store.startNewThread()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .accessibilityLabel("New thread")
                    }
                }

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Settings")
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) async {
        await Task.yield()

        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func updateConnectionNotice(for key: String) {
        guard !key.isEmpty else {
            lastConnectionNoticeKey = ""
            withAnimation {
                connectionNotice = nil
            }
            return
        }

        guard key != lastConnectionNoticeKey else { return }
        lastConnectionNoticeKey = key

        let notice = PhoneConnectionNotice(name: connectedBridgeName)
        withAnimation {
            connectionNotice = notice
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))

            guard connectionNotice?.id == notice.id else { return }
            withAnimation {
                connectionNotice = nil
            }
        }
    }

    private var projectMenu: some View {
        Menu {
            if store.projects.isEmpty {
                Text("No synced projects")
            } else {
                ForEach(store.projects) { project in
                    Button {
                        store.selectProject(project.id)
                    } label: {
                        if project.id == store.selectedProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedProject?.name ?? "Select project")
                    .font(.headline)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(PhoneTheme.surfaceStrong)
                    .overlay(
                        Capsule()
                            .stroke(PhoneTheme.line, lineWidth: 1)
                    )
            )
        }
        .disabled(store.projects.isEmpty)
    }
}

private struct PhoneChatComposerBar: View {
    let store: PhoneCompanionStore

    var body: some View {
        VStack(spacing: 8) {
            Divider()
                .overlay(PhoneTheme.line)

            HStack(alignment: .bottom, spacing: 8) {
                modeMenu
                reasoningMenu

                TextField("Message T3 Code", text: Binding(
                    get: { store.taskPrompt },
                    set: { store.taskPrompt = $0 }
                ), axis: .vertical)
                .lineLimit(1...5)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(PhoneTheme.surfaceStrong)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(PhoneTheme.line, lineWidth: 1)
                )
                .foregroundStyle(.white)
                .disabled(store.projects.isEmpty)

                Button {
                    store.submitTask()
                } label: {
                    Image(systemName: store.isSubmittingTask ? "hourglass" : "arrow.up")
                        .font(.headline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(store.canSubmitTask ? PhoneTheme.accentStrong : PhoneTheme.surfaceStrong)
                        )
                }
                .foregroundStyle(.white)
                .disabled(!store.canSubmitTask)
                .accessibilityLabel(store.isSubmittingTask ? "Sending" : "Send")

                if store.shouldShowIosRunButton {
                    Button {
                        store.startIosRun()
                    } label: {
                        Image(systemName: store.isStartingOrRunningIosRun ? "hourglass" : "play.fill")
                            .font(.headline.weight(.semibold))
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(store.canStartIosRun ? PhoneTheme.accent : PhoneTheme.surfaceStrong)
                            )
                    }
                    .foregroundStyle(.white)
                    .disabled(!store.canStartIosRun)
                    .accessibilityLabel(store.isStartingOrRunningIosRun ? "Running" : "Run")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var modeMenu: some View {
        Menu {
            ForEach(PhoneTaskInteractionMode.allCases) { mode in
                Button {
                    store.selectedInteractionMode = mode
                } label: {
                    Label(mode.title, systemImage: mode == store.selectedInteractionMode ? "checkmark" : mode.systemImage)
                }
            }
        } label: {
            composerIconButton(systemImage: store.selectedInteractionMode.systemImage, label: "Mode")
        }
        .disabled(store.projects.isEmpty)
    }

    private var reasoningMenu: some View {
        Menu {
            ForEach(PhoneTaskReasoningEffort.allCases) { effort in
                Button {
                    store.selectedReasoningEffort = effort
                } label: {
                    Label(effort.title, systemImage: effort == store.selectedReasoningEffort ? "checkmark" : "brain")
                }
            }
        } label: {
            composerIconButton(systemImage: "brain", label: "Reasoning")
        }
        .disabled(store.projects.isEmpty)
    }

    private func composerIconButton(systemImage: String, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(PhoneTheme.surfaceStrong)
                    .overlay(
                        Circle()
                            .stroke(PhoneTheme.line, lineWidth: 1)
                    )
            )
            .foregroundStyle(.white)
            .accessibilityLabel(label)
    }
}

private struct PhoneRunStatusBanner: View {
    let run: PhoneIosRun
    let onInfo: () -> Void
    let onCancel: () -> Void

    private var isActive: Bool {
        !run.isTerminal
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isActive {
                ProgressView()
                    .tint(PhoneTheme.accent)
            } else {
                Image(systemName: run.status == "succeeded" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(phoneRunStatusTint(run.status))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(run.projectName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    PhoneStatusPill(title: run.phase.capitalized, color: phoneRunStatusTint(run.status))
                }

                Text(run.summary)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Build details")

            if isActive {
                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Cancel run")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PhoneTheme.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PhoneTheme.line, lineWidth: 1)
        )
    }
}

private struct PhoneRunLogView: View {
    let store: PhoneCompanionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PhoneBackground()

            VStack(alignment: .leading, spacing: 0) {
                if let run = store.activeRun {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            PhoneStatusPill(title: run.status.capitalized, color: phoneRunStatusTint(run.status))

                            if let deviceName = run.deviceName {
                                PhoneStatusPill(title: deviceName, color: PhoneTheme.accent)
                            }
                        }

                        Text(run.summary)
                            .font(.subheadline)
                            .foregroundStyle(PhoneTheme.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }

                if let runError = store.runError {
                    PhoneInlineMessage(message: runError, tint: PhoneTheme.danger)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if store.runLogs.isEmpty {
                                PhoneEmptyState(
                                    title: "Waiting for build output",
                                    message: "Xcode output will appear here when the Mac starts the run."
                                )
                                .padding(16)
                            } else {
                                ForEach(Array(store.runLogs.enumerated()), id: \.offset) { index, entry in
                                    PhoneRunLogRow(entry: entry)
                                        .id(index)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .onChange(of: store.runLogs.count) { _, newCount in
                        guard newCount > 0 else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("Run")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct PhoneRunLogRow: View {
    let entry: PhoneIosRunLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.stream)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(streamColor)
                .frame(width: 54, alignment: .leading)

            Text(entry.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(backgroundColor)
    }

    private var streamColor: Color {
        switch entry.stream {
        case "stderr":
            PhoneTheme.warning
        case "system":
            PhoneTheme.accent
        default:
            PhoneTheme.muted
        }
    }

    private var backgroundColor: Color {
        switch entry.stream {
        case "stderr":
            PhoneTheme.warning.opacity(0.10)
        case "system":
            PhoneTheme.accent.opacity(0.10)
        default:
            Color.white.opacity(0.04)
        }
    }
}

private struct PhoneDiffRequest: Identifiable {
    let taskID: String
    let file: PhoneChangedFile

    var id: String { "\(taskID)-\(file.path)" }
}

private struct PhoneConnectionNotice: Identifiable, Equatable {
    let id = UUID()
    let name: String
}

private struct PhoneConnectionToast: View {
    let name: String

    var body: some View {
        Label("Connected to \(name)", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(PhoneTheme.success)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    )
            )
            .shadow(color: PhoneTheme.success.opacity(0.28), radius: 14, y: 8)
            .accessibilityLabel("Connected to \(name)")
    }
}

private struct PhoneMacSearchState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Searching for Mac")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("Keep Anywhere Bridge open on your Mac and stay on the same Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.muted)
            }

            VStack(alignment: .leading, spacing: 10) {
                PhoneShimmerBar(width: 0.82)
                PhoneShimmerBar(width: 0.58)
                PhoneShimmerBar(width: 0.72)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PhoneTheme.surfaceStrong)
        )
    }
}

private struct PhoneShimmerBar: View {
    let width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .frame(width: proxy.size.width * width)
                .phoneShimmer()
        }
        .frame(height: 12)
    }
}

private struct PhoneThreadDetailView: View {
    let task: PhoneCompanionTask
    let store: PhoneCompanionStore
    let onOpenDiff: (PhoneChangedFile) -> Void
    let onUndo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    PhoneStatusPill(
                        title: task.status.capitalized,
                        color: phoneTaskStatusTint(task.status)
                    )

                    Text(phoneFormattedDate(task.updatedAt))
                        .font(.caption)
                        .foregroundStyle(PhoneTheme.muted)
                }

                Text(task.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(task.summary)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.muted)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if task.messages.isEmpty {
                PhoneInlineMessage(message: "No thread messages have synced yet.", tint: PhoneTheme.warning)
            } else {
                ForEach(task.messages) { message in
                    PhoneThreadMessageBubble(message: message)
                }
            }

            if task.status == "running" || task.status == "queued" {
                PhoneAssistantThinkingBubble(status: task.status)
            }

            if task.status == "done" {
                PhoneChangedFilesSection(
                    task: task,
                    onOpenDiff: onOpenDiff,
                    onUndo: onUndo,
                    isUndoing: store.undoingTaskID == task.id
                )
            }
        }
    }
}

private struct PhoneAssistantThinkingBubble: View {
    let status: String
    @State private var isAnimating = false

    private var label: String {
        status == "queued" ? "Waiting for T3 Code" : "T3 Code is thinking"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PhoneTheme.muted)

                HStack(spacing: 7) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(PhoneTheme.accent)
                            .frame(width: 7, height: 18)
                            .scaleEffect(y: isAnimating ? 1.0 : 0.34, anchor: .bottom)
                            .opacity(isAnimating ? 1.0 : 0.42)
                            .animation(
                                .easeInOut(duration: 0.58)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.11),
                                value: isAnimating
                            )
                    }
                }
                .frame(height: 22, alignment: .bottom)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PhoneTheme.surfaceStrong)
            )
            .onAppear {
                isAnimating = true
            }

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhoneThreadMessageBubble: View {
    let message: PhoneCompanionMessage

    private var isUser: Bool {
        message.role == "user"
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 36)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(message.role.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isUser ? .white.opacity(0.82) : PhoneTheme.muted)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isUser ? PhoneTheme.accentStrong.opacity(0.82) : PhoneTheme.surfaceStrong)
            )
            .frame(maxWidth: 330, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct PhoneChangedFilesSection: View {
    let task: PhoneCompanionTask
    let onOpenDiff: (PhoneChangedFile) -> Void
    let onUndo: () -> Void
    let isUndoing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Changed files")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                if task.undoAvailable {
                    Button(role: .destructive) {
                        onUndo()
                    } label: {
                        Label(isUndoing ? "Undoing" : "Undo", systemImage: "arrow.uturn.backward")
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(isUndoing)
                }
            }

            if task.changedFiles.isEmpty {
                Text("No changed files captured yet.")
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(task.changedFiles) { file in
                        Button {
                            onOpenDiff(file)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(PhoneTheme.accent)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.path)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)

                                    if let status = file.status, !status.isEmpty {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(PhoneTheme.muted)
                                    }
                                }

                                Spacer()

                                PhoneDiffStatView(additions: file.additions, deletions: file.deletions)

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(PhoneTheme.muted)
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)

                        if file.id != task.changedFiles.last?.id {
                            Divider()
                                .overlay(PhoneTheme.line)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PhoneTheme.surfaceStrong)
        )
    }
}

private struct PhoneDiffStatView: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)")
                .foregroundStyle(PhoneTheme.success)

            Text("-\(deletions)")
                .foregroundStyle(PhoneTheme.danger)
        }
        .font(.caption.weight(.bold))
        .lineLimit(1)
        .monospacedDigit()
    }
}

private enum PhoneDiffLineKind {
    case context
    case addition
    case deletion
    case hunk
    case note
}

private struct PhoneParsedDiffLine: Identifiable {
    let id = UUID()
    let oldLine: Int?
    let newLine: Int?
    let marker: String
    let text: String
    let kind: PhoneDiffLineKind
}

private struct PhoneDiffView: View {
    let store: PhoneCompanionStore
    let request: PhoneDiffRequest
    @Environment(\.dismiss) private var dismiss
    @State private var diffText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            PhoneBackground()

            ScrollView {
                if isLoading {
                    ProgressView("Loading diff")
                        .tint(PhoneTheme.accent)
                        .foregroundStyle(.white)
                        .padding(24)
                } else if let errorMessage {
                    PhoneInlineMessage(message: errorMessage, tint: PhoneTheme.danger)
                        .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(request.file.path)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(3)

                            Spacer(minLength: 8)

                            PhoneDiffStatView(additions: request.file.additions, deletions: request.file.deletions)
                        }
                        .padding(14)
                        .background(PhoneTheme.surfaceStrong)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            let lines = phoneParseUnifiedDiff(diffText)
                            if lines.isEmpty {
                                Text("No diff was available for this file.")
                                    .font(.subheadline)
                                    .foregroundStyle(PhoneTheme.muted)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(lines) { line in
                                    PhoneDiffLineRow(line: line)
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(PhoneTheme.line, lineWidth: 1)
                    )
                    .padding(16)
                }
            }
        }
        .navigationTitle(request.file.path)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .task(id: request.id) {
            isLoading = true
            errorMessage = nil

            do {
                diffText = try await store.loadTaskDiff(taskID: request.taskID, filePath: request.file.path)
            } catch {
                errorMessage = error.localizedDescription
            }

            isLoading = false
        }
    }
}

private struct PhoneDiffLineRow: View {
    let line: PhoneParsedDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(PhoneTheme.muted.opacity(0.7))

            Text(line.newLine.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(PhoneTheme.muted.opacity(0.7))

            Text(line.marker)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(markerColor)

            Text(line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 7 : 4)
        .padding(.trailing, 8)
        .background(backgroundColor)
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition:
            PhoneTheme.success
        case .deletion:
            PhoneTheme.danger
        case .hunk:
            PhoneTheme.accent
        case .context, .note:
            PhoneTheme.muted
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .hunk:
            PhoneTheme.accent
        case .note:
            PhoneTheme.muted
        default:
            .white
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition:
            return PhoneTheme.success.opacity(0.16)
        case .deletion:
            return PhoneTheme.danger.opacity(0.16)
        case .hunk:
            return PhoneTheme.accent.opacity(0.12)
        case .context:
            return Color.white.opacity(0.03)
        case .note:
            return Color.white.opacity(0.02)
        }
    }
}

private func phoneParseUnifiedDiff(_ diff: String) -> [PhoneParsedDiffLine] {
    var lines: [PhoneParsedDiffLine] = []
    var oldLine: Int?
    var newLine: Int?
    var hasHunk = false

    for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if rawLine.hasPrefix("diff --git ") ||
            rawLine.hasPrefix("index ") ||
            rawLine.hasPrefix("--- ") ||
            rawLine.hasPrefix("+++ ") {
            continue
        }

        if rawLine.hasPrefix("@@") {
            let starts = phoneParseHunkStarts(rawLine)
            oldLine = starts?.oldLine
            newLine = starts?.newLine
            hasHunk = true
            lines.append(
                PhoneParsedDiffLine(
                    oldLine: nil,
                    newLine: nil,
                    marker: "",
                    text: rawLine,
                    kind: .hunk
                )
            )
            continue
        }

        guard hasHunk else {
            continue
        }

        if rawLine.hasPrefix("+") {
            lines.append(
                PhoneParsedDiffLine(
                    oldLine: nil,
                    newLine: newLine,
                    marker: "+",
                    text: String(rawLine.dropFirst()),
                    kind: .addition
                )
            )
            newLine = newLine.map { $0 + 1 }
        } else if rawLine.hasPrefix("-") {
            lines.append(
                PhoneParsedDiffLine(
                    oldLine: oldLine,
                    newLine: nil,
                    marker: "-",
                    text: String(rawLine.dropFirst()),
                    kind: .deletion
                )
            )
            oldLine = oldLine.map { $0 + 1 }
        } else if rawLine.hasPrefix("\\") {
            lines.append(
                PhoneParsedDiffLine(
                    oldLine: nil,
                    newLine: nil,
                    marker: "",
                    text: rawLine,
                    kind: .note
                )
            )
        } else {
            let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
            lines.append(
                PhoneParsedDiffLine(
                    oldLine: oldLine,
                    newLine: newLine,
                    marker: " ",
                    text: text,
                    kind: .context
                )
            )
            oldLine = oldLine.map { $0 + 1 }
            newLine = newLine.map { $0 + 1 }
        }
    }

    return lines
}

private func phoneParseHunkStarts(_ line: String) -> (oldLine: Int, newLine: Int)? {
    let parts = line.split(separator: " ")
    guard let oldPart = parts.first(where: { $0.hasPrefix("-") }),
          let newPart = parts.first(where: { $0.hasPrefix("+") }) else {
        return nil
    }

    let oldStart = oldPart.dropFirst().split(separator: ",").first.flatMap { Int($0) }
    let newStart = newPart.dropFirst().split(separator: ",").first.flatMap { Int($0) }

    guard let oldStart, let newStart else {
        return nil
    }

    return (oldStart, newStart)
}

private struct PhoneShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.34),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.68)
                    .offset(x: phase * proxy.size.width)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
    }
}

private extension View {
    func phoneShimmer() -> some View {
        modifier(PhoneShimmerModifier())
    }
}

private struct PhoneSettingsView: View {
    let store: PhoneCompanionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PhoneBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PhoneConnectionView(store: store)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct PhoneConnectionView: View {
    let store: PhoneCompanionStore

    var body: some View {
        PhoneSectionCard("Anywhere Bridge", systemImage: "network") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(store.isRefreshing ? "Refreshing..." : "Reconnect") {
                        store.reconnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PhoneTheme.accentStrong)
                    .disabled(store.isRefreshing)

                    if let health = store.health {
                        PhoneStatusPill(
                            title: health.ok ? "Bridge online" : "Unavailable",
                            color: health.ok ? PhoneTheme.success : PhoneTheme.warning
                        )
                    } else {
                        PhoneStatusPill(title: "Disconnected", color: PhoneTheme.warning)
                    }
                }

                connectionDetail

                if !store.discoveredCompanions.isEmpty {
                    nearbyCompanions
                }

                if let detail = store.health?.provider?.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(PhoneTheme.muted)
                }

                if let discoveryError = store.discoveryError {
                    PhoneInlineMessage(message: discoveryError, tint: PhoneTheme.warning)
                }

                if let lanScanError = store.lanScanError {
                    PhoneInlineMessage(message: lanScanError, tint: PhoneTheme.warning)
                }

                if let error = store.connectionError, !store.needsOffNetworkTransport {
                    PhoneInlineMessage(message: error, tint: PhoneTheme.danger)
                }

                DisclosureGroup("Connect manually") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("http://192.168.1.10:4242", text: Binding(
                            get: { store.daemonURLString },
                            set: { store.daemonURLString = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .phoneFieldStyle()

                        Text("Only needed if discovery cannot find your Mac.")
                            .font(.footnote)
                            .foregroundStyle(PhoneTheme.muted)
                    }
                    .padding(.top, 6)
                }
                .tint(.white)

                DisclosureGroup("Pair with QR payload") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: Binding(
                            get: { store.pairingPayloadText },
                            set: { store.pairingPayloadText = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 96)
                        .phoneFieldStyle()

                        Button("Pair Phone") {
                            store.pairWithQRCodePayload()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PhoneTheme.accentStrong)
                        .disabled(store.pairingPayloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text("Scan or copy the QR payload from the Mac. The paired phone credential lasts 30 days.")
                            .font(.footnote)
                            .foregroundStyle(PhoneTheme.muted)

                        if let message = store.pairingMessage {
                            PhoneInlineMessage(message: message, tint: PhoneTheme.success)
                        }

                        if let error = store.pairingError {
                            PhoneInlineMessage(message: error, tint: PhoneTheme.danger)
                        }
                    }
                    .padding(.top, 6)
                }
                .tint(.white)
            }
        }
    }

    @ViewBuilder
    private var connectionDetail: some View {
        if let companionName = store.connectedCompanionName, store.hasResolvedConnection {
            Text("Connected to \(companionName)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        } else if store.needsOffNetworkTransport {
            Text(store.offNetworkTransportMessage)
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.warning)
        } else if store.isScanningLAN {
            Text("Scanning the local Wi-Fi for your Mac.")
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.muted)
        } else if store.isDiscovering && store.discoveredCompanions.isEmpty {
            Text("Searching for nearby Macs on your local network.")
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.muted)
        } else if !store.daemonURLString.isEmpty {
            Text(store.daemonURLString)
                .font(.footnote.monospaced())
                .foregroundStyle(PhoneTheme.muted)
        }
    }

    private var nearbyCompanions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nearby Macs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            ForEach(store.discoveredCompanions) { companion in
                Button {
                    store.connect(to: companion)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(companion.name)
                                .foregroundStyle(.white)
                            Text(companion.host)
                                .font(.footnote)
                                .foregroundStyle(PhoneTheme.muted)
                        }

                        Spacer()

                        if companion.urlString == store.daemonURLString {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PhoneTheme.success)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PhoneTheme.surfaceStrong)
                )
            }
        }
    }
}

private struct PhoneThreadsView: View {
    let store: PhoneCompanionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PhoneBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        PhoneStatusPill(title: store.daemonHostLabel, color: store.hasResolvedConnection ? PhoneTheme.success : PhoneTheme.warning)

                        Spacer()

                        Button("Refresh") {
                            Task {
                                await store.refreshAll()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    if store.tasks.isEmpty {
                        PhoneEmptyState(
                            title: "No T3-backed threads yet",
                            message: "Start a chat and it will appear here."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.tasks) { task in
                                PhoneThreadListRow(
                                    task: task,
                                    projectName: store.projects.first { $0.id == task.projectId }?.name,
                                    isSelected: task.id == store.selectedTaskID
                                ) {
                                    store.selectThread(task)
                                    dismiss()
                                }

                                if task.id != store.tasks.last?.id {
                                    Divider()
                                        .overlay(PhoneTheme.line)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(PhoneTheme.surfaceStrong)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Threads")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct PhoneThreadListRow: View {
    let task: PhoneCompanionTask
    let projectName: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                        .foregroundStyle(isSelected ? .white : PhoneTheme.muted)
                        .lineLimit(1)

                    if let projectName {
                        Text(projectName)
                            .font(.caption)
                            .foregroundStyle(PhoneTheme.muted.opacity(0.82))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(phoneRelativeThreadDate(task.updatedAt))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : PhoneTheme.muted.opacity(0.72))
                    .lineLimit(1)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private func phoneFormattedDate(_ value: String) -> String {
    guard let date = phoneDate(from: value) else {
        return value
    }

    return date.formatted(date: .abbreviated, time: .shortened)
}

private func phoneRelativeThreadDate(_ value: String) -> String {
    guard let date = phoneDate(from: value) else {
        return value
    }

    let elapsed = max(0, Int(Date().timeIntervalSince(date)))
    if elapsed < 60 {
        return "\(max(1, elapsed)) sec ago"
    }

    if elapsed < 60 * 60 {
        return "\(elapsed / 60) min ago"
    }

    if elapsed < 60 * 60 * 24 {
        return "\(elapsed / (60 * 60)) h ago"
    }

    if elapsed < 60 * 60 * 24 * 7 {
        return "\(elapsed / (60 * 60 * 24)) d ago"
    }

    return date.formatted(date: .abbreviated, time: .omitted)
}

private func phoneDate(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) {
        return date
    }

    return nil
}
