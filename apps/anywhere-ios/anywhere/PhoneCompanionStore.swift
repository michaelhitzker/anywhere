import Foundation
import Observation

struct PhoneDaemonHealth: Decodable {
    struct ProviderInfo: Decodable {
        let id: String
        let label: String
        let detail: String
    }

    let ok: Bool
    let service: String
    let codexAuth: String
    let transport: String
    let provider: ProviderInfo?
}

struct PhoneCompanionProject: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let repoPath: String
    let platform: String
    let supportsIosRun: Bool?
    let previewModes: [String]

    var canRunIos: Bool {
        supportsIosRun == true || platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ios"
    }
}

struct PhoneCompanionArtifact: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let label: String
    let url: String
    let note: String
}

struct PhoneCompanionMessage: Decodable, Identifiable, Hashable {
    let id: String
    let role: String
    let text: String
    let createdAt: String
    let updatedAt: String
}

struct PhoneChangedFile: Decodable, Identifiable, Hashable {
    let path: String
    let status: String?
    let additions: Int
    let deletions: Int

    var id: String { path }
}

struct PhoneTaskLogEntry: Decodable, Identifiable, Hashable {
    let at: String
    let message: String

    var id: String { "\(at)-\(message)" }
}

struct PhoneIosRunLogEntry: Decodable, Identifiable, Hashable {
    let at: String
    let stream: String
    let line: String

    var id: String { "\(at)-\(stream)-\(line)" }
}

struct PhoneIosRun: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let projectName: String
    let status: String
    let phase: String
    let summary: String
    let createdAt: String
    let updatedAt: String
    let deviceId: String?
    let deviceName: String?
    let scheme: String?
    let appPath: String?
    let bundleIdentifier: String?
    let logTail: [PhoneIosRunLogEntry]

    var isTerminal: Bool {
        status == "succeeded" || status == "failed" || status == "canceled"
    }
}

struct PhoneCompanionTask: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let projectId: String
    let prompt: String
    let createdAt: String
    let updatedAt: String
    let status: String
    let summary: String
    let branchName: String?
    let worktreePath: String?
    let messages: [PhoneCompanionMessage]
    let changedFiles: [PhoneChangedFile]
    let latestTurnCount: Int?
    let undoAvailable: Bool
    let logs: [PhoneTaskLogEntry]
    let artifacts: [PhoneCompanionArtifact]
    let nextActions: [String]
}

private struct PhoneAPIErrorResponse: Decodable {
    let error: String
}

private struct PhonePairingPayload: Decodable {
    let type: String
    let version: Int
    let pairingId: String
    let pairingSecret: String
    let desktopName: String
    let apiBaseUrl: String?
    let relayUrl: String?
    let expiresAt: String
    let credentialExpiresAt: String
}

private struct PhonePairingCompletePayload: Encodable {
    let pairingId: String
    let pairingSecret: String
    let clientName: String
}

private struct PhonePairedClient: Decodable {
    let id: String
    let name: String
    let expiresAt: String
}

private struct PhonePairingCompleteResponse: Decodable {
    let client: PhonePairedClient
    let token: String
}

private struct PhoneProjectsResponse: Decodable {
    let projects: [PhoneCompanionProject]
}

private struct PhoneTasksResponse: Decodable {
    let tasks: [PhoneCompanionTask]
}

private struct PhoneTaskMutationResponse: Decodable {
    let task: PhoneCompanionTask
    let tasks: [PhoneCompanionTask]
}

private struct PhoneRunMutationResponse: Decodable {
    let run: PhoneIosRun
}

private struct PhoneEmptyPayload: Encodable {}

private struct PhoneRunEventPayload: Decodable {
    let at: String?
    let run: PhoneIosRun?
    let phase: String?
    let status: String?
    let message: String?
    let stream: String?
    let line: String?
}

private struct PhoneTaskSubmissionPayload: Encodable {
    let projectId: String
    let prompt: String
    let interactionMode: String
    let reasoningEffort: String?
}

private struct PhoneTaskTurnPayload: Encodable {
    let prompt: String
    let interactionMode: String
    let reasoningEffort: String?
}

enum PhoneTaskInteractionMode: String, CaseIterable, Identifiable {
    case code
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .code:
            "Chat"
        case .plan:
            "Plan"
        }
    }

    var systemImage: String {
        switch self {
        case .code:
            "bubble.left.and.bubble.right"
        case .plan:
            "list.bullet.clipboard"
        }
    }
}

