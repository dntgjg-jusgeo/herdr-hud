#!/usr/bin/env python3
"""Install the per-user chat recovery helper for the local default hc core."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import pwd
import subprocess
import sys
import tempfile
import tomllib

LABEL = "org.herdr.community.hud.chat-restore"
SCRIPTS = ("herdr_chat_restore.py", "herdr_chat_capture.py")


def atomic_write(path, content, mode):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as target:
        scratch = Path(target.name)
        try:
            target.write(content)
            target.flush()
            os.fchmod(target.fileno(), mode)
            os.replace(scratch, path)
        finally:
            scratch.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin" or not args.socket.is_absolute() or not args.socket.is_socket():
        parser.error("Specify the live local macOS hc socket.")
    home = Path.home()
    hc = home / ".local/bin/hc"
    if not os.access(hc, os.X_OK):
        parser.error("Install hc in ~/.local/bin first.")
    install = home / "Library/Application Support/Herdr HUD/Chat Recovery"
    state = install / "state"
    # Keep a stable Python path through Homebrew point upgrades.
    python = str(Path(sys.executable).parent / "python3")
    if Path("/opt/homebrew/bin/python3").exists() and os.path.samefile(python, "/opt/homebrew/bin/python3"):
        python = "/opt/homebrew/bin/python3"
    command = [python, str(install / SCRIPTS[0]), "--state-dir", str(state), "--socket", str(args.socket)]
    config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "herdr-core/config.toml"
    data = config.read_bytes() if config.exists() else b""
    prior = tomllib.loads(data.decode()).get("shell")
    if prior and prior[:len(command)+2] == [*command, "shell", "--"]:
        wrapper = prior
    else:
        if prior is not None:
            parser.error("A custom hc shell is configured. Preserve its exact command when adding the wrapper.")
        wrapper = [*command, "shell", "--", pwd.getpwuid(os.getuid()).pw_shell, "-l"]
    line = ("shell = " + json.dumps(wrapper, ensure_ascii=False) + "\n").encode()
    updated = data if prior else line + data
    assert tomllib.loads(updated.decode())["shell"] == wrapper
    agent_path = home / "Library/LaunchAgents" / (LABEL + ".plist")
    domain = "gui/" + str(os.getuid())
    script_dir = Path(__file__).resolve().parent
    modules = {name:(script_dir / name).read_bytes() for name in SCRIPTS}
    for filename, source in modules.items():
        compile(source, filename, "exec")
    for name, source in modules.items():
        atomic_write(install / name, source, 0o700)
    if updated != data:
        atomic_write(config, updated, 0o600)
    job = {
        "Label": LABEL, "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 15,
        "ProgramArguments": ["/bin/sh", "-c", '"$1" server start >/dev/null || exit 1; shift; exec "$@"',
                             "herdr-login", str(hc), *command, "watch"],
        "EnvironmentVariables": {"PATH": ":".join([str(home / ".local/bin"),str(home / ".opencode/bin"),
                                                   "/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin","/usr/sbin","/sbin"]),
                                 "PYTHONDONTWRITEBYTECODE":"1"},
        "ProcessType": "Background",
    }
    atomic_write(agent_path, plistlib.dumps(job), 0o600)
    target = domain + "/" + LABEL
    if subprocess.run(["launchctl","print",target],capture_output=True).returncode == 0:
        subprocess.run(["launchctl","bootout",target],check=True)
    subprocess.run(["launchctl","enable",target],check=True)
    subprocess.run(["launchctl","bootstrap",domain,str(agent_path)],check=True)
    print("Installed login capture and kept-pane recovery.")


if __name__ == "__main__":
    main()
