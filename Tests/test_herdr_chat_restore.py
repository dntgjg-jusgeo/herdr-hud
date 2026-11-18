from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import herdr_chat_restore as restore


SHELL = ["/bin/zsh", "-l"]
BEFORE = "old-boot"
AFTER = "new-boot"


class FakeCore:
    def __init__(self):
        self.core_id = "local-core"
        self.path = Path("/tmp/fixture socket.sock")
        self.rows = {}

    def identity(self):
        return self.core_id

    def terminal(self, address):
        return self.rows[address]

    def terminals(self):
        return self.rows.copy()


class RestoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name)
        self.state = restore.State(self.path / "private")
        self.core = FakeCore()
        self.chat = {
            "provider": "codex", "session_id": "example-thread", "cwd": str(self.path),
            "model": "test-model", "effort": "medium", "executable": "/bin/echo",
        }
        self.row = self.add_row("t7", 101, 99)

    def add_row(self, address, created_ms, pid):
        row = {
            "address": address, "created_ms": created_ms, "pid": pid, "cwd": str(self.path),
            "labels": {"herdr.space": "space", "herdr.tab": "tab"}, "state": "live", "keep": True,
            "argv": ["codex"], "foreground": {"pid": pid, "name": "codex", "argv": ["codex"]},
        }
        self.core.rows[address] = row
        return row

    def capture(self, row, core_id):
        self.assertEqual(core_id, self.core.core_id)
        return {**self.chat, "token": "must never be persisted"} if row["foreground"]["name"] == "codex" else None

    def snapshot(self, boot=BEFORE):
        return restore.snapshot(self.core, self.state, boot, self.capture)

    def recovered(self, pid=991):
        argv = [sys.executable, restore.__file__, "--state-dir", str(self.state.directory),
                "--socket", "/tmp/fixture.sock", "shell", "--", *SHELL]
        self.row.update(pid=pid, argv=argv, foreground={"pid": pid, "name": "Python", "argv": argv})

    def blank(self, pid=99):
        self.row.update(pid=pid, argv=SHELL, foreground={"pid": pid, "name": "zsh", "argv": SHELL})

    def test_exact_boot_resume_is_consumed_atomically_without_saving_other_metadata(self):
        self.assertEqual(self.snapshot(), 1)
        state_path = self.state.directory / "records.json"
        self.assertEqual(stat.S_IMODE(state_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.state.directory.stat().st_mode), 0o700)
        self.assertNotIn("must never be persisted", state_path.read_text())
        self.recovered()
        self.assertIsNone(restore.claim(self.core, self.state, BEFORE, "t7", 991, explicit=False))
        self.assertEqual(self.snapshot(AFTER), 1)
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 99, explicit=False))
        self.assertEqual(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False), self.chat)
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False))

    def test_moved_replaced_remote_and_closed_panes_do_not_claim(self):
        self.snapshot()
        self.recovered()
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "remote/t7", 991, explicit=False))
        for attribute, value in (("created_ms", 102), ("labels", {"herdr.space": "space", "herdr.tab": "other"}),
                                 ("keep", False), ("state", "finished"), ("argv", SHELL)):
            with self.subTest(attribute=attribute):
                previous = self.row[attribute]
                self.row[attribute] = value
                self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False))
                self.row[attribute] = previous
        self.core.core_id = "another-core"
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False))

    def test_latest_conversation_replaces_old_record_and_exit_removes_it(self):
        self.snapshot()
        self.chat["session_id"] = "other-thread"
        self.chat["model"] = "another-model"
        self.assertEqual(self.snapshot(), 1)
        state_path = self.state.directory / "records.json"
        self.assertEqual(json.loads(state_path.read_text())["records"]["t7"]["chat"], self.chat)
        self.blank()
        self.assertEqual(self.snapshot(), 0)
        self.recovered()
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False))

    def test_duplicate_conversations_are_never_armed(self):
        self.add_row("t8", 102, 100)
        self.assertEqual(self.snapshot(), 0)
        self.recovered()
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False))

    def test_explicit_seed_requires_confirmed_shell_and_matching_process(self):
        seed = {**restore.pane(self.row), "chat": self.chat}
        with self.assertRaisesRegex(restore.RestoreError, "exact kept pane"):
            restore.seed(self.core, self.state, BEFORE, [seed], SHELL)
        self.blank()
        self.assertEqual(restore.seed(self.core, self.state, BEFORE, [seed], SHELL), 1)
        self.assertEqual(self.snapshot(), 1)
        self.assertIsNone(restore.claim(self.core, self.state, BEFORE, "t7", 100, explicit=True))
        self.assertIsNone(restore.claim(self.core, self.state, BEFORE, "t7", 99, explicit=False))
        self.assertEqual(restore.claim(self.core, self.state, BEFORE, "t7", 99, explicit=True), self.chat)
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 99, explicit=False))
        self.assertEqual(restore.claim(self.core, self.state, BEFORE, "t7", 99, explicit=True, fallback=SHELL), self.chat)

    def test_same_boot_seed_is_removed_when_shell_is_replaced(self):
        self.blank()
        seed = {**restore.pane(self.row), "chat": self.chat}
        restore.seed(self.core, self.state, BEFORE, [seed], SHELL)
        self.blank(pid=100)
        self.assertEqual(self.snapshot(), 0)

    def test_same_boot_seed_survives_watcher_while_explicit_wrapper_execs(self):
        self.blank()
        seed = {**restore.pane(self.row), "chat": self.chat}
        restore.seed(self.core, self.state, BEFORE, [seed], SHELL)
        argv = [sys.executable, restore.__file__, "--state-dir", str(self.state.directory),
                "--socket", str(self.core.path), "recover", "--", *SHELL]
        self.row["foreground"] = {"name": "Python", "pid": 99, "argv": argv}
        self.assertEqual(self.snapshot(), 1)
        self.assertEqual(restore.claim(self.core, self.state, BEFORE, "t7", 99, explicit=True), self.chat)

    def test_kept_record_survives_transient_capture_failure_of_exact_foreground(self):
        class Unavailable(Exception):
            pass

        def transient(row, core_id):
            raise Unavailable()

        self.assertEqual(self.snapshot(), 1)
        self.assertEqual(restore.snapshot(self.core, self.state, BEFORE, transient, Unavailable), 1)
        self.row["foreground"]["pid"] += 1
        self.assertEqual(restore.snapshot(self.core, self.state, BEFORE, transient, Unavailable), 0)
        self.assertEqual(self.snapshot(), 1)
        self.assertEqual(restore.snapshot(self.core, self.state, BEFORE, lambda *a, **k: None), 0)

    def test_startup_keeps_capture_until_recovery_wrapper_observes_it(self):
        self.snapshot()
        former_foreground = self.row["foreground"]
        self.row["pid"] = None
        self.assertEqual(self.snapshot(AFTER), 1)
        self.recovered()
        wrapper_foreground = self.row["foreground"]
        self.row["foreground"] = former_foreground
        self.assertEqual(restore.snapshot(self.core, self.state, AFTER, lambda *a, **k: None), 1)
        self.row["foreground"] = {**wrapper_foreground, "name": "zsh", "argv": SHELL}
        self.assertEqual(self.snapshot(AFTER), 0)

    def test_failed_attempt_is_private_until_exact_recapture_and_requires_explicit_retry(self):
        self.snapshot()
        self.recovered()
        self.assertEqual(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False), self.chat)
        path = self.state.directory / "records.json"
        self.assertEqual(json.loads(path.read_text())["pending"]["t7"]["chat"], self.chat)
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False))
        self.row["foreground"] = {"name": "codex", "pid": 992, "argv": ["codex"]}
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=True, fallback=SHELL))
        self.row["foreground"] = {"name": "zsh", "pid": 991, "argv": SHELL}
        self.assertEqual(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=True, fallback=SHELL), self.chat)
        self.row["foreground"] = {"name": "codex", "pid": 992, "argv": ["codex"]}
        self.assertEqual(self.snapshot(AFTER), 1)
        ledger = json.loads(path.read_text())
        self.assertEqual(ledger["pending"], {})
        self.assertEqual(ledger["records"]["t7"]["chat"], self.chat)

    def test_a_repurposed_pane_cannot_retry_the_prior_attempt(self):
        self.snapshot()
        self.recovered()
        restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False)
        previous_chat = self.chat.copy()
        self.chat["session_id"] = "new-owner"
        self.row["foreground"] = {"name": "codex", "pid": 992, "argv": ["codex"]}
        self.snapshot(AFTER)
        self.row["foreground"] = {"name": "zsh", "pid": 991, "argv": SHELL}
        self.snapshot(AFTER)
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=True, fallback=SHELL))
        ledger = json.loads((self.state.directory / "records.json").read_text())
        self.assertEqual(ledger["pending"]["t7"]["chat"], previous_chat)

    def test_retry_cannot_duplicate_a_chat_observed_in_another_local_terminal(self):
        self.snapshot()
        self.recovered()
        self.assertEqual(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=False), self.chat)
        self.row["foreground"] = {"name": "zsh", "pid": 991, "argv": SHELL}
        other = self.add_row("t8", 102, 100)
        other["keep"] = False
        self.assertEqual(self.snapshot(AFTER), 0)
        self.assertIsNone(restore.claim(self.core, self.state, AFTER, "t7", 991, explicit=True, fallback=SHELL))
        other["keep"] = True
        self.assertEqual(self.snapshot(AFTER), 1)
        ledger = json.loads((self.state.directory / "records.json").read_text())
        self.assertTrue(ledger["pending"]["t7"]["blocked"])
        self.assertEqual(ledger["records"]["t8"]["chat"], self.chat)

    def test_codex_cross_cwd_seed_must_match_native_snapshot_and_database(self):
        self.blank()
        session = "22000000-0000-0000-0000-000000000002"
        other = self.path / "other project"
        other.mkdir()
        home = self.path / "home"
        snapshots = home / ".codex" / "shell_snapshots"
        snapshots.mkdir(parents=True)
        rollout = home / ".codex" / "fixture.jsonl"
        rollout.touch()
        with closing(sqlite3.connect(home / ".codex" / "state_5.sqlite")) as database, database:
            database.execute("CREATE TABLE threads (id, rollout_path, cwd, model, reasoning_effort, model_provider, archived)")
            database.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?)", (session, str(rollout), str(other.resolve()),
                             self.chat["model"], self.chat["effort"], "openai", 0))
        record = {**restore.pane(self.row), "chat": {**self.chat, "session_id": session, "cwd": str(other)}}
        timestamp = time.time_ns() - 1_000_000
        filename = snapshots / f"{session}.{timestamp}.sh"
        with self.assertRaisesRegex(restore.RestoreError, "directory"):
            restore.seed(self.core, self.state, BEFORE, [record], SHELL, home=home)
        filename.write_text(f'export HC_TERMINAL_ID=t6\nexport HC_TERMINAL_SOCKET={str(self.core.path)!r}\n')
        with self.assertRaisesRegex(restore.RestoreError, "directory"):
            restore.seed(self.core, self.state, BEFORE, [record], SHELL, home=home)
        filename.write_text(f'export HC_TERMINAL_ID=t7\nexport HC_TERMINAL_SOCKET={str(self.core.path)!r}\n')
        self.assertEqual(restore.seed(self.core, self.state, BEFORE, [record], SHELL, home=home), 1)

    def test_storage_refuses_symlinks_and_insecure_existing_files(self):
        self.snapshot()
        state_path = self.state.directory / "records.json"
        state_path.chmod(0o644)
        with self.assertRaisesRegex(restore.RestoreError, "private"):
            self.snapshot()
        state_path.unlink()
        target = self.path / "unrelated.json"
        target.write_text("{}")
        os.symlink(target, state_path)
        with self.assertRaises(OSError):
            self.snapshot()
        self.assertEqual(target.read_text(), "{}")


if __name__ == "__main__":
    unittest.main()
