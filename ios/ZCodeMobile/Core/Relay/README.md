# Native official relay adapter

`RelayClient` is an independent Swift 6 actor using Foundation and CryptoKit. It reads and controls the selected **original desktop workspace service** through the official encrypted relay. It never launches another CLI runtime. All source is in this directory; it has no AppStore, UI, or HTTP-client dependency.

Implementation is ready for integration. Offline official codec compatibility, a mocked complete connection, and arm64 iOS 26 SDK compilation pass. **A real official account connection has not been attempted.** Keep that boundary visible until explicit pairing and live acceptance are complete.

## Integration entry points

1. Store one stable `clientID` for this installation. A changed client identity must not silently inherit another controller's pending journal.
2. Parse only an explicit user-scanned official QR with `RelayPairing(scannedURL:)`. It contains a secret; never write the URL, QR, `hash`, or HMAC proof to logs, analytics, crash reports, or ordinary preferences. The type's printable descriptions redact its credential.
3. Show the selected desktop and explain that connecting may replace another mobile controller. Call `connect(pairing:confirmedControllerReplacement:true)` only after that explicit action. The adapter never reconnects after `KICKED` or network loss.
4. Call `bootstrap()` (or `workspaces()` to refresh), then `openWorkspace(key:taskID:)` for one host-returned workspace key. Calls during a workspace switch fail with `relay_busy`; serialize navigation and pending command reconciliation. Remote workspaces need the host identity and remote session ID.
5. Use `listTasks(archived:pinned:)` and `readSession(_:)`. Task engine `provider` is not the selected model provider. Read current model/thought/mode from `RelaySessionSnapshot` or `projection.config`; do not synthesize defaults.
6. Use `client.observeEvents()` for a separate observer per view/facade lifetime. The legacy `events` property remains single-consumer. Before conversation traffic, the client performs one strict `helloConversationV4` → `initializeConversationV4` per attached bridge, declaring the implemented dedicated hook UI. Handshake params omit workspace fields; other RPCs retain their scope. `subscribe(sessionID:)` then installs the listener before sending the subscribe request and retains initial frames arriving before ACK. `.projection` carries a complete merged projection. A gap or corrupt frame requests a read-only snapshot recovery. On event overflow, reload `currentProjection(sessionID:)`.
7. Call `unsubscribe(sessionID:)` when leaving a subscribed task and `disconnect()` when the user disconnects. A connection or workspace switch resets stream attachment state. Cross-host/workspace caches are cleared.

```swift
let client = try RelayClient(clientID: persistedInstallationID)
let pairing = try RelayPairing(scannedURL: explicitlyScannedURL)
try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
let bootstrap = try await client.bootstrap()
// selectedWorkspace must come from bootstrap.workspaces and the user's selection.
_ = try await client.openWorkspace(key: selectedWorkspace.id)
let tasks = try await client.listTasks()
let snapshot = try await client.readSession(selectedTaskID)
_ = try await client.subscribe(sessionID: selectedTaskID)
// Consume events in one task; hop to MainActor before changing UI state.
```

## Durable mutations and attachments

Build a `RelayCommandEnvelope` with `makeCommand(sessionID:type:payload:commandID:)`, persist that **exact Codable envelope**, and only then call `submit(_:explicitUserAction:confirmFullAccess:)`. Its command ID, client ID, session ID, issued time, payload, base revision, and log epoch must stay unchanged on an uncertain retry. `queryCommands(_:)` reconciles up to 64 original keys. An `unknown` result does not prove an offline command never ran after the host's result-retention window expired. Do not generate another send ID automatically.

`sendText`, `stop`, `reply`, `pauseGoal`, and `resumeGoal` are one-shot convenience calls. They create the envelope at call time. Use `makeCommand` + persisted `submit` for an outbox; calling a convenience method again with the same ID can correctly fail `command_conflict` because its issued time/base changed. A command ACK is an admission decision, not proof of eventual completion; confirm stop and other final state through the subsequent projection.

Supported command types are `createSession`, `sendText`, `stop`, `renameSession`, `resolveInteraction`, `switchModelConfig`, `switchCollaborationMode`, `pauseGoal`, and `resumeGoal`. Their payloads are in `docs/backend/RELAY_PROTOCOL.md`. Full access (`yolo`) requires `confirmFullAccess:true` on that submission. Model or thought changes occur only through the explicitly requested action; this client does not choose a fallback model. Relay has no HTTP-style independent `permissionMode` field: the facade preserves that restoration choice without leaving plan mode.

`makeCreateSessionCommand`/`createSession` use an empty v4 create envelope. The app should normally use `RelayRemoteTransport` in `Core/RelayAdapter/`: it persists creation intent/ACK, applies and reads back exact inherited or selected configuration without changing workspace defaults, triggers original-host task registration, then requires that task in the real list before allowing a first prompt. A completed draft retry does not reconfigure a running task. Source-level evidence shows create-time config can silently fail in the original CLI, so do not put firstInput/config in an unverified create shortcut.

`RelayWorkspaceServices` exposes `readWorkspaceState`, `listModels`, safe directory/search/readFile, workspaceChanges/workspaceDiff and conversationFileChanges. File changes are read-only and workspace Git is explicitly distinct from task authorship. POSIX workspace roots only, bounded previews/search, credential/hidden/symlink/generated-path restrictions, and component revalidation apply. The host service cannot provide an atomic no-follow guarantee against a concurrently hostile project.

