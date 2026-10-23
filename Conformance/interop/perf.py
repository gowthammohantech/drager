#!/usr/bin/env python3
"""Loopback throughput and memory for the interop pairs (lane H3). macOS only (/usr/bin/time -l).

For each sender→receiver pair this starts the receiver's `serve` (as run_matrix.py does), pairs with
`pair-initiate`, then sends random files of each size with `send`:
  - sender peak RSS: `/usr/bin/time -l` on the `send` process (maximum resident set size)
  - receiver peak RSS: `ps` sampling of the `serve` process group every 20 ms; baseline = before the send
  - throughput: file size / (time of the sender's `committed` event - time of its `sessionReady`),
    measured from the sender's live stdout; `wall` is the whole `send` process including startup.
Memory is bounded if peak RSS barely moves between the small and the large file.

It also checks start-time staging cleanup: before `serve` starts, a `.sbpart` file with an mtime two
days old and a fresh one are planted in `<state>/staging` (the CLIs' staging folder). After
`listening`, the stale one should be gone and the fresh one kept.

Usage: perf.py [--pairs swift-swift,swift-dotnet,jvm-swift,jvm-dotnet] [--sizes 10,100] [--runs 2]
               [--jvm-opts=-Xmx64m] [--swift-bin P] [--jvm-bin P] [--dotnet-dll P] [--json OUT]
--jvm-opts is passed to sb-jvm as JAVA_OPTS: a small -Xmx shows whether JVM RSS growth is retained
memory or just heap the collector had no reason to give back.
Standard library only. Prints a Markdown table. Never prints file contents, names or secrets.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MIB = 1 << 20


def tools(args) -> dict[str, list[str]]:
    swift = args.swift_bin or next((str(REPO / c) for c in (
        "Conformance/SwiftHarness/.build/out/Products/Release/sb-swift",
        "Conformance/SwiftHarness/.build/release/sb-swift") if (REPO / c).exists()), None)
    jvm = args.jvm_bin or str(REPO / "Apps/SpatialBridge-Android/cli/build/install/sb-jvm/bin/sb-jvm")
    dll = args.dotnet_dll or str(REPO / "Apps/SpatialBridge-Windows/src/SpatialBridge.Cli/bin/Release/net10.0/sb-dotnet.dll")
    dotnet = shutil.which("dotnet") or str(Path.home() / ".dotnet/dotnet")
    out = {}
    if swift and Path(swift).exists():
        out["swift"] = [swift]
    if Path(jvm).exists():
        out["jvm"] = [jvm]
    if Path(dll).exists() and Path(dotnet).exists():
        out["dotnet"] = [dotnet, dll]
    return out


def env() -> dict[str, str]:
    e = dict(os.environ)
    if "JAVA_HOME" not in e and Path("/opt/homebrew/opt/openjdk@17").is_dir():
        e["JAVA_HOME"] = "/opt/homebrew/opt/openjdk@17"
    dotnet_home = Path.home() / ".dotnet"
    if dotnet_home.is_dir():
        e.setdefault("DOTNET_ROOT", str(dotnet_home))
        e["PATH"] = f"{dotnet_home}:{e.get('PATH', '')}"
    e.update(DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1")
    return e


def events(text: str) -> list[dict]:
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and "event" in obj:
                out.append(obj)
    return out


def group_rss_kib(pgid: int) -> int:
    """Total RSS (KiB) of every process in the process group."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], capture_output=True, text=True, timeout=5).stdout
    except subprocess.SubprocessError:
        return 0
    total = 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == str(pgid):
            total += int(parts[1])
    return total


class Sampler:
    def __init__(self, pgid: int):
        self.pgid, self.peak, self.stop_flag = pgid, 0, threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stop_flag.is_set():
            self.peak = max(self.peak, group_rss_kib(self.pgid))
            time.sleep(0.02)

    def __enter__(self):
        self.peak = group_rss_kib(self.pgid)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop_flag.set()
        self.thread.join()


