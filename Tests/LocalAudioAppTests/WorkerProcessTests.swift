import XCTest
@testable import LocalAudioApp

@MainActor
final class WorkerProcessTests: XCTestCase {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-worker-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSuccessfulChildRemovesTemporaryLog() async throws {
        let logs = try scratch()
        try await WorkerProcess().run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], logs: logs)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    func testTaskCancellationStopsChildAndCleansUp() async throws {
        let logs = try scratch(), worker = WorkerProcess()
        let start = Date()
        let task = Task { try await worker.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], logs: logs) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { try await task.value; XCTFail("Cancelled child reported success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    func testTimeoutStopsChildAndReportsFailure() async throws {
        let logs = try scratch()
        do {
            try await WorkerProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], logs: logs, timeout: 0.05)
            XCTFail("Timed out child reported success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("took too long")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    func testCancellationBeforeStartCannotLaunchChild() async throws {
        let logs = try scratch(), worker = WorkerProcess()
        worker.cancel()
        do {
            try await worker.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], logs: logs)
            XCTFail("Pre-cancelled worker launched")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    func testMissingHelperIsActionableAndDoesNotCreateLog() async throws {
        let logs = try scratch()
        do {
            try await WorkerProcess().run(executable: logs.appendingPathComponent("missing"), arguments: [], logs: logs)
            XCTFail("Missing helper accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("helper is missing")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    func testPrivateTemporaryAudioIsRemovedAfterSuccessfulChild() async throws {
        let logs = try scratch()
        let script = "import os, pathlib, stat; p=pathlib.Path(os.environ['TMPDIR']); assert stat.S_IMODE(p.stat().st_mode)==0o700; (p/'decoded.raw').write_bytes(b'generated derivative')"
        try await WorkerProcess().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], logs: logs)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    func testCancellationRemovesAChildsAbandonedDecodedAudio() async throws {
        let logs = try scratch(), worker = WorkerProcess()
        let script = "import os, pathlib, time; (pathlib.Path(os.environ['TMPDIR'])/'decoded.raw').write_bytes(b'generated derivative'); time.sleep(20)"
        let task = Task { try await worker.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], logs: logs) }
        var derivative: URL?
        for _ in 0..<100 {
            let folders = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
            derivative = folders.map { $0.appendingPathComponent("decoded.raw") }.first { FileManager.default.fileExists(atPath: $0.path) }
            if derivative != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(derivative, "The child must create a derivative before the cancellation test.")
        worker.cancel()
        do { try await task.value; XCTFail("Cancelled child reported success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }
}
