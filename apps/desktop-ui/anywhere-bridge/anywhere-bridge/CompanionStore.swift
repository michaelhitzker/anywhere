//
//  CompanionStore.swift
//  anywhere-bridge
//
//  Created by Codex on 10.04.26.
//

import AppKit
import Darwin
import Foundation
import Observation

struct DaemonHealth: Decodable {
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

struct T3IntegrationSettings: Codable {
    var companionRepoPath: String
    var baseDir: String
    var host: String
    var port: Int
    var autoStartServer: Bool

    static let empty = T3IntegrationSettings(
        companionRepoPath: "",
        baseDir: "",
        host: "127.0.0.1",
        port: 3773,
        autoStartServer: true
    )
}

struct CompanionSettings: Codable {
    let t3: T3IntegrationSettings
}

struct CompanionPairingTicket: Decodable {
    let id: String
    let createdAt: String
    let expiresAt: String
    let credentialExpiresAt: String
    let qrPayload: String
}

struct CompanionPairingClient: Decodable, Identifiable {
    let id: String
    let name: String
    let createdAt: String
    let expiresAt: String
    let lastSeenAt: String?
    let isExpired: Bool
}

private struct APIErrorResponse: Decodable {
    let error: String
}

private struct PairingStatusResponse: Decodable {
    let credentialTtlDays: Int
    let ticketTtlMinutes: Int
    let activeTicket: CompanionPairingTicket?
    let clients: [CompanionPairingClient]
}

private struct PairingTicketResponse: Decodable {
    let ticket: CompanionPairingTicket
}

private struct PairingTicketPayload: Encodable {
    let desktopName: String
    let apiBaseUrl: String?
    let relayUrl: String?
}

enum DaemonConnectionState: String {
    case offline
    case starting
    case online
    case misconfigured
}

@MainActor
@Observable
final class CompanionStore {
    private let daemonPort = 4242
    private let userDefaults = UserDefaults.standard
    private var process: Process?
    private var processOutputHandles: [FileHandle] = []
    private var monitorTask: Task<Void, Never>?

    var daemonState: DaemonConnectionState = .offline
    var daemonHealth: DaemonHealth?
    var daemonEvents: [String] = []
    var lastError: String?
    var repoRootPath: String
    var nodeBinaryPath: String
    var t3Settings: T3IntegrationSettings = .empty
    var launchCommandPreview = ""
    var localBridgeURL: URL?
    var mobileBridgeURL: URL?
    var settingsMessage: String?
    var settingsError: String?
    var existingDaemonPID: Int32?
    var existingDaemonCommand: String?
    var pairingTicket: CompanionPairingTicket?
    var pairedClients: [CompanionPairingClient] = []
    var pairingMessage: String?
    var pairingError: String?
    var isCreatingPairingTicket = false

    convenience init() {
        let defaults = Self.defaultConfiguration()
        self.init(configuration: defaults)
    }

    init(configuration: (repoRootPath: String, nodeBinaryPath: String)) {
        repoRootPath = configuration.repoRootPath
        nodeBinaryPath = configuration.nodeBinaryPath
        rebuildLaunchCommandPreview()
        refreshBridgeURLs()
    }

    func launchPreview() -> (executableURL: URL, arguments: [String]) {
        daemonLaunch()
    }

    func daemonScriptLocation() -> URL? {
        daemonScriptURL
    }

