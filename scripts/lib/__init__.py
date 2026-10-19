"""Display, input, logging, and process lifecycle for Zodo smoke tests."""

import json
import os
from pathlib import Path
import platform
import re
import select
import subprocess
import time


def native_linux_abi():
    """Return the ABI Zig selects for a native Linux build."""
    try:
        env = subprocess.run(
            ["zig", "env"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=True,
            timeout=10,
        ).stdout
        match = re.search(r'\.target = "[^"]*-linux[^-]*-([A-Za-z0-9]+)', env)
        if match:
            return match.group(1)
    except (OSError, subprocess.SubprocessError):
        pass
    libc, _ = platform.libc_ver()
    return "musl" if libc == "musl" else "gnu"


def default_binary():
    """Locate the native Linux build using Zig's architecture and ABI names."""
    machine = platform.machine().lower()
    arch = {
        "amd64": "x86_64",
        "arm64": "aarch64",
        "i386": "x86",
        "i686": "x86",
        "armv6l": "arm",
        "armv7l": "arm",
    }.get(machine, machine)
    return (
        Path(__file__).resolve().parents[2]
        / "zig-out"
        / "bin"
        / f"zodo-{arch}-linux-{native_linux_abi()}"
    )


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


class Session:
    def __init__(self, binary, directory, timeout):
        self.directory = directory
        self.timeout = timeout
        self.env = os.environ.copy()
        # Force X11 so an inherited Wayland session can't bypass the private display.
        self.env.update(
            SDL_VIDEO_DRIVER="x11",
            SDL_RENDER_DRIVER="software",
            SDL_FRAMEBUFFER_ACCELERATION="0",
        )
        self.env.pop("XAUTHORITY", None)
        # SDL keeps saved tasks under $XDG_DATA_HOME; isolate them per run.
        self.data = directory / "data"
        self.data.mkdir()
        self.env["XDG_DATA_HOME"] = str(self.data)
        self.server = self.app = None
        self.window = None
        self.logs = []
        self.binary = binary

    def start(self):
        self.start_display()
        self.launch()

    def start_display(self):
        read_fd, write_fd = os.pipe()
        try:
            log = self.open_log("xvfb.log")
            self.server = subprocess.Popen(
                [
                    "Xvfb",
                    "-displayfd",
                    str(write_fd),
                    "-screen",
                    "0",
                    "1024x900x24",
                    "-nolisten",
                    "tcp",
                    # Keep the server ready between app launches in reload checks.
                    "-noreset",
                    "-ac",
                ],
                pass_fds=(write_fd,),
                stdout=log,
                stderr=log,
            )
            os.close(write_fd)
            write_fd = None
            deadline = time.monotonic() + self.timeout
            display_bytes = bytearray()
            while not display_bytes.endswith(b"\n"):
                remaining = deadline - time.monotonic()
                require(
                    remaining > 0 and select.select([read_fd], [], [], remaining)[0],
                    "Xvfb did not become ready",
                )
                chunk = os.read(read_fd, 64)
                require(chunk, "Xvfb closed its readiness pipe")
                display_bytes.extend(chunk)
            display = display_bytes.decode().strip()
            require(display.isdecimal(), "Xvfb failed to allocate a display")
            self.env["DISPLAY"] = f":{display}"
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    def launch(self):
        """Starts the app on the display and waits for its visible window."""
        self.launches = getattr(self, "launches", 0) + 1
        log = self.open_log(f"zodo-{self.launches}.log")
        self.window = None
        self.app = subprocess.Popen(
            [str(self.binary)], env=self.env, stdout=log, stderr=log
        )
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            self.alive()
            found = self.command(
                "xdotool", "search", "--onlyvisible", "--name", "^Zodo$", check=False
            )
            if found.returncode == 0 and found.stdout.strip():
                self.window = found.stdout.splitlines()[0].decode()
                break
            time.sleep(0.05)
        require(self.window is not None, "visible Zodo window was not found")
        self.command("xdotool", "windowfocus", "--sync", self.window)

    def open_log(self, name):
        log = (self.directory / name).open("wb")
        self.logs.append(log)
        return log

    def command(self, *args, check=True):
        return subprocess.run(
            args,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
            timeout=self.timeout,
        )

    def alive(self):
        if self.app is None:
            raise RuntimeError("Zodo has not been started")
        if self.server is None:
            raise RuntimeError("Xvfb has not been started")
        require(
            self.app.poll() is None,
            f"Zodo exited unexpectedly ({self.app.returncode})",
        )
        require(self.server.poll() is None, "Xvfb exited unexpectedly")

    def key(self, key):
        """Presses a key or chord such as "Return" or "ctrl+a"."""
        self.alive()
        self.command("xdotool", "key", "--clearmodifiers", key)

    def type(self, text):
        """Types text through XTEST key events, which SDL turns into text input."""
        self.alive()
        self.command("xdotool", "type", "--delay", "20", text)

    def click(self, x, y, repeat=1):
        """Clicks the left button at window coordinates."""
        self.alive()
        self.command(
            "xdotool",
            "mousemove",
            "--window",
            self.window,
            str(x),
            str(y),
            "click",
            "--repeat",
            str(repeat),
            "--delay",
            "40",
            "1",
        )

    def close(self):
        stop(self.app)
        stop(self.server)
        for log in self.logs:
            log.close()


class FileDialogs:
    def __init__(self, session):
        self.session = session
        self.response = session.directory / "dialog-response.json"
        self.log = session.directory / "dialog-requests.jsonl"
        tools = session.directory / "tools"
        tools.mkdir()
        zenity = tools / "zenity"
        zenity.write_text(
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

if '--version' in sys.argv:
    print('4.0.0')
    sys.exit(0)
if '--file-selection' not in sys.argv:
    sys.exit(2)
with Path(os.environ['ZODO_DIALOG_LOG']).open('a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
response = json.loads(Path(os.environ['ZODO_DIALOG_RESPONSE']).read_text())
if response is None:
    sys.exit(1)
print(response)
""",
            encoding="utf-8",
        )
        zenity.chmod(0o755)
        session.env.update(
            SDL_FILE_DIALOG_DRIVER="zenity",
            PATH=str(tools) + os.pathsep + session.env.get("PATH", ""),
            ZODO_DIALOG_RESPONSE=str(self.response),
            ZODO_DIALOG_LOG=str(self.log),
        )
        self.choose(None)

    def choose(self, path):
        self.response.write_text(
            json.dumps(str(path) if path is not None else None), encoding="utf-8"
        )

    def wait_request(self, count):
        deadline = time.monotonic() + self.session.timeout
        while time.monotonic() < deadline:
            self.session.alive()
            requests = (
                self.log.read_text(encoding="utf-8").splitlines()
                if self.log.exists()
                else []
            )
            if len(requests) >= count:
                return json.loads(requests[count - 1])
            time.sleep(0.05)
        require(False, f"file dialog request {count} was not received")