class Server:
    def __init__(self, argv0: list[str], root: Path, e: dict, stale_check: bool):
        self.state, self.dest = root / "server-state", root / "server-dest"
        self.dest.mkdir(parents=True)
        self.staging_result = None
        if stale_check:
            staging = self.state / "staging"
            staging.mkdir(parents=True)
            os.chmod(staging, 0o700)
            self.stale = staging / "00000000-0000-4000-8000-0000000000AA.sbpart"
            self.fresh = staging / "00000000-0000-4000-8000-0000000000BB.sbpart"
            self.stale.write_bytes(b"x")
            self.fresh.write_bytes(b"y")
            two_days_ago = time.time() - 2 * 86_400
            os.utime(self.stale, (two_days_ago, two_days_ago))
        argv = argv0 + ["serve", "--state", str(self.state), "--listen", "127.0.0.1:0", "--dest", str(self.dest),
                        "--decision", "approve", "--test-mode"]
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=e,
                                     start_new_session=True)
        self.events: list[dict] = []
        self.cond = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        listening = self.wait("listening", 90)
        if not listening:
            self.stop()
            raise RuntimeError("serve did not print listening")
        self.pairing_port, self.session_port = listening["pairingPort"], listening["sessionPort"]
        if stale_check:
            time.sleep(0.5)
            self.staging_result = {"staleRemoved": not self.stale.exists(), "freshKept": self.fresh.exists()}

    def _read(self):
        for line in self.proc.stdout:
            for ev in events(line):
                with self.cond:
                    self.events.append(ev)
                    self.cond.notify_all()

    def wait(self, name: str, timeout: float, after: int = 0):
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for ev in self.events[after:]:
                    if ev.get("event") == name:
                        return ev
                left = deadline - time.monotonic()
                if left <= 0 or self.proc.poll() is not None:
                    return None
                self.cond.wait(left)

    def stop(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, 15)
                self.proc.wait(timeout=5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, 9)
                except ProcessLookupError:
                    pass


def make_file(path: Path, size: int):
    with open(path, "wb") as f:
        left = size
        while left:
            block = os.urandom(min(left, MIB))
            f.write(block)
            left -= len(block)


def timed_send(argv0: list[str], state: Path, port: int, file: Path, e: dict, timeout: float) -> dict:
    argv = ["/usr/bin/time", "-l"] + argv0 + ["send", "--state", str(state), "--connect", f"127.0.0.1:{port}",
                                             "--file", str(file), "--test-mode"]
    start = time.monotonic()
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=e)
    stamps: dict[str, float] = {}
    evs: list[dict] = []

    def read():
        for line in proc.stdout:
            for ev in events(line):
                evs.append(ev)
                stamps.setdefault(ev["event"], time.monotonic())

    errs: list[str] = []
    reader = threading.Thread(target=read, daemon=True)
    err_reader = threading.Thread(target=lambda: errs.append(proc.stderr.read()), daemon=True)
    reader.start()
    err_reader.start()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    reader.join(10)
    err_reader.join(10)
    err = "".join(errs)
    wall = time.monotonic() - start
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    fp = re.search(r"(\d+)\s+peak memory footprint", err)
    committed = next((ev for ev in evs if ev["event"] == "committed"), None)
    stream = stamps.get("committed", 0) - stamps.get("sessionReady", start) if committed else None
    return {
        "ok": proc.returncode == 0 and committed is not None,
        "exit": proc.returncode,
        "wall": wall,
        "stream": stream,
        "senderMaxRssBytes": int(m.group(1)) if m else None,
        "senderPeakFootprintBytes": int(fp.group(1)) if fp else None,
        "byteCount": committed.get("byteCount") if committed else None,
        "error": next((ev.get("code") for ev in evs if ev["event"] == "error"), None),
    }


