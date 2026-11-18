"""Exact provider metadata for local hc recovery. Never store process arguments or chat text."""

import ctypes
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import time
from contextlib import closing

UUID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", re.I)
SESSION = re.compile(r"ses[A-Za-z0-9_-]{1,100}")
MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:+/-]{0,177}")
PANE = re.compile(r"t[0-9a-z]+")
FOLDER = re.compile(r"[0-9a-f]{16}")
CODEX_EFFORT = frozenset(("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"))
CLAUDE_EFFORT = frozenset(("low", "medium", "high", "xhigh", "max"))
SHELLS = frozenset(("bash", "fish", "sh", "zsh", "nu"))
PROVIDER_APPS = {"codex": {"codex"}, "claude": {"claude", "claude-code"}, "opencode": {"opencode"}}
OPENCODE_COMMANDS = frozenset(("serve", "service", "api", "run", "acp", "models", "auth", "debug", "reload", "plugin", "session", "stats", "pair", "upgrade", "update", "uninstall"))
CODEX_FOOTER = re.compile(r"(gpt-[0-9a-z._-]+) (none|minimal|low|medium|high|xhigh|extra high|max|ultra)\s+·\s+.+", re.I)


class CaptureUnavailable(Exception):
    """A provider probe could not complete; this is distinct from a changed chat."""


def matches(pattern, value):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def positive(value):
    return type(value) is int and value > 0


def directory(value):
    if not isinstance(value, str) or not value.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in value):
        return None
    path = Path(value)
    return str(path.resolve(strict=True)) if path.is_dir() else None


def run_read(argv):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=4, check=False)
    return result.stdout if result.returncode == 0 else b""


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            return None
        contents = file.read(65537)
        value = json.loads(contents) if len(contents) <= 65536 else None
        return value if isinstance(value, dict) else None


def sqlite_read(path, sql, args):
    if not path.is_file():
        return []
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.5)) as db:
        return db.execute(sql, args).fetchall()


def provider_args(row):
    foreground = row.get("foreground") or {}
    argv = foreground.get("argv") or []
    if not argv or not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        return None, []
    entry = Path(argv[0]).name
    if entry in ("node", "nodejs") and len(argv) > 1 and not argv[1].startswith("-"):
        argv = argv[1:]
        entry = Path(argv[0]).name
    entry = entry.removesuffix(".js").removesuffix(".exe")
    if entry not in PROVIDER_APPS:
        return None, []
    first = argv[1] if len(argv) > 1 else None
    if entry == "codex" and first in ("app-server", "remote-control", "exec-server", "exec", "e"):
        return None, []
    if entry == "opencode" and first in OPENCODE_COMMANDS:
        return None, []
    if entry == "claude" and any(a in argv for a in ("--print", "-p", "--bare", "--fork-session", "--no-session-persistence")):
        return None, []
    return entry, argv


def flag(args, *names):
    values = []
    for position, arg in enumerate(args[1:], 1):
        if arg in names and position + 1 < len(args):
            values.append(args[position+1])
        elif arg.partition("=")[0] in names and "=" in arg:
            values.append(arg.partition("=")[2])
    return values[0] if len(values) == 1 else None


def process_start(pid):
    # Invoking ps with only a numeric PID and the start-time column keeps argv private.
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3,
                            check=False, env={"LC_ALL": "C"})
    return int(time.mktime(time.strptime(result.stdout.decode().strip(), "%a %b %d %H:%M:%S %Y"))) if result.returncode == 0 else None


def process_environment(pid, keys):
    """Read a small allowlist of routing settings from Darwin; never retain other entries."""
    if sys.platform != "darwin":
        return None
    libc = ctypes.CDLL(None)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) or not 4 < size.value <= 4 * 1024 * 1024:
        return None
    data = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0):
        return None
    blob = data.raw[:size.value]
    count = int.from_bytes(blob[:4], sys.byteorder, signed=True)
    if not 0 < count < 4096:
        return None
    start = blob.find(b"\0", 4)
    if start < 4:
        return None
    entries = blob[start:].lstrip(b"\0").split(b"\0")
    if len(entries) <= count:
        return None
    env = {}
    for entry in entries[count:]:
        key, separator, value = entry.partition(b"=")
        if separator and key in keys:
            env[key.decode("ascii")] = value.decode("utf-8")
    return env


def executable(provider, home, argv):
    candidates = (home / ".opencode/bin/opencode",) if provider == "opencode" else (home / ".local/bin" / provider,)
    for candidate in (*candidates, Path(argv[0])):
        if candidate.is_absolute() and candidate.is_file() and os.access(candidate, os.X_OK):
            if candidate.name in (provider, provider + ".exe", provider + ".js"):
                return str(candidate)
    return None


def result(provider, session_id, cwd, model, effort, command, **extra):
    return {"provider": provider, "session_id": session_id, "cwd": cwd,
            "model": model, "effort": effort, "executable": command, **extra}


def codex_record(path, session_id, cwd):
    rows = sqlite_read(path, "SELECT rollout_path,cwd,model,reasoning_effort,model_provider FROM threads WHERE id=? AND archived=0", (session_id,))
    if len(rows) != 1:
        return None
    rollout, recorded_cwd, model, effort, provider = rows[0]
    if directory(recorded_cwd) != cwd or provider != "openai" or not Path(rollout).is_file():
        return None
    return rollout, model, effort


