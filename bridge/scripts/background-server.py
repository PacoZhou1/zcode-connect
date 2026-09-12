#!/usr/bin/env python3
"""Start the existing loopback bridge outside tool-session process groups."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

root = Path(__file__).resolve().parent.parent
runtime = root / ".runtime"
lock_path = runtime / "runtime.lock"
log_path = runtime / "background-server.log"
action = sys.argv[1] if len(sys.argv) > 1 else "start"
if action not in {"start", "stop", "status"} or len(sys.argv) > 2:
    raise SystemExit("Use background-server.py start|stop|status")

def lock():
    try:
        return json.loads(lock_path.read_text())
    except FileNotFoundError:
        return None

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False

def health():
    try:
        with urllib.request.urlopen("http://127.0.0.1:18789/health", timeout=2) as response:
            return json.load(response).get("service") == "zcode-mobile-bridge"
    except Exception:
        return False

owner = lock()
running = bool(owner and alive(owner["pid"]))
if action == "status":
    print(json.dumps({"running": running, "pid": owner["pid"] if running else None, "health": health(), "logPath": str(log_path)}))
elif action == "stop":
    if running:
        cwd = subprocess.check_output(["/usr/sbin/lsof", "-a", "-p", str(owner["pid"]), "-d", "cwd", "-Fn"], text=True)
        if "n" + str(root) + "\n" not in cwd or not health():
            raise SystemExit("The lock owner is not the verified bridge in this directory; no signal sent.")
        registry = json.loads((runtime / "sessions.json").read_text())
        busy = [item["id"] for item in registry.get("sessions", {}).values() if item.get("status") in {"running", "waiting"}]
        if busy:
            raise SystemExit("Finish or explicitly stop active bridge tasks before stopping its service: " + ", ".join(busy))
        os.kill(owner["pid"], signal.SIGTERM)
        for _ in range(150):
            if not alive(owner["pid"]):
                break
            time.sleep(0.1)
        else:
            raise SystemExit("The bridge did not exit in 15 seconds; no forced signal sent.")
    print(json.dumps({"stopped": True, "pid": owner["pid"] if owner else None}))
else:
    if running:
        raise SystemExit("An existing bridge owns this runtime; use status or stop first.")
    node = shutil.which("node")
    if not node:
        raise SystemExit("Node.js is unavailable.")
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.chmod(log_path, 0o600)
    environment = dict(os.environ, ZCODE_MOBILE_HOST="127.0.0.1", ZCODE_MOBILE_PORT="18789", ZCODE_MOBILE_RUNTIME_DIR=str(runtime))
    with os.fdopen(fd, "ab", buffering=0) as log:
        process = subprocess.Popen([node, "src/server.mjs"], cwd=root, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True, close_fds=True)
    for _ in range(100):
        current = lock()
        if current and current["pid"] == process.pid and health():
            print(json.dumps({"started": True, "pid": process.pid, "url": "http://127.0.0.1:18789", "logPath": str(log_path), "detached": True}))
            break
        if process.poll() is not None:
            raise SystemExit("Bridge startup failed; inspect the private background log.")
        time.sleep(0.1)
    else:
        raise SystemExit("Startup is unconfirmed; inspect the private log and status before retrying.")
