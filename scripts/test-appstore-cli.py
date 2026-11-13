#!/usr/bin/env python3
"""Fixture-only signed terminal CLI -> sandboxed broker integration, including adversarial caller cases, with no real vault, UI or app registration.

Pass an already development-signed sandbox Debug app and same-team signed CLI. This script never signs,
installs, launches the normal app, creates Apple account resources or sets submission readiness.
"""
import argparse
import datetime
import json
import os
import pathlib
import plistlib
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import uuid

SECRET = "fixture-secret-transport-12345"
FILE_SECRET = "fixture-private-key-67890"


def provenance(info):
    """Where the evidence came from: the signed build and the source commit the probes were built from."""
    commit = subprocess.run(["git", "-C", str(pathlib.Path(__file__).resolve().parent), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", str(pathlib.Path(__file__).resolve().parent), "status", "--porcelain", "--", ".", ":!docs/evidence"], capture_output=True, text=True).stdout.strip())
    return {"build": f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), development-signed sandbox Debug experiment",
            "sourceCommit": commit, "sourceClean": not dirty, "verifiedOn": datetime.date.today().isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("report already exists; choose a new filename")
    app, cli = args.app.resolve(), args.cli.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("LatchkeyDistributionChannel") != "app-store-sandbox-experiment":
        parser.error("only the sandbox Debug experiment can run these probes")
    for artifact in (app, cli):
        if subprocess.run(["codesign", "--verify", "--strict", str(artifact)], capture_output=True).returncode:
            parser.error("both artifacts must have valid signatures")
    group = info.get("LatchkeyAppGroup", "")
    if not group or "$" in group or "/" in group:
        parser.error("built app must declare a resolved App Group")
    node, npm = shutil.which("node"), shutil.which("npm")
    if not node or not npm:
        parser.error("Node and npm must be installed to run the command compatibility probes")
    checks = []

    def check(name, body):
        try:
            passed = body()
            checks.append({"name": name, "passed": bool(passed)})
        except Exception as error:
            # Never record commands, process output, credentials or the user's home path in evidence.
            checks.append({"name": name, "passed": False, "error": type(error).__name__})

    with tempfile.TemporaryDirectory(prefix="latchkey-cli-probe-") as temporary:
        folder = pathlib.Path(temporary).resolve()
        outside = folder / "outside"
        outside.mkdir()
        project = folder / "project"
        project.mkdir()
        envfile = project / ".env"
        envfile.write_text("FIXTURE_KEY=latchkey://FIXTURE_KEY\nKEY_FILE=latchkey-file://FIXTURE_FILE\n")
        (project / "package.json").write_text(json.dumps({"private": True, "scripts": {
            "probe": "node -e \"if (!process.env.FIXTURE_KEY || !require('fs').readFileSync(process.env.KEY_FILE, 'utf8').startsWith('fixture-private-key')) process.exit(9); console.log('npm-fixture-ok')\""
        }}))
        identifier = uuid.uuid4().hex[:8]
        endpoint = pathlib.Path.home() / "Library/Group Containers" / group / (".c" + identifier)
        environment = os.environ.copy()
        for key in ("LATCHKEY_SOCKET", "LATCHKEY_LOCAL_SOCKET", "LATCHKEY_BROKER", "LATCHKEY_ORIGIN"):
            environment.pop(key, None)
        environment.update(LATCHKEY_BROKER="app-store", LATCHKEY_LOCAL_SOCKET=str(endpoint), LATCHKEY_NO_LAUNCH="1")
        server_env = environment | {"LATCHKEY_PROBE_ID": identifier, "LATCHKEY_PROBE_FOLDER": str(project)}
        server = subprocess.Popen([str(app / "Contents/MacOS" / info["CFBundleExecutable"]), "--broker-transport-self-test"],
                                  env=server_env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def run(arguments, cwd=project, env=environment):
            return subprocess.run([str(cli)] + arguments, cwd=cwd, env=env, input=b"", capture_output=True, timeout=20)

        try:
            deadline = time.monotonic() + 15
            while not endpoint.exists() and server.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not endpoint.exists():
                raise RuntimeError("fixture broker did not start")

            check("signed CLI and sandbox broker authenticate", lambda:
                  (result := run(["status"])).returncode == 0 and b"signature checked" in result.stdout)
            check("log reads through the selected broker", lambda: run(["log", "--limit", "1"]).returncode == 0)
            check("invalid log limit is refused", lambda: run(["log", "--limit", "-1"]).returncode == 64)
            check("fixture secret read", lambda:
                  (result := run(["get", "FIXTURE_KEY"])).returncode == 0 and result.stdout.strip() == SECRET.encode())

            def reject_unsigned():
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(3)
                    connection.connect(str(endpoint))
                    try:
                        connection.sendall(b'{"op":"get","names":["FIXTURE_KEY"]}\n')
                        return connection.recv(4096) == b""
                    except (BrokenPipeError, ConnectionResetError):
                        return True
            check("unsigned caller refused before request handling", reject_unsigned)

            def reject_server():
                path = str(folder / "fake.sock")
                received = []
                with socket.socket(socket.AF_UNIX) as listener:
                    listener.bind(path)
                    listener.listen(1)
                    listener.settimeout(5)
                    def accept():
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(5)
                            received.append(connection.recv(4096))
                    worker = threading.Thread(target=accept)
                    worker.start()
                    result = run(["get", "FIXTURE_KEY"], env=environment | {"LATCHKEY_LOCAL_SOCKET": path})
                    worker.join(timeout=6)
                return result.returncode != 0 and received == [b""]
            check("impostor broker receives zero request bytes", reject_server)

            def masked_shell():
                result = run(["run", "--env-file", str(envfile), "--", "/bin/sh", "-c",
                              'printf "%s" "$FIXTURE_KEY"; printf "%s" "$FIXTURE_KEY" >&2; exit 7'])
                return result.returncode == 7 and SECRET.encode() not in result.stdout + result.stderr and \
                    b"<concealed by latchkey>" in result.stdout and b"<concealed by latchkey>" in result.stderr
            check("shell execution masking and exit status", masked_shell)

            def node_files():
                code = "const fs=require('fs'); if(fs.readFileSync(process.env.KEY_FILE,'utf8') !== '" + FILE_SECRET + "') process.exit(8); console.log(process.env.KEY_FILE)"
                result = run(["run", "--env-file", str(envfile), "--", node, "-e", code])
                path = result.stdout.decode().strip()
                return result.returncode == 0 and bool(path) and not pathlib.Path(path).exists()
            check("Node key-file delivery and cleanup", node_files)
            check("npm project execution", lambda:
                  (result := run(["run", "--env-file", str(envfile), "--", npm, "run", "probe", "--silent"])).returncode == 0 and b"npm-fixture-ok" in result.stdout)

            check("kernel command and folder grant matches", lambda:
                  run(["run", "--file", "KEY=GRANTED_KEY", "--", "/usr/bin/true"]).returncode == 0)
            check("command grant refuses other command", lambda:
                  run(["run", "--file", "KEY=GRANTED_KEY", "--", "/usr/bin/false"]).returncode == 77)
            check("folder grant refuses other folder", lambda:
                  run(["run", "--file", "KEY=GRANTED_KEY", "--", "/usr/bin/true"], cwd=outside).returncode == 77)
            def forged_unsigned():
                # Caller-supplied context and grant fields from an unsigned process: refused, and no grant appears.
                lines = [{"op": "grant", "names": ["GRANTED_KEY"], "folder": str(outside), "duration": 3600},
                         {"op": "get", "names": ["GRANTED_KEY"], "origin": "cli", "remote": {"host": "fixture", "folder": str(project)}},
                         {"op": "check", "names": ["GRANTED_KEY"], "intended": ["/usr/bin/true"], "folder": str(project)}]
                for line in lines:
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(3)
                        connection.connect(str(endpoint))
                        try:
                            connection.sendall(json.dumps(line).encode() + b"\n")
                            if connection.recv(4096) != b"":
                                return False
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                return run(["run", "--file", "KEY=GRANTED_KEY", "--", "/usr/bin/true"], cwd=outside).returncode == 77
            check("forged context and grant fields from an unsigned caller are refused", forged_unsigned)

            def forged_grant_request():
                # The signed tool may ask for a grant over another folder, but only the approver can create it.
                asked = run(["grant", "GRANTED_KEY", "--folder", str(outside), "--for", "1h"])
                return asked.returncode != 0 and SECRET.encode() not in asked.stdout + asked.stderr and \
                    run(["run", "--file", "KEY=GRANTED_KEY", "--", "/usr/bin/true"], cwd=outside,
                        env=environment | {"LATCHKEY_ORIGIN": "mcp"}).returncode == 77
            check("claimed folder and origin cannot create or widen a grant", forged_grant_request)

            check("single-use grant is not replayable", lambda:
                  run(["run", "--file", "KEY=ONCE_KEY", "--", "/usr/bin/true"]).returncode == 0 and
                  run(["run", "--file", "KEY=ONCE_KEY", "--", "/usr/bin/true"]).returncode == 77)

            def vanished_caller():
                # A caller that writes a request and disappears before it is read gets nothing and breaks nothing.
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(endpoint))
                    connection.sendall(b'{"op":"get","names":["GRANTED_KEY"]}\n')
                time.sleep(0.3)
                return run(["status"]).returncode == 0 and server.poll() is None
            check("caller that vanishes after sending leaves the broker serving", vanished_caller)

            check("grant revocation stops future reads", lambda:
                  run(["revoke", "all"]).returncode == 0 and
                  run(["run", "--file", "KEY=GRANTED_KEY", "--", "/usr/bin/true"]).returncode == 77)

            def terminate_child():
                report = project / "child-file-path"
                code = "require('fs').writeFileSync(process.argv[1], process.env.KEY_FILE); console.log('ready'); setInterval(()=>{},1000)"
                child = subprocess.Popen([str(cli), "run", "--env-file", str(envfile), "--", node, "-e", code, str(report)],
                                         cwd=project, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, start_new_session=True)
                try:
                    ready, _, _ = select.select([child.stdout], [], [], 10)
                    if not ready or child.stdout.readline().strip() != b"ready":
                        return False
                    child.send_signal(signal.SIGTERM)
                    child.communicate(timeout=10)
                    return child.returncode == 143 and report.exists() and not pathlib.Path(report.read_text()).exists()
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.communicate()
            check("SIGTERM reaches child and cleans key files", terminate_child)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            endpoint.unlink(missing_ok=True)
    report = {"passed": all(item["passed"] for item in checks), "submissionReady": False, "checks": checks,
              "boundary": "An independently signed terminal CLI executes commands; the sandboxed app only serves fixture credentials.",
              "notCovered": ["App Store CLI packaging and review", "TestFlight", "real vault and approval UI", "SSH forwarding to store",
                             "proxy upstream traffic", "live AWS STS", "real PID reuse of a signed caller (wrap-around)", "MCP server entry point", "ancestor-bound session grants", "remote pushes", "migration and sync"]}
    report.update(provenance(info))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    for item in checks:
        print(("PASS: " if item["passed"] else "FAIL: ") + item["name"])
    print("Report:", args.report)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
