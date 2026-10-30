import XCTest
@testable import ZCodeMobile

@MainActor final class TranscriptDisclosureTests: XCTestCase {
    func testManualExpansionSurvivesAutomaticCompletionAndReconfiguration() {
        let state = TranscriptDisclosureState()
        state.toggle(turnID: "one", defaultValue: false)
        XCTAssertTrue(state.expanded(turnID: "one", defaultValue: false))
        state.collapse(turnID: "one")
        XCTAssertTrue(state.expanded(turnID: "one", defaultValue: false))
        XCTAssertFalse(state.expanded(turnID: "two", defaultValue: false))
        state.toggle(turnID: "one", defaultValue: false)
        XCTAssertFalse(state.expanded(turnID: "one", defaultValue: true))
    }
    func testCompletionCollapseIsCancelledWhileReadingHistoryAndResumesOnce() async throws {
        let state = TranscriptDisclosureState()
        let process = ChatMessage(id: "work", role: .assistant, text: "正在读取")
        let answer = ChatMessage(id: "answer", role: .assistant, text: "完成")
        let running = TranscriptTurn(id: "turn", messages: [process], userMessages: [], processMessages: [process], resultMessages: [], state: .running)
        let completed = TranscriptTurn(id: "turn", messages: [process, answer], userMessages: [], processMessages: [process], resultMessages: [answer], state: .completed)
        state.synchronize(turns: [running], allowsAutoCollapse: true, reduceMotion: true)
        state.synchronize(turns: [completed], allowsAutoCollapse: true, reduceMotion: true)
        state.synchronize(turns: [completed], allowsAutoCollapse: false, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertTrue(state.expanded(turnID: "turn", defaultValue: false))
        state.synchronize(turns: [completed], allowsAutoCollapse: true, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertFalse(state.expanded(turnID: "turn", defaultValue: true))
    }

}
