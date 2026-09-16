#!/usr/bin/env python3
"""Review an endpoint-only ZCode launch; default is plan, never quit/reset.

Only --launch starts the original app, and only when it is already closed.
No credential-store access, task commands, launchctl, data-directory override,
or automatic pairing reset. Actual reset remains the user's official UI action.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import tempfile
import shlex
import sys
import time
from urllib.parse import parse_qs, urlsplit


APP = Path("/Applications/ZCode.app/Contents/MacOS/ZCode")
ASAR = Path("/Applications/ZCode.app/Contents/Resources/app.asar")
EXPECTED_ASAR = "0317216fc08f374162e5cc1b779bae5f94ef70c5eaa585cb71b8ffedc537b668"
EXPECTED_MID = ""
WS_KEY = "ZCODE_WEB_REMOTE_CONTROL_RELAY_WS_URL"
PAGE_KEY = "ZCODE_WEB_REMOTE_CONTROL_URL"
ORIGIN = ""


def private_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("DIRECTORY_MUST_BE_OWNED_PRIVATE_NON_SYMLINK")


def load_enrollment(path):
    private_directory(path.parent)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("ENROLLMENT_MUST_BE_OWNED_PRIVATE_NON_SYMLINK")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if os.fstat(stream.fileno()).st_size > 32768:
            raise ValueError("ENROLLMENT_TOO_LARGE")
        config = json.load(stream)
    if config.get("version") != 1 or config.get("deviceMid") != EXPECTED_MID:
        raise ValueError("ENROLLMENT_IDENTITY_MISMATCH")
    expiry = config.get("expiresAt")
    if not isinstance(expiry, (int, float)) or not math.isfinite(expiry) or expiry <= time.time() * 1000:
        raise ValueError("ENROLLMENT_EXPIRED")
    values = config.get("desktopEnvironment")
    if not isinstance(values, dict) or set(values) != {WS_KEY, PAGE_KEY}:
        raise ValueError("UNEXPECTED_ENVIRONMENT_KEYS")
    if values[PAGE_KEY] != ORIGIN + "/zcode/remote/v4":
        raise ValueError("PAIRING_ENDPOINT_MISMATCH")
    ws = urlsplit(values[WS_KEY])
    query = parse_qs(ws.query, keep_blank_values=True, strict_parsing=True)
    if (ws.scheme, ws.hostname, ws.port, ws.path) != ("wss", urlsplit(ORIGIN).hostname, urlsplit(ORIGIN).port, "/zcode/ws"):
        raise ValueError("RELAY_ENDPOINT_MISMATCH")
    if ws.username or ws.password or ws.fragment or set(query) != {"enroll"} or len(query["enroll"]) != 1:
        raise ValueError("UNEXPECTED_RELAY_QUERY")
    token = config.get("enrollmentToken")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token) or query["enroll"][0] != token:
        raise ValueError("ENROLLMENT_TOKEN_MISMATCH")
    return values, expiry


def main():
    global EXPECTED_MID, ORIGIN
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["custom", "custom-saved", "official", "offline-reset"], default="custom")
    parser.add_argument("--enrollment-file", type=Path)
    parser.add_argument("--log-directory", type=Path)
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--save-launcher", type=Path, help="Write a reusable custom-saved .command without any enrollment token")
    parser.add_argument("--official-credential-state", choices=["original-official-unchanged", "cleared-offline"])
    parser.add_argument("--origin", required=True)
    parser.add_argument("--mid", help="Defaults to the existing ZCode device identifier; never generates one")
    args = parser.parse_args()
    origin = urlsplit(args.origin)
    if origin.scheme != "https" or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or origin.path not in ("", "/"):
        raise ValueError("INVALID_HTTPS_ORIGIN")
    ORIGIN = args.origin.rstrip("/")
    if args.mid is None:
        try:
            args.mid = json.loads((Path.home() / ".zcode/v2/telemetry-state.json").read_text()).get("deviceMid")
        except (OSError, ValueError):
            raise ValueError("OPEN_ZCODE_ONCE_TO_CREATE_DEVICE_ID")
    if not isinstance(args.mid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", args.mid):
        raise ValueError("INVALID_DEVICE_ID")
    EXPECTED_MID = args.mid
    running = subprocess.run(["/usr/bin/pgrep", "-x", "ZCode"], capture_output=True, text=True)
    if running.returncode not in (0, 1):
        raise ValueError("PROCESS_CHECK_FAILED")
    pids = running.stdout.split()
    environment = dict(os.environ)
    environment.pop(WS_KEY, None)
    environment.pop(PAGE_KEY, None)
    expiry = None
    if args.mode == "custom":
        if args.enrollment_file:
            values, expiry = load_enrollment(args.enrollment_file.absolute())
            environment.update(values)
        elif args.launch:
            raise ValueError("PRIVATE_ENROLLMENT_FILE_REQUIRED")
    elif args.mode == "custom-saved":
        # Only after the operator has observed a successful private registration.
        # Retained SID authenticates normally; no expired enrollment query needed.
        environment.update({WS_KEY: "wss://" + urlsplit(ORIGIN).netloc + "/zcode/ws",
                            PAGE_KEY: ORIGIN + "/zcode/remote/v4"})
    elif args.mode == "offline-reset":
        # Intentionally unreachable TLS endpoint. No server, firewall or DNS change.
        # Verify it is unoccupied again at the actual launch boundary below.
        environment.update({WS_KEY: "wss://127.0.0.1:1/zcode/ws",
                            PAGE_KEY: "https://127.0.0.1:1/zcode/remote/v4"})
    if args.mode == "official" and args.launch and not args.official_credential_state:
        raise ValueError("OFFICIAL_CREDENTIAL_BOUNDARY_MUST_BE_ATTESTED")
    plan = {"mode": args.mode, "launched": False, "app": str(APP), "currentMainPIDs": pids,
            "deviceMID": EXPECTED_MID, "secretPrinted": False, "quitOrResetPerformed": False,
            "dataDirectoryChanged": False, "enrollmentExpiresAt": expiry,
            "targetOrigin": ORIGIN if args.mode.startswith("custom") else ("loopback-offline" if args.mode == "offline-reset" else "installed-official-default"),
            "needsUserOfficialReset": args.mode in ("custom", "offline-reset")}
    if args.save_launcher:
        if args.mode != "custom-saved" or args.enrollment_file or args.launch or not args.log_directory:
            raise ValueError("SAVED_LAUNCHER_REQUIRES_CUSTOM_SAVED_AND_PRIVATE_LOGS")
        private_directory(args.log_directory.absolute())
        command = [sys.executable, str(Path(__file__).resolve()), "--mode", "custom-saved", "--origin", ORIGIN,
                   "--mid", EXPECTED_MID, "--log-directory", str(args.log_directory.absolute()), "--launch"]
        fd = os.open(args.save_launcher.absolute(), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
        with os.fdopen(fd, "w") as output:
            output.write("#!/bin/sh\nexec " + shlex.join(command) + "\n")
        plan["savedLauncher"] = str(args.save_launcher.absolute())
    if not args.launch:
        print(json.dumps(plan))
        return
    if pids:
        raise ValueError("ZCODE_STILL_RUNNING_NORMAL_QUIT_REQUIRED")
    if environment.get("ZCODE_DATA_BASE_DIR", str(Path.home())).rstrip("/") != str(Path.home()):
        raise ValueError("UNEXPECTED_DATA_BASE_OVERRIDE")
    if hashlib.sha256(ASAR.read_bytes()).hexdigest() != EXPECTED_ASAR:
        raise ValueError("INSTALLED_SOURCE_CHANGED_REVIEW_REQUIRED")
    if args.mode == "offline-reset":
        with socket.socket() as check:
            check.settimeout(0.5)
            if check.connect_ex(("127.0.0.1", 1)) == 0:
                raise ValueError("OFFLINE_PORT_IS_LISTENING")
    if not args.log_directory:
        raise ValueError("PRIVATE_LOG_DIRECTORY_REQUIRED")
    private_directory(args.log_directory.absolute())
    # Recheck just before spawn. The installed app also owns a single-instance lock.
    if subprocess.run(["/usr/bin/pgrep", "-x", "ZCode"], stdout=subprocess.DEVNULL).returncode != 1:
        raise ValueError("ZCODE_OPENED_DURING_PREFLIGHT")
    fd, log_path = tempfile.mkstemp(prefix="zcode-" + args.mode + "-", suffix=".log", dir=args.log_directory)
    with os.fdopen(fd, "wb") as log:
        process = subprocess.Popen([str(APP)], env=environment, cwd=str(Path.home()),
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    plan.update({"launched": True, "pid": process.pid, "privateLogPath": log_path})
    print(json.dumps(plan))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Whitelisted codes only: parser/native error strings may contain URLs.
        message = str(error)
        print(json.dumps({"ok": False, "error": message if re.fullmatch(r"[A-Z_]+", message) else "LAUNCH_PREFLIGHT_FAILED", "secretPrinted": False}))
        raise SystemExit(1)
