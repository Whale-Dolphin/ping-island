import Foundation
import XCTest
@testable import Ping_Island

final class SessionCompletionPreviewBuilderTests: XCTestCase {
    func testLatestUserAndAssistantTextPreferConversationHistory() {
        let session = SessionState(
            sessionId: "completion-preview-history",
            cwd: "/tmp/project",
            chatItems: [
                ChatHistoryItem(id: "1", type: .user("第一条问题"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "2", type: .assistant("第一条回答"), timestamp: Date(timeIntervalSince1970: 2)),
                ChatHistoryItem(id: "3", type: .user("最新问题"), timestamp: Date(timeIntervalSince1970: 3)),
                ChatHistoryItem(id: "4", type: .assistant("最新回答"), timestamp: Date(timeIntervalSince1970: 4))
            ],
            conversationInfo: ConversationInfo(
                summary: "会话摘要",
                lastMessage: "回退消息",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "首条问题",
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: session), "最新问题")
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "最新回答")
    }

    func testLatestPreviewFallsBackToStoredConversationSummary() {
        let session = SessionState(
            sessionId: "completion-preview-fallback",
            cwd: "/tmp/project",
            previewText: "  最终\n结果  ",
            conversationInfo: ConversationInfo(
                summary: "会话摘要",
                lastMessage: "  最后一条消息  ",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "  最初问题  ",
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: session), "最初问题")
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "最终 结果")
    }

    func testFinalHookMessageWinsOverTrailingToolActivity() {
        let session = SessionState(
            sessionId: "remote-tool-tail",
            cwd: "/synthetic/workspaces/results",
            latestHookMessage: "Final answer",
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: "tool",
                    type: .toolCall(ToolCallItem(
                        name: "Write", input: ["file_path": "/synthetic/workspaces/results/output.txt"],
                        status: .success, result: "created", structuredResult: nil, subagentTools: []
                    )),
                    timestamp: Date(timeIntervalSince1970: 1)
                )
            ]
        )
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "Final answer")
    }

    func testAssistantReplyWinsOverTrailingThinkingActivity() {
        let session = SessionState(
            sessionId: "assistant-before-thinking",
            cwd: "/synthetic/workspaces/results",
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "reply", type: .assistant("Final answer"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "thinking", type: .thinking("Internal activity"), timestamp: Date(timeIntervalSince1970: 2))
            ]
        )
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "Final answer")
    }

    func testLatestUserBoundaryRejectsPriorReplyAndCachedSummary() {
        let session = SessionState(
            sessionId: "new-turn-no-result", cwd: "/synthetic/workspaces/preview",
            previewText: "Previous answer", phase: .ended,
            chatItems: [
                ChatHistoryItem(id: "old-answer", type: .assistant("Previous answer"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "new-user", type: .user("New task"), timestamp: Date(timeIntervalSince1970: 2))
            ],
            conversationInfo: ConversationInfo(
                summary: nil, lastMessage: "Previous answer", lastMessageRole: "assistant",
                lastToolName: nil, firstUserMessage: "Old task", lastUserMessageDate: nil
            )
        )
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: session), "New task")
        XCTAssertNil(SessionCompletionPreviewBuilder.latestAssistantText(for: session))
    }

    func testCurrentTurnActivityFallbackDoesNotCrossLatestUserBoundary() {
        let session = SessionState(
            sessionId: "new-turn-activity", cwd: "/synthetic/workspaces/preview",
            previewText: "Previous answer", phase: .ended,
            chatItems: [
                ChatHistoryItem(id: "old-answer", type: .assistant("Previous answer"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "new-user", type: .user("New task"), timestamp: Date(timeIntervalSince1970: 2)),
                ChatHistoryItem(id: "current-thinking", type: .thinking("Current turn activity"), timestamp: Date(timeIntervalSince1970: 3))
            ]
        )
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "Current turn activity")
    }

    func testCompactedNotificationSuppressesAssistantPreview() {
        let session = SessionState(
            sessionId: "completion-preview-compacted",
            cwd: "/tmp/project",
            previewText: "压缩后的最新结果",
            conversationInfo: ConversationInfo(
                summary: "会话摘要",
                lastMessage: "最终消息",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "初始问题",
                lastUserMessageDate: nil
            )
        )

        XCTAssertNil(
            SessionCompletionPreviewBuilder.latestAssistantText(
                for: session,
                notificationKind: .compacted
            )
        )
        XCTAssertEqual(
            SessionCompletionPreviewBuilder.latestAssistantText(
                for: session,
                notificationKind: .completed
            ),
            "压缩后的最新结果"
        )
    }
}
