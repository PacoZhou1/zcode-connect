#!/usr/bin/env python3
"""Run an isolated, loopback-only Caddy query-redaction regression.

No live Caddy admin calls, credentials, TLS issuance or production config writes.
All markers are synthetic. Raw subprocess logs stay in a private evidence directory.
"""
import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse


LOGGING = """ log default {
  exclude http.log.error
 }
 log relay_safe_http_errors {
  include http.log.error
  output stderr
  format filter {
   fields {
    request>uri query {
     delete hash
     delete enroll
    }
    request>headers>Referer query {
     delete hash
     delete enroll
    }
   }
   wrap json
  }
 }
"""


def private_write(path, data):
    data = data.encode() if isinstance(data, str) else data
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def request(port, path, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def reserve_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    return sock, sock.getsockname()[1]


def run_case(binary, directory, filtered, upstream_port, dead_port):
    label = "filtered" if filtered else "baseline"
    reservation, port = reserve_port()
    text = "{\n admin off\n auto_https off\n" + (LOGGING if filtered else "") + "}\n"
    text += f"""http://127.0.0.1:{port} {{
 handle /zcode/failure* {{
  reverse_proxy 127.0.0.1:{dead_port} {{
   transport http {{
    dial_timeout 200ms
   }}
  }}
 }}
 handle /zcode/* {{
  reverse_proxy 127.0.0.1:{upstream_port}
 }}
 handle {{
  respond "unrelated" 418
 }}
}}
"""
    config = directory / (label + ".Caddyfile")
    private_write(config, text)
    stderr = directory / (label + ".stderr.jsonl")
    stdout = directory / (label + ".stdout")
    with os.fdopen(os.open(stderr, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb") as err, \
            os.fdopen(os.open(stdout, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb") as out:
        # No production daemon environment: isolated local HTTP needs no secrets.
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(directory),
                       "XDG_DATA_HOME": str(directory / "data"),
                       "XDG_CONFIG_HOME": str(directory / "config")}
        reservation.close()
        process = subprocess.Popen([binary, "run", "--config", str(config), "--adapter", "caddyfile"],
                                   cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        responses = []
        try:
            for _ in range(60):
                if process.poll() is not None:
                    raise AssertionError("isolated Caddy failed to start; inspect private evidence")
                try:
                    assert request(port, "/unrelated")[0] == 418
                    break
                except (OSError, http.client.HTTPException):
                    time.sleep(0.05)
            else:
                raise AssertionError("isolated Caddy listener timeout")
            paths = [
                "/zcode/failure?hash=SYNTHETIC_HASH_A&enroll=SYNTHETIC_ENROLL_A&keep=one",
                "/zcode/failure?hash=SYNTHETIC_HASH_B&hash=SYNTHETIC_HASH_C&keep=two",
                "/zcode/failure?%68ash=SYNTHETIC_HASH_D&%65nroll=SYNTHETIC_ENROLL_D&keep=three",
                "/zcode/failure?hash=SYNTHETIC_HASH_E&malformed=%ZZ&keep=four",
            ]
            for path in paths:
                status, body = request(port, path, {"Referer": "https://example.invalid/zcode/remote/v4?hash=SYNTHETIC_REF_HASH&enroll=SYNTHETIC_REF_ENROLL&keep=ref"})
                assert status == 502
                responses.append(status)
            passthrough = "/zcode/health?hash=SYNTHETIC_FORWARD_HASH&enroll=SYNTHETIC_FORWARD_ENROLL&keep=exact%2Fbytes"
            status, body = request(port, passthrough)
            assert status == 200 and json.loads(body)["requestURI"] == passthrough
            assert request(port, "/unrelated")[0] == 418
        finally:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
    raw = stderr.read_bytes() + stdout.read_bytes()
    rows = []
    for line in stderr.read_text().splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    errors = [row for row in rows if row.get("logger", "").startswith("http.log.error")]
    assert len(errors) == 4, "lost or duplicated HTTP error records"
    assert all(row.get("status") == 502 for row in errors)
    assert all("dial tcp" in row.get("msg", "") for row in errors)
    assert all(row.get("request", {}).get("method") == "GET" for row in errors)
    leaked = any(marker in raw for marker in (b"SYNTHETIC_HASH_", b"SYNTHETIC_ENROLL_", b"SYNTHETIC_REF_"))
    if filtered:
        assert not leaked, "query markers escaped the native field filters"
        for row in errors:
            uri = urllib.parse.urlsplit(row["request"]["uri"])
            query = urllib.parse.parse_qs(uri.query)
            assert uri.path == "/zcode/failure" and "keep" in query
            assert "hash" not in query and "enroll" not in query
            for value in row["request"]["headers"]["Referer"]:
                ref = urllib.parse.parse_qs(urllib.parse.urlsplit(value).query)
                assert ref == {"keep": ["ref"]}
    else:
        assert leaked, "baseline did not reproduce the logging risk"
    return {"name": label, "port": port, "responses": responses,
            "errorRecords": len(errors), "credentialMarkerFound": leaked,
            "upstreamURIUnchanged": True, "unrelatedRouteStatus": 418,
            "diagnosticFieldsPreserved": True, "processStopped": process.poll() is not None,
            "configSHA256": hashlib.sha256(config.read_bytes()).hexdigest(),
            "stderrSHA256": hashlib.sha256(stderr.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--caddy", required=True)
    parser.add_argument("--output-parent", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(tempfile.mkdtemp(prefix="logging-check-", dir=args.output_parent))
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"requestURI": self.path}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=upstream.serve_forever, daemon=True)
    worker.start()
    dead_socket, dead_port = reserve_port()  # Bound but not listening: deterministic refusal.
    try:
        cases = [run_case(args.caddy, directory, filtered, upstream.server_port, dead_port)
                 for filtered in (False, True)]
    finally:
        dead_socket.close()
        upstream.shutdown()
        upstream.server_close()
        worker.join(timeout=2)
    result = {"ok": True, "scope": "isolated Mac Pro loopback Caddy; synthetic credentials only",
              "liveAdminRequests": 0, "liveConfigWrites": 0, "rawEvidenceDirectory": str(directory),
              "cases": cases}
    private_write(directory / "result.json", json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
