#!/usr/bin/env python3
"""Capture exact local Herdr chats and resume them in hc's replacement shell."""

import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import socket
import sqlite3
import stat
import subprocess
import sys
import time
import uuid


RECORD_LIMIT = 256
STATE_LIMIT = 512 * 1024
ADDRESS = re.compile(r"t[0-9a-z]{1,16}\Z")
CHAT_FIELDS = {"provider", "session_id", "cwd", "model", "effort", "executable", "route", "managed"}


class RestoreError(Exception):
    pass


def boot_id():
    reply = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        capture_output=True, text=True, check=True, timeout=2,
    )
    return str(uuid.UUID(reply.stdout.strip()))


def rpc(socket_path, method, params, timeout=4):
    request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as link:
        link.settimeout(timeout)
        link.connect(str(socket_path))
        link.sendall(json.dumps(request).encode() + b"\n")
        with link.makefile("rb") as reader:
            line = reader.readline(8 * 1024 * 1024)
    reply = json.loads(line)
    if not isinstance(reply, dict) or reply.get("id") != 1 or not isinstance(reply.get("result"), dict):
        raise RestoreError("hc did not return the requested metadata")
    return reply["result"]


class Core:
    def __init__(self, socket_path):
        self.path = socket_path

    def identity(self):
        reply = rpc(self.path, "hello", {"generation": 1, "framed": False}, timeout=0.5)
        info = reply.get("core")
        if not isinstance(info, dict) or not safe_text(info.get("id"), 128):
            raise RestoreError("hc core identity is unavailable")
        return info["id"]

    def terminals(self):
        rows = rpc(self.path, "terminal.list", {}).get("terminals")
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise RestoreError("hc terminal list is unavailable")
        return {row["address"]: row for row in rows if local_terminal(row)}

    def terminal(self, address):
        return rpc(self.path, "terminal.get", {"terminal": address}, timeout=0.5)


def safe_text(value, maximum):
    return isinstance(value, str) and 0 < len(value) <= maximum and value.isprintable()


def positive_integer(value):
    return type(value) is int and value > 0


def local_terminal(row):
    address = row.get("address")
    return (row.get("state") == "live" and isinstance(address, str) and ADDRESS.fullmatch(address) is not None
            and positive_integer(row.get("created_ms")))


def pane(row):
    labels = row.get("labels")
    if (not local_terminal(row) or row.get("keep") is not True or not isinstance(labels, dict)
            or not all(safe_text(labels.get(key), 128) for key in ("herdr.space", "herdr.tab"))):
        return None
    return {"address": row["address"], "created_ms": row["created_ms"], "space": labels["herdr.space"], "tab": labels["herdr.tab"]}


def checked_chat(chat):
    if not isinstance(chat, dict):
        raise RestoreError("chat metadata is invalid")
    provider = chat.get("provider")
    if (provider not in ("codex", "claude", "opencode") or not safe_text(chat.get("session_id"), 128)
            or not safe_text(chat.get("cwd"), 4096) or not os.path.isabs(chat["cwd"])
            or not safe_text(chat.get("executable"), 4096) or not os.path.isabs(chat["executable"])
            or not safe_text(chat.get("model"), 256)
            or any(chat.get(key) is not None and not safe_text(chat[key], 128)
                   for key in ("effort", "route", "managed"))):
        raise RestoreError("chat metadata is incomplete")
    return {key: value for key, value in chat.items() if key in CHAT_FIELDS}


def conversation(record):
    return record["chat"]["provider"], record["chat"]["session_id"]


def validate_private(info, mode):
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise RestoreError("restore storage must be private to this account")
    if stat.S_IFMT(info.st_mode) != mode or (mode == stat.S_IFREG and info.st_nlink != 1):
        raise RestoreError("restore storage has an unexpected type")


