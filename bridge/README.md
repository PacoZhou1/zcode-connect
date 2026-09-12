# ZCode Mobile Bridge

Local Node.js service for the native iOS client. Requires Node.js 22.13+ and the installed ZCode app.

```sh
cd "/Users/developer/claude code/zcode-mobile/bridge"
npm start
```

The listener is `127.0.0.1:18789`. Its pairing token is created at `.runtime/pairing-token` with mode `0600`. Display it locally in an interactive terminal with `npm run pair`; never put it in a URL. iOS Simulator can connect to the loopback listener.

`npm run check` reads availability and counts without printing private transcripts. `npm test` runs deterministic protocol, isolation, authentication, replay, file, and attachment tests. `npm run smoke` performs real model requests in a dedicated acceptance workspace, verifies attachment delivery and stopping, and archives its own task. It writes sanitized evidence to `../docs/backend/evidence/latest-smoke.json`.

Configuration uses `ZCODE_MOBILE_RUNTIME_DIR`, `ZCODE_MOBILE_DESKTOP_ROOT`, `ZCODE_MOBILE_CLI_PATH`, and `ZCODE_MOBILE_PORT`. The runtime directory contains private session storage and uploads; it must not be committed. Only loopback binding is allowed. Remote and physical-device networking require a separately authorized secure route.

Existing desktop tasks are read-only. Tasks created through the bridge use an isolated session store and the current configured model. The bridge does not modify the running desktop database, transcript files, app bundle, or model defaults.

`npm run smoke:interactions`, `npm run smoke:denials`, and `npm run smoke:restart` cover real approval/question flows, rejection, stopping while waiting, and recovery of persisted tasks. `node scripts/secure-gateway.mjs --plan` prepares the connection review without opening network access. See [encrypted phone routing](../docs/backend/SECURE_CONNECTION.md).

`npm run smoke:drafts` verifies `clientDraftId` creation idempotency without generating a model response. `npm run smoke:https` verifies a real reply and SSE through a pinned ephemeral loopback HTTPS gateway. `npm run verify:relay` and `npm run inspect:relay` compare cached public official-relay wire/schema evidence offline; neither pairs with the desktop. The experimental relay's exact payloads and live acceptance boundary are in [RELAY_PROTOCOL.md](../docs/backend/RELAY_PROTOCOL.md).

See [the HTTP contract](../docs/backend/HTTP_CONTRACT.md) and [protocol evidence](../docs/backend/PROTOCOL_EVIDENCE.md) for capability boundaries and acceptance details.
