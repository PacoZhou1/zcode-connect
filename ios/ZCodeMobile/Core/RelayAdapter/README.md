# Official relay facade

`RelayRemoteTransport` conforms to the app's `RemoteTransport`. It runs no HTTP server and consumes an already authenticated `RelayClient` attached to one workspace.

```swift
let bootstrap = try await client.bootstrap()
let bridge = try await client.openWorkspace(key: selectedWorkspace.id)
let transport = try await RelayRemoteTransport(
    client: client, bootstrap: bootstrap, bridge: bridge, hostName: computerName
)
// Assign transport to the app's existing RemoteTransport property.
// Before changing workspace or discarding this facade:
await transport.shutdown()
```

Pairing, controller replacement confirmation, QR storage and workspace selection remain caller responsibilities. Keep `RelayClient.clientID` stable across launches. The facade checks the paired desktop and attached bridge identity. A cancelled facade does not disconnect the controller; `observeEvents()` gives each observer its own lifetime.

Supported app routes: status, the selected project, task list/read/create, project defaults, model catalog, task settings, messages, stop, one-time permissions, structured question answers, attachments, rename/pin/archive/unread/fork, project file listing/search/preview, workspace unstaged Git changes, goal pause/resume. A task using another engine returns `relay_provider_unsupported`. No goal removal or local synthetic goal lifecycle is exposed.

`GET detail` and `host.activity` events contain `hostActivity` with original `goal`, `subagents`, `availability`, and actual subagent `rows.window`, preserving revision/logEpoch/seq and ended titles/status/summary. The full projection is available through `hostProjection(sessionID:)`. No goal means explicit null; no agents means empty real collections. Operations carry the expected attached bridge through a TaskLocal to reject stale workspace RPCs.

Detail also has `history:{hasMore,beforeRowId,firstRowId,logEpoch,atSeq,loadedRowCount,totalRowCount}`. GET `v1/sessions/:id/messages?beforeRowId=...&logEpoch=...&limit=200` returns complete already loaded `messages` plus updated history. Replace the collection and retain stream updates newer than the request. Old rows join the same reducer; assistantResponseId remains stable across pages. Epoch/cursor/sequence mismatches return `relay_history_changed`; limits return `relay_history_limit` (10,000 rows/16 MiB). Recovery snapshots may require loading older pages again.

Task listing is separately paginated: GET `v1/sessions?includeArchived=true&limit=100&cursor=...&search=...` returns `sessions` and `pagination:{snapshotId,total,hasMore,nextCursor,truncated}`. First request omits cursor; subsequent requests retain identical project/archive/search/limit filters. Frozen pages prevent sorting changes from dropping or duplicating tasks. Four snapshots remain for five minutes, up to 5,000 tasks/16 MiB each. Always surface `truncated`; `hasMore:false` alone does not prove completeness. `session_cursor_expired` and `session_cursor_mismatch` require a new first page. These cursors are a local facade extension; original host metadata APIs have no cursor.

The outbox is stored under Application Support/ZCodeRelay/Outbox, with desktop/workspace/client namespace, 0700 directory, 0600 atomic files, iOS data protection and backup exclusion. An optional `journalDirectory` is for controlled tests. Send and fork persist the exact command envelope before submission; retry keeps command ID, issuedAt, base revision/log epoch and attachment refs. A previously attempted command is queried before retransmission of that same envelope. A create draft persists its ACK/session ID before applying and verifying configuration. Completed create retries return the original result; different payloads conflict.

Attachment IDs are deterministic over session, file name, MIME and content hash. An uploaded ref is persisted before returning the ID, so relaunch does not change a pending message's refs. Host attachment retention across a desktop reset is not guaranteed; this cannot be accepted without a live account test.

The original CLI can silently ignore failed `createSession.config`. This facade therefore creates an empty task without `firstInput` or credential-bearing runtime configuration, then uses the original host's session setters with `persistAsWorkspaceLastUsed: false` and reads back exact model, thought and mode. No prompt is sent until configuration succeeds. A failure keeps the known task ID. `permissionMode` while in plan only changes the locally stored restoration preference; the host remains in plan. Exiting plan is an explicit mode change. `yolo` requires `confirmFullAccess: true` for every explicit request.

Original-host `setModel` registers/subscribes a newly created task even when that intended model already matches. This registration call is limited to newly created drafts and does not persist workspace defaults. The facade requires real matching workspace task metadata before returning the created session. A missing registration returns `relay_task_registration_unconfirmed`; its known ID remains in the durable journal for reconciliation.

File browsing uses `file.readdir` because it exposes symbolic links. It blocks hidden, credential, database and generated paths, checks all components, bounds search and text size, and validates components again after preview. The host's read service follows symlinks, so pre/post checks cannot provide an atomic no-follow guarantee against a concurrently hostile project. Windows roots are currently unsupported. Changes are explicitly labelled `workspace-git-unstaged`; they are not attributed to a task without host evidence.

`bash Core/RelayAdapter/run-self-tests.sh <evidence-directory>` (from an appropriate path) validates the complete facade against a mock official socket, then compiles all production types for iOS 26 arm64 with Swift 6 warnings as errors. Core/Relay's separate golden-vector tests remain independent. No real account, device, simulator or official relay has been connected by these tests.

Unread metadata uses the verified original host `setTaskUnread` service. PATCH `v1/sessions/:id` with `{unread:true}` marks it; `{unread:false,expectedUnreadAt:<exact milliseconds>}` performs compare-and-clear. Returned sessions preserve `unreadAt` as a number and set `unreadScope:"desktop"`; a newer marker remains visible with `unreadApplied:false`. List/detail/preview reads never clear unread. These paths are source/mock validated without a real official account.

Fork uses POST `v1/sessions/:id/fork` with a required persisted `clientForkId` and optional exact `{rowId,entityId}` from `Message.forkTarget`. Omitted targets are selected once and journaled. The full original envelope survives ACK loss, relaunch and an `unknown` query. A definite rejected fork ACK throws `fork_rejected`; uncertainty retains the request. A changed source/target conflicts. The host returns the actual child ID and performs all history cloning. If needed, only that newly returned child is registered through the original host's resume service. Fork does not set model/thought or rewind workspace files. See `docs/backend/FORK_INTEGRATION.md`.

The current facade suite passed 10 groups at 2026-09-12 15:16:43 UTC, including fork journal/ACK recovery/terminal rejection and archive/restore list readback when metadata ACKs omit archive flags. Swift 6/iOS 26 arm64 compilation passed. Official account pairing remains untested.