enum PhoneTaskReasoningEffort: String, CaseIterable, Identifiable {
    case automatic
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "Auto"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        }
    }

    var payloadValue: String? {
        switch self {
        case .automatic:
            nil
        case .low, .medium, .high:
            rawValue
        }
    }
}

@MainActor
@Observable
final class PhoneCompanionStore {
    private let userDefaults = UserDefaults.standard
    private let discovery = PhoneBonjourDiscovery()
    private let lanScanner = PhoneLANScanner()
    private var refreshTask: Task<Void, Never>?
    private var lanScanTask: Task<Void, Never>?
    private var runStreamTask: Task<Void, Never>?
    private var runStreamID: UUID?
    private static let daemonURLKey = "phone.daemonURL"
    private static let lastSuccessfulDaemonURLKey = "phone.lastSuccessfulDaemonURL"
    private static let pairingTokenKey = "phone.pairingToken"

    var daemonURLString: String
    var pairingPayloadText = ""
    var pairingMessage: String?
    var pairingError: String?
    var pairingToken: String?
    var health: PhoneDaemonHealth?
    var projects: [PhoneCompanionProject] = []
    var tasks: [PhoneCompanionTask] = []
    var discoveredCompanions: [PhoneDiscoveredCompanion] = []
    var selectedProjectID = ""
    var selectedTaskID = ""
    var selectedInteractionMode = PhoneTaskInteractionMode.code
    var selectedReasoningEffort = PhoneTaskReasoningEffort.automatic
    var taskPrompt = ""
    var isRefreshing = false
    var isDiscovering = false
    var isScanningLAN = false
    var isSubmittingTask = false
    var undoingTaskID: String?
    var activeRun: PhoneIosRun?
    var runLogs: [PhoneIosRunLogEntry] = []
    var connectionError: String?
    var discoveryError: String?
    var lanScanError: String?
    var taskError: String?
    var runError: String?

    var hasPairingCredential: Bool {
        pairingToken?.isEmpty == false
    }

    init() {
        daemonURLString = userDefaults.string(forKey: Self.lastSuccessfulDaemonURLKey)
            ?? userDefaults.string(forKey: Self.daemonURLKey)
            ?? Self.defaultDaemonURLString()
        pairingToken = userDefaults.string(forKey: Self.pairingTokenKey)

        if !Self.prefersLoopbackDefault, isLoopbackURLString(daemonURLString) {
            daemonURLString = ""
        }

        discovery.onUpdate = { [weak self] companions in
            self?.discoveredCompanions = companions
        }
        discovery.onStateChange = { [weak self] isSearching, error in
            self?.isDiscovering = isSearching
            self?.discoveryError = error
        }
        discovery.onPreferredCompanionResolved = { [weak self] companion in
            self?.maybeAutoConnect(to: companion)
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        discovery.start()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            if hasPairingCredential && shouldAttemptNetworkRequests {
                await refreshAll()
            } else {
                scheduleLANScanFallback()
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if hasPairingCredential && shouldAttemptNetworkRequests {
                    await refreshTasks()
                    await refreshActiveRun(restartStream: false)
                } else {
                    scheduleLANScanFallback()
                }
            }
        }
    }

    func reconnect() {
        persistDaemonURL()
        discovery.start()

        guard hasPairingCredential else {
            connectionError = nil
            scheduleLANScanFallback()
            return
        }

        guard shouldAttemptNetworkRequests else {
            connectionError = Self.prefersLoopbackDefault
                ? nil
                : "Pick a nearby Mac or enter its LAN address. 127.0.0.1 only works in the simulator."
            scheduleLANScanFallback()
            return
        }

        Task {
            await refreshAll()
        }
    }

    func connect(to companion: PhoneDiscoveredCompanion) {
        daemonURLString = companion.urlString
        reconnect()
    }

    func pairWithQRCodePayload() {
        pair(withQRCodePayload: pairingPayloadText)
    }

    func pairWithScannedQRCodePayload(_ payload: String) {
        pairingPayloadText = payload
        pair(withQRCodePayload: payload)
    }