For an attachment, persist a stable upload ID before `uploadAttachment(...)`, then persist the returned `RelayAttachment` before building a send envelope containing `attachments.map(\.wire)`. Its session ownership must match the message task. Repeat the same upload ID only with identical content and the same host/task connection context. The upload uses begin/chunk/commit, checks chunk progress, and attempts abort even when the caller cancels. Every upload re-reads the host's model capability. Text is bounded to 64 KiB, image/PDF to 8 MiB, and six attachments per message. PDF requires the host's `supportsPdf` flag; the current tested HTTP model does not advertise it. A committed ref is scoped to the host's attachment service; durability across host restart/controller replacement remains unverified.

Ordinary tool permissions accept only an exact pending one-time or deny option. User-input answers preserve question text keys and string/string-array values. `reply` rejects stale interactions after stop admission. Hook review uses its own typed request and persistent-change confirmation, never an ordinary permission answer. Direct `renameTask`, `archiveTask`, and `pinTask` call the task service; refresh metadata after a timeout rather than assuming a mutation failed.

`currentHookReview(sessionID:)` returns the complete immutable `RelayHookReviewRequest`. `.trustSelected(itemIDs:)`, `.revokeSelected(itemIDs:)` and `.setEnabled(itemID:enabled:)` are distinct operations; generate their local confirmation only from the corresponding affirmative UI action. Use `makeHookReviewCommand(authorization:commandID:)`, persist the envelope, then `submit(...,hookReviewAuthorization:)`. The facade owns this durability and original-ID recovery for the integrated app. Request-only review has `makeRequestHookReviewCommand`; it grants no trust. Missing server capability, expired/changed target, changed displayed content or a mismatched confirmation prevents submission. See `docs/backend/HOOK_REVIEW_CONTRACT.md` for exact routes and error/replay behavior. Native code/UI is offline validated; real official grant/toggle/revoke is unverified.

## Host goal and agent visibility

`projection.hostGoal` exists only when the host sent a goal. It exposes `timeUsedSeconds`, `activeRunStartedAtMs`, status, iteration, verifications, and iterations. Use `elapsedSeconds(atUnixMilliseconds:)` in a UI timer; its live time is added only for active/verifying/notSatisfied. A known clock offset can be applied by the caller. `pauseAvailable` and `resumeAvailable` come directly from host availability and are checked again before sending real `pauseGoal:{}` / `resumeGoal:{}` commands. There is no verified remove-goal command: `removeAvailable` is false and `removeGoal` returns `goal_remove_unsupported`.

`projection.hostAgents` preserves host `childSessionIDs`, `running`, `endedTotal`, and revision. `showsHostAgents` is derived only from that real collection; it never uses a fixed count or creates local agents. Background work is exposed separately in `backgroundWorks`. No local goal/agent lifecycle is inferred from assistant text, a slash command, or an elapsed timer.

## Historical rows

Subagent history has a separate strict read-only entry: `readSubagentSession(_:parentSessionID:)`. It requires an already loaded parent projection and verifies original ancestry, subagent type and workspace. It calls only `zcode-agent.readSession` with `runtimePolicy:"existing-only"` and no message limit. Cold subscribe/rowsRange can restore an interactive runtime in the installed host, so those paths are forbidden for a recognized child. A missing live runtime returns `relay_subagent_history_unavailable`; there is no resume or registration fallback. The facade presents the complete snapshot through local history pages. See `docs/backend/RELAY_SUBAGENT_READONLY.md` for the scope, source evidence and explicit cold-history limitation.

`rows(sessionID:beforeRowID:limit:)` returns the original page. For displayed history use `loadOlderRows(sessionID:beforeRowID:logEpoch:limit:)`: it atomically joins old rows to the subscribed reducer so later delta/upsert/remove operations continue to work. The cursor must match the current first loaded row, epoch and returned atSeq; stale pages fail explicitly. Caps: 200 rows per page, 10,000 loaded rows, 16 MiB per projection. Recovery snapshots may reset the loaded history window. `RelayRemoteTransport` exposes the app's `history` DTO and GET-messages route, merging assistantResponseId across page boundaries.

## Reproducible offline validation

Run from any directory:

```sh
bash ios/ZCodeMobile/Core/Relay/run-self-tests.sh /path/to/docs/backend/evidence
```

The evidence argument points to the official `relay-ipc-vectors.json` and `relay-frame-vectors.json`. It defaults to this project's `docs/backend/evidence`. The script builds in a temporary directory, runs the mock transport without network access, and compiles the production module against the installed iPhoneOS SDK. `RelaySelfTests.swift` is empty unless `RELAY_SELF_TESTS` is defined, so it can remain in app sources. The shell script and Markdown files are not app source or bundle resources.

See `VALIDATION.md` for retained results and `docs/backend/RELAY_PROTOCOL.md` for exact fields, source hashes and official-code vectors. Live pairing, account policy, task control, approvals, large histories, host restart/recovery, actual desktop create/configuration registration, read-only file services and multi-device interoperability still need paired acceptance. The adapter exposes no credential endpoints, cloud deployment, network configuration, arbitrary project-file writes or automatic controller replacement. A dedicated confirmed hook toggle can change that exact host-managed hook configuration.
