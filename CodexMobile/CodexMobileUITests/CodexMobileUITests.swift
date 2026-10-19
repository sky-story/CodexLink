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