    func refreshURLsForTesting() {
        refreshBridgeURLs()
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            await refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refreshAll()
            }
        }
    }

    func launchDaemon() {
        guard process == nil || process?.isRunning == false else {
            daemonEvents.insert("Daemon is already running.", at: 0)
            return
        }

        guard daemonScriptURL != nil else {
            daemonState = .misconfigured
            lastError = "Select the repo root that contains apps/desktop-agent-service/src/index.ts."
            return
        }

        let launch = daemonLaunch()
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = repoRootURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        attachOutputReader(outputPipe.fileHandleForReading, prefix: "stdout")
        attachOutputReader(errorPipe.fileHandleForReading, prefix: "stderr")

        process.terminationHandler = { [store = self] finishedProcess in
            Task { @MainActor in
                store.daemonEvents.insert("Daemon exited with status \(finishedProcess.terminationStatus).", at: 0)
                store.process = nil
                if finishedProcess.terminationStatus == 0 {
                    store.daemonState = .offline
                } else {
                    await store.refreshAll()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            daemonState = .starting
            lastError = nil
            daemonEvents.insert("Launching desktop daemon.", at: 0)
        } catch {
            self.process = nil
            daemonState = .misconfigured
            lastError = error.localizedDescription
        }
    }

    func stopDaemon() {
        process?.terminate()
        process = nil
        daemonState = .offline
        daemonEvents.insert("Stop requested for desktop daemon.", at: 0)
    }

    func killExistingDaemon() {
        guard let pid = existingDaemonPID else { return }

        if kill(pid, SIGTERM) == 0 {
            daemonEvents.insert("Requested stop for existing daemon process \(pid).", at: 0)
            existingDaemonPID = nil
            existingDaemonCommand = nil
            lastError = nil
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await refreshAll()
            }
        } else {
            lastError = "Could not stop daemon process \(pid)."
        }
    }

    func chooseRepoRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the Anywhere repo root."

        if panel.runModal() == .OK, let url = panel.url {
            repoRootPath = url.path
            userDefaults.set(url.path, forKey: Self.repoRootKey)
            rebuildLaunchCommandPreview()
        }
    }

    func chooseT3CompanionDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the T3 companion repository root."

        if panel.runModal() == .OK, let url = panel.url {
            t3Settings.companionRepoPath = url.path
        }
    }

    func chooseT3BaseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the shared T3 state directory."

        if panel.runModal() == .OK, let url = panel.url {
            t3Settings.baseDir = url.path
        }
    }

    func persistNodePath() {
        userDefaults.set(nodeBinaryPath, forKey: Self.nodeBinaryKey)
        rebuildLaunchCommandPreview()
    }

    func saveT3Settings() async {
        settingsMessage = nil
        settingsError = nil

        do {
            let response: CompanionSettings = try await send("/api/settings", method: "POST", body: CompanionSettings(t3: t3Settings))
            t3Settings = response.t3
            settingsMessage = "Saved T3 connection settings."
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func openLocalBridge() {
        guard let localBridgeURL else { return }
        NSWorkspace.shared.open(localBridgeURL.appending(path: "api/health"))
    }

    func openMobileAddress() {
        guard let mobileBridgeURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mobileBridgeURL.absoluteString, forType: .string)
        NSWorkspace.shared.open(mobileBridgeURL.appending(path: "api/health"))
    }

    func refreshNow() {
        Task {
            await refreshAll()
        }
    }

    func createPairingTicket() {
        Task {
            await requestPairingTicket()
        }
    }

    func revokePairingClient(_ client: CompanionPairingClient) {
        Task {
            await revokePairingClient(client.id)
        }
    }

    private func refreshAll() async {
        refreshBridgeURLs()
        updateExistingDaemonInfo()

        do {
            let health: DaemonHealth = try await fetch("/api/health")
            if let compatibilityError = compatibilityError(for: health) {
                daemonHealth = health
                daemonState = .misconfigured
                lastError = compatibilityError
                return
            }

            let settings: CompanionSettings = try await fetch("/api/settings")
            let pairingStatus: PairingStatusResponse = try await fetch("/api/pairing/status")

            daemonHealth = health
            t3Settings = settings.t3
            pairingTicket = pairingStatus.activeTicket
            pairedClients = pairingStatus.clients
            daemonState = .online
            lastError = nil
        } catch {
            daemonHealth = nil
            pairingTicket = nil
            pairedClients = []
            updateExistingDaemonInfo()
            if process?.isRunning == true {
                daemonState = .starting
            } else if daemonScriptURL == nil {
                daemonState = .misconfigured
            } else if existingDaemonPID != nil {
                daemonState = .misconfigured
                lastError = "Another daemon is already using port \(daemonPort). Stop it or use the kill button below."
            } else {
                daemonState = .offline
                lastError = error.localizedDescription
            }
        }
    }

    private func requestPairingTicket() async {
        isCreatingPairingTicket = true
        pairingMessage = nil
        pairingError = nil

        do {
            let response: PairingTicketResponse = try await send(
                "/api/pairing/tickets",
                method: "POST",
                body: PairingTicketPayload(
                    desktopName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                    apiBaseUrl: mobileBridgeURL?.absoluteString,
                    relayUrl: nil
                )
            )
            pairingTicket = response.ticket
            pairingMessage = "Pairing QR ready. Paired phones stay trusted for 30 days."
            let status: PairingStatusResponse = try await fetch("/api/pairing/status")
            pairedClients = status.clients
        } catch {
            pairingError = error.localizedDescription
        }

        isCreatingPairingTicket = false
    }

    private func revokePairingClient(_ clientID: String) async {
        pairingMessage = nil
        pairingError = nil

        do {
            let status: PairingStatusResponse = try await send(
                "/api/pairing/clients/\(clientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clientID)",
                method: "DELETE"
            )
            pairedClients = status.clients
            pairingTicket = status.activeTicket
            pairingMessage = "Removed paired phone."
        } catch {
            pairingError = error.localizedDescription
        }
    }

    private func compatibilityError(for health: DaemonHealth) -> String? {
        guard let providerID = health.provider?.id else {
            return "The daemon on port 4242 looks older than this app build. Stop the existing daemon and launch it again from Anywhere Bridge."
        }

        if providerID != "t3code" {
            return "An older daemon is already running on port 4242. Stop that existing process and relaunch Anywhere Bridge so it can start the T3-backed daemon."
        }

        return nil
    }

    private func updateExistingDaemonInfo() {
        let owner = Self.detectListeningProcess(on: daemonPort)
        existingDaemonPID = owner?.pid
        existingDaemonCommand = owner?.command
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: "http://127.0.0.1:\(daemonPort)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return try decodeResponse(data: data, response: response)
    }

    private func send<Response: Decodable>(
        _ path: String,
        method: String
    ) async throws -> Response {
        let url = URL(string: "http://127.0.0.1:\(daemonPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func send<Request: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Request
    ) async throws -> Response {
        let url = URL(string: "http://127.0.0.1:\(daemonPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if (200..<300).contains(http.statusCode) {
            return try JSONDecoder().decode(T.self, from: data)
        }

        if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            throw NSError(
                domain: "CompanionStore.API",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: apiError.error]
            )
        }

        throw URLError(.badServerResponse)
    }

    private func attachOutputReader(_ handle: FileHandle, prefix: String) {
        processOutputHandles.append(handle)
        handle.readabilityHandler = { [store = self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else {
                return
            }
            let lines = output
                .split(whereSeparator: \.isNewline)
                .map { "[\(prefix)] \($0)" }

            Task { @MainActor in
                store.daemonEvents.insert(contentsOf: lines.reversed(), at: 0)
                store.daemonEvents = Array(store.daemonEvents.prefix(16))
            }
        }
    }

    private func rebuildLaunchCommandPreview() {
        let launch = daemonLaunch()
        launchCommandPreview = ([launch.executableURL.path] + launch.arguments).joined(separator: " ")
    }

    private func refreshBridgeURLs() {
        localBridgeURL = URL(string: "http://127.0.0.1:\(daemonPort)")
        if let localAddress = Self.firstLANAddress() {
            mobileBridgeURL = URL(string: "http://\(localAddress):\(daemonPort)")
        } else {
            mobileBridgeURL = nil
        }
    }

    private var repoRootURL: URL? {
        guard !repoRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: repoRootPath, isDirectory: true)
    }

    private var daemonScriptURL: URL? {
        Self.daemonScriptURL(repoRootURL: repoRootURL)
    }

    private func daemonLaunch() -> (executableURL: URL, arguments: [String]) {
        Self.daemonLaunch(nodeBinaryPath: nodeBinaryPath, daemonScriptURL: daemonScriptURL)
    }

    private static let repoRootKey = "companion.repoRootPath"
    private static let nodeBinaryKey = "companion.nodeBinaryPath"

    private static func defaultConfiguration() -> (repoRootPath: String, nodeBinaryPath: String) {
        let defaults = UserDefaults.standard
        let repoRootPath = defaults.string(forKey: repoRootKey) ?? discoverRepoRoot() ?? ""
        let nodeBinaryPath = defaults.string(forKey: nodeBinaryKey) ?? discoverNodeBinary()
        return (repoRootPath, nodeBinaryPath)
    }

    nonisolated private static func discoverRepoRoot() -> String? {
        discoverRepoRoot(
            in: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                Bundle.main.bundleURL,
                URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            ]
        )
    }

    nonisolated static func discoverRepoRoot(in candidates: [URL], fileManager: FileManager = .default) -> String? {
        for base in candidates {
            for directory in ancestorChain(of: base) {
                let script = directory.appending(path: "apps/desktop-agent-service/src/index.ts")
                let package = directory.appending(path: "package.json")
                if fileManager.fileExists(atPath: script.path) &&
                    fileManager.fileExists(atPath: package.path) {
                    return directory.path
                }
            }
        }

        return nil
    }

    nonisolated static func ancestorChain(of url: URL) -> [URL] {
        var chain: [URL] = []
        var currentPath = url.standardizedFileURL.path

        while true {
            chain.append(URL(fileURLWithPath: currentPath, isDirectory: true))

            if currentPath == "/" {
                break
            }

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            let normalizedParentPath = parentPath.isEmpty ? "/" : parentPath
            if normalizedParentPath == currentPath {
                break
            }

            currentPath = normalizedParentPath
        }

        return chain
    }

    nonisolated private static func discoverNodeBinary() -> String {
        discoverNodeBinary(
            candidates: [
                "/opt/homebrew/bin/node",
                "/usr/local/bin/node",
                "/usr/bin/node"
            ]
        )
    }

    nonisolated static func discoverNodeBinary(candidates: [String], fileManager: FileManager = .default) -> String {
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        return "/usr/bin/env"
    }

    nonisolated static func daemonScriptURL(repoRootURL: URL?, fileManager: FileManager = .default) -> URL? {
        guard let repoRootURL else { return nil }
        let url = repoRootURL.appending(path: "apps/desktop-agent-service/src/index.ts")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func daemonLaunch(
        nodeBinaryPath: String,
        daemonScriptURL: URL?,
        fileManager: FileManager = .default
    ) -> (executableURL: URL, arguments: [String]) {
        if nodeBinaryPath == "/usr/bin/env" {
            return (
                URL(fileURLWithPath: "/usr/bin/env"),
                ["node", "--import", "tsx"] + (daemonScriptURL.map { [$0.path] } ?? [])
            )
        }

        if fileManager.isExecutableFile(atPath: nodeBinaryPath) {
            return (
                URL(fileURLWithPath: nodeBinaryPath),
                ["--import", "tsx"] + (daemonScriptURL.map { [$0.path] } ?? [])
            )
        }

        return (
            URL(fileURLWithPath: "/usr/bin/env"),
            ["node", "--import", "tsx"] + (daemonScriptURL.map { [$0.path] } ?? [])
        )
    }

    nonisolated static func detectListeningProcess(
        on port: Int,
        processInfo: ProcessInfo = .processInfo
    ) -> (pid: Int32, command: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let rawOutput = String(data: data, encoding: .utf8) else {
            return nil
        }

        var pid: Int32?
        var command: String?

        for line in rawOutput.split(whereSeparator: \.isNewline) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                pid = Int32(value)
            case "c":
                command = value
            default:
                continue
            }
        }

        guard let pid else {
            return nil
        }

        let currentPID = Int32(processInfo.processIdentifier)
        guard pid != currentPID else {
            return nil
        }

        return (pid, command ?? "unknown")
    }

    private static func firstLANAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            let family = pointer.pointee.ifa_addr.pointee.sa_family

            guard family == UInt8(AF_INET) else { continue }
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                pointer.pointee.ifa_addr,
                socklen_t(pointer.pointee.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                address = String(cString: host)
                break
            }
        }

        return address
    }
}
