//
//  JSONLInterruptWatcher.swift
//  PingIsland
//
//  Watches JSONL files for transcript changes and interrupts in real-time
//  Uses file system events to refresh sessions without waiting for polling
//

import Foundation
import os.log

/// Logger for interrupt watcher
private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Interrupt")

protocol JSONLInterruptWatcherDelegate: AnyObject {
    func didDetectInterrupt(sessionId: String)
    func didObserveFileChange(sessionId: String, requiresImmediateSync: Bool)
}

/// Watches a session's JSONL file for interrupt patterns in real-time
/// Uses DispatchSource for immediate detection when new lines are written
class JSONLInterruptWatcher {
    private static let initialRetryDelayMs = 250
    private static let maxRetryDelayMs = 5_000

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var retryWorkItem: DispatchWorkItem?
    private var lastOffset: UInt64 = 0
    private var pendingLineFragment = Data()
    private var hasAttached = false
    private var retryAttempt = 0
    private var loggedMissingFile = false
    private let sessionId: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.wudanwu.pingisland.interruptwatcher", qos: .userInteractive)

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user"
    ]

    init(sessionId: String, cwd: String, explicitFilePath: String? = nil) {
        self.sessionId = sessionId
        if let explicitFilePath, !explicitFilePath.isEmpty {
            self.filePath = explicitFilePath
        } else {
            self.filePath = Self.resolveFallbackFilePath(sessionId: sessionId, cwd: cwd)
        }
    }

    static func resolveFallbackFilePath(
        sessionId: String,
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let qoderPath = homeDirectory.path + "/.qoder/projects/" + projectDir + "/transcript/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderPath) {
            return qoderPath
        }

        let qoderWorkPath = homeDirectory.path + "/.qoderwork/projects/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderWorkPath) {
            return qoderWorkPath
        }

        if let codexPath = resolveCodexRolloutPath(
            sessionId: sessionId,
            sessionsRoot: homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        ) {
            return codexPath
        }

        return homeDirectory.path + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
    }

    private static func resolveCodexRolloutPath(sessionId: String, sessionsRoot: URL) -> String? {

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let suffix = "-\(sessionId).jsonl"
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(suffix) else { continue }
            return fileURL.path
        }

        return nil
    }

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath) else {
            if !loggedMissingFile {
                logger.debug("Waiting for transcript file: \(self.filePath, privacy: .public)")
                loggedMissingFile = true
            }
            scheduleRetry()
            return
        }

        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            logger.warning("Failed to open transcript file: \(self.filePath, privacy: .public)")
            scheduleRetry()
            return
        }

        fileHandle = handle
        let needsInitialSync = !hasAttached
        pendingLineFragment.removeAll(keepingCapacity: true)
        retryAttempt = 0
        if loggedMissingFile {
            logger.debug("Attached transcript watcher after file became available: \(self.sessionId.prefix(8), privacy: .public)...")
            loggedMissingFile = false
        }

        do {
            lastOffset = try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            try? handle.close()
            fileHandle = nil
            scheduleRetry()
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForInterrupt()
        }

        newSource.setCancelHandler {
            try? handle.close()
        }

        source = newSource
        hasAttached = true
        newSource.resume()

        logger.debug("Started watching: \(self.sessionId.prefix(8), privacy: .public)...")

        if needsInitialSync {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.didObserveFileChange(sessionId: self.sessionId, requiresImmediateSync: true)
            }
        }
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        if currentSize < lastOffset {
            lastOffset = 0
            pendingLineFragment.removeAll(keepingCapacity: true)
        }
        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(), !newData.isEmpty else { return }
        lastOffset += UInt64(newData.count)
        let lines = completedLines(from: newData)
        let requiresImmediateSync = Self.requiresImmediateSessionSync(in: lines)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.didObserveFileChange(
                sessionId: self.sessionId,
                requiresImmediateSync: requiresImmediateSync
            )
        }
        for line in lines where !line.isEmpty {
            if isInterruptLine(line) {
                logger.info("Detected interrupt in session: \(self.sessionId.prefix(8), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.didDetectInterrupt(sessionId: self.sessionId)
                }
                return
            }
        }
    }

    /// Keep bytes until a newline, including UTF-8 scalars split across writes.
    func completedLines(from data: Data) -> [String] {
        pendingLineFragment.append(data)
        guard let newline = pendingLineFragment.lastIndex(of: 0x0A) else { return [] }
        let end = pendingLineFragment.index(after: newline)
        let complete = pendingLineFragment[..<end]
        let lines = complete.split(separator: 0x0A).compactMap { String(data: $0, encoding: .utf8) }
        pendingLineFragment = Data(pendingLineFragment[end...])
        return lines
    }

    private static let immediateLifecycleEvents: Set<String> = [
        "task_started", "task_complete", "turn_aborted", "context_compacted"
    ]
    private static let immediateInteractionItems: Set<String> = [
        "function_call", "function_call_output"
    ]

    static func requiresImmediateSessionSync(in content: String) -> Bool {
        requiresImmediateSessionSync(in: content.components(separatedBy: "\n"))
    }

    private static func requiresImmediateSessionSync(in lines: [String]) -> Bool {
        for line in lines {
            guard immediateLifecycleEvents.contains(where: { line.contains("\"\($0)\"") })
                || immediateInteractionItems.contains(where: { line.contains("\"\($0)\"") }) else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }
            if type == "event_msg", immediateLifecycleEvents.contains(payloadType) { return true }
            if type == "response_item", immediateInteractionItems.contains(payloadType) { return true }
        }
        return false
    }

    private func isInterruptLine(_ line: String) -> Bool {
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
               line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }

        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            for pattern in Self.interruptContentPatterns {
                if line.contains(pattern) {
                    return true
                }
            }
        }

        if line.contains("\"interrupted\":true") {
            return true
        }

        return false
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if source != nil {
            logger.debug("Stopped watching: \(self.sessionId.prefix(8), privacy: .public)...")
        }
        source?.cancel()
        source = nil
        if fileHandle != nil {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.startWatching()
        }
        retryWorkItem = workItem
        let delay = Self.retryDelay(forMissingFileAttempt: retryAttempt)
        retryAttempt += 1
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    static func retryDelay(forMissingFileAttempt attempt: Int) -> DispatchTimeInterval {
        let boundedAttempt = max(0, min(attempt, 8))
        let multiplier = 1 << boundedAttempt
        let delayMs = min(initialRetryDelayMs * multiplier, maxRetryDelayMs)
        return .milliseconds(delayMs)
    }

    deinit {
        source?.cancel()
    }
}

// MARK: - Interrupt Watcher Manager

/// Manages interrupt watchers for all active sessions
@MainActor
class InterruptWatcherManager {
    static let shared = InterruptWatcherManager()

    private var watchers: [String: JSONLInterruptWatcher] = [:]
    weak var delegate: JSONLInterruptWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, cwd: String, explicitFilePath: String? = nil) {
        guard watchers[sessionId] == nil else { return }

        let watcher = JSONLInterruptWatcher(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        watcher.delegate = delegate
        watcher.start()
        watchers[sessionId] = watcher
    }

    /// Stop watching a specific session
    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionId: String) -> Bool {
        watchers[sessionId] != nil
    }
}
