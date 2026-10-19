#if DEBUG && targetEnvironment(simulator)
import Foundation

// An unpaired simulator fixture for drawer/scroll regressions with long CJK Markdown.
// Every RPC is intercepted; this scene cannot send a task to a real agent.
@MainActor
func configureSidebarPerformancePreview(_ service: CodexService) {
    let threadID = "sidebar-demo"
    UserDefaults.standard.set(true, forKey: "codex.hasSeenOnboarding")
    UserDefaults.standard.set("1.1", forKey: "codex.whatsNew.lastPresentedVersion")
    service.isConnected = true
    service.isInitialized = true
    service.supportsSharedSessionControl = true
    service.lastNegotiatedSharedSession = true
    service.syncRealtimeEnabled = false
    service.threads = (0..<70).map { index in
        CodexThread(id: index == 0 ? threadID : "sidebar-project-\(index)",
                    title: index == 0 ? "长中文消息示例" : "示例会话 \(index)",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
                    cwd: "/demo/project-\(index % 8)")
    }
    let paragraph = "这是一段用于验证界面性能的虚构中文内容。侧边栏打开和关闭时，屏幕外的历史消息不应反复参与排版。消息仍需保留粗体、列表、代码和链接，滚动后可以继续阅读历史内容。"
    let messages = (0..<60).map { (index: Int) in
        CodexMessage(id: "sidebar-message-\(index)", threadId: threadID, role: .assistant,
                     text: """
                     ### 示例记录 \(index)

                     **排版检查**：\(String(repeating: paragraph, count: 3))

                     - 第一项：保留原有内容与操作。
                     - 第二项：展开侧边栏后可以继续阅读。

                     ```swift
                     let message = "示例 \(index)"
                     print(message)
                     ```

                     \(index == 59 ? "SIDEBAR_TAIL_MARKER" : "历史记录 \(index)")
                     """, turnId: "sidebar-turn-\(index)", orderIndex: index)
    }
    service.messagesByThread[threadID] = messages
    service.messageRevisionByThread[threadID] = 1
    service.resumedThreadIDs.insert(threadID)
    service.hydratedThreadIDs.insert(threadID)
    service.activeThreadId = threadID

    let threadJSON: JSONValue = .object([
        "id": .string(threadID), "name": .string("长中文消息示例"),
        "cwd": .string("/demo/project-0"), "status": .object(["type": .string("idle")]),
        "turns": .array(messages.map { message in
            .object(["id": .string(message.turnId!), "status": .string("completed"),
                     "items": .array([.object(["id": .string(message.id), "type": .string("agentMessage"),
                                               "text": .string(message.text)])])])
        })
    ])
    let threadList: JSONValue = .array(service.threads.map { thread in
        .object(["id": .string(thread.id), "name": .string(thread.displayTitle),
                 "cwd": .string(thread.cwd ?? "/demo"), "status": .object(["type": .string("idle")])])
    })
    service.requestTransportOverride = { method, _ in
        let result: JSONValue
        switch method {
        case "thread/read", "thread/resume": result = .object(["thread": threadJSON])
        case "remote/sync": result = .object(["approvals": .array([])])
        case "thread/list":
            result = .object(["data": threadList, "nextCursor": .null])
        default: result = .object(["data": .array([])])
        }
        return RPCMessage(id: .string("sidebar-fixture"), result: result)
    }
}
#endif
