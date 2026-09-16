import Foundation

private actor ParseProbe {
    private var paused: Set<Int>
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [MessageTextParseRequest] = []
    private(set) var returned: Set<Int> = []

    init(paused: Set<Int> = []) { self.paused = paused }
    func parse(_ request: MessageTextParseRequest) async -> [MessageTextBlock] {
        let index = calls.count
        calls.append(request)
        if paused.contains(index) {
            await withCheckedContinuation { continuations[index] = $0 }
        }
        // Intentionally ignores cancellation to test the consumer's stale-result guard.
        let result = MessageTextCache.parse(text: request.text, user: request.user)
        returned.insert(index)
        return result
    }
    func release(_ index: Int) { paused.remove(index); continuations.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        paused = []
        let pending = continuations.values; continuations = [:]
        for continuation in pending { continuation.resume() }
    }
    func count() -> Int { calls.count }
    func texts() -> [String] { calls.map(\.text) }
    func hasReturned(_ index: Int) -> Bool { returned.contains(index) }
}

@main struct StreamingMessageTextTests {
    struct Failure: Error { var message: String }
    struct Result: Codable { var name: String; var passed: Bool; var detail: String }
    @MainActor static var results: [Result] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw Failure(message: "Timed out waiting for the gated parser") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let message = (error as? Failure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: message)); print("FAIL \(name): \(message)") }
    }
    @MainActor static func main() async throws {
        await run("CommonMark headings lists quotes escapes and inline attributes") {
            let blocks = MessageTextCache.parse(text: "### 标题\n\n- 第一项\n- **第二项**\n\n> 引用\n\n\\# 字面标记", user: false)
            let texts = blocks.compactMap { block -> AttributedString? in if case .prose(_, let value) = block { return value }; return nil }
            try check(texts.map { String($0.characters) } == ["标题", "第一项", "第二项", "引用", "# 字面标记"], "Block markers leaked or escaped text lost")
            try check(texts[0].runs.first?.presentationIntent?.components.first?.kind == .header(level: 3), "Heading level absent")
            try check(texts[2].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true, "Bold list item lost")
        }
        await run("long answer has independent stable paragraph blocks and bounded cache reuse") {
            let text = (0..<1000).map { "### 标题 \($0)\n\n这是段落 **正文** 与链接 [Apple](https://apple.com)。" }.joined(separator: "\n\n")
            let clock = ContinuousClock(); let start = clock.now
            let parsed = MessageTextCache.shared.blocks(text: text, user: false)
            let cold = start.duration(to: clock.now)
            let warmStart = clock.now
            for _ in 0..<20 { _ = MessageTextCache.shared.blocks(text: text, user: false) }
            print("BENCHMARK 1000 headings/paragraphs cold=\(cold) warm20=\(warmStart.duration(to: clock.now)) bytes=\(text.utf8.count)")
            try check(parsed.count == 2000, "Long answer flattened into an eager giant block")
        }
        await run("actor output exactly matches completed-message parsing and attributes") {
            let fixtures = ["", "中文 **加粗** 与 [链接](https://example.com)\n下一行", "开始\n```swift\nlet x = 1\n```\n结束",
                            "| 名称 | 值 |\n|---|---|\n| A | 1 |", "```swift\nlet value", "前文\n\n\n后文", "👨‍👩‍👧‍👦 e\u{301} 与 🧑🏽‍💻", "文本\n| 未闭合 | 表"]
            for user in [false, true] {
                for text in fixtures {
                    let parsed = try await StreamingMessageTextParser.shared.parse(.init(text: text, user: user))
                    try check(parsed == MessageTextCache.shared.blocks(text: text, user: user), "Attributes, block identities or content changed")
                }
            }
        }
        await run("continuous append publishes progress and coalesces pending prefixes") {
            let probe = ParseProbe(paused: [0, 1])
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            state.update(text: "一", user: false)
            do {
                try await wait { await probe.count() == 1 }
                for suffix in ["二", "二三", "二三四"] { state.update(text: "一" + suffix, user: false) }
                await probe.release(0)
                try await wait { await probe.count() == 2 }
                let inputs = await probe.texts()
                try check(inputs == ["一", "一二三四"], "Intermediate queued prefixes were parsed")
                try check(state.renderedRequest?.text == "一", "Ongoing append starved the completed prefix")
                state.update(text: "一二三四五", user: false)
                await probe.release(1)
                try await wait { state.renderedRequest?.text == "一二三四五" }
                try check(state.blocks == MessageTextCache.parse(text: "一二三四五", user: false), "Final output was truncated")
            } catch { state.cancel(); await probe.releaseAll(); throw error }
            state.cancel(); await probe.releaseAll()
        }
        await run("equal-length rewrite cannot publish the old in-flight answer") {
            let probe = ParseProbe(paused: [0, 1])
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            state.update(text: "旧答案", user: false)
            do {
                try await wait { await probe.count() == 1 }
                state.update(text: "新答案", user: false); await probe.release(0)
                try await wait { await probe.count() == 2 }
                try check(state.renderedRequest == nil && state.blocks.isEmpty, "Old rewritten content became visible")
                await probe.release(1); try await wait { state.renderedRequest?.text == "新答案" }
                try check(state.blocks == MessageTextCache.parse(text: "新答案", user: false), "Latest replacement did not render")
            } catch { state.cancel(); await probe.releaseAll(); throw error }
            state.cancel(); await probe.releaseAll()
        }
        await run("shortened answer rejects the larger old parse") {
            let probe = ParseProbe(paused: [0, 1])
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            state.update(text: "原来的较长答案", user: false)
            do {
                try await wait { await probe.count() == 1 }
                state.update(text: "原来", user: false); await probe.release(0)
                try await wait { await probe.count() == 2 }
                try check(state.blocks.isEmpty, "A withdrawn suffix escaped the latest-input guard")
                await probe.release(1); try await wait { state.renderedRequest?.text == "原来" }
                try check(state.blocks == MessageTextCache.parse(text: "原来", user: false), "Short replacement was not exact")
            } catch { state.cancel(); await probe.releaseAll(); throw error }
            state.cancel(); await probe.releaseAll()
        }
        await run("cancel and restart keeps a late old result out of the new generation") {
            let probe = ParseProbe(paused: [0, 1])
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            state.update(text: "旧消息", user: false)
            do {
                try await wait { await probe.count() == 1 }
                state.cancel(); state.update(text: "新消息", user: false)
                try await wait { await probe.count() == 2 }
                await probe.release(0); try await wait { await probe.hasReturned(0) }
                try await Task.sleep(for: .milliseconds(10))
                try check(state.renderedRequest == nil && state.blocks.isEmpty, "Cancelled task wrote into the new generation")
                state.update(text: "新消息继续", user: false); await probe.release(1)
                try await wait { state.renderedRequest?.text == "新消息继续" }
                let inputs = await probe.texts()
                try check(inputs == ["旧消息", "新消息", "新消息继续"], "Old task cleanup disrupted the new queue")
            } catch { state.cancel(); await probe.releaseAll(); throw error }
            state.cancel(); await probe.releaseAll()
        }
        await run("disappearance cancels pending output even when the parser ignores cancellation") {
            let probe = ParseProbe(paused: [0])
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            state.update(text: "不可再出现", user: false)
            do {
                try await wait { await probe.count() == 1 }
                state.cancel(); await probe.release(0)
                try await wait { await probe.hasReturned(0) }
                try await Task.sleep(for: .milliseconds(10))
                try check(state.blocks.isEmpty && state.renderedRequest == nil, "Disappeared view received old output")
            } catch { state.cancel(); await probe.releaseAll(); throw error }
            state.cancel(); await probe.releaseAll()
        }
        await run("role change rejects an in-flight parse with the wrong text interpretation") {
            let probe = ParseProbe(paused: [0, 1])
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            let text = "```swift\nlet x = 1\n```"
            state.update(text: text, user: false)
            do {
                try await wait { await probe.count() == 1 }
                state.update(text: text, user: true); await probe.release(0)
                try await wait { await probe.count() == 2 }
                try check(state.blocks.isEmpty, "Assistant code layout escaped into the user role")
                await probe.release(1); try await wait { state.renderedRequest?.user == true }
                try check(state.blocks == MessageTextCache.parse(text: text, user: true), "User parsing no longer matches the static path")
            } catch { state.cancel(); await probe.releaseAll(); throw error }
            state.cancel(); await probe.releaseAll()
        }
        await run("identical updates do not start another parse") {
            let probe = ParseProbe()
            let state = StreamingMessageTextState(interval: .zero) { await probe.parse($0) }
            state.update(text: "同一个正文", user: false)
            try await wait { state.renderedRequest?.text == "同一个正文" }
            for _ in 0..<100 { state.update(text: "同一个正文", user: false) }
            try await Task.sleep(for: .milliseconds(10))
            let count = await probe.count()
            try check(count == 1, "Identical body invalidations reparsed completed input")
            state.cancel()
        }
        await run("final reparent reuses exact streaming parse without a blank placeholder") {
            let text = "### Handoff " + UUID().uuidString + "\n\n" + String(repeating: "正文 **加粗**。", count: 200)
            let state = StreamingMessageTextState(interval: .zero)
            state.update(text: text, user: false)
            try await wait { state.renderedRequest?.text == text }
            let expected = state.blocks
            state.cancel()
            try check(MessageTextCache.shared.cached(text: text, user: false) == expected, "Final row lost exact stream parse on reparent")
            try check(MessageTextCache.shared.cached(text: text + "changed", user: false) == nil, "Handoff reused a stale prefix")
        }
        await run("production actor observes a cancelled task") {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await StreamingMessageTextParser.shared.parse(.init(text: "取消", user: false)); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            let cancelled = await task.value
            try check(cancelled, "Production parser ignored pre-existing cancellation")
        }
        var report: [String: Any] = ["cases": results.count, "passed": results.filter(\.passed).count, "assertions": assertions]
        report["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; production parser and stream state, no network or Simulator")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