class State:
    def __init__(self, directory):
        self.directory = directory

    @contextmanager
    def transaction(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            validate_private(os.fstat(directory), stat.S_IFDIR)
            lock = os.open("restore.lock", os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
            try:
                validate_private(os.fstat(lock), stat.S_IFREG)
                fcntl.flock(lock, fcntl.LOCK_EX)
                yield directory, self.read(directory)
            finally:
                os.close(lock)
        finally:
            os.close(directory)

    @staticmethod
    def read(directory):
        try:
            data = os.open("records.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            return {"version": 1, "core": None, "records": {}, "pending": {}}
        with os.fdopen(data, "rb") as handle:
            validate_private(os.fstat(handle.fileno()), stat.S_IFREG)
            content = handle.read(STATE_LIMIT + 1)
        if len(content) > STATE_LIMIT:
            raise RestoreError("restore storage exceeds the state limit")
        value = json.loads(content)
        if not isinstance(value, dict) or value.get("version") != 1 or not safe_text(value.get("core"), 128):
            raise RestoreError("restore storage has an unsupported format")
        value.setdefault("pending", {})
        if any(not isinstance(value.get(key), dict) or len(value[key]) > RECORD_LIMIT for key in ("records", "pending")):
            raise RestoreError("restore storage has an unsupported format")
        for address, record in (*value["records"].items(), *value["pending"].items()):
            if (not ADDRESS.fullmatch(address) or not isinstance(record, dict) or record.get("address") != address
                    or not positive_integer(record.get("created_ms")) or not positive_integer(record.get("pid"))
                    or not all(safe_text(record.get(key), 128) for key in ("space", "tab", "boot"))
                    or type(record.get("seed")) is not bool
                    or (record["seed"] and not valid_argv(record.get("shell")))):
                raise RestoreError("restore storage has invalid pane metadata")
            record["chat"] = checked_chat(record.get("chat"))
        return value

    @staticmethod
    def write(directory, value):
        content = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if len(content) > STATE_LIMIT or any(len(value[key]) > RECORD_LIMIT for key in ("records", "pending")):
            raise RestoreError("restore storage exceeds the state limit")
        temporary = f".records-{uuid.uuid4().hex}.tmp"
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, "records.json", src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass


def same_pane(record, identity):
    return identity is not None and all(record.get(key) == value for key, value in identity.items())


def valid_argv(argv):
    return isinstance(argv, list) and bool(argv) and all(safe_text(arg, 4096) for arg in argv)


def matches_wrapper(argv, command="shell"):
    """Core keeps the configured shell argv even after its process execs."""
    return (isinstance(argv, list) and len(argv) >= 7 and argv[1] == os.path.abspath(__file__)
            and argv[2] == "--state-dir" and argv[4] == "--socket" and argv[6] == command)


def old_record_pending(row):
    foreground = row.get("foreground") or {}
    if not row.get("pid"):
        return True
    argv = row.get("argv")
    if not matches_wrapper(argv):
        return False
    # A stale prior-boot capture can wait for this wrapper's claim. Once the
    # fallback shell or a different program is foreground, the wrapper is done.
    foreground_argv = foreground.get("argv")
    return (foreground.get("pid") != row["pid"] or foreground_argv is None
            or (len(foreground_argv) >= 2 and foreground_argv[1] == argv[1]))


def observed_foreground(row):
    foreground = row.get("foreground") or {}
    if positive_integer(foreground.get("pid")) and safe_text(foreground.get("name"), 128):
        return {"foreground_pid": foreground["pid"], "foreground_program": foreground["name"]}
    return {}


def explicit_shell(row, shell):
    foreground = row.get("foreground") or {}
    return (row.get("argv") == shell and positive_integer(row.get("pid"))
            and foreground.get("pid") == row["pid"] and isinstance(foreground.get("name"), str)
            and os.path.basename(foreground["name"]).lstrip("-") == os.path.basename(shell[0]))


def starting_explicit_recovery(row, shell):
    foreground = row.get("foreground") or {}
    return (row.get("argv") == shell and row.get("pid") == foreground.get("pid")
            and matches_wrapper(foreground.get("argv"), "recover"))


def snapshot(core, state, boot, capture, transient=()):
    started = time.monotonic_ns()
    identity = core.identity()
    rows = core.terminals()
    observed = {}
    unavailable = set()
    active = defaultdict(set)
    for address, row in rows.items():
        if positive_integer(row.get("pid")):
            try:
                chat = capture(row, core_id=identity)
            except transient:
                unavailable.add(address)
                continue
            if chat is not None:
                try:
                    chat = checked_chat(chat)
                except RestoreError:
                    continue
                active[(chat["provider"], chat["session_id"])].add(address)
                target = pane(row)
                if target is not None:
                    observed[address] = {**target, **observed_foreground(row), "boot": boot,
                                         "pid": row["pid"], "seed": False, "chat": chat}
    if core.identity() != identity:
        raise RestoreError("hc changed during observation")

    with state.transaction() as (directory, previous):
        if previous.get("scan_boot") == boot and previous.get("scan_ns", 0) > started:
            return len(previous["records"])
        records = {}
        pending = {}
        if previous["core"] == identity:
            pending = previous["pending"].copy()
            for address, record in previous["records"].items():
                row = rows.get(address, {})
                if address in observed or not same_pane(record, pane(row)):
                    continue
                if record["boot"] != boot and old_record_pending(row):
                    records[address] = record
                elif (record["seed"] and record["boot"] == boot and row.get("pid") == record["pid"]
                      and (explicit_shell(row, record["shell"]) or starting_explicit_recovery(row, record["shell"]))):
                    records[address] = record
                elif record["boot"] == boot and address in unavailable and row.get("pid") == record["pid"]:
                    foreground = observed_foreground(row)
                    if foreground and all(record.get(key) == item for key, item in foreground.items()):
                        records[address] = record
        for address, recorded in list(pending.items()):
            locations = active[conversation(recorded)]
            if address in locations and recorded["created_ms"] == rows[address]["created_ms"]:
                del pending[address]
            elif locations or address in observed:
                pending[address] = {**recorded, "blocked": True}
        records.update(observed)
        for address, record in records.items():
            active[conversation(record)].add(address)
        for address, record in pending.items():
            if not record.get("blocked"):
                active[conversation(record)].add(address)
        records = {address: record for address, record in records.items() if len(active[conversation(record)]) == 1}
        if previous["core"] != identity or records != previous["records"] or pending != previous["pending"]:
            state.write(directory, {"version": 1, "core": identity, "scan_boot": boot, "scan_ns": started,
                                    "records": records, "pending": pending})
        return len(records)


def codex_seed_matches(core_socket, record, chat, home):
    if chat["provider"] != "codex":
        return False
    try:
        session_id = str(uuid.UUID(chat["session_id"]))
    except ValueError:
        return False
    if session_id != chat["session_id"].lower():
        return False

    from herdr_chat_capture import codex_record

    codex = home / ".codex"
    directory = os.open(codex / "shell_snapshots", os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW)
    snapshots = []
    try:
        current_ms = time.time_ns() // 1_000_000
        pattern = re.compile(rf"{re.escape(session_id)}\.(\d{{19}})\.sh\Z")
        for name in os.listdir(directory):
            match = pattern.fullmatch(name)
            if match is None or not record["created_ms"] <= int(match[1]) // 1_000_000 <= current_ms:
                continue
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            with os.fdopen(fd, "rb") as handle:
                info = os.fstat(handle.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_nlink != 1 or info.st_mode & 0o022):
                    return False
                content = handle.read(STATE_LIMIT + 1)
            if len(content) > STATE_LIMIT:
                return False
            values = {}
            for line in content.decode().splitlines():
                for key in ("HC_TERMINAL_ID", "HC_TERMINAL_SOCKET"):
                    if line.startswith(f"export {key}="):
                        words = shlex.split(line, comments=False)
                        if len(words) != 2 or key in values:
                            return False
                        values[key] = words[1].split("=", 1)[1]
            snapshots.append(values)
    finally:
        os.close(directory)
    expected = {"HC_TERMINAL_ID": record["address"], "HC_TERMINAL_SOCKET": str(core_socket)}
    if not snapshots or not all(snapshot == expected for snapshot in snapshots):
        return False
    saved = codex_record(codex / "state_5.sqlite", session_id, str(Path(chat["cwd"]).resolve(strict=True)))
    return saved is not None and saved[1:] == (chat["model"], chat.get("effort"))


def seed(core, state, boot, entries, shell, home=None):
    if not isinstance(entries, list) or len(entries) > RECORD_LIMIT:
        raise RestoreError("seed input must be a bounded JSON array")
    identity = core.identity()
    rows = core.terminals()
    prepared = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("address"), str):
            raise RestoreError("seed input has invalid pane metadata")
        address = entry["address"]
        row = rows.get(address, {})
        expected = pane(row)
        if address in prepared or not same_pane(entry, expected) or not explicit_shell(row, shell):
            raise RestoreError("seed requires the exact kept pane and its shell")
        chat = checked_chat(entry.get("chat"))
        if (not os.path.samefile(chat["cwd"], row["cwd"])
                and not codex_seed_matches(core.path, expected, chat, home or Path.home())):
            raise RestoreError("seed working directory does not match its pane")
        prepared[address] = {**expected, "boot": boot, "pid": row["pid"], "seed": True, "shell": shell, "chat": chat}

    if core.identity() != identity:
        raise RestoreError("hc identity changed during seeding")
    for address, record in prepared.items():
        current = core.terminal(address)
        if not same_pane(record, pane(current)) or current.get("pid") != record["pid"] or not explicit_shell(current, shell):
            raise RestoreError("a seeded pane changed before it was recorded")
    with state.transaction() as (directory, value):
        if value["core"] not in (None, identity):
            raise RestoreError("hc identity changed during seeding")
        records = value["records"] | prepared
        all_records = [*records.values(), *(record for record in value["pending"].values() if not record.get("blocked"))]
        if prepared.keys() & value["pending"].keys() or len(set(map(conversation, all_records))) != len(all_records):
            raise RestoreError("one conversation cannot be seeded into multiple panes")
        state.write(directory, {**value, "core": identity, "records": records})
    return len(prepared)


def claim(core, state, boot, address, pid, explicit, fallback=None):
    # New shells should reach their prompt promptly. Peek before making any RPC.
    if not (state.directory / "records.json").exists():
        return None
    with state.transaction() as (_, value):
        record = value["records"].get(address)
        retry = explicit and record is None
        if retry:
            record = value["pending"].get(address)
        if record is None or record.get("blocked"):
            return None
        if not retry and explicit and not (record["seed"] and record["boot"] == boot and record["pid"] == pid):
            return None
        if not explicit and record["boot"] == boot:
            return None

    # The wrapper can run before the holder's spawned acknowledgement sets pid.
    deadline = time.monotonic() + 1.5
    identity = core.identity()
    while True:
        row = core.terminal(address)
        if row.get("pid") is not None or time.monotonic() >= deadline:
            break
        time.sleep(0.025)

    with state.transaction() as (directory, value):
        current = value["pending" if retry else "records"].get(address)
        all_records = [*value["records"].values(), *(item for item in value["pending"].values() if not item.get("blocked"))]
        if (identity != value["core"] or record != current or not same_pane(record, pane(row))
                or row.get("pid") != pid
                or sum(conversation(item) == conversation(record) for item in all_records) != 1):
            return None
        configured_wrapper = matches_wrapper(row.get("argv"))
        if retry and not (configured_wrapper or (fallback and row.get("argv") == fallback)):
            return None
        if explicit:
            foreground = row.get("foreground") or {}
            args = foreground.get("argv") or []
            shell = fallback or record.get("shell")
            has_shell = shell and foreground.get("name", "").lstrip("-") == os.path.basename(shell[0])
            has_wrapper = len(args) >= 2 and args[1] == os.path.abspath(__file__)
            if foreground.get("pid") != pid or not (has_shell or has_wrapper):
                return None
        if not retry:
            if (explicit and record.get("shell") != row.get("argv")) or (not explicit and not configured_wrapper):
                return None
            value["pending"][address] = value["records"].pop(address)
            state.write(directory, value)
        return record["chat"]


def exec_restore(argv, chat, fallback):
    directory = chat["cwd"]
    os.chdir(directory)
    provider_bin = str(Path(chat["executable"]).parent)
    path = provider_bin + os.pathsep + os.environ.get("PATH", os.defpath)
    env = {**os.environ, "PWD": directory, "PATH": path}
    if fallback == ["/bin/zsh", "-l"]:
        # Keep the login shell as the pane's root. Native zsh job control gives
        # the CLI the foreground and brings the shell back after it exits.
        command = 'restore_directory=$1; shift; cd -- "$restore_directory" && command "$@"; exec /bin/zsh -l'
        argv = ["/bin/zsh", "-ilc", command, "herdr-chat-restore", directory, *argv]
    os.execve(argv[0], argv, env)


def shell_entry(core, state, fallback, explicit):
    address = os.environ.get("HC_TERMINAL_ID", "")
    if str(core.path) == os.environ.get("HC_TERMINAL_SOCKET") and ADDRESS.fullmatch(address):
        try:
            chat = claim(core, state, boot_id(), address, os.getpid(), explicit, fallback)
            if chat is not None:
                from herdr_chat_capture import resume_argv

                argv = resume_argv(chat)
                if valid_argv(argv) and os.path.isabs(argv[0]):
                    exec_restore(argv, chat, fallback)
                print("Herdr chat restore could not validate the saved launch.", file=sys.stderr)
        except (OSError, ValueError, KeyError, RestoreError, subprocess.SubprocessError, ImportError):
            print("Herdr chat restore could not verify this pane.", file=sys.stderr)
    os.execvp(fallback[0], fallback)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("command", choices=("watch", "snapshot", "status", "seed", "shell", "recover"))
    parser.add_argument("shell", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.state_dir.is_absolute() or not args.socket.is_absolute():
        parser.error("state and socket paths must be absolute")
    shell = args.shell[1:] if args.shell[:1] == ["--"] else args.shell
    if not shell:
        shell = [pwd.getpwuid(os.getuid()).pw_shell or "/bin/sh", "-l"]
    core, state = Core(args.socket), State(args.state_dir)
    if args.command in ("shell", "recover"):
        shell_entry(core, state, shell, explicit=args.command == "recover")
        return
    try:
        if args.command == "status":
            with state.transaction() as (_, value):
                summary = Counter("seeded" if record["seed"] else "captured" for record in value["records"].values())
                print(json.dumps({"captured": summary["captured"], "seeded": summary["seeded"], "pending": len(value["pending"])}))
            return
        boot = boot_id()
        if args.command == "seed":
            payload = sys.stdin.buffer.read(STATE_LIMIT + 1)
            if len(payload) > STATE_LIMIT:
                raise RestoreError("seed input exceeds the state limit")
            print(f"Seeded {seed(core, state, boot, json.loads(payload), shell)} exact pane records.")
            return
        from herdr_chat_capture import CaptureUnavailable, capture_chat

        if args.command == "snapshot":
            print(f"Saved {snapshot(core, state, boot, capture_chat, CaptureUnavailable)} exact pane records.")
            return
        healthy = True
        while True:
            try:
                snapshot(core, state, boot, capture_chat, CaptureUnavailable)
                healthy = True
            except (OSError, ValueError, KeyError, RestoreError, subprocess.SubprocessError):
                if healthy:
                    print("Herdr chat restore is waiting for readable core and state metadata.", file=sys.stderr)
                    healthy = False
            time.sleep(2)
    except (OSError, ValueError, KeyError, RestoreError, sqlite3.Error, subprocess.SubprocessError, ImportError):
        print("Herdr chat restore could not complete the requested operation.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