def codex_capture(home, row, argv, pid, cwd, status):
    env = process_environment(pid, {b"CODEX_HOME"})
    if env is None or env.get("CODEX_HOME", str(home / ".codex")) != str(home / ".codex"):
        return None
    if flag(argv, "--remote", "--local-provider") is not None or any(a in argv for a in ("--oss", "--ephemeral", "--fork")):
        return None
    root = home / ".codex"
    database = root / "state_5.sqlite"
    opened = set()
    files = run_read(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-u", str(os.getuid()), "-Ffan"])
    writable = False
    for line in files.splitlines():
        if line.startswith(b"f"):
            writable = False
        elif line in (b"aw", b"au"):
            writable = True
        elif writable and line.startswith(b"n"):
            path = Path(os.fsdecode(line[1:]))
            if path.is_relative_to(root / "sessions") and path.name.startswith("rollout-"):
                session_id = path.stem[-36:]
                if matches(UUID, session_id):
                    opened.add((session_id, str(path)))
    rows = []
    if opened:
        for session_id, path in opened:
            record = codex_record(database, session_id, cwd)
            if record and path == record[0]:
                rows.append((session_id, *record[1:]))
    else:
        started = process_start(pid)
        if started is None:
            return None
        # Codex records its actual PID as part of the process fingerprint. Bound
        # the selection to the current birth time so a reused PID cannot match.
        ids = sqlite_read(root / "logs_2.sqlite", """
            SELECT DISTINCT process_uuid,thread_id FROM logs
            WHERE ts>=? AND process_uuid LIKE ? AND thread_id IS NOT NULL LIMIT 257
            """, (started, f"pif:{pid}:%"))
        if len(ids) > 256 or len({fingerprint for fingerprint, _ in ids}) != 1:
            return None
        for _, session_id in ids:
            if not matches(UUID, session_id):
                continue
            roots = sqlite_read(database, "SELECT id FROM threads WHERE id=? AND source IN ('cli','app_server') AND (thread_source IS NULL OR thread_source='user')", (session_id,))
            record = codex_record(database, session_id, cwd) if roots else None
            if record:
                rows.append((session_id, *record[1:]))
    if len(rows) != 1:
        return None
    session_id, stored_model, stored_effort = rows[0]
    model, effort = codex_settings(home, row, status, stored_model, stored_effort)
    command = executable("codex", home, argv)
    return result("codex", session_id, cwd, model, effort, command) if command and matches(MODEL, model) and effort in CODEX_EFFORT else None


def codex_footer(reply):
    if reply.get("how") != "screen" or reply.get("complete") is not True or not isinstance(reply.get("text"), str):
        return None, None
    lines = [line.strip() for line in reply["text"].splitlines() if line.strip()]
    for index in range(len(lines) - 2, max(-1, len(lines) - 6), -1):
        if not lines[index].startswith("›"):
            continue
        found = CODEX_FOOTER.fullmatch(lines[index+1])
        if found and not any(line.startswith(("›", "•", "❯")) for line in lines[index+2:]):
            model, effort = (value.lower() for value in found.groups())
            return model, "xhigh" if effort == "extra high" else effort
    return None, None


def codex_settings(home, row, status, stored_model, stored_effort):
    model, effort = status.get("model"), status.get("reasoning_effort")
    if not model or not effort:
        try:
            reply = hc_rpc(home, "terminal.read", {"terminal": row["address"], "lines": 0})
            latest = get_terminal(home, row["address"])
            if terminal_identity(latest) == terminal_identity(row):
                footer_model, footer_effort = codex_footer(reply)
                model, effort = model or footer_model, effort or footer_effort
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return model or stored_model, effort or stored_effort


def claude_transcript(root, session_id, cwd):
    paths = list((root / "projects").glob("*/" + session_id + ".jsonl"))
    if len(paths) != 1 or paths[0].is_symlink() or not paths[0].is_file():
        return None, False
    # Use only main-chat metadata; the tail is bounded and never leaves memory.
    model = None
    found = False
    with paths[0].open("rb") as file:
        length = file.seek(0, os.SEEK_END)
        begin = max(0, length - 2 * 1024 * 1024)
        file.seek(begin)
        lines = file.read(2 * 1024 * 1024).splitlines()
    for raw in reversed(lines[bool(begin):]):
        try:
            data = json.loads(raw)
        except (ValueError, UnicodeError):
            continue
        if not isinstance(data, dict) or data.get("sessionId") != session_id or data.get("isSidechain") is True or directory(data.get("cwd")) != cwd:
            continue
        found = True
        if data.get("type") == "assistant" and not data.get("isApiErrorMessage"):
            model = (data.get("message") or {}).get("model")
            if matches(MODEL, model) and not model.startswith("<"):
                break
            model = None
    return model, found


def claude_capture(home, row, argv, pid, cwd, status):
    root = home / ".claude"
    record = read_private(root / "sessions" / f"{pid}.json")
    if not record or record.get("pid") != pid or directory(record.get("cwd")) != cwd:
        return None
    started = process_start(pid)
    stamp = record.get("startedAt")
    if started is None or not positive(stamp) or stamp < started * 1000 or stamp // 1000 > time.time() + 2:
        return None
    session_id = record.get("sessionId")
    if not matches(UUID, session_id):
        return None
    env = process_environment(pid, {b"ANTHROPIC_BASE_URL", b"CLAUDE_CONFIG_DIR", b"CLAUDE_CODE_EFFORT_LEVEL",
                                    b"CLAUDE_CODE_USE_BEDROCK", b"CLAUDE_CODE_USE_VERTEX", b"CLAUDE_CODE_USE_FOUNDRY"})
    if env is None or env.get("CLAUDE_CONFIG_DIR", str(root)) != str(root):
        return None
    if any(env.get(k, "").lower() not in ("", "0", "false") for k in ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")):
        return None
    base = env.get("ANTHROPIC_BASE_URL", "").rstrip("/")
    route = {}
    if base == "https://api.orcarouter.ai/v1" or base == "https://api.orcarouter.ai":
        route = {"route": "orca-claude"}
    elif base not in ("", "https://api.anthropic.com"):
        return None
    stored_model, exists = claude_transcript(root, session_id, cwd)
    if not exists:
        return None
    model = status.get("model") or record.get("model") or stored_model or flag(argv, "--model")
    effort = status.get("reasoning_effort") or record.get("effort") or flag(argv, "--effort") or env.get("CLAUDE_CODE_EFFORT_LEVEL")
    command = executable("claude", home, argv)
    return result("claude", session_id, cwd, model, effort, command, **route) if command and matches(MODEL, model) and (effort is None or effort in CLAUDE_EFFORT) else None


def opencode_record(database, session_id, cwd):
    # A TUI can switch root sessions without replacing its process. Refuse a
    # store or directory that admits more than the one explicit root.
    rows = sqlite_read(database, "SELECT id,model FROM session_v2 WHERE directory=? AND parent_id IS NULL AND time_archived IS NULL LIMIT 2", (cwd,))
    if len(rows) != 1 or rows[0][0] != session_id:
        return None
    model = json.loads(rows[0][1] or "{}")
    if isinstance(model, dict) and matches(MODEL, model.get("providerID")) and matches(MODEL, model.get("id")):
        if model.get("variant") is None or matches(MODEL, model["variant"]):
            return model
    return None


def opencode_capture(home, argv, pid, cwd):
    session_id = flag(argv, "--session", "-s")
    if not matches(SESSION, session_id) or flag(argv, "--server") is not None:
        return None
    env = process_environment(pid, {b"XDG_DATA_HOME", b"OPENCODE_CONFIG", b"OPENCODE_CONFIG_CONTENT"})
    if env is None or env.get("OPENCODE_CONFIG") or "OPENCODE_CONFIG_CONTENT" in env:
        return None
    root = home / ".local/share"
    if env.get("XDG_DATA_HOME", str(root)) != str(root):
        return None
    model = opencode_record(root / "opencode/opencode.db", session_id, cwd)
    command = executable("opencode", home, argv)
    if not model or not command:
        return None
    return result("opencode", session_id, cwd, model["providerID"] + "/" + model["id"], model.get("variant"), command)


def managed_folder(home, name, kind="OrcaOpenCode"):
    path = home / "Library/Application Support/Herdr HUD" / kind / name
    for candidate in (path.parent, path):
        info = candidate.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return None
    return path


def orca_spec(home, name):
    if not matches(FOLDER, name):
        return None
    path = managed_folder(home, name)
    if path is None:
        return None
    descriptor = read_private(path / "session.json")
    spec = read_private(path / "launch.json")
    if not spec or not descriptor:
        return None
    nonce = descriptor.get("nonce")
    session_id = descriptor.get("sessionID")
    model_id = descriptor.get("modelID")
    provider_id = descriptor.get("providerID")
    port = descriptor.get("port")
    cwd = directory(descriptor.get("directory"))
    command = descriptor.get("opencode")
    if (descriptor.get("version") != 1 or descriptor.get("folder") != name or not matches(UUID, nonce)
        or nonce.replace("-", "")[:16] != name or provider_id != "herdr-orca-" + nonce.replace("-", "")
        or not matches(SESSION, session_id) or not matches(MODEL, model_id) or not positive(port) or not 1024 <= port <= 65535
        or descriptor.get("endpoint") != f"http://127.0.0.1:{port}" or cwd is None or not command
        or executable("opencode", home, [command]) != command):
        return None
    if any(spec.get(key) != descriptor.get(key) for key in ("nonce", "sessionID", "port", "directory", "opencode")):
        return None
    config = spec.get("config") or {}
    providers = config.get("providers") or {}
    provider = providers.get(provider_id) or {}
    if (config.get("model") != provider_id + "/" + model_id or set(providers) != {provider_id}
        or set(provider.get("models") or {}) != {model_id} or provider.get("package") != "@opencode/ai/providers/openai-compatible"
        or provider.get("settings") != {"baseURL": "https://api.orcarouter.ai/v1", "apiKey": "{env:ORCAROUTER_API_KEY}"}):
        return None
    metadata = opencode_record(path / "data/opencode/opencode.db", session_id, cwd)
    if not metadata or metadata.get("id") != model_id or metadata.get("providerID") != provider_id:
        return None
    return path, descriptor, metadata


def terminal_identity(row):
    foreground = row.get("foreground") or {}
    identity = {"address": row.get("address"), "created_ms": row.get("created_ms"), "pid": row.get("pid"), "foreground_pid": foreground.get("pid")}
    if row.get("state") == "live" and matches(PANE, identity["address"]) and all(positive(identity[k]) for k in ("created_ms", "pid", "foreground_pid")):
        return identity
    return None


def managed_capture(row, home, core_id, parked=False):
    labels = row.get("labels") or {}
    nonce = labels.get("hud.orca.owner")
    if labels.get("hud.orca.role") != "tui" or not matches(UUID, nonce):
        return None
    name = nonce.replace("-", "")[:16]
    binding = orca_spec(home, name)
    if not binding:
        return None
    _, descriptor, metadata = binding
    if descriptor.get("nonce") != nonce:
        return None
    prior = descriptor.get("tui") or {}
    actual = terminal_identity(row)
    foreground = row.get("foreground") or {}
    cwd = directory(foreground.get("cwd"))
    if not actual or cwd != descriptor["directory"]:
        return None
    expected = [descriptor["opencode"], "--server", descriptor["endpoint"], "--session", descriptor["sessionID"], cwd]
    if parked:
        args = foreground.get("argv") or []
        if (not args or Path(args[0]).name.lstrip("-") not in SHELLS
            or any(actual[k] != prior.get(k) for k in ("address", "created_ms"))):
            return None
    elif actual != prior or core_id != descriptor.get("coreID") or foreground.get("argv") != expected:
        return None
    return result("opencode", descriptor["sessionID"], cwd, descriptor["modelID"], metadata.get("variant"), descriptor["opencode"], managed=name)


def capture_parked_chat(row, home=Path.home()):
    """Adopt a managed descriptor only for its original retained shell pane."""
    try:
        if (row.get("labels") or {}).get("hud.codex.role") == "tui":
            return codex_managed_capture(row, home, None, parked=True)
        return managed_capture(row, home, None, parked=True)
    except (OSError, ValueError, TypeError, AttributeError, sqlite3.Error, subprocess.SubprocessError):
        return None


def capture_chat(row, home=Path.home(), core_id=None):
    """Return the exact local foreground conversation or None when evidence is missing."""
    try:
        identity = terminal_identity(row)
        if not identity:
            return None
        labels = row.get("labels") or {}
        if any(labels.get(name) == "transport" for name in ("hud.orca.role", "hud.codex.role")):
            return None
        foreground = row["foreground"]
        cwd = directory(foreground.get("cwd"))
        provider, argv = provider_args(row)
        if not cwd or provider is None:
            return None
        pid = identity["foreground_pid"]
        status = row.get("status") or {}
        status = status if status.get("app") in PROVIDER_APPS[provider] else {}
        if provider == "codex":
            if labels.get("hud.codex.role") == "tui":
                return codex_managed_capture(row, home, core_id)
            return codex_capture(home, row, argv, pid, cwd, status)
        if provider == "claude":
            return claude_capture(home, row, argv, pid, cwd, status)
        if labels.get("hud.orca.role") == "tui":
            return managed_capture(row, home, core_id)
        return opencode_capture(home, argv, pid, cwd)
    except (FileNotFoundError, ValueError, TypeError, AttributeError):
        return None
    except (OSError, sqlite3.Error, subprocess.SubprocessError):
        raise CaptureUnavailable("Local provider metadata is temporarily unavailable") from None


def resume_argv(chat, home=Path.home()):
    """Construct fixed, prompt-free provider arguments from a validated recovery record."""
    try:
        provider = chat.get("provider")
        session_id = chat.get("session_id")
        cwd = directory(chat.get("cwd"))
        command = chat.get("executable")
        model = chat.get("model")
        effort = chat.get("effort")
        if provider not in PROVIDER_APPS or not cwd or not matches(MODEL, model) or not isinstance(command, str) or executable(provider, home, [command]) != command:
            return None
        if not matches(SESSION if provider == "opencode" else UUID, session_id):
            return None
        if provider == "codex":
            if effort not in CODEX_EFFORT or not codex_record(home / ".codex/state_5.sqlite", session_id, cwd):
                return None
            if chat.get("managed") is not None:
                binding = codex_spec(home, chat["managed"])
                if not binding or not native_codex_executable(command) or binding[1]["threadID"] != session_id or binding[1]["directory"] != cwd:
                    return None
                return ["/usr/bin/python3", str(Path(__file__).resolve()), "resume-managed-codex", chat["managed"], model, effort]
            return [command, "resume", session_id, "--no-daemon", "--model", model, "--config", 'model_reasoning_effort="' + effort + '"']
        if provider == "claude":
            if (effort is not None and effort not in CLAUDE_EFFORT) or not claude_transcript(home / ".claude", session_id, cwd)[1]:
                return None
            args = ["--resume", session_id, "--model", model]
            if effort is not None:
                args += ["--effort", effort]
            if chat.get("route") == "orca-claude":
                return ["/bin/zsh", "-lic", 'orca-claude "$@"', "herdr-recovery", *args]
            return [command, *args] if chat.get("route") is None else None
        managed = chat.get("managed")
        if managed is not None:
            binding = orca_spec(home, managed)
            if not binding or any(binding[1][k] != v for k, v in (("sessionID", session_id), ("directory", cwd), ("modelID", model), ("opencode", command))) or binding[2].get("variant") != effort:
                return None
            return ["/usr/bin/python3", str(Path(__file__).resolve()), "resume-managed-opencode", managed]
        stored = opencode_record(home / ".local/share/opencode/opencode.db", session_id, cwd)
        if not stored or stored["providerID"] + "/" + stored["id"] != model or stored.get("variant") != effort:
            return None
        return [command, "--session", session_id, cwd]
    except (OSError, ValueError, TypeError, AttributeError, sqlite3.Error):
        return None


def hc_rpc(home, method, params):
    binary = home / ".local/bin/hc"
    wire = json.dumps({"jsonrpc": "2.0", "id": "recovery", "method": method, "params": params}) + "\n"
    process = subprocess.run([str(binary), "connect", "--session", "default"], input=wire.encode(),
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=False)
    replies = [json.loads(line) for line in process.stdout.splitlines()]
    usable = [reply["result"] for reply in replies if reply.get("id") == "recovery" and isinstance(reply.get("result"), dict)]
    if process.returncode or len(usable) != 1:
        raise ValueError("No valid Herdr acknowledgement")
    return usable[0]


def current_core(home):
    hello = hc_rpc(home, "hello", {"generation": 1, "framed": False})
    core = (hello.get("core") or {}).get("id")
    if hello.get("generation") != 1 or hello.get("framed") is not False or not isinstance(core, str) or not core:
        raise ValueError("Cannot identify the local Herdr core")
    return core


def get_terminal(home, pane):
    if not matches(PANE, pane):
        raise ValueError("Invalid local pane address")
    return hc_rpc(home, "terminal.get", {"terminal": pane})


def orca_foreground(row, descriptor, role):
    labels = row.get("labels") or {}
    if labels.get("hud.orca.role") != role or labels.get("hud.orca.owner") != descriptor["nonce"]:
        return None
    if role == "transport":
        args = [descriptor["opencode"], "serve", "--hostname", "127.0.0.1", "--port", str(descriptor["port"])]
    else:
        args = [descriptor["opencode"], "--server", descriptor["endpoint"], "--session", descriptor["sessionID"], descriptor["directory"]]
    foreground = row.get("foreground") or {}
    if foreground.get("argv") == args and directory(foreground.get("cwd")) == descriptor["directory"]:
        return terminal_identity(row)
    return None


def usable_listener(pid, port):
    fields = run_read(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-u", str(os.getuid()),
                       f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpn"]).splitlines()
    owners = [line for line in fields if line.startswith(b"p")]
    addresses = [line for line in fields if line.startswith(b"n")]
    return owners == [f"p{pid}".encode()] and bool(addresses) and all(a == f"n127.0.0.1:{port}".encode() for a in addresses)


def write_descriptor(path, previous, updated):
    import tempfile

    if read_private(path) != previous:
        raise ValueError("OpenCode binding changed")
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".recovery-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(updated, file, separators=(",", ":"), ensure_ascii=False, sort_keys=True)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def managed_rebind(home, name, core, server_address, tui_pid):
    path, previous, _ = orca_spec(home, name)
    old_tui = previous["tui"]
    for _ in range(100):
        row = get_terminal(home, old_tui["address"])
        tui = orca_foreground(row, previous, "tui")
        if not tui:
            time.sleep(0.15)
            continue
        if tui["created_ms"] != old_tui["created_ms"] or tui["foreground_pid"] != tui_pid:
            return False
        server = orca_foreground(get_terminal(home, server_address), previous, "transport")
        if not server or not usable_listener(server["foreground_pid"], previous["port"]) or current_core(home) != core:
            return False
        app = (row.get("status") or {}).get("app") or ""
        identity = {"core": core, "remote": None, "created_ms": tui["created_ms"],
                    "pid": tui_pid, "provider": "opencode", "app": app}
        agent_id = json.dumps([core, tui["address"], identity], ensure_ascii=False,
                              separators=(",", ":"), sort_keys=True)
        updated = dict(previous, coreID=core, server=server, serverPID=server["foreground_pid"],
                       tui=tui, agentID=agent_id)
        write_descriptor(path / "session.json", previous, updated)
        return True
    return False


def managed_resume(home, name):
    import socket

    path, descriptor, _ = orca_spec(home, name)
    pane = os.environ.get("HC_TERMINAL_ID")
    core = current_core(home)
    row = get_terminal(home, pane)
    labels = row.get("labels") or {}
    if pane != descriptor["tui"]["address"] or row.get("created_ms") != descriptor["tui"]["created_ms"]:
        raise ValueError("The original managed pane changed")
    if labels.get("hud.orca.owner") != descriptor["nonce"] or labels.get("hud.orca.role") != "tui":
        raise ValueError("The original managed owner changed")
    script = path / "launch.py"
    info = script.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise ValueError("Cannot validate the managed launcher")
    # The stored endpoint belongs exclusively to this session. A reused port
    # or live server causes refusal instead of handing the TUI to another process.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", descriptor["port"]))
    started = hc_rpc(home, "terminal.run", {
        "argv": ["/usr/bin/python3", str(script), "serve"], "cwd": descriptor["directory"],
        "labels": {"hud.orca.owner": descriptor["nonce"], "hud.orca.role": "transport"},
        "no_parent": True, "no_notify": True, "outlive_parent": True,
    })
    address = started.get("address")
    server = None
    for _ in range(100):
        live = get_terminal(home, address)
        if any(live.get(k) != started.get(k) for k in ("created_ms", "pid")) or live.get("state") != "live":
            raise ValueError("The new managed transport changed")
        server = orca_foreground(live, descriptor, "transport")
        if server and usable_listener(server["foreground_pid"], descriptor["port"]):
            break
        time.sleep(0.15)
    else:
        raise ValueError("Managed OpenCode server did not become ready")
    if not server or current_core(home) != core or not usable_listener(server["foreground_pid"], descriptor["port"]):
        raise ValueError("Managed OpenCode server identity changed")
    subprocess.Popen(["/usr/bin/python3", str(Path(__file__).resolve()), "rebind-managed-opencode", name,
                      core, address, str(os.getpid())], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    os.execv("/usr/bin/python3", ["/usr/bin/python3", str(script), "tui"])


def codex_spec(home, name):
    if not matches(FOLDER, name):
        return None
    path = managed_folder(home, name, "CodexSessions")
    if path is None:
        return None
    descriptor = read_private(path / "session.json")
    if not descriptor:
        return None
    owner = descriptor.get("owner")
    session_id = descriptor.get("threadID")
    cwd = directory(descriptor.get("directory"))
    if (descriptor.get("version") != 1 or descriptor.get("folder") != name or not matches(UUID, owner)
        or owner.replace("-", "")[:16] != name or not matches(UUID, session_id)
        or not cwd or descriptor.get("socketAlias") != str(path / "s")):
        return None
    record = codex_record(home / ".codex/state_5.sqlite", session_id, cwd)
    return (path, descriptor, record) if record else None


def codex_socket_instance(alias):
    import hashlib

    link = alias.lstat()
    physical = alias
    if stat.S_ISLNK(link.st_mode):
        normalized = alias.parent.resolve() / alias.name
        digest = hashlib.sha256(os.fsencode(normalized)).hexdigest()
        root = Path("/tmp").resolve() / f"codex-daemon-{os.geteuid()}"
        owner = root.lstat()
        if not stat.S_ISDIR(owner.st_mode) or owner.st_uid != os.geteuid() or owner.st_mode & 0o777 != 0o700:
            return None
        physical = root / digest
        if os.readlink(alias) != str(physical):
            return None
    info = physical.lstat()
    if link.st_uid != os.geteuid() or not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        return None
    return {"path": str(physical), "device": info.st_dev, "inode": info.st_ino,
            "aliasDevice": link.st_dev, "aliasInode": link.st_ino}


def reclaim_codex_socket(alias, previous):
    """Clear only the recorded inode after proving it has no listener."""
    import hashlib
    import socket

    if not os.path.lexists(alias):
        return
    recorded = previous.get("socketInstance") or {}
    info = alias.lstat()
    if info.st_uid != os.geteuid() or (info.st_dev, info.st_ino) != (recorded.get("aliasDevice"), recorded.get("aliasInode")):
        raise ValueError("The previous native Codex alias changed")
    if stat.S_ISLNK(info.st_mode):
        digest = hashlib.sha256(os.fsencode(alias.parent.resolve() / alias.name)).hexdigest()
        physical = Path("/tmp").resolve() / f"codex-daemon-{os.geteuid()}" / digest
        if os.readlink(alias) != str(physical) or recorded.get("path") != str(physical):
            raise ValueError("The previous native Codex alias target changed")
        if not os.path.lexists(physical):
            alias.unlink()
            return
    instance = codex_socket_instance(alias)
    if not instance or instance != recorded:
        raise ValueError("The previous native Codex socket changed")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        try:
            probe.connect(instance["path"])
        except ConnectionRefusedError:
            pass
        else:
            raise ValueError("The previous native Codex socket is still live")
    if codex_socket_instance(alias) != instance:
        raise ValueError("The previous native Codex socket changed")
    Path(instance["path"]).unlink()
    if instance["path"] != str(alias):
        alias.unlink()


def codex_loaded(path, peer_pid):
    """Read only thread identity over the app-server's authenticated local socket."""
    import base64
    import hashlib
    import socket

    key = base64.b64encode(os.urandom(16))
    expected = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(path)
        # Darwin SOL_LOCAL / LOCAL_PEERPID binds this socket to the verified hc server.
        pid = int.from_bytes(connection.getsockopt(0, 2, 4), sys.byteorder)
        if pid != peer_pid:
            raise ValueError("The local Codex peer changed")
        connection.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + b"\r\n\r\n")
        with connection.makefile("rb") as wire:
            if wire.readline(2049).split()[:2] != [b"HTTP/1.1", b"101"]:
                raise ValueError("Codex rejected the local handshake")
            headers = {}
            for _ in range(32):
                line = wire.readline(2049)
                if line == b"\r\n":
                    break
                header, sep, value = line.partition(b":")
                header = header.lower()
                if not sep or not line.endswith(b"\r\n") or header in headers:
                    raise ValueError("Invalid Codex upgrade headers")
                headers[header] = value.strip()
            else:
                raise ValueError("Codex upgrade headers exceed the limit")
            if (headers.get(b"sec-websocket-accept") != expected or headers.get(b"upgrade", b"").lower() != b"websocket"
                or b"upgrade" not in [part.strip() for part in headers.get(b"connection", b"").lower().split(b",")]
                or b"sec-websocket-extensions" in headers or b"sec-websocket-protocol" in headers):
                raise ValueError("Could not verify the local Codex handshake")

            def send(payload, opcode=1):
                if len(payload) > 65535:
                    raise ValueError("Invalid Codex frame size")
                size = bytes([128 | len(payload)]) if len(payload) < 126 else b"\xfe" + len(payload).to_bytes(2, "big")
                mask = os.urandom(4)
                connection.sendall(bytes([0x80 | opcode]) + size + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))

            def send_json(row):
                send(json.dumps(row, separators=(",", ":")).encode())

            def read(count):
                payload = wire.read(count)
                if len(payload) != count:
                    raise ValueError("Local Codex connection closed")
                return payload

            def receive(message_id):
                deadline = time.monotonic() + 3
                chunks = bytearray()
                for _ in range(64):
                    if time.monotonic() > deadline:
                        break
                    flags, length = read(2)
                    opcode = flags & 15
                    final = bool(flags & 0x80)
                    if length & 0x80 or flags & 0x70 or opcode not in (0, 1, 9, 10):
                        raise ValueError("Unexpected Codex frame")
                    if length in (126, 127):
                        length = int.from_bytes(read(2 if length == 126 else 8), "big")
                    if length > 1_048_576 or len(chunks) + length > 1_048_576:
                        raise ValueError("Codex recovery response exceeds the limit")
                    payload = read(length)
                    if opcode in (9, 10):
                        if not final or length > 125:
                            raise ValueError("Invalid Codex ping")
                        if opcode == 9:
                            send(payload, 10)
                        continue
                    if (opcode == 0) != bool(chunks):
                        raise ValueError("Unexpected Codex continuation")
                    chunks.extend(payload)
                    if not final:
                        continue
                    row = json.loads(chunks)
                    chunks.clear()
                    if row.get("id") == message_id:
                        if not isinstance(row.get("result"), dict) or "error" in row:
                            raise ValueError("Codex refused recovery inspection")
                        return row["result"]
                raise TimeoutError("Codex recovery inspection did not complete")

            send_json({"id": "initialize", "method": "initialize", "params": {"clientInfo": {
                "name": "herdr_hud_recovery", "title": "Herdr HUD", "version": "1"}, "capabilities": {"experimentalApi": True}}})
            receive("initialize")
            send_json({"method": "initialized"})
            send_json({"id": "loaded", "method": "thread/loaded/list", "params": {"limit": 2}})
            result_row = receive("loaded")
            ids = result_row.get("data")
            if not isinstance(ids, list) or result_row.get("nextCursor") is not None or not all(matches(UUID, i) for i in ids):
                raise ValueError("Ambiguous local Codex threads")
            return ids


def codex_foreground(row, descriptor, role):
    labels = row.get("labels") or {}
    if labels.get("hud.codex.role") != role or labels.get("hud.codex.owner") != descriptor["owner"]:
        return None
    endpoint = "unix://" + descriptor["socketAlias"]
    argv = (row.get("foreground") or {}).get("argv") or []
    if not argv or Path(argv[0]).name not in ("codex", "codex.js"):
        return None
    if role == "transport" and argv[1:] != ["app-server", "--listen", endpoint]:
        return None
    if role == "tui" and flag(argv, "--remote") != endpoint:
        return None
    return terminal_identity(row)


def codex_managed_capture(row, home, core_id, parked=False):
    labels = row.get("labels") or {}
    owner = labels.get("hud.codex.owner")
    if not matches(UUID, owner):
        return None
    name = owner.replace("-", "")[:16]
    binding = codex_spec(home, name)
    if not binding:
        return None
    alias, descriptor, (_, stored_model, stored_effort) = binding
    if descriptor.get("owner") != owner:
        return None
    actual = terminal_identity(row)
    old = descriptor.get("tui") or {}
    foreground = row.get("foreground") or {}
    cwd = directory(foreground.get("cwd"))
    if not actual or cwd != descriptor["directory"]:
        return None
    if parked:
        args = foreground.get("argv") or []
        if not args or Path(args[0]).name.lstrip("-") not in SHELLS or any(actual[k] != old.get(k) for k in ("address", "created_ms")):
            return None
        model, effort = stored_model, stored_effort
    else:
        if core_id != descriptor.get("coreID") or codex_foreground(row, descriptor, "tui") != old:
            return None
        server = codex_foreground(get_terminal(home, descriptor["server"]["address"]), descriptor, "transport")
        socket_info = codex_socket_instance(alias / "s")
        if not server or server != descriptor.get("server") or not socket_info or socket_info != descriptor.get("socketInstance"):
            return None
        if codex_loaded(socket_info["path"], server["foreground_pid"]) != [descriptor["threadID"]]:
            return None
        status = row.get("status") or {}
        status = status if status.get("app") == "codex" else {}
        model, effort = codex_settings(home, row, status, stored_model, stored_effort)
    command = executable("codex", home, [(home / ".local/bin/codex").as_posix()])
    return result("codex", descriptor["threadID"], cwd, model, effort, command, managed=name) if command and matches(MODEL, model) and effort in CODEX_EFFORT else None


def codex_rebind(home, name, core, server_address, tui_pid, model, effort):
    path, previous, _ = codex_spec(home, name)
    old = previous["tui"]
    for _ in range(100):
        row = get_terminal(home, old["address"])
        tui = codex_foreground(row, previous, "tui")
        if not tui:
            time.sleep(0.15)
            continue
        if tui["created_ms"] != old["created_ms"] or tui["foreground_pid"] != tui_pid:
            return False
        if (row.get("status") or {}).get("app") != "codex":
            time.sleep(0.15)
            continue
        server = codex_foreground(get_terminal(home, server_address), previous, "transport")
        instance = codex_socket_instance(path / "s")
        if not server or not instance or current_core(home) != core:
            return False
        ids = codex_loaded(instance["path"], server["foreground_pid"])
        if not ids:
            time.sleep(0.15)
            continue
        if ids != [previous["threadID"]]:
            return False
        identity = {"core": core, "remote": None, "created_ms": tui["created_ms"],
                    "pid": tui_pid, "provider": "codex", "app": "codex"}
        agent_id = json.dumps([core, tui["address"], identity], ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        updated = dict(previous, coreID=core, server=server, tui=tui, agentID=agent_id, model=model,
                       reasoningEffort=effort, socket=instance["path"], socketInstance=instance)
        write_descriptor(path / "session.json", previous, updated)
        return True
    return False


def codex_resume(home, name, model, effort):
    path, descriptor, _ = codex_spec(home, name)
    command = executable("codex", home, [(home / ".local/bin/codex").as_posix()])
    native = native_codex_executable(command) if command else None
    if not native or not matches(MODEL, model) or effort not in CODEX_EFFORT:
        raise ValueError("Invalid Codex configuration")
    pane = os.environ.get("HC_TERMINAL_ID")
    core = current_core(home)
    row = get_terminal(home, pane)
    labels = row.get("labels") or {}
    if (pane != descriptor["tui"]["address"] or row.get("created_ms") != descriptor["tui"]["created_ms"]
        or labels.get("hud.codex.owner") != descriptor["owner"] or labels.get("hud.codex.role") != "tui"):
        raise ValueError("The original native Codex pane changed")
    reclaim_codex_socket(path / "s", descriptor)
    endpoint = "unix://" + descriptor["socketAlias"]
    started = hc_rpc(home, "terminal.run", {"argv": [command, "app-server", "--listen", endpoint],
        "cwd": descriptor["directory"], "labels": {"hud.codex.owner": descriptor["owner"], "hud.codex.role": "transport"},
        "no_parent": True, "no_notify": True, "outlive_parent": True})
    address = started.get("address")
    for _ in range(100):
        live = get_terminal(home, address)
        if any(live.get(k) != started.get(k) for k in ("created_ms", "pid")) or live.get("state") != "live":
            raise ValueError("The new native Codex transport changed")
        server = codex_foreground(live, descriptor, "transport")
        try:
            instance = codex_socket_instance(path / "s") if server else None
            if server and instance:
                if codex_loaded(instance["path"], server["foreground_pid"]):
                    raise ValueError("The new native Codex transport already has a thread")
                break
        except (FileNotFoundError, ConnectionRefusedError):
            pass
        time.sleep(0.15)
    else:
        raise ValueError("The new native Codex transport did not become ready")
    if current_core(home) != core:
        raise ValueError("The Herdr core changed")
    subprocess.Popen(["/usr/bin/python3", str(Path(__file__).resolve()), "rebind-managed-codex", name,
                      core, address, str(os.getpid()), model, effort], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    os.execv(native, [native, "resume", descriptor["threadID"], "--remote", endpoint,
                      "--model", model, "--config", 'model_reasoning_effort="' + effort + '"'])


def native_codex_executable(command):
    """The npm wrapper spawns a different PID. Resolve its verified macOS package layout."""
    path = Path(command).resolve()
    if path.name == "codex.js" and path.parent.name == "bin" and path.parents[1].name == "codex":
        arch = os.uname().machine
        package = {"arm64": "arm64", "x86_64": "x64"}.get(arch)
        triple = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}.get(arch)
        if not package:
            return None
        root = path.parents[1]
        vendor = Path("vendor") / triple / "bin/codex"
        path = next((p for p in (root / "node_modules/@openai" / ("codex-darwin-" + package) / vendor,
                                 root / vendor) if p.is_file() and os.access(p, os.X_OK)), None)
    return str(path) if path and path.name == "codex" and path.is_file() and os.access(path, os.X_OK) else None


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "resume-managed-opencode":
            managed_resume(Path.home(), sys.argv[2])
        elif len(sys.argv) == 6 and sys.argv[1] == "rebind-managed-opencode":
            sys.exit(0 if managed_rebind(Path.home(), *sys.argv[2:5], int(sys.argv[5])) else 1)
        elif len(sys.argv) == 5 and sys.argv[1] == "resume-managed-codex":
            codex_resume(Path.home(), *sys.argv[2:])
        elif len(sys.argv) == 8 and sys.argv[1] == "rebind-managed-codex":
            sys.exit(0 if codex_rebind(Path.home(), *sys.argv[2:5], int(sys.argv[5]), *sys.argv[6:]) else 1)
        else:
            sys.exit(2)
    except (OSError, ValueError, TypeError, AttributeError, sqlite3.Error, subprocess.SubprocessError):
        sys.stderr.write("Managed chat recovery could not verify the original chat. Inspect its Herdr pane.\n")
        sys.exit(1)
