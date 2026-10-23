#!/usr/bin/env python3
"""Loopback interop matrix for sb-swift, sb-jvm and sb-dotnet (docs/API/CONFORMANCE.md §5).

Standard library only. Every pair runs a long-lived `serve` of the responder tool on
127.0.0.1 with ephemeral ports, then drives the initiator tool's `pair-initiate` and `send`
commands against it. Each tool run gets its own temp `--state`; each server its own `--dest`.

Usage: run_matrix.py [--large] [--self] [--pairs swift-dotnet,jvm-swift] [--only id,id]
                     [--swift-bin P] [--jvm-bin P] [--dotnet-dll P] [--keep]
Writes Conformance/interop/results.json and logs under Conformance/interop/logs/.
Exit code: 0 if no scenario failed, 1 otherwise.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

def default_tool_argv(args) -> dict[str, list[str]]:
    swift = args.swift_bin
    if not swift:
        for cand in ("Conformance/SwiftHarness/.build/out/Products/Release/sb-swift",
                     "Conformance/SwiftHarness/.build/release/sb-swift"):
            if (REPO / cand).exists():
                swift = str(REPO / cand)
                break
    jvm = args.jvm_bin or str(REPO / "Apps/SpatialBridge-Android/cli/build/install/sb-jvm/bin/sb-jvm")
    dll = args.dotnet_dll or str(REPO / "Apps/SpatialBridge-Windows/src/SpatialBridge.Cli/bin/Release/net10.0/sb-dotnet.dll")
    dotnet = shutil.which("dotnet") or str(Path.home() / ".dotnet/dotnet")
    tools = {}
    if swift and Path(swift).exists():
        tools["swift"] = [swift]
    if Path(jvm).exists():
        tools["jvm"] = [jvm]
    if Path(dll).exists() and Path(dotnet).exists():
        tools["dotnet"] = [dotnet, dll]
    return tools


def parse_events(text: str) -> list[dict]:
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and "event" in obj:
            events.append(obj)
    return events


def first(events: list[dict], name: str) -> dict | None:
    return next((e for e in events if e.get("event") == name), None)


class ToolRun:
    """One finished CLI invocation."""

    def __init__(self, argv, code, events, stdout, stderr, seconds, timed_out):
        self.argv, self.code, self.events = argv, code, events
        self.stdout, self.stderr, self.seconds, self.timed_out = stdout, stderr, seconds, timed_out

    def error_code(self) -> str | None:
        for e in self.events:
            if e.get("event") in ("error", "pairFailed"):
                return e.get("code")
        return None

    def summary(self) -> str:
        if self.timed_out:
            return f"timed out after {self.seconds:.1f}s; events={self.events}"
        return f"exit={self.code} events={self.events}" + (f" stderr={self.stderr.strip()[-300:]!r}" if self.stderr.strip() else "")


class Runner:
    def __init__(self, tools, env, logdir: Path):
        self.tools, self.env, self.logdir = tools, env, logdir
        self.counter = 0

    def run(self, tool: str, cmd: list[str], timeout: float, tag: str) -> ToolRun:
        argv = self.tools[tool] + cmd
        self.counter += 1
        start = time.monotonic()
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                env=self.env, start_new_session=True)
        timed_out = False
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_group(proc)
            out, err = proc.communicate()
        seconds = time.monotonic() - start
        log = self.logdir / f"{self.counter:03d}-{tag}-{tool}-{cmd[0]}.log"
        log.write_text(f"$ {' '.join(argv)}\n# exit={proc.returncode} seconds={seconds:.2f} timed_out={timed_out}\n"
                       f"--- stdout\n{out}--- stderr\n{err}")
        return ToolRun(argv, proc.returncode, parse_events(out), out, err, seconds, timed_out)


def kill_group(proc: subprocess.Popen):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.wait()


class Server:
    """A running `serve` with a background reader collecting JSON-lines events."""

    def __init__(self, runner: Runner, tool: str, root: Path, name: str, decision: str, before_start=None):
        self.tool, self.name = tool, name
        self.state, self.dest = root / f"{name}-state", root / f"{name}-dest"
        self.dest.mkdir(parents=True, exist_ok=True)
        if before_start:
            before_start(self)
        self.events: list[dict] = []
        self.cond = threading.Condition()
        self.log = (runner.logdir / f"serve-{name}-{tool}.log").open("w")
        argv = runner.tools[tool] + ["serve", "--state", str(self.state), "--listen", "127.0.0.1:0",
                                     "--dest", str(self.dest), "--decision", decision, "--test-mode"]
        self.log.write(f"$ {' '.join(argv)}\n")
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=self.log, text=True,
                                     env=runner.env, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        listening = self.wait(lambda e: e.get("event") == "listening", 0, 90)
        if not listening:
            self.stop()
            raise RuntimeError(f"{tool} serve did not print listening (see {self.log.name})")
        self.pairing_port, self.session_port = listening["pairingPort"], listening["sessionPort"]

    def _read(self):
        for line in self.proc.stdout:
            self.log.write(line)
            self.log.flush()
            for e in parse_events(line):
                with self.cond:
                    self.events.append(e)
                    self.cond.notify_all()
        with self.cond:
            self.cond.notify_all()

    def mark(self) -> int:
        with self.cond:
            return len(self.events)

    def since(self, mark: int) -> list[dict]:
        with self.cond:
            return list(self.events[mark:])

    def wait(self, pred, mark: int, timeout: float) -> dict | None:
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for e in self.events[mark:]:
                    if pred(e):
                        return e
                left = deadline - time.monotonic()
                if left <= 0 or self.proc.poll() is not None:
                    return None
                self.cond.wait(left)

    def alive(self) -> bool:
        return self.proc.poll() is None

    def dest_files(self) -> dict[str, str]:
        return {p.name: p for p in self.dest.iterdir() if p.is_file()}

    def staging_files(self) -> list[str]:
        staging = self.state / "staging"
        if not staging.exists():
            return []
        return [p.name for p in staging.rglob("*") if p.is_file()]

    def stop(self):
        kill_group(self.proc)
        self.log.close()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class Files:
    """Random source files, created once and shared by every pair."""

    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        self.cache: dict[int, tuple[Path, str]] = {}

    def get(self, size: int) -> tuple[Path, str]:
        if size not in self.cache:
            path = self.root / f"sb-{size}.bin"
            h = hashlib.sha256()
            with open(path, "wb") as f:
                left = size
                while left:
                    block = os.urandom(min(left, 1 << 20))
                    f.write(block)
                    h.update(block)
                    left -= len(block)
            self.cache[size] = (path, h.hexdigest())
        return self.cache[size]


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

class Failure(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Failure(msg)


def exit_for(code: str) -> int:
    return int(code[1:])


class PairContext:
    def __init__(self, runner, files, initiator, responder, root: Path):
        self.runner, self.files = runner, files
        self.initiator, self.responder, self.root = initiator, responder, root
        self.client_state = root / "client-state"
        self.server: Server | None = None
        self.extra_servers: list[Server] = []
        self.passed: set[str] = set()
        self.server_peer_id = None  # responder's ID as seen by the client

    def main_server(self) -> Server:
        if self.server is None or not self.server.alive():
            if self.server is not None:
                raise Failure(f"{self.responder} serve exited unexpectedly (code {self.server.proc.returncode})")
            self.server = Server(self.runner, self.responder, self.root, "main", "approve")
        return self.server

    def close(self):
        for s in [self.server, *self.extra_servers]:
            if s is not None:
                s.stop()

    def send(self, state: Path, port: int, file: Path, timeout: float, tag: str, extra=()) -> ToolRun:
        return self.runner.run(self.initiator, ["send", "--state", str(state), "--connect", f"127.0.0.1:{port}",
                                                "--file", str(file), "--test-mode", *extra], timeout, tag)


def sc_pair_approve(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    mark = srv.mark()
    run = ctx.runner.run(ctx.initiator, ["pair-initiate", "--state", str(ctx.client_state), "--connect",
                                         f"127.0.0.1:{srv.pairing_port}", "--decision", "approve", "--test-mode"],
                         sc["timeout"], sc["id"])
    check(not run.timed_out and run.code == 0, f"initiator: {run.summary()}")
    s_paired = srv.wait(lambda e: e.get("event") in ("paired", "pairFailed"), mark, 10)
    s_events = srv.since(mark)
    check(s_paired and s_paired["event"] == "paired", f"responder did not print paired: {s_events}")
    c_sas, s_sas = first(run.events, "sas"), first(s_events, "sas")
    c_paired = first(run.events, "paired")
    check(c_sas and s_sas, f"missing sas (client={c_sas}, server={s_sas})")
    check(c_sas["code"] == s_sas["code"], f"SAS differs: client {c_sas['code']} vs server {s_sas['code']}")
    check(c_paired, f"initiator did not print paired: {run.events}")
    check(c_paired["pskFingerprint"] == s_paired["pskFingerprint"],
          f"pskFingerprint differs: client {c_paired['pskFingerprint']} vs server {s_paired['pskFingerprint']}")
    check(c_paired["peerID"] and s_paired["peerID"] and c_paired["peerID"] != s_paired["peerID"],
          f"peer IDs not distinct: client saw {c_paired['peerID']}, server saw {s_paired['peerID']}")
    check(first(run.events, "done"), "initiator did not print done")
    ctx.server_peer_id, ctx.client_peer_id = c_paired["peerID"], s_paired["peerID"]
    return f"sas={c_sas['code']} fp={c_paired['pskFingerprint']}"


def expect_commit(ctx: PairContext, srv: Server, mark: int, run: ToolRun, sha: str, size: int, before: dict,
                  receiver_required=True) -> list:
    check(not run.timed_out and run.code == 0, f"sender: {run.summary()}")
    committed = first(run.events, "committed")
    check(committed, f"sender printed no committed: {run.events}")
    check(committed["sha256Hex"] == sha and committed["byteCount"] == size,
          f"sender committed mismatch {committed} (want sha {sha}, {size} B)")
    tid = committed["transferID"].lower()
    s_commit = srv.wait(lambda e: e.get("event") == "committed" and str(e.get("transferID", "")).lower() == tid, mark,
                        10 if receiver_required else 1)
    if receiver_required or s_commit:
        check(s_commit, f"receiver printed no committed for {tid}: {srv.since(mark)}")
        check(s_commit["sha256Hex"].lower() == sha, f"receiver sha {s_commit['sha256Hex']} != source {sha}")
    # Sender-side sessionReady peerID (sb-swift, sb-dotnet) must be the responder's ID from pairing.
    ready = first(run.events, "sessionReady")
    check(ready, "sender printed no sessionReady")
    if ready.get("peerID") and ctx.server_peer_id:
        check(ready["peerID"] == ctx.server_peer_id, f"sender sessionReady peerID {ready['peerID']} != paired {ctx.server_peer_id}")
    s_ready = [e for e in srv.since(mark) if e.get("event") == "sessionReady"]
    if s_ready and s_ready[0].get("peerID") and getattr(ctx, "client_peer_id", None):
        check(s_ready[0]["peerID"] == ctx.client_peer_id,
              f"receiver sessionReady peerID {s_ready[0]['peerID']} != paired {ctx.client_peer_id}")
    new = {}
    for _ in range(30):
        new = {k: v for k, v in srv.dest_files().items() if k not in before}
        if new:
            break
        time.sleep(0.1)
    return [tid, new, bool(s_commit)]


def sc_send(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    path, sha = ctx.files.get(sc["bytes"])
    before, mark = srv.dest_files(), srv.mark()
    run = ctx.send(ctx.client_state, srv.session_port, path, sc["timeout"], sc["id"])
    _, new, _ = expect_commit(ctx, srv, mark, run, sha, sc["bytes"], before)
    check(len(new) == 1, f"expected exactly one new file in dest, got {len(new)}")
    got = sha256_file(next(iter(new.values())))
    check(got == sha, f"dest file sha {got} != source {sha}")
    return f"{run.seconds:.1f}s"


def sc_replay(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    path, sha = ctx.files.get(sc["bytes"])
    tid = str(uuid.uuid4()).upper()
    before = srv.dest_files()
    receiver_event = False
    for attempt in (1, 2):
        mark = srv.mark()
        run = ctx.send(ctx.client_state, srv.session_port, path, sc["timeout"], f"{sc['id']}{attempt}", ["--transfer-id", tid])
        # The contract does not require the receiver to print `committed` for a ledger replay
        # (sb-swift does not; sb-dotnet does, with "replayed": true).
        got_tid, _, receiver_event = expect_commit(ctx, srv, mark, run, sha, sc["bytes"], before, receiver_required=attempt == 1)
        check(got_tid == tid.lower(), f"attempt {attempt}: committed transferID {got_tid} != {tid}")
    time.sleep(0.3)
    new = {k: v for k, v in srv.dest_files().items() if k not in before}
    check(len(new) == 1, f"expected one file in dest after replay, got {len(new)}")
    check(sha256_file(next(iter(new.values()))) == sha, "replayed dest file sha differs")
    return f"2x COMMITTED, 1 file (receiver replay event: {'yes' if receiver_event else 'no'})"


def expect_error(ctx, srv: Server, mark: int, run: ToolRun, code: str, before: dict, receiver_required=True) -> str:
    check(not run.timed_out, f"sender: {run.summary()}")
    check(run.error_code() == code, f"sender error {run.error_code()} != {code}: {run.summary()}")
    check(run.code == exit_for(code), f"sender exit {run.code} != {exit_for(code)}")
    check(not first(run.events, "committed"), "sender printed committed on a failure")
    s_err = srv.wait(lambda e: e.get("event") == "error", mark, 10)
    note = ""
    if receiver_required:
        check(s_err, f"receiver printed no error: {srv.since(mark)}")
        check(s_err.get("code") == code, f"receiver error {s_err.get('code')} != {code}")
    else:
        note = f" receiver={s_err.get('code') if s_err else 'none'}"
    check(not [e for e in srv.since(mark) if e.get("event") == "committed"], "receiver committed on a failure")
    new = {k for k in srv.dest_files() if k not in before}
    check(not new, f"{len(new)} new file(s) in dest after a failure")
    staged = []
    for _ in range(30):
        staged = srv.staging_files()
        if not staged:
            break
        time.sleep(0.1)
    check(not staged, f"staging not empty: {len(staged)} file(s)")
    return f"{code} both sides{note}, {run.seconds:.1f}s"


def sc_fault(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    path, _ = ctx.files.get(sc["bytes"])
    before, mark = srv.dest_files(), srv.mark()
    run = ctx.send(ctx.client_state, srv.session_port, path, sc["timeout"], sc["id"], ["--fault", sc["fault"]])
    return expect_error(ctx, srv, mark, run, sc["expect"], before)


def sc_denied_type(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    path, _ = ctx.files.get(sc["bytes"])
    before, mark = srv.dest_files(), srv.mark()
    run = ctx.send(ctx.client_state, srv.session_port, path, sc["timeout"], sc["id"], ["--content-type", sc["contentType"]])
    # The receiver must reject the offer. A sender that refuses locally never offers, so the
    # receiver may print nothing; that is reported in the detail but still a pass.
    return expect_error(ctx, srv, mark, run, sc["expect"], before, receiver_required=False)


def sc_unknown_identity(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    other = Server(ctx.runner, ctx.responder, ctx.root, "other", "approve")
    ctx.extra_servers.append(other)
    stranger = ctx.root / "stranger-state"
    run = ctx.runner.run(ctx.initiator, ["pair-initiate", "--state", str(stranger), "--connect",
                                         f"127.0.0.1:{other.pairing_port}", "--decision", "approve", "--test-mode"],
                         sc["timeout"], sc["id"] + "-pair")
    check(run.code == 0, f"pairing with the other server failed: {run.summary()}")
    path, _ = ctx.files.get(1024)
    before, mark = srv.dest_files(), srv.mark()
    run = ctx.send(stranger, srv.session_port, path, sc["timeout"], sc["id"])
    check(not first(run.events, "sessionReady"), "sender reached sessionReady with a foreign PSK")
    check(not [e for e in srv.since(mark) if e.get("event") == "sessionReady"], "receiver accepted a foreign identity")
    return expect_error(ctx, srv, mark, run, sc["expect"], before)


def sc_pair_reject(ctx: PairContext, sc) -> str:
    srv = Server(ctx.runner, ctx.responder, ctx.root, "reject", "reject")
    ctx.extra_servers.append(srv)
    mark = srv.mark()
    run = ctx.runner.run(ctx.initiator, ["pair-initiate", "--state", str(ctx.root / "reject-client"), "--connect",
                                         f"127.0.0.1:{srv.pairing_port}", "--decision", "approve", "--test-mode"],
                         sc["timeout"], sc["id"])
    code = sc["expect"]
    check(not run.timed_out, f"initiator: {run.summary()}")
    check(run.error_code() == code and run.code == exit_for(code), f"initiator: want {code}: {run.summary()}")
    check(not first(run.events, "paired"), "initiator printed paired on rejection")
    s_fail = srv.wait(lambda e: e.get("event") in ("pairFailed", "paired"), mark, 10)
    check(s_fail and s_fail["event"] == "pairFailed", f"responder did not print pairFailed: {srv.since(mark)}")
    check(s_fail.get("code") == code, f"responder pairFailed {s_fail.get('code')} != {code}")
    return f"{code} both sides"


def unpair_and_check(ctx: PairContext, tool: str, state: Path, peer: str, timeout: float, tag: str) -> ToolRun:
    """Runs `<tool> unpair` and checks its event, exit code and that the state files forgot `peer`."""
    run = ctx.runner.run(tool, ["unpair", "--state", str(state), "--peer", peer], timeout, tag)
    check(not run.timed_out and run.code == 0, f"{tool} unpair: {run.summary()}")
    ev = first(run.events, "unpaired")
    check(ev and ev.get("peerID") == peer, f"{tool} unpair printed {run.events}, want unpaired {peer}")
    for name in ("secrets.json", "trusted-peers.json"):
        path = state / name
        check(not path.exists() or peer not in path.read_text(errors="replace"), f"{tool} unpair left {peer} in {name}")
    return run


def sc_after_unpair(ctx: PairContext, sc) -> str:
    srv = ctx.main_server()
    client_id = getattr(ctx, "client_peer_id", None)
    check(client_id and ctx.server_peer_id, "peer IDs from pair-approve are missing")
    mark = srv.mark()
    # The receiver forgets the sender while `serve` keeps running on the same state directory.
    unpair_and_check(ctx, ctx.responder, srv.state, client_id, sc["timeout"], sc["id"] + "-unpair")
    seen = srv.wait(lambda e: e.get("event") == "unpaired" and e.get("peerID") == client_id, mark, 10)
    check(seen, f"running {ctx.responder} serve did not report the unpair: {srv.since(mark)}")
    path, _ = ctx.files.get(1024)
    before, mark = srv.dest_files(), srv.mark()
    run = ctx.send(ctx.client_state, srv.session_port, path, sc["timeout"], sc["id"])
    check(not first(run.events, "sessionReady"), "sender reached sessionReady after the receiver unpaired it")
    check(not [e for e in srv.since(mark) if e.get("event") == "sessionReady"], "receiver accepted an unpaired sender")
    detail = expect_error(ctx, srv, mark, run, sc["expect"], before)
    # The sender's CLI can unpair too; afterwards it has no trusted peer left.
    unpair_and_check(ctx, ctx.initiator, ctx.client_state, ctx.server_peer_id, sc["timeout"], sc["id"] + "-unpair-sender")
    return f"live unpair picked up by serve; {detail}; sender-side unpair ok"


# `<transferID>.sbpart` as each implementation names its partial files.
PART_NAME = {"swift": str.upper, "dotnet": str.upper, "jvm": str.lower}


def sc_staging_purge(ctx: PairContext, sc) -> str:
    """A fresh `serve` deletes staged partial files older than the 24 h retention, and only those."""
    name = PART_NAME.get(ctx.responder, str.upper)
    planted = {}

    def plant(srv: Server):
        staging = srv.state / "staging"
        staging.mkdir(parents=True, exist_ok=True)
        os.chmod(staging, 0o700)
        old_age = time.time() - sc.get("staleHours", 48) * 3600
        for label in ("stale", "fresh"):
            path = staging / (name(str(uuid.uuid4())) + ".sbpart")
            path.write_bytes(os.urandom(64))
            os.chmod(path, 0o600)
            if label == "stale":
                os.utime(path, (old_age, old_age))
            planted[label] = path

    srv = Server(ctx.runner, ctx.responder, ctx.root, "purge", "approve", before_start=plant)
    ctx.extra_servers.append(srv)
    for _ in range(30):
        if not planted["stale"].exists():
            break
        time.sleep(0.1)
    check(not planted["stale"].exists(), f"{ctx.responder} serve kept a {sc.get('staleHours', 48)} h old .sbpart")
    check(planted["fresh"].exists(), f"{ctx.responder} serve deleted a fresh .sbpart")
    return "stale .sbpart removed at start, fresh one kept"


KINDS = {
    "pair-approve": sc_pair_approve,
    "send": sc_send,
    "replay": sc_replay,
    "fault": sc_fault,
    "denied-type": sc_denied_type,
    "unknown-identity": sc_unknown_identity,
    "pair-reject": sc_pair_reject,
    "after-unpair": sc_after_unpair,
    "staging-purge": sc_staging_purge,
}


def run_pair(runner, files, spec, pair, root: Path, args) -> list[dict]:
    ini, rsp = pair["initiator"], pair["responder"]
    unsupported = {**spec["unsupported"].get(ini, {}), **spec["unsupported"].get(rsp, {})}
    unsupported.pop("comment", None)
    ctx = PairContext(runner, files, ini, rsp, root)
    results = []
    try:
        for sc in spec["scenarios"]:
            sid = sc["id"]
            if args.only and sid not in args.only:
                continue
            res = {"pair": f"{ini}->{rsp}", "scenario": sid}
            start = time.monotonic()
            if sc["kind"] == "skip":
                res.update(status=SKIP, detail=sc["reason"])
            elif sid in unsupported:
                res.update(status=SKIP, detail=unsupported[sid])
            elif sc.get("large") and not args.large:
                res.update(status=SKIP, detail="opt-in: pass --large")
            elif sc.get("requires") and sc["requires"] not in ctx.passed:
                res.update(status=FAIL, detail=f"blocked: {sc['requires']} did not pass")
            else:
                try:
                    detail = KINDS[sc["kind"]](ctx, sc)
                    res.update(status=PASS, detail=detail)
                    ctx.passed.add(sid)
                except (Failure, RuntimeError) as e:
                    res.update(status=FAIL, detail=str(e))
            res["seconds"] = round(time.monotonic() - start, 2)
            results.append(res)
            print(f"  {res['status']:4}  {ini}->{rsp:7} {sid:18} {res['detail'][:160]}", flush=True)
    finally:
        ctx.close()
    return results


def print_table(results: list[dict], pairs: list[str], scenarios: list[str]):
    cell = {(r["pair"], r["scenario"]): r["status"] for r in results}
    w0 = max(len(s) for s in scenarios + ["scenario"])
    widths = [max(len(p), 4) for p in pairs]
    print("\n" + "scenario".ljust(w0) + " | " + " | ".join(p.ljust(w) for p, w in zip(pairs, widths)))
    print("-" * w0 + "-+-" + "-+-".join("-" * w for w in widths))
    for s in scenarios:
        print(s.ljust(w0) + " | " + " | ".join(cell.get((p, s), "-").ljust(w) for p, w in zip(pairs, widths)))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--large", action="store_true", help="include the 100 MiB send")
    ap.add_argument("--self", dest="self_pairs", action="store_true", help="also run jvm->jvm and dotnet->dotnet")
    ap.add_argument("--pairs", help="comma list like swift-dotnet,jvm-swift")
    ap.add_argument("--only", help="comma list of scenario ids (prerequisites run implicitly)")
    ap.add_argument("--swift-bin"), ap.add_argument("--jvm-bin"), ap.add_argument("--dotnet-dll")
    ap.add_argument("--scenarios", default=str(HERE / "scenarios.json"))
    ap.add_argument("--results", default=str(HERE / "results.json"))
    ap.add_argument("--logs", default=str(HERE / "logs"))
    ap.add_argument("--keep", action="store_true", help="keep the temp state/dest directories")
    args = ap.parse_args()
    spec = json.loads(Path(args.scenarios).read_text())
    if args.only:
        only = set(args.only.split(","))
        only |= {s["requires"] for s in spec["scenarios"] if s["id"] in only and s.get("requires")}
        args.only = only
    tools = default_tool_argv(args)
    env = dict(os.environ)
    if "DOTNET_ROOT" not in env and (Path.home() / ".dotnet").exists():
        env["DOTNET_ROOT"] = str(Path.home() / ".dotnet")
    env.setdefault("DOTNET_CLI_TELEMETRY_OPTOUT", "1")
    env.setdefault("DOTNET_NOLOGO", "1")

    pairs = list(spec["pairs"]) + (list(spec["selfPairs"]) if args.self_pairs else [])
    if args.pairs:
        wanted = {p.strip() for p in args.pairs.split(",")}
        pairs = [p for p in pairs + spec["selfPairs"] if f"{p['initiator']}-{p['responder']}" in wanted]
        pairs = list({(p["initiator"], p["responder"]): p for p in pairs}.values())

    logdir = Path(args.logs)
    shutil.rmtree(logdir, ignore_errors=True)
    logdir.mkdir(parents=True)
    tmp = Path(tempfile.mkdtemp(prefix="sb-interop-"))
    runner = Runner(tools, env, logdir)
    files = Files(tmp / "files")
    results: list[dict] = []
    scenario_ids = [s["id"] for s in spec["scenarios"] if not args.only or s["id"] in args.only]
    started = time.time()
    try:
        for pair in pairs:
            ini, rsp = pair["initiator"], pair["responder"]
            name = f"{ini}->{rsp}"
            print(f"== {name} ({pair.get('label', '')})", flush=True)
            missing = [t for t in (ini, rsp) if t not in tools]
            if missing:
                for sid in scenario_ids:
                    results.append({"pair": name, "scenario": sid, "status": FAIL,
                                    "detail": f"tool not built: {', '.join(missing)}"})
                print(f"  FAIL  tool not built: {', '.join(missing)}")
                continue
            pdir = tmp / f"{ini}-{rsp}"
            pdir.mkdir()
            runner.logdir = logdir / f"{ini}-{rsp}"
            runner.logdir.mkdir()
            try:
                results += run_pair(runner, files, spec, pair, pdir, args)
            except Exception as e:  # noqa: BLE001 - a harness crash must still produce results
                results.append({"pair": name, "scenario": "(harness)", "status": FAIL, "detail": f"{type(e).__name__}: {e}"})
                print(f"  FAIL  harness error: {e}")
    finally:
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"kept temp dir {tmp}")

    pair_names = [f"{p['initiator']}->{p['responder']}" for p in pairs]
    print_table(results, pair_names, scenario_ids)
    counts = {s: sum(1 for r in results if r["status"] == s) for s in (PASS, FAIL, SKIP)}
    print(f"\n{counts[PASS]} passed, {counts[FAIL]} failed, {counts[SKIP]} skipped")
    for r in results:
        if r["status"] == FAIL:
            print(f"FAIL {r['pair']} {r['scenario']}: {r['detail']}")
    Path(args.results).write_text(json.dumps({
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "durationSeconds": round(time.time() - started, 1),
        "tools": {k: v for k, v in tools.items()},
        "pairs": pair_names,
        "counts": counts,
        "results": results,
    }, indent=2) + "\n")
    print(f"results: {args.results}\nlogs: {logdir}")
    return 1 if counts[FAIL] else 0


if __name__ == "__main__":
    sys.exit(main())
