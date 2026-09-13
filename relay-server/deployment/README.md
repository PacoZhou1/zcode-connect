# Mac Pro isolated candidate — not installed

This service only relays the phone's native ZCode protocol to the MacBook's **existing desktop ZCode runtime**. It does not run an app-server, restore tasks, migrate projects or carry model-provider traffic. Neither this directory nor its tests change the existing HTTP bridge or port 18789.

The candidate listener is **127.0.0.1:28791**. Confirm this port is unused on the Mac Pro immediately before starting. The executable refuses public/non-loopback addresses. Public HTTPS/WSS termination, DNS, authentication of its TLS certificate and any change to an existing Caddy configuration remain separate deployment work; none have been done by this PoC.

The checked-in plist is a template only. Replace all `@@...@@` placeholders with verified absolute paths and a reviewed HTTPS origin, e.g. `https://example.com:8443`. Render XML using an XML library, not shell interpolation. Check with `plutil -lint` before loading. `@@NODE_BIN@@` must be the actual Mac Pro Node 22+ executable, `@@RELAY_DIR@@` the copied `relay-server`, and `@@STATE_DIR@@` an owner-only local directory with mode 0700. Do not put state on NFS. The service log files are mode 0600 under launchd's 0077 umask and contain only startup metadata/error codes. Keep the default `/zcode` prefix: the current native parser only accepts `/zcode/remote/v4` and `/zcode/ws`.

Install only `package.json`, `package-lock.json`, `src/`, and `web/` on the Mac Pro, then use **`npm ci --omit=optional` on that Mac**. Do not copy `node_modules` from the MacBook: `fs-ext` is a native binding. Required build dependencies are Python and a working C/C++ toolchain in addition to Node/npm. The locked dependency graph is `ws`, `fs-ext` and `nan`. No model, database, bridge token or official ZCode credential is needed.

`launchd.plist.template` uses an ordinary per-user LaunchAgent label `cn.paco.zcode-private-relay`, `RunAtLoad`, `KeepAlive` and a 10-second restart throttle. This requires that user to be logged in; a pre-login LaunchDaemon is a separate reviewed choice, not covered by this template. The registry uses a kernel flock held for the whole process, so SIGKILL/crash releases it automatically. The lock file is intentionally retained and never unlinked. Its PID text is diagnostic only. A second process cannot overwrite a live owner's registry. Do not remove the lock to bypass that protection.

Before starting the service for initial enrollment, issue a 10-minute permission for the exact MacBook MID:

```sh
node src/cli.mjs enroll --state-dir /PRIVATE/relay-state --origin https://example.com:8443 --mid MACBOOK_MID --out /PRIVATE/macbook-enrollment.json
```

`/PRIVATE` denotes a private 0700 directory, not a literal recommended system path. The command writes a 0600 file and prints only its path. This output contains a **temporary enrollment token**, not the phone's pairing hash. Transfer that file by the operator's reviewed secure channel; do not paste its contents into logs or a shared terminal. This command requires the relay process to be stopped because it takes the same exclusive registry lock. Unused permission expires; the first registration consumes it. Repeating the same MID/hash after a lost registration ACK returns the same SID, but cannot rotate credentials.

After enrollment is prepared, the reviewable start command is:

```sh
node src/cli.mjs start --state-dir /PRIVATE/relay-state --origin https://example.com:8443 --port 28791
```

It prints a safe JSON listener description. `/zcode/health` is the only read-only service status endpoint. Forward `/zcode/ws` using WebSocket upgrades with a timeout longer than the 10-second heartbeat, and `/zcode/remote/v4` plus `/zcode/pairing.js` as ordinary HTTPS. Preserve paths; do not expose the registry directory. Disable access logging of query strings at every proxy, especially the pairing page (`hash`) and initial desktop WS URL (`enroll`). The service itself never logs request URLs, bodies, proof values or credentials. It does not use per-message compression.

For a later explicit pairing reset, first boot out **only this relay LaunchAgent job** so KeepAlive cannot restart it, then issue `enroll` again with `--rotate-existing-pairing` for the same MID, start it again and update the desktop's reviewed startup environment with the new private enrollment output. The old SID remains usable until a fresh successful registration, which atomically replaces it with a new SID and revokes old connections. A refresh with no current rotation permission is deliberately denied. Do not merely kill Node: launchd would restart it within the throttle interval and retake the registry lock. This avoids an unauthenticated “same MID” takeover; it is not a one-click reset workflow.

Stopping this relay closes transport sockets; there is no task stop/abort command in the relay. The MacBook's existing task runtime remains on the MacBook. Mac sleep, network loss, system restart, startup environment changes and desktop application restart are distinct lifecycle cases: only the protocol/loopback cases listed in the acceptance report have been tested. No unattended Mac Pro startup or physical phone traffic has been observed yet.

See [the exact protocol and safe desktop switch candidate](../../docs/backend/SELF_HOSTED_RELAY.md). In particular, **do not simply apply the endpoint environment variables to a desktop with saved official credentials** without the unknown-scope rejection and explicit fresh reset sequence described there.