    private func pair(withQRCodePayload payload: String) {
        let rawPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPayload.isEmpty else { return }

        pairingError = nil
        pairingMessage = nil

        Task {
            do {
                let payload = try decodePairingPayload(rawPayload)
                if let apiBaseUrl = payload.apiBaseUrl, !apiBaseUrl.isEmpty {
                    daemonURLString = apiBaseUrl
                    persistDaemonURL()
                }

                let response: PhonePairingCompleteResponse = try await send(
                    "/api/pairing/complete",
                    method: "POST",
                    body: PhonePairingCompletePayload(
                        pairingId: payload.pairingId,
                        pairingSecret: payload.pairingSecret,
                        clientName: "iPhone"
                    )
                )

                pairingToken = response.token
                userDefaults.set(response.token, forKey: Self.pairingTokenKey)
                pairingPayloadText = ""
                pairingMessage = "Paired with \(payload.desktopName). Access expires \(response.client.expiresAt)."
                await refreshAll()
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let healthResponse: PhoneDaemonHealth = try await fetch("/api/health")
            let projectResponse: PhoneProjectsResponse = try await fetch("/api/projects")
            let taskResponse: PhoneTasksResponse = try await fetch("/api/tasks")

            health = healthResponse
            projects = projectResponse.projects
            tasks = taskResponse.tasks
            connectionError = nil
            discoveryError = nil
            synchronizeSelectedProject()
            synchronizeSelectedTask()
            persistSuccessfulDaemonURL()
            await refreshActiveRun(restartStream: false)
        } catch {
            health = nil
            projects = []
            tasks = []
            selectedTaskID = ""
            connectionError = error.localizedDescription
            discovery.start()
            scheduleLANScanFallback()
        }
    }

    func refreshTasks() async {
        do {
            let response: PhoneTasksResponse = try await fetch("/api/tasks")
            tasks = response.tasks
            connectionError = nil
            synchronizeSelectedTask()
            await refreshActiveRun(restartStream: false)
        } catch {
            if tasks.isEmpty {
                connectionError = error.localizedDescription
            }
        }
    }

    func submitTask() {
        let prompt = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedProjectID.isEmpty, !prompt.isEmpty else { return }

        isSubmittingTask = true
        taskError = nil

        Task {
            defer { isSubmittingTask = false }

            do {
                let response: PhoneTaskMutationResponse
                if canContinueSelectedTask {
                    response = try await send(
                        "/api/tasks/\(percentEncodedPathSegment(selectedTaskID))/turns",
                        method: "POST",
                        body: PhoneTaskTurnPayload(
                            prompt: prompt,
                            interactionMode: selectedInteractionMode.rawValue,
                            reasoningEffort: selectedReasoningEffort.payloadValue
                        )
                    )
                } else {
                    response = try await send(
                        "/api/tasks",
                        method: "POST",
                        body: PhoneTaskSubmissionPayload(
                            projectId: selectedProjectID,
                            prompt: prompt,
                            interactionMode: selectedInteractionMode.rawValue,
                            reasoningEffort: selectedReasoningEffort.payloadValue
                        )
                    )
                }

                taskPrompt = ""
                tasks = response.tasks
                selectedTaskID = response.task.id
                selectedProjectID = response.task.projectId
                connectionError = nil
            } catch {
                taskError = error.localizedDescription
            }
        }
    }

    func selectProject(_ projectID: String) {
        selectedProjectID = projectID
        selectedTaskID = tasks.first { $0.projectId == projectID }?.id ?? ""
    }

    func selectThread(_ task: PhoneCompanionTask) {
        selectedProjectID = task.projectId
        selectedTaskID = task.id
    }

    func startNewThread() {
        selectedTaskID = ""
        taskPrompt = ""
    }

    func loadTaskDiff(taskID: String, filePath: String) async throws -> String {
        try await fetchText(taskDiffPath(taskID: taskID, filePath: filePath))
    }

    func undoLatestTurn(taskID: String) {
        undoingTaskID = taskID
        taskError = nil

        Task {
            defer { undoingTaskID = nil }

            do {
                let response: PhoneTaskMutationResponse = try await send(
                    "/api/tasks/\(percentEncodedPathSegment(taskID))/undo",
                    method: "POST",
                    body: PhoneTaskTurnPayload(
                        prompt: "",
                        interactionMode: selectedInteractionMode.rawValue,
                        reasoningEffort: selectedReasoningEffort.payloadValue
                    )
                )
                tasks = response.tasks
                selectedTaskID = response.task.id
                selectedProjectID = response.task.projectId
                connectionError = nil
            } catch {
                taskError = error.localizedDescription
            }
        }
    }

    func startIosRun() {
        guard canStartIosRun else { return }

        runError = nil

        Task {
            do {
                let response: PhoneRunMutationResponse = try await send(
                    "/api/projects/\(percentEncodedPathSegment(selectedProjectID))/runs",
                    method: "POST",
                    body: PhoneEmptyPayload()
                )
                activeRun = response.run
                runLogs = response.run.logTail
                observeRunEvents(runID: response.run.id)
            } catch {
                runError = error.localizedDescription
            }
        }
    }

    func cancelActiveRun() {
        guard let activeRun, !activeRun.isTerminal else { return }

        Task {
            do {
                let response: PhoneRunMutationResponse = try await send(
                    "/api/runs/\(percentEncodedPathSegment(activeRun.id))/cancel",
                    method: "POST",
                    body: PhoneEmptyPayload()
                )
                self.activeRun = response.run
                runLogs = response.run.logTail
                runStreamTask?.cancel()
                runStreamTask = nil
                runStreamID = nil
            } catch {
                runError = error.localizedDescription
            }
        }
    }

    func resumeActiveRun() async {
        guard shouldAttemptNetworkRequests else { return }
        await refreshActiveRun(restartStream: true)
    }

    func artifactURL(for path: String) -> URL? {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let baseURL = normalizedDaemonURL else {
            return nil
        }

        return URL(string: path, relativeTo: baseURL)
    }

    var canSubmitTask: Bool {
        hasPairingCredential &&
        !selectedProjectID.isEmpty &&
        !taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSubmittingTask
    }

    var canStartIosRun: Bool {
        hasPairingCredential && shouldShowIosRunButton && !isStartingOrRunningIosRun
    }

    var shouldShowIosRunButton: Bool {
        selectedProject?.canRunIos == true
    }

    var isStartingOrRunningIosRun: Bool {
        activeRun.map { !$0.isTerminal } ?? false
    }

    var selectedProject: PhoneCompanionProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedTask: PhoneCompanionTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    private var canContinueSelectedTask: Bool {
        tasks.contains { $0.id == selectedTaskID && $0.projectId == selectedProjectID }
    }

    var daemonHostLabel: String {
        normalizedDaemonURL?.host() ?? daemonURLString
    }

    var hasResolvedConnection: Bool {
        health != nil
    }

    var connectedCompanionName: String? {
        guard let normalizedURL = normalizedDaemonURL?.absoluteString else {
            return nil
        }

        return discoveredCompanions.first(where: { $0.urlString == normalizedURL })?.name
    }

    var shouldShowManualAddress: Bool {
        discoveredCompanions.isEmpty || health == nil
    }

    var needsOffNetworkTransport: Bool {
        hasPairingCredential &&
        !hasResolvedConnection &&
        connectionError != nil &&
        isUsingLocalNetworkAddress
    }

    var offNetworkTransportMessage: String {
        "Your phone is paired, but the saved Mac address only works on the Mac's local network. Join the same Wi-Fi or use a VPN/tunnel such as Tailscale or WireGuard; built-in relay transport is still pending."
    }

    private var shouldAttemptNetworkRequests: Bool {
        guard normalizedDaemonURL != nil else { return false }
        return Self.prefersLoopbackDefault || !isLoopbackURLString(daemonURLString)
    }

    private var isUsingLocalNetworkAddress: Bool {
        guard let host = normalizedDaemonURL?.host()?.lowercased() else { return false }
        return Self.isLocalNetworkHost(host)
    }

    private var normalizedDaemonURL: URL? {
        let trimmed = daemonURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let directURL = URL(string: trimmed), directURL.scheme != nil {
            return sanitizedURL(directURL)
        }

        if let prefixedURL = URL(string: "http://\(trimmed)") {
            return sanitizedURL(prefixedURL)
        }

        return nil
    }

    private func sanitizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private func persistDaemonURL() {
        daemonURLString = normalizedDaemonURL?.absoluteString ?? daemonURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        userDefaults.set(daemonURLString, forKey: Self.daemonURLKey)
    }

    private func persistSuccessfulDaemonURL() {
        persistDaemonURL()
        userDefaults.set(daemonURLString, forKey: Self.lastSuccessfulDaemonURLKey)
    }

    private func synchronizeSelectedProject() {
        if projects.contains(where: { $0.id == selectedProjectID }) {
            return
        }

        selectedProjectID = projects.first?.id ?? ""
    }

    private func synchronizeSelectedTask() {
        if selectedTaskID.isEmpty {
            return
        }

        if tasks.contains(where: { $0.id == selectedTaskID && $0.projectId == selectedProjectID }) {
            return
        }

        selectedTaskID = ""
    }

    private func fetch<Response: Decodable>(_ path: String) async throws -> Response {
        guard let url = apiURL(path) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
        return try decodeResponse(data: data, response: response)
    }

    private func send<Request: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Request
    ) async throws -> Response {
        guard let url = apiURL(path) else {
            throw URLError(.badURL)
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func observeRunEvents(runID: String) {
        runStreamTask?.cancel()
        let streamID = UUID()
        runStreamID = streamID

        runStreamTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await streamRunEvents(runID: runID)
                guard runStreamID == streamID else { return }
                runStreamTask = nil
                runStreamID = nil
                await refreshActiveRun(restartStream: false)
            } catch is CancellationError {
            } catch {
                guard runStreamID == streamID else { return }
                let errorMessage = error.localizedDescription
                runStreamTask = nil
                runStreamID = nil
                await refreshActiveRun(restartStream: false)

                if !isRequestTimedOut(error) {
                    runError = errorMessage
                }
            }
        }
    }

