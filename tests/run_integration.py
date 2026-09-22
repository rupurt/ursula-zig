#!/usr/bin/env python3
"""Run a Zig test binary against an isolated, ephemeral Ursula process."""

import argparse
import contextlib
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def stop(process):
    if process is not None and process.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("test_binary", type=Path)
    parser.add_argument("--timeout", type=float, default=120, help="test deadline in seconds")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    binary = args.test_binary.resolve(strict=True)
    server_binary = shutil.which("ursula")
    if server_binary is None:
        parser.error("ursula is missing; run inside `nix develop`")
    signal.signal(signal.SIGTERM, interrupted)
    # Ignore proxy settings and user Ursula/telemetry configuration for this fixture.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("URSULA_", "OTEL_"))}
    env.update(RUST_LOG="warn", TOKIO_WORKER_THREADS="2")

    with tempfile.TemporaryDirectory(prefix="ursula-zig-") as directory:
        root = Path(directory)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        url = f"http://127.0.0.1:{port}"
        config = root / "ursula.toml"
        config.write_text(f'''[server]
listen = "127.0.0.1:{port}"
admin_listen = "127.0.0.1:0"
[runtime]
core_count = 2
[raft]
node_id = 1
group_count = 1
[raft.wal]
backend = "memory"
[storage.cold]
backend = "none"
[storage.snapshot]
backend = "inline"
''')
        server = tests = None
        success = False
        with (root / "server.log").open("w+") as log:
            try:
                server = subprocess.Popen(
                    [server_binary, "server", "--preset", "default", "--config", str(config)],
                    cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                )
                deadline = time.monotonic() + 30
                while True:
                    if server.poll() is not None:
                        raise RuntimeError(f"Ursula exited during startup ({server.returncode})")
                    try:
                        with opener.open(f"{url}/__ursula/ready", timeout=0.5) as response:
                            if response.status == 200:
                                break
                    except (urllib.error.URLError, TimeoutError):
                        pass
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Ursula did not become ready within 30 seconds")
                    time.sleep(0.05)
                print(f"Running integration tests against {server_binary} at {url}", flush=True)
                tests = subprocess.Popen(
                    [str(binary)], cwd=root, env={**env, "URSULA_TEST_URL": url},
                    start_new_session=True,
                )
                code = tests.wait(timeout=args.timeout)
                if server.poll() is not None:
                    raise RuntimeError("Ursula exited while tests were running")
                success = code == 0
                return code if code >= 0 else 128 - code
            except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                print(f"Integration test failure: {error}", file=sys.stderr)
                return 1
            except KeyboardInterrupt:
                print("Integration tests interrupted", file=sys.stderr)
                return 130
            finally:
                # A second interrupt must not leave children behind during cleanup.
                with contextlib.ExitStack() as stack:
                    for sig in (signal.SIGINT, signal.SIGTERM):
                        previous = signal.signal(sig, signal.SIG_IGN)
                        stack.callback(signal.signal, sig, previous)
                    stop(tests)
                    stop(server)
                if not success:
                    log.seek(0)
                    print("--- Ursula server log (last 80 lines) ---", file=sys.stderr)
                    print("".join(log.readlines()[-80:]), file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