def run_pair(sender: str, receiver: str, tl: dict, sizes: list[int], runs: int, e: dict, files: dict) -> dict:
    root = Path(tempfile.mkdtemp(prefix=f"sb-perf-{sender}-{receiver}-"))
    result = {"pair": f"{sender}->{receiver}", "sizes": {}}
    server = Server(tl[receiver], root, e, stale_check=True)
    result["staging"] = server.staging_result
    try:
        client_state = root / "client-state"
        pair = subprocess.run(tl[sender] + ["pair-initiate", "--state", str(client_state), "--connect",
                                            f"127.0.0.1:{server.pairing_port}", "--decision", "approve", "--test-mode"],
                              capture_output=True, text=True, env=e, timeout=120)
        if pair.returncode != 0:
            result["error"] = f"pair-initiate exit {pair.returncode}"
            return result
        time.sleep(0.5)
        for size in sizes:
            samples = []
            for _ in range(runs):
                baseline = group_rss_kib(server.proc.pid)
                mark = len(server.events)
                with Sampler(server.proc.pid) as sampler:
                    r = timed_send(tl[sender], client_state, server.session_port, files[size], e, 600)
                    server.wait("committed", 10, after=mark)
                r["receiverBaselineKiB"] = baseline
                r["receiverPeakKiB"] = sampler.peak
                samples.append(r)
                for p in server.dest.iterdir():  # keep disk use flat between runs
                    if p.is_file():
                        p.unlink()
            result["sizes"][size] = samples
    finally:
        server.stop()
        shutil.rmtree(root, ignore_errors=True)
    return result


def summarize(results: list[dict], sizes: list[int]) -> str:
    rows = ["| Pair | Size | Throughput (MiB/s, streaming) | Wall (s) | Sender peak RSS (MiB) | Receiver peak RSS (MiB) | Receiver baseline (MiB) | OK |",
            "|---|---|---|---|---|---|---|---|"]
    for res in results:
        if "error" in res:
            rows.append(f"| {res['pair']} | — | {res['error']} | | | | | FAIL |")
            continue
        for size in sizes:
            samples = res["sizes"].get(size, [])
            ok = all(s["ok"] for s in samples)
            tps = [size / MIB / s["stream"] for s in samples if s["ok"] and s["stream"]]
            walls = [s["wall"] for s in samples]
            snd = [s["senderMaxRssBytes"] / MIB for s in samples if s["senderMaxRssBytes"]]
            rcv = [s["receiverPeakKiB"] / 1024 for s in samples]
            base = [s["receiverBaselineKiB"] / 1024 for s in samples]
            med = lambda xs: f"{statistics.median(xs):.0f}" if xs else "n/a"
            tp = f"{statistics.median(tps):.0f} ({min(tps):.0f}–{max(tps):.0f})" if tps else "n/a"
            rows.append(f"| {res['pair']} | {size // MIB} MiB | {tp} | {statistics.median(walls):.1f} | {med(snd)} | "
                        f"{med(rcv)} | {med(base)} | {'PASS' if ok else 'FAIL'} |")
    lines = ["\n".join(rows), "", "Start-time staging purge (stale = mtime 48 h ago):"]
    seen = set()
    for res in results:
        receiver = res["pair"].split("->")[1]
        if receiver in seen or not res.get("staging"):
            continue
        seen.add(receiver)
        s = res["staging"]
        lines.append(f"- {receiver} serve: stale removed={s['staleRemoved']}, fresh kept={s['freshKept']}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pairs", default="swift-swift,swift-dotnet,jvm-swift,jvm-dotnet")
    ap.add_argument("--sizes", default="10,100", help="MiB, comma-separated")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--jvm-opts", help="JAVA_OPTS for sb-jvm, e.g. -Xmx64m")
    ap.add_argument("--swift-bin")
    ap.add_argument("--jvm-bin")
    ap.add_argument("--dotnet-dll")
    ap.add_argument("--json", help="also write raw results here")
    args = ap.parse_args()
    if not Path("/usr/bin/time").exists():
        print("needs /usr/bin/time (macOS)", file=sys.stderr)
        return 2
    tl, e = tools(args), env()
    if args.jvm_opts:
        e["JAVA_OPTS"] = args.jvm_opts
    sizes = [int(s) * MIB for s in args.sizes.split(",")]
    pairs = [p.split("-") for p in args.pairs.split(",")]
    missing = {t for p in pairs for t in p if t not in tl}
    if missing:
        print(f"missing tools: {sorted(missing)}", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="sb-perf-files-"))
    try:
        files = {}
        for size in sizes:
            files[size] = work / f"perf-{size}.bin"
            make_file(files[size], size)
        results = []
        for sender, receiver in pairs:
            print(f"== {sender} -> {receiver}", file=sys.stderr, flush=True)
            results.append(run_pair(sender, receiver, tl, sizes, args.runs, e, files))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2, default=str))
    print(summarize(results, sizes))
    return 0 if all("error" not in r and all(s["ok"] for v in r["sizes"].values() for s in v) for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
