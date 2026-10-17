import Foundation
import CryptoKit
import XCTest
@testable import LocalAudioCore

private actor FixtureModelDownloader: ModelDownloading {
    let contents: [String: Data]
    var requested: [String] = []
    var failingPath: String?
    var corruptPath: String?
    var pausedPath: String?
    var didPause = false

    init(contents: [String: Data], failingPath: String? = nil, corruptPath: String? = nil, pausedPath: String? = nil) {
        self.contents = contents
        self.failingPath = failingPath
        self.corruptPath = corruptPath
        self.pausedPath = pausedPath
    }
    func setFailingPath(_ path: String?) { failingPath = path }
    func download(_ file: ModelManifestFile, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        requested.append(file.path)
        if file.path == pausedPath {
            didPause = true
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        if file.path == failingPath { throw URLError(.notConnectedToInternet) }
        let data = file.path == corruptPath ? Data(repeating: 255, count: Int(file.size)) : contents[file.path]!
        try data.write(to: destination)
        progress(Int64(data.count))
    }
}

private final class ModelFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("stream fixture".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url!.path.contains("failure") ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ModelValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class ModelCompletionProbe { var completed = 0 }

@MainActor
final class ModelInstallerTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-model-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func fixture() -> (ModelManifest, [String: Data]) {
        var paths = ModelManifest.requiredBundles.flatMap { bundle in
            ["coremldata.bin", "model.mil", "weights/weight.bin"].map { bundle + "/" + $0 }
        }
        paths += ["parakeet_vocab.json", "README.md"]
        let contents = Dictionary(uniqueKeysWithValues: paths.map { ($0, Data(("fixture:" + $0).utf8)) })
        let revision = String(repeating: "a", count: 40)
        let repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        let files = paths.map { path in
            let data = contents[path]!
            return ModelManifestFile(path: path,
                url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!,
                size: Int64(data.count), algorithm: .sha256,
                digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return (ModelManifest(schemaVersion: 1, id: "parakeet-v2", repository: repo, revision: revision,
            displayName: "Fixture", license: "CC-BY-4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            attribution: "Synthetic fixture", modelCardURL: URL(string: "https://huggingface.co/")!,
            totalBytes: files.reduce(0) { $0 + $1.size }, files: files), contents)
    }

    private func localFolder(beneath root: URL) throws -> URL {
        let folder = root.appendingPathComponent("external-local", isDirectory: true)
        for bundle in ModelManifest.requiredBundles {
            let directory = folder.appendingPathComponent(bundle)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("parakeet_vocab.json"))
        return folder
    }

    private func installer(_ root: URL, manifest: ModelManifest, downloader: FixtureModelDownloader,
                           validator: @escaping ModelInstaller.Validator = { _ in }) -> ModelInstaller {
        ModelInstaller(storage: root.appendingPathComponent("store"), manifest: manifest,
            downloader: downloader, validator: validator, capacity: { _ in Int64.max })
    }

    func testBundledManifestHasPinnedMetadataAndAll22Assets() throws {
        let manifest = try ModelManifest.bundled()
        XCTAssertEqual(manifest.revision, "ee09c569f73759e6d44c9bd16766f477b2b36d39")
        XCTAssertEqual(manifest.files.count, 22)
        XCTAssertEqual(manifest.totalBytes, 464_414_912)
        XCTAssertTrue(manifest.files.contains { $0.algorithm == .gitBlobSHA1 })
        XCTAssertTrue(manifest.files.contains { $0.algorithm == .sha256 })
    }

    func testPackagedResourcesTakePrecedenceWithoutEvaluatingDevelopmentAccessor() throws {
        let root = try temporary()
        let resourceBundle = root.appendingPathComponent("LocalAudio_LocalAudioCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
        let expected = try ModelManifest.bundled()
        try JSONEncoder().encode(expected).write(to: resourceBundle.appendingPathComponent("parakeet-v2.json"))
        var evaluatedFallback = false
        let loaded = try ModelManifest.bundled(resourcesDirectory: root, fallback: {
            evaluatedFallback = true
            return nil
        })
        XCTAssertEqual(loaded.revision, expected.revision)
        XCTAssertFalse(evaluatedFallback)
    }

    func testBundledHelperFindsSiblingResourcesWithoutDevelopmentAccessor() throws {
        let root = try temporary()
        let contents = root.appendingPathComponent("LocalAudio.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources/LocalAudio_LocalAudioCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let expected = try ModelManifest.bundled()
        try JSONEncoder().encode(expected).write(to: resources.appendingPathComponent("parakeet-v2.json"))
        let helper = contents.appendingPathComponent("Helpers/local-audio-transcriber")
        var evaluatedFallback = false
        let loaded = try ModelManifest.bundled(resourcesDirectory: helper.deletingLastPathComponent(), executableURL: helper, fallback: {
            evaluatedFallback = true
            return nil
        })
        XCTAssertEqual(loaded.revision, expected.revision)
        XCTAssertFalse(evaluatedFallback)
        XCTAssertThrowsError(try ModelManifest.bundled(resourcesDirectory: nil,
            executableURL: contents.appendingPathComponent("Helpers/unrelated-helper"), fallback: { nil }))
    }

    func testRecognizedJointManifestSignatureAndOfflineIntegrityGate() throws {
        let manifest = try ModelManifest.bundled()
        let known = try XCTUnwrap(manifest.files.first { $0.path == "JointDecision.mlmodelc/model.mil" })
        XCTAssertEqual(known.size, 9_722)
        XCTAssertEqual(known.algorithm, .gitBlobSHA1)
        XCTAssertEqual(known.digest, "339c35b303b074de7fe047bb099311a4cc08cf53")
        let root = try temporary()
        let graph = root.appendingPathComponent(known.path)
        XCTAssertThrowsError(try ParakeetCompatibility.validateV2Joint(in: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Download the English model"))
        }
        try FileManager.default.createDirectory(at: graph.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("synthetic recognized graph".utf8)
        try data.write(to: graph)
        let digest = Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
        let fixture = ModelManifestFile(path: known.path, url: graph, size: Int64(data.count), algorithm: .gitBlobSHA1, digest: digest)
        XCTAssertNoThrow(try ParakeetCompatibility.validateV2Joint(in: root, expected: fixture))
        try Data(repeating: 255, count: data.count).write(to: graph)
        XCTAssertThrowsError(try ParakeetCompatibility.validateV2Joint(in: root, expected: fixture))
        XCTAssertEqual(try Data(contentsOf: graph), Data(repeating: 255, count: data.count), "Compatibility failures never repair the selected folder")
    }

    func testUnsafePathsFailBeforeTouchingStorage() {
        for path in ["../escape", "/absolute", "a//b", "a/./b", "a/../b", "a\\b", "a/%2e%2e/b", ""] {
            let file = ModelManifestFile(path: path, url: URL(string: "https://example.invalid/")!, size: 1,
                algorithm: .sha256, digest: String(repeating: "a", count: 64))
            XCTAssertThrowsError(try file.validatePath(), path)
        }
    }

    func testIntegrityChecksGitBlobHeaderAndRejectsCorruption() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("small.txt")
        let data = Data("hello\n".utf8)
        try data.write(to: file)
        let gitDigest = Insecure.SHA1.hash(data: Data("blob 6\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
        let expected = ModelManifestFile(path: "small.txt", url: file, size: 6, algorithm: .gitBlobSHA1, digest: gitDigest)
        XCTAssertNoThrow(try ModelFileIntegrity.verify(file, expected: expected))
        try Data("wrong\n".utf8).write(to: file)
        XCTAssertThrowsError(try ModelFileIntegrity.verify(file, expected: expected))
        try Data("short".utf8).write(to: file)
        XCTAssertThrowsError(try ModelFileIntegrity.verify(file, expected: expected))
    }

    func testInstallActivatesOnlyAfterValidatorAndRestoresOffline() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        let directory = try await worker.install(report: { _ in })
        XCTAssertTrue(directory.path.contains("/installed/parakeet-v2-"))
        let firstCount = await downloader.requested.count
        XCTAssertEqual(firstCount, contents.count)
        let restored = try await worker.restore(report: { _ in })
        XCTAssertEqual(restored, directory)
        let finalCount = await downloader.requested.count
        XCTAssertEqual(finalCount, contents.count, "Restore must not contact the downloader")
    }

    func testHashFailureKeepsExistingSelectedModelAndNeverActivatesBadPack() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents, corruptPath: manifest.files[1].path)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        let local = try localFolder(beneath: root)
        _ = try await worker.useLocalFolder(local)
        let state = root.appendingPathComponent("store/model-selection.json")
        let priorState = try Data(contentsOf: state)
        do { _ = try await worker.install(report: { _ in }); XCTFail("Corrupt download must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: state), priorState)
        let restored = try await worker.restore(report: { _ in })
        XCTAssertEqual(restored, local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/installed").path))
    }

    func testOfflineValidatorFailureDoesNotReplacePreviousSelection() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let oldWorker = installer(root, manifest: manifest, downloader: downloader)
        let local = try localFolder(beneath: root)
        _ = try await oldWorker.useLocalFolder(local)
        let rejecting = installer(root, manifest: manifest, downloader: downloader, validator: { _ in
            throw ModelSetupError.message("Fixture Core ML loader rejected this pack")
        })
        do { _ = try await rejecting.install(report: { _ in }); XCTFail("Validator must gate activation") } catch {}
        let restored = try await oldWorker.restore(report: { _ in })
        XCTAssertEqual(restored, local)
    }

    func testRetryReusesOnlyVerifiedFiles() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents, failingPath: manifest.files[2].path)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        do { _ = try await worker.install(report: { _ in }); XCTFail("Offline fixture must fail") } catch {}
        let failedRequests = await downloader.requested
        XCTAssertEqual(failedRequests.filter { $0 == manifest.files[2].path }.count, 3)
        await downloader.setFailingPath(nil)
        _ = try await worker.install(report: { _ in })
        let requested = await downloader.requested
        XCTAssertEqual(requested.filter { $0 == manifest.files[0].path }.count, 1)
        XCTAssertEqual(requested.filter { $0 == manifest.files[1].path }.count, 1)
    }

    func testDiskPreflightRefusesBeforeAnyDownload() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let worker = ModelInstaller(storage: root.appendingPathComponent("store"), manifest: manifest,
            downloader: downloader, validator: { _ in }, capacity: { _ in 0 })
        do { _ = try await worker.install(report: { _ in }); XCTFail("Insufficient capacity must fail") } catch {}
        let requests = await downloader.requested
        XCTAssertTrue(requests.isEmpty)
    }

    func testManagerCancelPreservesReadyLocalSelection() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents, pausedPath: manifest.files[1].path)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        let manager = ModelManager(installer: worker)
        let local = try localFolder(beneath: root)
        try await manager.useLocalFolder(local)
        let operation = Task { await manager.install() }
        for _ in 0..<200 {
            if await downloader.didPause { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let paused = await downloader.didPause
        XCTAssertTrue(paused)
        manager.cancel()
        await operation.value
        XCTAssertFalse(manager.isBusy)
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.modelDirectory, local)
        XCTAssertTrue(manager.statusText.contains("cancelled"))
        let replacement = FixtureModelDownloader(contents: contents)
        _ = try await installer(root, manifest: manifest, downloader: replacement).install(report: { _ in })
        let replacementRequests = await replacement.requested
        XCTAssertFalse(replacementRequests.contains(manifest.files[0].path), "Cancelled setup retains already verified files")
    }

    func testMissingLocalFolderFailsWithoutNetworkOrSelection() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        do { _ = try await worker.useLocalFolder(root.appendingPathComponent("missing")); XCTFail("Missing local assets must fail") } catch {}
        let requests = await downloader.requested
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/model-selection.json").path))
    }

    func testURLSessionDownloadStreamsToFileWithoutRealNetwork() async throws {
        let root = try temporary()
        let downloader = StreamingModelDownloader(makeSession: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ModelFixtureURLProtocol.self]
            return URLSession(configuration: configuration)
        })
        let file = ModelManifestFile(path: "fixture", url: URL(string: "https://example.invalid/fixture")!,
            size: Int64(ModelFixtureURLProtocol.body.count), algorithm: .sha256, digest: "")
        let destination = root.appendingPathComponent("downloaded")
        try await downloader.download(file, to: destination, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), ModelFixtureURLProtocol.body)
        let failure = ModelManifestFile(path: "failure", url: URL(string: "https://example.invalid/failure")!,
            size: file.size, algorithm: .sha256, digest: "")
        do {
            try await downloader.download(failure, to: root.appendingPathComponent("bad"), progress: { _ in })
            XCTFail("HTTP error must not become a model file")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }

    func testManagedRestoreRejectsChangedBytesWithoutNetwork() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        let installed = try await worker.install(report: { _ in })
        let changed = installed.appendingPathComponent(manifest.files[0].path)
        let original = contents[manifest.files[0].path]!
        try Data(repeating: 255, count: original.count).write(to: changed)
        do { _ = try await worker.restore(report: { _ in }); XCTFail("Altered installed bytes must fail offline verification") } catch {}
        let requests = await downloader.requested
        XCTAssertEqual(requests.count, manifest.files.count)
    }

    func testStagingSymlinkIsRejectedWithoutChangingTarget() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let store = root.appendingPathComponent("store")
        let stage = store.appendingPathComponent("staging-" + manifest.revision)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try manifest.revision.write(to: stage.appendingPathComponent(".localaudio-staging"), atomically: true, encoding: .utf8)
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let preserved = external.appendingPathComponent("coremldata.bin")
        try Data("keep".utf8).write(to: preserved)
        try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("Preprocessor.mlmodelc"), withDestinationURL: external)
        let worker = installer(root, manifest: manifest, downloader: downloader)
        do { _ = try await worker.install(report: { _ in }); XCTFail("Injected symlink must fail") } catch {}
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "keep")
        let requests = await downloader.requested
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancelAndWaitWaitsForValidatorAndPerformCleanupForEveryWaiter() async throws {
        let root = try temporary()
        let (manifest, contents) = fixture()
        let downloader = FixtureModelDownloader(contents: contents)
        let gate = ModelValidationGate()
        let worker = installer(root, manifest: manifest, downloader: downloader, validator: { _ in
            await gate.wait()
            try Task.checkCancellation()
        })
        let manager = ModelManager(installer: worker)
        let local = try localFolder(beneath: root)
        let selection = Task { try? await manager.useLocalFolder(local) }
        for _ in 0..<200 {
            if await gate.hasStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await gate.hasStarted
        XCTAssertTrue(started)
        let probe = ModelCompletionProbe()
        let first = Task { await manager.cancelAndWait(); probe.completed += 1 }
        let second = Task { await manager.cancelAndWait(); probe.completed += 1 }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(manager.isBusy)
        XCTAssertEqual(probe.completed, 0, "Shutdown must not report completion while validation is still active")
        await manager.install()
        let requestsWhileBlocked = await downloader.requested
        XCTAssertTrue(requestsWhileBlocked.isEmpty, "A second operation must not overlap cancelled validation")
        await gate.release()
        await first.value
        await second.value
        await selection.value
        XCTAssertEqual(probe.completed, 2)
        XCTAssertFalse(manager.isBusy)
        XCTAssertFalse(manager.isReady)
        XCTAssertNil(manager.progress)
        XCTAssertTrue(manager.statusText.contains("cancelled"))
        await manager.cancelAndWait() // Idle shutdown must also complete.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/model-selection.json").path))
    }
}
