import Foundation
import Testing
@testable import anywhere_bridge

struct CompanionStoreTests {

    @Test
    func ancestorChainWalksUpToRoot() {
        let leaf = URL(fileURLWithPath: "/tmp/anywhere-bridge/nested/deeper", isDirectory: true)

        let chain = CompanionStore.ancestorChain(of: leaf)

        #expect(chain.prefix(4).map(\.path) == [
            "/tmp/anywhere-bridge/nested/deeper",
            "/tmp/anywhere-bridge/nested",
            "/tmp/anywhere-bridge",
            "/tmp"
        ])
        #expect(chain.last?.path == "/")
    }

    @Test
    func ancestorChainStopsAtRootForBundleLikePaths() {
        let bundlePath = URL(
            fileURLWithPath: "/Applications/Test.app/Contents/MacOS",
            isDirectory: true
        )

        let chain = CompanionStore.ancestorChain(of: bundlePath)

        #expect(chain.map(\.path) == [
            "/Applications/Test.app/Contents/MacOS",
            "/Applications/Test.app/Contents",
            "/Applications/Test.app",
            "/Applications",
            "/"
        ])
    }

    @Test
    func ancestorChainForRootContainsOnlyRoot() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)

        let chain = CompanionStore.ancestorChain(of: root)

        #expect(chain.map(\.path) == ["/"])
    }

    @Test
    func discoverRepoRootFindsMatchingAncestor() throws {
        let tempDirectory = try TemporaryDirectory()
        let repoRoot = tempDirectory.url.appending(path: "workspace", directoryHint: .isDirectory)
        let nestedFolder = repoRoot.appending(path: "apps/desktop-ui/anywhere-bridge", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        _ = try tempDirectory.createFile(relativePath: "workspace/package.json")
        _ = try tempDirectory.createFile(relativePath: "workspace/apps/desktop-agent-service/src/index.ts")

        let discovered = CompanionStore.discoverRepoRoot(in: [nestedFolder])

        #expect(discovered == repoRoot.path)
    }

    @Test
    func discoverRepoRootFindsMatchingAncestorFromBundleLikeLaunchPath() throws {
        let tempDirectory = try TemporaryDirectory()
        let repoRoot = tempDirectory.url.appending(path: "workspace", directoryHint: .isDirectory)
        let bundlePath = repoRoot.appending(
            path: "dist/Anywhere Bridge.app/Contents/MacOS",
            directoryHint: .isDirectory
        )

        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        _ = try tempDirectory.createFile(relativePath: "workspace/package.json")
        _ = try tempDirectory.createFile(relativePath: "workspace/apps/desktop-agent-service/src/index.ts")

        let discovered = CompanionStore.discoverRepoRoot(in: [bundlePath])

        #expect(discovered == repoRoot.path)
    }

    @Test
    func discoverNodeBinaryReturnsFirstExecutableCandidate() throws {
        let tempDirectory = try TemporaryDirectory()
        let executable = try tempDirectory.createExecutable(relativePath: "bin/node")
        let fallback = tempDirectory.url.appending(path: "bin/other-node")

        let discovered = CompanionStore.discoverNodeBinary(
            candidates: [
                tempDirectory.url.appending(path: "bin/missing-node").path,
                executable.path,
                fallback.path
            ]
        )

        #expect(discovered == executable.path)
    }

    @Test
    func daemonScriptURLReturnsScriptWhenPresent() throws {
        let tempDirectory = try TemporaryDirectory()
        let repoRoot = tempDirectory.url.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let script = try tempDirectory.createFile(relativePath: "repo/apps/desktop-agent-service/src/index.ts")

        let resolved = CompanionStore.daemonScriptURL(repoRootURL: repoRoot)

        #expect(resolved?.path == script.path)
    }

    @Test
    func daemonLaunchUsesExplicitExecutableWhenAvailable() throws {
        let tempDirectory = try TemporaryDirectory()
        let executable = try tempDirectory.createExecutable(relativePath: "bin/node")
        let script = try tempDirectory.createFile(relativePath: "repo/apps/desktop-agent-service/src/index.ts")

        let launch = CompanionStore.daemonLaunch(
            nodeBinaryPath: executable.path,
            daemonScriptURL: script
        )

        #expect(launch.executableURL.path == executable.path)
        #expect(launch.arguments == ["--import", "tsx", script.path])
    }

    @Test
    func daemonLaunchFallsBackToEnvWhenBinaryIsMissing() throws {
        let tempDirectory = try TemporaryDirectory()
        let script = try tempDirectory.createFile(relativePath: "repo/apps/desktop-agent-service/src/index.ts")

        let launch = CompanionStore.daemonLaunch(
            nodeBinaryPath: tempDirectory.url.appending(path: "bin/missing-node").path,
            daemonScriptURL: script
        )

        #expect(launch.executableURL.path == "/usr/bin/env")
        #expect(launch.arguments == ["node", "--import", "tsx", script.path])
    }

    @MainActor
    @Test
    func storeBuildsPreviewFromInjectedConfiguration() throws {
        let tempDirectory = try TemporaryDirectory()
        let executable = try tempDirectory.createExecutable(relativePath: "bin/node")
        let repoRoot = tempDirectory.url.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let script = try tempDirectory.createFile(relativePath: "repo/apps/desktop-agent-service/src/index.ts")

        let store = CompanionStore(
            configuration: (
                repoRootPath: repoRoot.path,
                nodeBinaryPath: executable.path
            )
        )

        #expect(store.daemonScriptLocation()?.path == script.path)
        #expect(store.launchPreview().executableURL.path == executable.path)
        #expect(store.launchCommandPreview == "\(executable.path) --import tsx \(script.path)")
        #expect(store.localBridgeURL?.absoluteString == "http://127.0.0.1:4242")
    }

    @MainActor
    @Test
    func launchDaemonMarksStoreAsMisconfiguredWhenScriptIsMissing() {
        let store = CompanionStore(
            configuration: (
                repoRootPath: "/tmp/does-not-exist",
                nodeBinaryPath: "/usr/bin/env"
            )
        )

        store.launchDaemon()

        #expect(store.daemonState == .misconfigured)
        #expect(store.lastError == "Select the repo root that contains apps/desktop-agent-service/src/index.ts.")
    }

    @MainActor
    @Test
    func stopDaemonMovesStateOfflineAndAddsEvent() {
        let store = CompanionStore(
            configuration: (
                repoRootPath: "",
                nodeBinaryPath: "/usr/bin/env"
            )
        )
        store.daemonState = .online
        store.daemonEvents = ["Earlier event"]

        store.stopDaemon()

        #expect(store.daemonState == .offline)
        #expect(store.daemonEvents.first == "Stop requested for desktop daemon.")
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func createFile(relativePath: String, contents: String = "") throws -> URL {
        let fileURL = url.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    func createExecutable(relativePath: String, contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let fileURL = try createFile(relativePath: relativePath, contents: contents)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }
}
