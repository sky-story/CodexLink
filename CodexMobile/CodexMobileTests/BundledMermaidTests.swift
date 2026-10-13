import XCTest
import WebKit
@testable import CodexMobile

@MainActor
final class BundledMermaidTests: XCTestCase {
    func testOfflineBundleRendersFlowchart() async throws {
        let bundle = Bundle.main
        let url = try XCTUnwrap(bundle.urls(forResourcesWithExtension: "js", subdirectory: nil)?.first(where: { $0.lastPathComponent == "mermaid.min.js" })
            ?? bundle.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        _ = try await view.evaluateJavaScript(source)
        let svg = try await view.callAsyncJavaScript("""
            mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' });
            const result = await mermaid.render('testdiagram', 'flowchart LR; Mac-->Phone');
            return result.svg;
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertTrue(svg?.contains("<svg") == true)
        XCTAssertTrue(svg?.contains("Mac") == true)
        XCTAssertTrue(svg?.contains("Phone") == true)
    }
}