    private func refreshActiveRun(restartStream: Bool) async {
        guard let runID = activeRun?.id else { return }

        do {
            let response: PhoneRunMutationResponse = try await fetch("/api/runs/\(percentEncodedPathSegment(runID))")
            activeRun = response.run
            runLogs = response.run.logTail

            if response.run.status != "failed" {
                runError = nil
            }

            if response.run.isTerminal {
                runStreamTask?.cancel()
                runStreamTask = nil
                runStreamID = nil
            } else if restartStream || runStreamTask == nil {
                observeRunEvents(runID: response.run.id)
            }
        } catch {
            if activeRun?.isTerminal != true {
                runError = error.localizedDescription
            }
        }
    }

    private func streamRunEvents(runID: String) async throws {
        guard let url = apiURL("/api/runs/\(percentEncodedPathSegment(runID))/events") else {
            throw URLError(.badURL)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: authorizedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        var eventName = "message"
        var dataLines: [String] = []

        for try await line in bytes.lines {
            if Task.isCancelled {
                throw CancellationError()
            }

            if line.isEmpty {
                handleRunEvent(name: eventName, data: dataLines.joined(separator: "\n"))
                eventName = "message"
                dataLines = []
                continue
            }

            if line.hasPrefix(":") {
                continue
            }

            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private func handleRunEvent(name: String, data: String) {
        guard !data.isEmpty, let rawData = data.data(using: .utf8) else {
            return
        }

        guard let payload = try? JSONDecoder().decode(PhoneRunEventPayload.self, from: rawData) else {
            return
        }

        if let run = payload.run {
            activeRun = run
            runLogs = run.logTail

            if run.isTerminal {
                runStreamTask?.cancel()
                runStreamTask = nil
                runStreamID = nil
            }
        }

        if name == "log", let stream = payload.stream, let line = payload.line {
            runLogs.append(
                PhoneIosRunLogEntry(
                    at: payload.at ?? ISO8601DateFormatter().string(from: Date()),
                    stream: stream,
                    line: line
                )
            )
            runLogs = Array(runLogs.suffix(400))
        }

        if name == "error", let message = payload.message {
            runError = message
        }
    }

    private func fetchText(_ path: String) async throws -> String {
        guard let url = apiURL(path) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
        try validateResponse(data: data, response: response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decodeResponse<Response: Decodable>(data: Data, response: URLResponse) throws -> Response {
        try validateResponse(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return
        }

        if httpResponse.statusCode == 401 {
            pairingToken = nil
            userDefaults.removeObject(forKey: Self.pairingTokenKey)
        }

        if let apiError = try? JSONDecoder().decode(PhoneAPIErrorResponse.self, from: data) {
            throw NSError(
                domain: "PhoneCompanionStore.API",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: apiError.error]
            )
        }

        throw URLError(.badServerResponse)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let pairingToken, !pairingToken.isEmpty {
            request.setValue("Bearer \(pairingToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func isRequestTimedOut(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func taskDiffPath(taskID: String, filePath: String) -> String {
        var components = URLComponents()
        components.path = "/api/tasks/\(percentEncodedPathSegment(taskID))/diff.txt"
        components.queryItems = [
            URLQueryItem(name: "path", value: filePath)
        ]
        return components.string ?? "/api/tasks/\(percentEncodedPathSegment(taskID))/diff.txt"
    }

    private func percentEncodedPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func apiURL(_ path: String) -> URL? {
        guard let baseURL = normalizedDaemonURL else {
            return nil
        }

        return URL(string: path, relativeTo: baseURL)
    }

    private func decodePairingPayload(_ value: String) throws -> PhonePairingPayload {
        if let data = value.data(using: .utf8),
           let payload = try? JSONDecoder().decode(PhonePairingPayload.self, from: data) {
            return payload
        }

        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedPayload = components.queryItems?.first(where: { $0.name == "payload" })?.value else {
            throw URLError(.cannotParseResponse)
        }

        if let data = encodedPayload.data(using: .utf8),
           let payload = try? JSONDecoder().decode(PhonePairingPayload.self, from: data) {
            return payload
        }

        guard let data = Self.base64URLDecodedData(encodedPayload) else {
            throw URLError(.cannotParseResponse)
        }

        return try JSONDecoder().decode(PhonePairingPayload.self, from: data)
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }

        return Data(base64Encoded: base64)
    }

    private func maybeAutoConnect(to companion: PhoneDiscoveredCompanion) {
        let lastSuccessfulURL = userDefaults.string(forKey: Self.lastSuccessfulDaemonURLKey)
        let currentHost = normalizedDaemonURL?.host()?.lowercased()
        let isUsingLocalhost = currentHost == "127.0.0.1" || currentHost == "localhost"
        let isUsingBonjourName = currentHost?.hasSuffix(".local") == true

        if lastSuccessfulURL == companion.urlString {
            daemonURLString = companion.urlString
            Task {
                await refreshAll()
            }
            return
        }

        if (isUsingLocalhost || isUsingBonjourName || health == nil) && discoveredCompanions.count <= 1 {
            daemonURLString = companion.urlString
            Task {
                await refreshAll()
            }
        }
    }

    private func scheduleLANScanFallback() {
        guard lanScanTask == nil, !hasResolvedConnection else {
            return
        }

        lanScanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.scanLANFallback()
        }
    }

    private func scanLANFallback() async {
        guard !hasResolvedConnection, !isScanningLAN else {
            lanScanTask = nil
            return
        }

        isScanningLAN = true
        lanScanError = nil
        defer {
            isScanningLAN = false
            lanScanTask = nil
        }

        guard let companion = await lanScanner.scan() else {
            lanScanError = "Couldn't find the Mac automatically. Make sure both devices are on the same Wi-Fi and Local Network access is allowed."
            return
        }

        if !discoveredCompanions.contains(companion) {
            discoveredCompanions.append(companion)
        }

        daemonURLString = companion.urlString
        await refreshAll()
    }

    private func isLoopbackURLString(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host()?.lowercased() else {
            return false
        }

        return host == "127.0.0.1" || host == "localhost"
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        if host == "localhost" ||
            host == "127.0.0.1" ||
            host == "::1" ||
            host.hasSuffix(".local") ||
            host.hasPrefix("10.") ||
            host.hasPrefix("192.168.") ||
            host.hasPrefix("fe80:") {
            return true
        }

        if host.contains(":") && (host.hasPrefix("fc") || host.hasPrefix("fd")) {
            return true
        }

        let addressParts = host.split(separator: ".")
        if addressParts.count == 4,
           addressParts[0] == "172",
           let secondOctet = Int(addressParts[1]),
           (16...31).contains(secondOctet) {
            return true
        }

        return false
    }

    private static func defaultDaemonURLString() -> String {
        if prefersLoopbackDefault {
            return "http://127.0.0.1:4242"
        }

        return ""
    }

    private static var prefersLoopbackDefault: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }
}
