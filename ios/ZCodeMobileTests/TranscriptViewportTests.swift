import XCTest
import SwiftUI
@testable import ZCodeMobile

@MainActor final class TranscriptViewportTests: XCTestCase {
    @Observable final class Fixture {
        var ids = Array(0..<50)
        var command: TranscriptListCommand?
    }
    struct Harness: View {
        let fixture: Fixture
        var body: some View {
            StableTranscriptList(rows: fixture.ids.map { id in
                TranscriptListRow(id: "message:\(id)", revision: id,
                    content: AnyView(Text("消息 \(id)").frame(height: CGFloat(70 + abs(id % 4) * 25))))
            }, command: fixture.command, followsBottom: false,
               onViewport: { _, _, _ in }, onInteraction: { _ in })
        }
    }
    func findTable(_ view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        return view.subviews.compactMap(findTable).first
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    func testPrependAndRemovingEarlierRowsPreserveVisibleMessagePosition() async throws {
        let fixture = Fixture()
        let host = UIHostingController(rootView: Harness(fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 900)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await settle()
        let table = try XCTUnwrap(findTable(host.view))
        fixture.command = .init(id: UUID(), target: "message:20", bottom: false)
        try await settle()
        func position() throws -> CGFloat {
            let cell = try XCTUnwrap(table.visibleCells.first { $0.accessibilityIdentifier == "message:20" })
            return cell.frame.minY - table.contentOffset.y
        }
        let original = try position()
        fixture.ids = Array(-25..<50)
        try await settle()
        XCTAssertEqual(try position(), original, accuracy: 1, "Prepending must preserve the message, not the old index path")
        // Simulate collapsing tool rows above the current reading anchor.
        fixture.ids.removeAll { (0..<18).contains($0) }
        try await settle()
        XCTAssertEqual(try position(), original, accuracy: 1)
        // A growing last answer must not pull a reader away from history.
        fixture.ids += Array(50..<75)
        try await settle()
        XCTAssertEqual(try position(), original, accuracy: 1)
    }
}
