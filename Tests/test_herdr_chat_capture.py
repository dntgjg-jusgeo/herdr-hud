import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import herdr_chat_capture as capture


CODEX = "11111111-1111-4111-8111-111111111111"
CLAUDE = "22222222-2222-4222-8222-222222222222"
ORCA = "ses_fixture"
OWNER = "12345678-1234-4567-8123-123456789abc"
FOLDER = OWNER.replace("-", "")[:16]
PROVIDER = "herdr-orca-" + OWNER.replace("-", "")


class CaptureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.cwd = str(self.home / "project with spaces")
        Path(self.cwd).mkdir()
        self.codex = self.executable(".local/bin/codex")
        self.claude = self.executable(".local/bin/claude")
        self.opencode = self.executable(".opencode/bin/opencode")

    def executable(self, relative):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o700)
        return str(path)

    def terminal(self, args, status=None, pid=700, labels=None):
        return {"address": "t7", "created_ms": 15, "pid": 603, "state": "live", "cwd": self.cwd,
                "foreground": {"pid": pid, "cwd": self.cwd, "argv": args}, "status": status,
                "labels": labels or {}}

    def write(self, file, data):
        file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        file.write_text(json.dumps(data), encoding="utf-8")
        file.chmod(0o600)

    def create_codex(self):
        path = self.home / ".codex/sessions" / ("rollout-test-" + CODEX + ".jsonl")
        path.parent.mkdir(parents=True)
        path.touch()
        with sqlite3.connect(self.home / ".codex/state_5.sqlite") as db:
            db.execute("CREATE TABLE threads (id, rollout_path, cwd, model, reasoning_effort, model_provider, archived, source, thread_source)")
            db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,0,'cli','user')",
                       (CODEX, str(path), self.cwd, "gpt-6-astra", "medium", "openai"))
        return path

    def test_codex_requires_exact_foreground_evidence_and_retains_effective_model(self):
        path = self.create_codex()
        row = self.terminal([self.codex], {"app": "codex", "model": "gpt-6.2-sol", "reasoning_effort": "high"})
        with patch.object(capture, "process_environment", return_value={}), patch.object(capture, "run_read", return_value=b"f12\naw\nn" + bytes(path) + b"\n"):
            chat = capture.capture_chat(row, self.home)
            self.assertEqual(chat["session_id"], CODEX)
            self.assertEqual(chat["model"], "gpt-6.2-sol")
            self.assertEqual(capture.resume_argv(chat, self.home),
                             [self.codex, "resume", CODEX, "--no-daemon", "--model", "gpt-6.2-sol", "--config", 'model_reasoning_effort="high"'])
            row["address"] = "remote/t7"
            self.assertIsNone(capture.capture_chat(row, self.home))
            row["address"] = "t7"
            row["foreground"]["argv"] += ["--remote", "unix:///arbitrary"]
            self.assertIsNone(capture.capture_chat(row, self.home))

    def test_codex_log_binding_rejects_pid_reuse_or_multiple_incarnations(self):
        self.create_codex()
        database = self.home / ".codex/logs_2.sqlite"
        with sqlite3.connect(database) as db:
            db.execute("CREATE TABLE logs (ts,process_uuid,thread_id)")
            db.execute("INSERT INTO logs VALUES (?,?,?)", (99, "pif:700:old", CODEX))
        row = self.terminal([self.codex])
        with patch.object(capture, "process_environment", return_value={}), patch.object(capture, "run_read", return_value=b""), patch.object(capture, "process_start", return_value=100):
            self.assertIsNone(capture.capture_chat(row, self.home))
            with sqlite3.connect(database) as db:
                db.execute("INSERT INTO logs VALUES (?,?,?)", (101, "pif:700:one", CODEX))
            self.assertEqual(capture.capture_chat(row, self.home)["session_id"], CODEX)
            with sqlite3.connect(database) as db:
                db.execute("INSERT INTO logs VALUES (?,?,?)", (101, "pif:700:two", CODEX))
            self.assertIsNone(capture.capture_chat(row, self.home))

    def test_codex_live_footer_requires_the_complete_native_composer(self):
        screen = {"how": "screen", "complete": True, "text": "• Done\n\n› Ask Codex to do anything\n\n  GPT-6-Astra Extra high · ~/project\n  ← for agents · ? for shortcuts"}
        self.assertEqual(capture.codex_footer(screen), ("gpt-6-astra", "xhigh"))
        self.assertEqual(capture.codex_footer(dict(screen, complete=False)), (None, None))
        self.assertEqual(capture.codex_footer(dict(screen, text=screen["text"] + "\n› /model")), (None, None))

    def test_codex_native_recovery_requires_the_original_pane_and_known_thread(self):
        self.create_codex()
        root = self.home / "Library/Application Support/Herdr HUD/CodexSessions" / FOLDER
        root.mkdir(parents=True, mode=0o700)
        root.parent.chmod(0o700)
        descriptor = {"version": 1, "folder": FOLDER, "owner": OWNER, "threadID": CODEX,
                      "directory": self.cwd, "socketAlias": str(root / "s"), "coreID": "old",
                      "tui": {"address": "t7", "created_ms": 15, "pid": 501, "foreground_pid": 503}}
        self.write(root / "session.json", descriptor)
        shell = self.terminal(["-zsh"], labels={"hud.codex.owner": OWNER, "hud.codex.role": "tui"})
        chat = capture.capture_parked_chat(shell, self.home)
        self.assertEqual(chat["session_id"], CODEX)
        self.assertEqual(capture.resume_argv(chat, self.home)[-4:], ["resume-managed-codex", FOLDER, "gpt-6-astra", "medium"])
        self.assertIsNone(capture.capture_parked_chat(dict(shell, address="t1"), self.home))
        self.assertIsNone(capture.capture_parked_chat(dict(shell, created_ms=98), self.home))

    def test_transient_capture_error_is_distinct_from_no_binding(self):
        row = self.terminal([self.codex])
        with patch.object(capture, "process_environment", side_effect=PermissionError):
            with self.assertRaises(capture.CaptureUnavailable):
                capture.capture_chat(row, self.home)
        self.assertIsNone(capture.capture_chat(self.terminal(["-zsh"]), self.home))

    def test_claude_pid_registry_ties_session_to_the_foreground_and_route(self):
        now = int(time.time())
        path = self.home / ".claude/sessions/700.json"
        self.write(path, {"pid": 700, "sessionId": CLAUDE, "cwd": self.cwd, "startedAt": now * 1000})
        transcript = self.home / ".claude/projects/a" / (CLAUDE + ".jsonl")
        self.write(transcript, {"sessionId": CLAUDE, "cwd": self.cwd, "type": "assistant", "message": {"model": "claude-sonnet-5", "content": "private"}})
        row = self.terminal([self.claude, "--effort", "high"])
        with patch.object(capture, "process_start", return_value=now - 1), patch.object(capture, "process_environment", return_value={"ANTHROPIC_BASE_URL": "https://api.orcarouter.ai/v1"}):
            chat = capture.capture_chat(row, self.home)
            self.assertEqual(set(chat), {"session_id", "provider", "cwd", "model", "effort", "executable", "route"})
            self.assertEqual(chat["session_id"], CLAUDE)
            self.assertEqual(capture.resume_argv(chat, self.home),
                             ["/bin/zsh", "-lic", 'orca-claude "$@"', "herdr-recovery", "--resume", CLAUDE, "--model", "claude-sonnet-5", "--effort", "high"])
            row["foreground"]["pid"] = 701
            self.assertIsNone(capture.capture_chat(row, self.home))

    def create_orca(self):
        root = self.home / "Library/Application Support/Herdr HUD/OrcaOpenCode" / FOLDER
        root.mkdir(parents=True, mode=0o700)
        root.parent.chmod(0o700)
        db_path = root / "data/opencode/opencode.db"
        db_path.parent.mkdir(parents=True)
        with sqlite3.connect(db_path) as db:
            db.execute("CREATE TABLE session_v2 (id, directory, model, parent_id, time_archived)")
            db.execute("INSERT INTO session_v2 VALUES (?,?,?,NULL,NULL)",
                       (ORCA, self.cwd, json.dumps({"providerID": PROVIDER, "id": "owner/model"})))
        descriptor = {"version": 1, "nonce": OWNER, "folder": FOLDER, "port": 42424, "endpoint": "http://127.0.0.1:42424",
                      "sessionID": ORCA, "directory": self.cwd, "opencode": self.opencode, "coreID": "old", "modelID": "owner/model",
                      "providerID": PROVIDER, "tui": {"address": "t7", "created_ms": 15, "pid": 603, "foreground_pid": 700}}
        self.write(root / "session.json", descriptor)
        config = {"model": PROVIDER + "/owner/model", "providers": {PROVIDER: {"package": "@opencode/ai/providers/openai-compatible",
                  "settings": {"baseURL": "https://api.orcarouter.ai/v1", "apiKey": "{env:ORCAROUTER_API_KEY}"}, "models": {"owner/model": {}}}}}
        self.write(root / "launch.json", dict(descriptor, config=config))
        return root, descriptor

    def test_orca_active_and_retained_pane_bindings_and_rebind(self):
        root, descriptor = self.create_orca()
        args = [self.opencode, "--server", descriptor["endpoint"], "--session", ORCA, self.cwd]
        row = self.terminal(args, labels={"hud.orca.owner": OWNER, "hud.orca.role": "tui"})
        active = capture.capture_chat(row, self.home, core_id="old")
        self.assertEqual(active["session_id"], ORCA)
        self.assertIsNone(capture.capture_chat(row, self.home, core_id="different"))
        row["foreground"]["argv"] = ["-zsh"]
        parked = capture.capture_parked_chat(row, self.home)
        self.assertEqual(parked, active)
        self.assertEqual(capture.resume_argv(parked, self.home)[-2:], ["resume-managed-opencode", FOLDER])
        row["created_ms"] = 5
        self.assertIsNone(capture.capture_parked_chat(row, self.home))
        row["created_ms"] = 15
        row["foreground"]["argv"] = args
        transport = self.terminal([self.opencode, "serve", "--hostname", "127.0.0.1", "--port", "42424"],
                                  pid=901, labels={"hud.orca.owner": OWNER, "hud.orca.role": "transport"})
        transport["address"] = "t9"
        with patch.object(capture, "current_core", return_value="new"), patch.object(capture, "usable_listener", return_value=True), patch.object(capture, "get_terminal", side_effect=[row, transport]):
            self.assertTrue(capture.managed_rebind(self.home, FOLDER, "new", "t9", 700))
        updated = json.loads((root / "session.json").read_text())
        self.assertEqual(updated["coreID"], "new")
        self.assertEqual(updated["server"]["address"], "t9")
        self.assertEqual(updated["serverPID"], 901)
        self.assertEqual(json.loads(updated["agentID"])[2]["pid"], 700)

    def test_opencode_refuses_ambiguous_or_missing_database_session(self):
        db_path = self.home / ".local/share/opencode/opencode.db"
        db_path.parent.mkdir(parents=True)
        row = self.terminal([self.opencode, "--session", ORCA])
        with patch.object(capture, "process_environment", return_value={}):
            self.assertIsNone(capture.capture_chat(row, self.home))
            with sqlite3.connect(db_path) as db:
                db.execute("CREATE TABLE session_v2 (id,directory,model,parent_id,time_archived)")
                model = json.dumps({"providerID": "synthetic", "id": "provider/model"})
                db.execute("INSERT INTO session_v2 VALUES (?,?,?,NULL,NULL)", (ORCA, self.cwd, model))
            chat = capture.capture_chat(row, self.home)
            self.assertEqual(capture.resume_argv(chat, self.home), [self.opencode, "--session", ORCA, self.cwd])
            with sqlite3.connect(db_path) as db:
                db.execute("INSERT INTO session_v2 VALUES (?,?,?,NULL,NULL)", ("ses_other", self.cwd, model))
            self.assertIsNone(capture.capture_chat(row, self.home))
            self.assertIsNone(capture.resume_argv(chat, self.home))


if __name__ == "__main__":
    unittest.main()
