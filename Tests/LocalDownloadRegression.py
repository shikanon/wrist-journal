"""Exercise the iOS simulator's real TLS server; cloud storage uses a Debug fixture."""
import argparse
import base64
import hashlib
import http.client
import json
from pathlib import Path
import ssl
import subprocess
import time
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simctl", required=True)
    parser.add_argument("--phone", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    bundle = "io.github.shikanon.wristjournal"

    def run(*values):
        result = subprocess.run([args.simctl, *values], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    run("install", args.phone, args.app)
    container = Path(run("get_app_container", args.phone, bundle, "data"))
    root = container / "Library/Application Support/WristJournalStorageTests"
    (root / "server.json").unlink(missing_ok=True)
    (root / "simulation-result.json").unlink(missing_ok=True)
    run("launch", "--terminate-running-process", args.phone, bundle, "-journal-storage-simulation")
    deadline = time.monotonic() + 30
    while not (root / "simulation-result.json").exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    evidence = json.loads((root / "simulation-result.json").read_text())
    assert evidence.get("passed") is True, evidence
    session = json.loads((root / "server.json").read_text())
    url = urlsplit(session["url"])
    certificate = base64.b64decode(session["certificate"])
    context = ssl.create_default_context(cadata=ssl.DER_cert_to_PEM_cert(certificate))
    auth = {"Authorization": "Bearer " + url.fragment}

    def request(path, headers=None, ctx=context):
        connection = http.client.HTTPSConnection(url.hostname, url.port, context=ctx, timeout=3)
        try:
            connection.request("GET", path, headers=headers or {})
            result = connection.getresponse()
            return result.status, dict(result.getheaders()), result.read()
        finally:
            connection.close()

    try:
        request("/", ctx=ssl.create_default_context())
        raise AssertionError("Self-signed identity unexpectedly trusted by system")
    except ssl.SSLCertVerificationError:
        pass
    code, headers, body = request("/")
    assert code == 200 and "no-store" in headers["Cache-Control"]
    assert url.fragment.encode() not in body
    assert request("/api/recordings")[0] == 401
    assert request("/api/recordings", {"Authorization": "Bearer wrong"})[0] == 401
    assert request("/api/recordings", {**auth, "Host": "evil.test"})[0] == 400
    code, _, body = request("/api/recordings", auth)
    assert code == 200
    rows = json.loads(body)
    assert len(rows) == 1 and rows[0]["id"] == session["recording"]
    assert request("/api/ticket/../../etc/passwd", auth)[0] == 404
    code, _, body = request("/api/ticket/" + rows[0]["id"], auth)
    assert code == 200
    ticket = json.loads(body)["path"]
    code, headers, audio = request(ticket)
    assert code == 200 and len(audio) == session["byteCount"]
    assert hashlib.sha256(audio).hexdigest() == session["sha256"]
    assert "attachment" in headers["Content-Disposition"]
    assert request(ticket)[0] == 403
    # Extend once near the original deadline. Unauthenticated requests must not keep it alive.
    time.sleep(5)
    assert request("/api/recordings", auth)[0] == 200
    time.sleep(4)
    assert request("/api/recordings")[0] == 401
    time.sleep(4.5)
    try:
        request("/")
        raise AssertionError("Expired server still accepts connections")
    except (OSError, http.client.HTTPException):
        pass
    evidence["https"] = {
        "certificateAndIPVerified": True, "systemTrustRejectsUnknownCertificate": True,
        "unauthorized401": True, "hostMismatch400": True, "ticketReplay403": True,
        "downloadSHA256Matches": True, "downloadBytes": len(audio),
        "authenticatedActivityExtendsLease": True, "unauthorizedActivityDoesNotExtendLease": True,
        "idleTimeoutClosesListener": True,
    }
    (output / "storage-and-https.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
    run("io", args.phone, "screenshot", str(output / "storage-and-https.png"))
    # The session's temporary token is deliberately absent from published evidence.
    (root / "server.json").unlink(missing_ok=True)
    print("PASS: storage fixture and real TLS authorization/download/idle expiry", flush=True)


if __name__ == "__main__":
    main()
