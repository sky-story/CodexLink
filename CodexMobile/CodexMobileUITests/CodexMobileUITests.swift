// FILE: CodexMobileUITests.swift
// Purpose: Measures timeline scrolling and streaming append performance on deterministic fixtures.
// Layer: UI Test
// Exports: CodexMobileUITests
// Depends on: XCTest

import XCTest

final class CodexMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testClaudeRendersAssistantMarkdown() {
        checkAssistantMarkdown(scene: "claude-markdown")
    }

    func testCodexRendersAssistantMarkdown() {
        checkAssistantMarkdown(scene: "markdown")
    }

    private func checkAssistantMarkdown(scene: String) {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = scene
        app.launch()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        // Both conversations initially anchor to the latest message.
        for _ in 0..<3 { scroll.swipeDown(velocity: .slow) }
        XCTAssertTrue(app.staticTexts["修改建议"].waitForExistence(timeout: 5), "Markdown headings must render without hash delimiters")
        let emphasis = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "重点文字恢复为黑色／白色加粗")).firstMatch
        XCTAssertTrue(emphasis.exists)
        XCTAssertFalse(emphasis.label.contains("**"))
        let heading = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "先确认")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertFalse(heading.label.contains("**"), "Strong markup must render instead of exposing delimiters")
        XCTAssertFalse(heading.label.contains("`"), "Inline code must render without backticks")
        XCTAssertLessThanOrEqual(heading.frame.maxX, app.frame.maxX)
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "\(scene)-formatted-prose"
        top.lifetime = .keepAlways
        add(top)

        for _ in 0..<3 { scroll.swipeUp(velocity: .slow) }
        let code = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "**literal**")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), "Fenced code must preserve literal Markdown characters")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "# literal heading")).firstMatch.exists, "Heading-like text inside fenced code must stay literal")
        XCTAssertTrue(app.buttons["Copy response"].firstMatch.exists)
        let bottom = XCTAttachment(screenshot: app.screenshot())
        bottom.name = "\(scene)-code-and-copy"
        bottom.lifetime = .keepAlways
        add(bottom)
    }

    func testSidebarPreservesDraftAndLongMarkdownScroll() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "sidebar-performance"
        app.launchEnvironment["CODEX_REMOTE_TEST_THREAD"] = "sidebar-demo"
        app.launch()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        let tail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SIDEBAR_TAIL_MARKER")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        let field = app.descendants(matching: .any)["shared-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("sidebar-draft-retained")

        for _ in 0..<3 {
            app.buttons["Menu"].tap()
            let close = app.buttons["Close menu"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["会话总览"].exists)
            close.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertEqual(field.value as? String, "sidebar-draft-retained")
        }

        timeline.swipeDown(velocity: .slow)
        timeline.swipeDown(velocity: .slow)
        let latest = app.buttons["Scroll to latest message"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        app.buttons["Menu"].tap()
        app.buttons["Close menu"].tap()
        XCTAssertTrue(latest.exists, "Closing the drawer must preserve reading position")
        latest.tap()
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "sidebar-draft-retained")
    }

    func testClaudeDraftSurvivesSameMacReconnect() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-reconnect"
        app.launch()
        let field = app.descendants(matching: .any)["claude-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("claude-reconnect-draft")
        app.buttons["模拟重连"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "claude-reconnect-draft")
        XCTAssertTrue(app.buttons["发送给 Claude"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Claude draft retained after same-Mac reconnect"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClaudeShowsLoadingAndRetriesFailedHistoryWithoutSendingAMessage() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-loading-retry"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["claude-history-loading"].firstMatch.waitForExistence(timeout: 3))
        let retry = app.buttons["claude-history-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["对话读取失败"].exists)
        let failed = XCTAttachment(screenshot: app.screenshot())
        failed.name = "Claude history loading failure has an explicit retry"
        failed.lifetime = .keepAlways
        add(failed)
        retry.tap()
        let tail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CLAUDE_HISTORY_LOADED")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        XCTAssertTrue(tail.isHittable, "A long latest page must render at the visible bottom, not a blank scroll region")
        XCTAssertTrue(app.staticTexts["已连接"].exists)
        XCTAssertFalse(app.staticTexts["已连接，等待首条回复验证"].exists)
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Claude Mac history visible without phone reply verification"
        recovered.lifetime = .keepAlways
        add(recovered)
    }

    func testClaudeReconnectRestartsStalledHistoryOnSameRelay() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-stalled-reconnect"
        app.launch()
        XCTAssertTrue(app.buttons["模拟重连"].waitForExistence(timeout: 5))
        app.buttons["模拟重连"].tap()
        let tail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CLAUDE_HISTORY_LOADED")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 8), "Replacing a connection must immediately replace a stuck read")
        XCTAssertTrue(tail.isHittable)
    }

    func testClaudeReconnectRestartsStalledSessionListOnSameRelay() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-list-stalled-reconnect"
        app.launch()
        XCTAssertTrue(app.staticTexts["暂无 Claude 会话"].waitForExistence(timeout: 5))
        app.buttons["模拟重连"].tap()
        XCTAssertTrue(app.staticTexts["示例：待办 App"].waitForExistence(timeout: 8), "A replaced connection must refresh the visible list without awaiting the retired request's deadline")
    }

    func testClaudeHistoryRefreshAndPaginationPreserveReadingPosition() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-history-scroll"
        app.launch()
        let tail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CLAUDE_HISTORY_LOADED")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        XCTAssertTrue(tail.isHittable)
        let scroll = app.scrollViews.firstMatch
        let earlier = app.buttons["加载更早消息"]
        for _ in 0..<25 {
            if earlier.exists && earlier.isHittable { break }
            scroll.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(earlier.isHittable)
        let anchor = app.staticTexts["继续检查第 16 项。"]
        XCTAssertTrue(anchor.isHittable)
        let beforeRefresh = anchor.frame.minY
        app.buttons["刷新对话"].tap()
        XCTAssertTrue(anchor.isHittable, "Refreshing while reading old messages must not jump to the bottom")
        XCTAssertEqual(anchor.frame.minY, beforeRefresh, accuracy: 20)
        earlier.tap()
        XCTAssertTrue(anchor.isHittable, "Backfilling earlier history must preserve the visible message")
        XCTAssertEqual(anchor.frame.minY, beforeRefresh, accuracy: 70)
        XCTAssertFalse(tail.isHittable)
        app.buttons["刷新对话"].tap()
        XCTAssertTrue(anchor.isHittable, "A latest-page poll must preserve the backfilled history and reading position")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Claude old-message reading position retained across refresh and pagination"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSessionOverviewRoutesToProviderSpecificConversation() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "agent-overview"
        app.launch()
        XCTAssertTrue(app.navigationBars["会话总览"].waitForExistence(timeout: 10))
        let claude = app.buttons["session-claude-overview-claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 10))
        claude.tap()
        XCTAssertTrue(app.staticTexts["Claude 请求使用 Bash"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["本次允许"].exists)
        XCTAssertFalse(app.buttons["Steer"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let codex = app.buttons["session-codex-overview-ready"]
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        codex.tap()
        XCTAssertTrue(app.buttons["Queue"].waitForExistence(timeout: 5))
    }

    func testSidebarOpensClaudeDirectlyAndPreservesCodexDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "sidebar-performance"
        app.launchEnvironment["CODEX_REMOTE_TEST_THREAD"] = "sidebar-demo"
        app.launch()
        let field = app.descendants(matching: .any)["shared-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("provider-switch-draft")
        let timeline = app.scrollViews["turn.timeline.scrollview"]
        timeline.swipeDown(velocity: .slow)
        timeline.swipeDown(velocity: .slow)
        let latest = app.buttons["Scroll to latest message"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        app.buttons["Menu"].tap()
        let claude = app.buttons["sidebar-claude-sidebar-claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5), "Claude must be directly visible in the main sidebar")
        let mainSidebarShot = XCTAttachment(screenshot: app.screenshot())
        mainSidebarShot.name = "Main sidebar with Codex and Claude"
        mainSidebarShot.lifetime = .keepAlways
        add(mainSidebarShot)
        app.segmentedControls.buttons["Codex"].tap()
        XCTAssertFalse(claude.exists)
        app.segmentedControls.buttons["Claude"].tap()
        XCTAssertTrue(claude.waitForExistence(timeout: 3))
        let search = app.textFields["Search conversations"]
        search.tap()
        search.typeText("storefront")
        XCTAssertTrue(claude.exists, "Sidebar search must include Claude projects")
        let sidebarShot = XCTAttachment(screenshot: app.screenshot())
        sidebarShot.lifetime = .keepAlways
        add(sidebarShot)
        claude.tap()
        XCTAssertTrue(app.staticTexts["Claude 请求使用 Bash"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["会话总览"].exists)
        XCTAssertFalse(app.buttons["Queue"].exists)
        XCTAssertFalse(app.buttons["Steer"].exists)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 3), "A sidebar Claude conversation must be a peer destination with its own menu, not a Back button over Codex")
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Provider switching uses the existing sidebar")
        let claudeField = app.descendants(matching: .any)["claude-message"].firstMatch
        claudeField.tap()
        claudeField.typeText("claude-provider-draft")
        app.buttons["Menu"].tap()
        app.segmentedControls.buttons["Codex"].tap()
        let codexRow = app.staticTexts["长中文消息示例"].firstMatch
        XCTAssertTrue(codexRow.waitForExistence(timeout: 5))
        codexRow.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "provider-switch-draft")
        XCTAssertTrue(latest.exists, "Switching back from Claude must retain the Codex reading position")
        app.buttons["Menu"].tap()
        app.segmentedControls.buttons["Claude"].tap()
        claude.tap()
        XCTAssertTrue(claudeField.waitForExistence(timeout: 5))
        XCTAssertEqual(claudeField.value as? String, "claude-provider-draft")
        let claudeRoot = XCTAttachment(screenshot: app.screenshot())
        claudeRoot.name = "Claude is a peer destination with a sidebar menu and retained draft"
        claudeRoot.lifetime = .keepAlways
        add(claudeRoot)
        app.buttons["Menu"].tap()
        XCTAssertTrue(claude.isSelected)
        app.buttons["会话总览"].tap()
        XCTAssertTrue(app.navigationBars["会话总览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["session-claude-sidebar-claude"].exists, "Overview must immediately reuse the sidebar's cache")
        let overviewShot = XCTAttachment(screenshot: app.screenshot())
        overviewShot.name = "Overview with 70 cached Codex conversations"
        overviewShot.lifetime = .keepAlways
        add(overviewShot)
        app.buttons["session-claude-sidebar-claude"].tap()
        XCTAssertTrue(app.staticTexts["Claude 请求使用 Bash"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["会话总览"].waitForExistence(timeout: 5), "Overview entry must return to the overview")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(claudeField.waitForExistence(timeout: 5), "Leaving overview must return to the selected Claude conversation")
        XCTAssertEqual(claudeField.value as? String, "claude-provider-draft")
        XCTAssertTrue(app.buttons["Menu"].exists)
        XCTAssertFalse(app.buttons["Queue"].exists)
    }

    func testClaudeLiveReplyFollowsWhenAlreadyAtBottom() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-live-append"
        app.launch()
        let initialTail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CLAUDE_HISTORY_LOADED")).firstMatch
        XCTAssertTrue(initialTail.waitForExistence(timeout: 10))
        XCTAssertTrue(initialTail.isHittable)
        app.buttons["模拟新回复"].tap()
        let newTail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CLAUDE_LIVE_TAIL_41")).firstMatch
        XCTAssertTrue(newTail.waitForExistence(timeout: 8))
        XCTAssertTrue(newTail.isHittable, "New replies should remain visible when already following the bottom")
    }

    func testClaudeLiveReplyPreservesOlderReadingPosition() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "claude-live-append"
        app.launch()
        XCTAssertTrue(app.buttons["刷新对话"].waitForExistence(timeout: 10))
        let scroll = app.scrollViews.firstMatch
        let earlier = app.buttons["加载更早消息"]
        for _ in 0..<25 {
            if earlier.exists && earlier.isHittable { break }
            scroll.swipeDown(velocity: .fast)
        }
        let anchor = app.staticTexts["继续检查第 16 项。"]
        XCTAssertTrue(anchor.isHittable)
        let oldY = anchor.frame.minY
        app.buttons["模拟新回复"].tap()
        app.buttons["刷新对话"].tap()
        XCTAssertTrue(anchor.isHittable)
        XCTAssertEqual(anchor.frame.minY, oldY, accuracy: 25)
        let newTail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CLAUDE_LIVE_TAIL_41")).firstMatch
        XCTAssertFalse(newTail.isHittable)
        // Verify the append really reached the model, after checking the old anchor.
        for _ in 0..<25 {
            if newTail.exists && newTail.isHittable { break }
            scroll.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(newTail.isHittable)
    }

    func testSharedSendAcknowledgmentPreservesNewerDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "sidebar-audit"
        app.launchEnvironment["CODEX_REMOTE_TEST_THREAD"] = "sidebar-demo"
        app.launch()
        let field = app.descendants(matching: .any)["shared-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("first-draft")
        app.buttons["Queue"].tap()
        field.tap()
        field.typeText("-newer")
        let received = NSPredicate(format: "label CONTAINS %@", "Queued on Mac")
        XCTAssertTrue(app.staticTexts.matching(received).firstMatch.waitForExistence(timeout: 12))
        XCTAssertEqual(field.value as? String, "first-draft-newer", "A delayed receipt must not erase text typed after sending")
    }

    func testCodexNotificationLeavesClaudeAndNestedNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_DOCS_SCENE"] = "sidebar-audit"
        app.launchEnvironment["CODEX_REMOTE_TEST_THREAD"] = "sidebar-demo"
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 15))
        app.buttons["Menu"].tap()
        let claude = app.buttons["sidebar-claude-sidebar-claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        claude.tap()
        XCTAssertTrue(app.staticTexts["Claude 请求使用 Bash"].waitForExistence(timeout: 5))
        app.buttons["模拟 Codex 通知"].tap()
        XCTAssertTrue(app.buttons["Queue"].waitForExistence(timeout: 5), "Notification must select Codex even when its thread ID was already active underneath Claude")
        app.buttons["Menu"].tap()
        app.buttons["会话总览"].tap()
        XCTAssertTrue(app.navigationBars["会话总览"].waitForExistence(timeout: 5))
        app.buttons["模拟 Codex 通知"].tap()
        XCTAssertTrue(app.buttons["Queue"].waitForExistence(timeout: 5), "Repeated notification must return to the conversation root")
        XCTAssertFalse(app.navigationBars["会话总览"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Codex notification returns to its conversation root"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSharedSessionQueueOverEncryptedRelay() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pairing = environment["CODEX_REMOTE_TEST_PAIRING"],
              let thread = environment["CODEX_REMOTE_TEST_THREAD"] else {
            throw XCTSkip("Run scripts/test-ios-live.py with the local smoke bridge")
        }
        let app = XCUIApplication()
        app.launchEnvironment["CODEX_REMOTE_TEST_PAIRING"] = pairing
        app.launchEnvironment["CODEX_REMOTE_TEST_THREAD"] = thread
        addUIInterruptionMonitor(withDescription: "System prompts") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["允许"].exists { alert.buttons["允许"].tap(); return true }
            return false
        }
        app.launch()
        let composer = app.descendants(matching: .any)["shared-thread-\(thread)"]
        XCTAssertTrue(composer.waitForExistence(timeout: 40), "Must target the isolated CLI test thread")
        let field = app.descendants(matching: .any)["shared-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let mode = environment["CODEX_REMOTE_TEST_MODE"] ?? "queue"
        if mode == "steer" { app.buttons["Steer · 指导当前任务"].tap() }
        field.tap()
        let marker = environment["CODEX_REMOTE_TEST_MARKER"] ?? "IOS_QUEUE_" + String(UUID().uuidString.prefix(8))
        field.typeText(mode == "steer" ? "After the existing sleep finishes, answer exactly \(marker). You may poll the existing command; do not start new commands." : "Answer exactly \(marker) without using tools.")
        app.buttons[mode == "steer" ? "Steer" : "Queue"].tap()
        let receipt = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@", "Input observed", "Queued on Mac", "Accepted by Codex")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 90), "Native iOS must receive a server receipt")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTurnTimelineScrollingPerformance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "1200",
        ]
        app.launch()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
        }
    }

    func testTurnStreamingAppendPerformance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "500",
            "-CodexUITestsAutoStream",
        ]
        app.launch()

        XCTAssertTrue(app.scrollViews["turn.timeline.scrollview"].waitForExistence(timeout: 5))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            // Wait window where fixture appends streaming chunks into the active timeline.
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        }
    }
}
