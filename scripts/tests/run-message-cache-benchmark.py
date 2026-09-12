#!/usr/bin/env python3
"""Foundation-only benchmark of the exact production parser and bounded cache."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root/'ios/ZCodeMobile/Features/MessageView.swift').read_text()
extracted = source[source.index('enum MessageTextBlock:'):source.index('struct RichMessageText:')]
harness = r'''
@main struct Run {
 @MainActor static func main() throws {
  func signature(_ blocks: [MessageTextBlock]) -> [String] {
   blocks.map { b in switch b { case .prose(_, let s): return "p:" + String(s.characters); case .code(_, let s): return "c:" + s; case .table(_, let rows): return "t:" + rows.map { $0.joined(separator: "|") }.joined(separator: "\n") } }
  }
  let fixtures = ["", "中文 **加粗** 与 [链接](https://example.com)\n下一行", "开始\n```swift\nlet x = 1\n```\n结束", "| 名称 | 值 |\n|---|---|\n| A | 1 |", "```swift\nlet value", "前文\n\n\n后文"]
  var assertions = 0
  for user in [true, false] { for text in fixtures {
   let direct = MessageTextCache.parse(text: text, user: user)
   let first = MessageTextCache.shared.blocks(text: text, user: user)
   let cached = MessageTextCache.shared.blocks(text: text, user: user)
   precondition(direct == first && first == cached); assertions += 1
  } }
  let stream1 = MessageTextCache.shared.blocks(text: "回答一", user: false)
  let stream2 = MessageTextCache.shared.blocks(text: "回答一继续", user: false)
  precondition(signature(stream1) == ["p:回答一"] && signature(stream2) == ["p:回答一继续"]); assertions += 1
  let prose = "这是一段包含 **重点**、`code` 和 [链接](https://example.com) 的中文回答。\n\n"
  let messages = (0..<30).map { "消息 \($0)\n" + String(repeating: prose, count: 20) + "\n```swift\nlet value = 1\n```\n| 项目 | 数值 |\n|---|---|\n| A | 100 |" }
  for text in messages { _ = MessageTextCache.shared.blocks(text: text, user: false) }
  let clock = ContinuousClock()
  var checksum = 0
  func measure(_ cached: Bool) -> Double {
   let start = clock.now
   for _ in 0..<20 { for text in messages { checksum += (cached ? MessageTextCache.shared.blocks(text: text, user: false) : MessageTextCache.parse(text: text, user: false)).count } }
   let d = start.duration(to: clock.now).components
   return Double(d.seconds)*1000 + Double(d.attoseconds)/1e15
  }
  let uncached = measure(false), cached = measure(true)
  precondition(checksum > 0)
  let report: [String: Any] = ["configuration":"swiftc -O, macOS Foundation; CPU parser microbenchmark, not scrolling FPS", "assertions":assertions, "messages":messages.count, "repetitions":20, "uncachedMilliseconds":uncached, "cachedMilliseconds":cached, "checksum":checksum]
  let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
  try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  print(String(decoding:data,as:UTF8.self))
 }
}
'''
with tempfile.TemporaryDirectory(prefix='zcode-message-cache-') as temp:
    path=Path(temp)
    (path/'main.swift').write_text('import Foundation\nimport Observation\n'+extracted+harness)
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun','swiftc','-sdk',sdk,'-O','-swift-version','6','-parse-as-library',str(path/'main.swift'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test'),str(root/'evidence/message-cache-benchmark.json')],check=True)
