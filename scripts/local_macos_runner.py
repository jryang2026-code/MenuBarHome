#!/opt/homebrew/bin/python3
"""One disposable Tart VM and one GitHub job at a time; host never runs repo code."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path.home() / ".local/share/menubarhome-ci"
REPO = "jryang2026-code/MenuBarHome"
BASE = "menubarhome-ci-base"
VM = "menubarhome-ci-job"
os.environ["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
os.environ["TART_NO_AUTO_PRUNE"] = "1"


def command(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def api(path, payload=None, method=None):
    args = ["gh", "api", f"repos/{REPO}/{path}"]
    if payload is not None:
        args += ["--method", "POST", "--input", "-"]
    elif method:
        args += ["--method", method]
    result = command(*args, input=json.dumps(payload) if payload else None,
                     capture_output=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def cleanup():
    # Only our fixed disposable name is ever stopped or deleted, never the base.
    subprocess.run(["tart", "stop", VM], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    subprocess.run(["tart", "delete", VM], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    state = ROOT / "state.json"
    if state.exists():
        data = json.loads(state.read_text())
        if data.get("runner_id"):
            try:
                api(f"actions/runners/{data['runner_id']}", method="DELETE")
            except subprocess.CalledProcessError as error:
                if "404" not in error.stderr:
                    raise
        state.unlink()


def stop(_signum, _frame):
    raise KeyboardInterrupt


def once():
    cleanup()
    # Keep breathing room for the user's apps and one Swift build.
    stat = os.statvfs(ROOT)
    if stat.f_bavail * stat.f_frsize < 25 * 1024**3:
        raise RuntimeError("Less than 25 GiB free; refusing to start a CI VM")
    command("tart", "clone", BASE, VM)
    with (ROOT / "vm.log").open("w") as log:
        vm = subprocess.Popen([
            "tart", "run", VM, "--no-graphics", "--no-audio",
            "--no-clipboard", "--no-usb-accessories", "--net-softnet",
            "--net-softnet-block=out @host,out @peers",
        ], stdout=log, stderr=log)
        try:
            for _ in range(90):
                if vm.poll() is not None:
                    raise RuntimeError("VM exited; inspect vm.log")
                try:
                    command("tart", "exec", VM, "/usr/bin/true",
                            capture_output=True, timeout=5)
                    break
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    time.sleep(2)
            else:
                raise RuntimeError("VM guest agent did not become ready")
            name = "menubarhome-vm-" + uuid.uuid4().hex[:10]
            config = api("actions/runners/generate-jitconfig", {
                "name": name, "runner_group_id": 1,
                "labels": ["self-hosted", "macOS", "ARM64", "menubarhome-vm"],
                "work_folder": "_work",
            })
            (ROOT / "state.json").write_text(json.dumps({
                "runner_id": config["runner"]["id"], "name": name,
                "started": time.time(),
            }) + "\n")
            print(f"Ready: {name}; VM will be discarded after one job", flush=True)
            with (ROOT / "job.log").open("w") as job_log:
                # Only the short-lived JIT config crosses into the guest.
                # No host token, keychain, directory, or SSH agent is exposed.
                command("tart", "exec", "-i", VM, "/bin/bash", "-c",
                        'export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; '
                        'IFS= read -r config; cd /Users/admin/actions-runner; '
                        'exec ./run.sh --jitconfig "$config"',
                        input=config["encoded_jit_config"] + "\n",
                        stdout=job_log, stderr=job_log, timeout=10800)
        finally:
            cleanup()
            try:
                vm.wait(timeout=20)
            except subprocess.TimeoutExpired:
                vm.terminate()
                vm.wait(timeout=10)


if __name__ == "__main__":
    import fcntl

    os.umask(0o077)
    lock = (ROOT / "controller.lock").open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        once()
    except KeyboardInterrupt:
        cleanup()
        sys.exit(0)
