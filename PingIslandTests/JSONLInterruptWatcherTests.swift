import Foundation
import XCTest
@testable import Ping_Island

final class JSONLInterruptWatcherTests: XCTestCase {
    func testResolveFallbackFilePathPrefersCodexRolloutWhenPresent() throws {
        let sessionId = "watcher-codex-fallback-\(UUID().uuidString)"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-home-\(UUID().uuidString)", isDirectory: true)
        let sessionsDirectory = home.appendingPathComponent(".codex/sessions/2099/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rolloutURL = sessionsDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try "{}\n".write(to: rolloutURL, atomically: true, encoding: .utf8)

        let resolved = JSONLInterruptWatcher.resolveFallbackFilePath(
            sessionId: sessionId,
            cwd: "/tmp/synthetic-project",
            homeDirectory: home
        )
        XCTAssertEqual(
            URL(fileURLWithPath: resolved).resolvingSymlinksInPath(),
            rolloutURL.resolvingSymlinksInPath()
        )
    }

    func testCodexLifecycleAndToolRecordsRequireImmediateSync() {
        for event in ["task_started", "task_complete", "turn_aborted", "context_compacted"] {
            XCTAssertTrue(JSONLInterruptWatcher.requiresImmediateSessionSync(
                in: #"{"type":"event_msg","payload":{"type":"\#(event)"}}"#
            ))
        }
        for item in ["function_call", "function_call_output"] {
            XCTAssertTrue(JSONLInterruptWatcher.requiresImmediateSessionSync(
                in: #"{"type":"response_item","payload":{"type":"\#(item)"}}"#
            ))
        }
        XCTAssertFalse(JSONLInterruptWatcher.requiresImmediateSessionSync(
            in: #"{"type":"response_item","payload":{"type":"message","text":"task_started"}}"#
        ))
        XCTAssertFalse(JSONLInterruptWatcher.requiresImmediateSessionSync(
            in: #"{"type":"event_msg","payload":{"type":"agent_message","text":"function_call"}}"#
        ))
        XCTAssertFalse(JSONLInterruptWatcher.requiresImmediateSessionSync(in: #"{"type":"task_started"}"#))
    }

    func testSplitJSONLWriteBuffersUntilNewlineIncludingSplitUTF8() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try Data().write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? writer.close(); try? reader.close() }
        let watcher = JSONLInterruptWatcher(sessionId: UUID().uuidString, cwd: directory.path, explicitFilePath: file.path)
        let record = Data(#"{"type":"event_msg","payload":{"type":"task_started","text":"café"}}"#.utf8)
        let split = try XCTUnwrap(record.firstIndex(of: 0xC3)) + 1

        try writer.write(contentsOf: record[..<split])
        try writer.synchronize()
        XCTAssertTrue(watcher.completedLines(from: try XCTUnwrap(reader.readToEnd())).isEmpty)
        try writer.write(contentsOf: record[split...])
        try writer.synchronize()
        XCTAssertTrue(watcher.completedLines(from: try XCTUnwrap(reader.readToEnd())).isEmpty)
        try writer.write(contentsOf: Data([0x0A]))
        try writer.synchronize()
        let completed = watcher.completedLines(from: try XCTUnwrap(reader.readToEnd()))
        XCTAssertEqual(completed, [String(decoding: record, as: UTF8.self)])
        XCTAssertTrue(JSONLInterruptWatcher.requiresImmediateSessionSync(in: completed.joined(separator: "\n")))
        XCTAssertTrue(watcher.completedLines(from: Data()).isEmpty, "A completed line is delivered only once")
    }

    func testFirstAttachmentRequestsImmediateSyncForAnExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        let attached = expectation(description: "Existing transcript requests an initial immediate sync")
        let delegate = AttachmentDelegate(expectation: attached)
        let watcher = JSONLInterruptWatcher(sessionId: UUID().uuidString, cwd: directory.path, explicitFilePath: file.path)
        watcher.delegate = delegate
        watcher.start()
        await fulfillment(of: [attached], timeout: 2)
        watcher.stop()
    }

    func testRetryDelayUsesExponentialBackoffWithCap() {
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 0), .milliseconds(250))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 1), .milliseconds(500))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 2), .milliseconds(1_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 3), .milliseconds(2_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 4), .milliseconds(4_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 5), .milliseconds(5_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 99), .milliseconds(5_000))
    }
}

private final class AttachmentDelegate: JSONLInterruptWatcherDelegate {
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func didDetectInterrupt(sessionId: String) {
        XCTFail("Initial attachment is not an interrupt")
    }

    func didObserveFileChange(sessionId: String, requiresImmediateSync: Bool) {
        XCTAssertTrue(requiresImmediateSync)
        expectation.fulfill()
    }
}
