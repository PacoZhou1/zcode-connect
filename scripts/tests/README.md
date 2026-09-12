# 独立 SSE 解码测试

从任意目录运行：

~~~sh
"/Users/developer/claude code/zcode-native-ios/scripts/tests/run-sse-decoder-tests.sh"
~~~

列出用例或只跑某一例：

~~~sh
"/Users/developer/claude code/zcode-native-ios/scripts/tests/run-sse-decoder-tests.sh" --list
"/Users/developer/claude code/zcode-native-ios/scripts/tests/run-sse-decoder-tests.sh" --case bare_cr_line_endings
~~~

- Swift 6 + Foundation 独立可执行程序，不需要 XCTest、Xcode project、模拟器、App 或网络。
- 脚本将生产 ServerSentEvents.swift 复制到唯一临时目录，记录 SHA-256，再使用 swiftc 编译该快照与测试源；临时编译产物和 module cache 退出时清理。
- BridgeFailure 是与生产错误值相同的最小依赖替身；解析逻辑完全使用生产文件，没有另写解析器。
- 测试固定预期事件与错误代码；包括逐字节、全部两段切分、256 个固定种子的分片计划、UTF-8/行尾/字段/EOF/容量边界。
- 输出覆盖 docs/audit/SSE_DECODER_TEST_RESULTS.json 和 SSE_DECODER_TEST_OUTPUT.txt；单例运行也会更新这些 latest 文件。可用 --report /绝对路径.json 指定 JSON 路径。审查初始、修复前、修复后证据另存为 *_INITIAL、*_BEFORE_FIX、*_AFTER_FIX。
- 退出码：0 全通过；1 至少一个断言失败；2 参数或写报告错误。编译错误直接返回 swiftc 非零状态。
- required 是用户要求范围；standard_compatibility 对照 WHATWG 的 CR/BOM 规则；strict_utf8_policy 保留应用的非法 UTF-8 拒绝策略；limit_policy 明确测试应用自定义的“保留事件总量”约束，不能当作 SSE 标准大小限制。

当前审查与真实失败见 [SSE_DECODER_REVIEW.md](</Users/developer/claude code/zcode-native-ios/docs/audit/SSE_DECODER_REVIEW.md>)。

## Outbox state audit

Run `python3 scripts/tests/run-outbox-tests.py` from the repository root. The runner
compiles a temporary snapshot of production AppStore / journal state logic with an
in-memory transport, inert UIKit / credential adapters, and a temporary journal.
It explicitly selects the active Xcode macOS SDK; it does not change xcode-select,
compile the iOS project, connect to a service, or operate Simulator.

Results and source SHA-256 values are saved to `docs/audit/OUTBOX_TEST_RESULTS.json`
and `OUTBOX_TEST_OUTPUT.txt`. The initial audit is preserved with `_INITIAL` suffixes.
Exit 1 means an expected state invariant failed; see `OUTBOX_REVIEW.md` for
reproduction conditions and distinctions from device / UI acceptance.

## Draft attachment persistence

Run `python3 scripts/tests/run-draft-attachment-tests.py`. This compiles the
production actor and Models with Foundation in a temporary directory. Results,
source hashes and output are saved to `docs/audit/DRAFT_ATTACHMENT_TEST_*`.
It checks scope isolation, reopen, corruption preservation, size limits, backup
exclusion, and concurrent atomic writes. Device file-protection behavior and
Composer integration require separate acceptance.

## Host goal and agent activity

Run `python3 scripts/tests/run-host-activity-tests.py`. The runner captures the
production AppStore, host activity types and relay mapping, then compiles them in
a temporary Foundation executable with inert transport/platform adapters. It
never pairs a relay, connects a socket, builds the iOS project, or uses Simulator.
The shared HTTP fixture is read from OutboxStateTests before its main entry point.

The 33 cases cover absence, independent goal/agent visibility, host removal,
goal statuses and timers, availability, in-flight command suppression, ended
agent history, duplicate IDs, connection deletion/switching, delayed snapshots,
SSE replay, retired epochs, and revision ordering. SwiftUI is statically inspected
only. Results and captured source hashes are written to
`docs/audit/HOST_ACTIVITY_TEST_RESULTS.json`; the initial failure and post-fix
evidence are preserved separately. See `HOST_ACTIVITY_REVIEW.md` for the boundary.

## Session list pagination

Run `python3 scripts/tests/run-session-pagination-tests.py`, or the equivalent
`python3 scripts/tests/run-outbox-tests.py --suite session-pagination`. This uses
the same production AppStore snapshot and shared inert fixtures as the outbox
suite, with an independent main entry point and report files. A 90-second execution
limit prevents an accidentally unbounded pagination regression from hanging the run.

The 11 cases cover 235 items, opaque cursors, SSE during paging and cursor restart,
repeated cursors, snapshot mismatch, one-time BridgeFailure/RelayFailure expiry
recovery, bounded repeated expiry, host switching, and superseding refreshes.
Results go to `docs/audit/SESSION_PAGINATION_TEST_RESULTS.json` and
`SESSION_PAGINATION_TEST_OUTPUT.txt`; source hashes and before/after failure evidence
are retained. See `SESSION_PAGINATION_REVIEW.md`. These are state tests, not live
HTTP/Relay, UI, or device acceptance.

## Unread and context preview

Run `python3 scripts/tests/run-unread-tests.py`, or
`python3 scripts/tests/run-outbox-tests.py --suite unread`. The eight bounded
production-AppStore cases cover read-only preview, expectedUnreadAt CAS, delayed
ACK/SSE ordering, connection switching, and isolated local fallback persistence.
Results and source hashes use `docs/audit/UNREAD_TEST_*`; see `UNREAD_REVIEW.md`.
HomeView and SessionContextInteraction are included in the evidence manifest for
the accompanying static review, not compiled or driven as UIKit tests.
