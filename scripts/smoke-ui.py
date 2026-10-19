#!/usr/bin/env python3
"""Smoke-test Zodo on Linux using Xvfb, xdotool, and ImageMagick import.

Uses SDL's software renderer on X11. Python needs only its standard library.
Screenshots are PPM files; logs and screenshots are retained in a temporary directory on failure.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from lib import FileDialogs, Session as SmokeSession, default_binary, require


WIDTH, HEIGHT = 640, 720
BACKGROUND = (13, 17, 27)
ACCENT = (75, 218, 205)
MUTED = (126, 145, 168)
PANEL = (21, 28, 42)
SELECTION = (36, 92, 96)
MENU_X, MENU_Y = 592, 44

# Checkboxes are at x 44-66, centered in 44-unit rows starting at y 200.
LIST_TOP, ROW_HEIGHT, MAX_ROWS = 200, 44, 10
SAVED = Path("zodo") / "tasks.md"


def pixel(frame, x, y):
    offset = (y * WIDTH + x) * 3
    return tuple(frame[offset : offset + 3])


def rows(frame):
    """Returns each visible row's checkbox state: True when checked."""
    states = []
    for row in range(MAX_ROWS):
        top = LIST_TOP + row * ROW_HEIGHT
        box = [
            pixel(frame, x, y) for x in range(40, 70) for y in range(top + 8, top + 36)
        ]
        if box.count(ACCENT) >= 100:
            states.append(True)
        elif box.count(MUTED) + box.count(ACCENT) >= 30:
            states.append(False)
        else:
            break
    return states


def row_center(row):
    return LIST_TOP + row * ROW_HEIGHT + ROW_HEIGHT // 2


class Session(SmokeSession):
    def wait_pixel(self, name, x, y, color):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            frame = self.capture(name)
            if pixel(frame, x, y) == color:
                return frame
            time.sleep(0.05)
        raise RuntimeError(f"{name}: expected {color} at ({x}, {y})")

    def capture(self, name):
        self.alive()
        frame = self.command(
            "import", "-window", self.window, "-depth", "8", "rgb:-"
        ).stdout
        require(
            len(frame) == WIDTH * HEIGHT * 3,
            "unexpected window dimensions or screenshot format",
        )
        (self.directory / f"{name}.ppm").write_bytes(
            f"P6\n{WIDTH} {HEIGHT}\n255\n".encode() + frame
        )
        return frame

    def wait_rows(self, name, expected):
        """Waits until the list shows `expected` rows, given as checkbox states."""
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            frame = self.capture(name)
            if rows(frame) == expected:
                return frame
            time.sleep(0.05)
        raise RuntimeError(f"{name}: expected rows {expected}, saw {rows(frame)}")

    def park_mouse(self):
        """Moves the pointer off the list so hover highlights don't affect checks."""
        self.command("xdotool", "mousemove", "--window", self.window, "620", "20")

    def quit(self):
        self.key("ctrl+q")
        app = self.app
        assert app is not None
        code = app.wait(timeout=self.timeout)
        require(code == 0, f"Ctrl+Q produced exit code {code}")

    def saved(self):
        return (self.data / SAVED).read_text(encoding="utf-8").splitlines()


def run(session):
    dialogs = FileDialogs(session)
    session.start()
    session.park_mouse()
    seeded = [True, False, False, False, False]
    initial = session.wait_rows("startup", seeded)
    require(pixel(initial, 10, 10) == BACKGROUND, "background was not rendered")

    # The header menu overlays the fields and captures input until dismissed.
    session.click(MENU_X, MENU_Y)
    session.wait_pixel("menu-open", 358, 80, PANEL)
    session.type("blocked")
    session.key("Escape")
    session.wait_pixel("menu-escape", 358, 80, BACKGROUND)
    session.key("Return")
    session.wait_rows("menu-text-blocked", seeded)
    session.key("F10")
    session.key("Down")
    session.wait_pixel("menu-keyboard", 365, 118, SELECTION)
    session.key("Escape")
    session.click(MENU_X, MENU_Y)
    session.click(55, row_center(1))
    session.park_mouse()
    session.wait_rows("menu-outside-click", seeded)
    session.wait_pixel("menu-dismissed", 358, 80, BACKGROUND)

    # The add field has focus at startup.
    session.type("Buy oat milk")
    session.key("Return")
    session.wait_rows("add", seeded + [False])

    # Typing in the search field filters the list on every keystroke.
    session.key("ctrl+f")
    session.type("MILK")
    session.wait_rows("search", [False])
    session.key("ctrl+a")
    session.type("ZODO")
    session.wait_rows("search-edit", [True])
    session.key("Escape")
    session.wait_rows("search-clear", seeded + [False])

    # Clipboard copy and paste work in text fields.
    session.key("ctrl+n")
    session.type("Call Sam")
    session.key("ctrl+a")
    session.key("ctrl+c")
    session.key("End")
    session.type(" or ")
    session.key("ctrl+v")
    session.key("Return")
    session.wait_rows("paste", seeded + [False, False])

    # Clicking a checkbox toggles it, and the filters follow.
    session.click(55, row_center(1))
    session.park_mouse()
    session.wait_rows("toggle", [True, True, False, False, False, False, False])
    session.key("ctrl+3")
    session.wait_rows("filter-done", [True, True])
    session.key("ctrl+2")
    session.wait_rows("filter-active", [False] * 5)
    session.key("ctrl+1")
    session.wait_rows("filter-all", [True, True] + [False] * 5)

    # Double-clicking renames a task in place.
    session.click(300, row_center(2), repeat=2)
    session.key("ctrl+a")
    session.type("Renamed task")
    session.key("Return")

    # Delete removes the selected task, and Space toggles the next one.
    session.click(300, row_center(3))
    session.key("Delete")
    session.key("space")
    session.park_mouse()
    session.wait_rows("list-keys", [True, True, False, True, False, False])

    # Native dialog results return on SDL's event queue.
    # A Zenity stand-in supplies deterministic paths without requiring a desktop portal.
    imported = session.directory / "import tasks.md"
    imported.write_text("- [ ] Imported task\n- [x] Imported done\n", encoding="utf-8")
    dialogs.choose(imported)
    session.click(MENU_X, MENU_Y)
    session.click(420, 90)
    request = dialogs.wait_request(1)
    require("--save" not in request, "Import opened a save dialog")
    session.park_mouse()
    session.wait_rows(
        "menu-import", [True, True, False, True, False, False, False, True]
    )

    # Export commits an in-progress rename and leaves the autosave path alone.
    session.click(300, row_center(6), repeat=2)
    session.key("ctrl+a")
    session.type("Imported and renamed")
    exported = session.directory / "export tasks.md"
    dialogs.choose(exported)
    session.key("F10")
    session.key("Down")
    session.key("Return")
    request = dialogs.wait_request(2)
    require("--save" in request, "Export did not open a save dialog")
    deadline = time.monotonic() + session.timeout
    while time.monotonic() < deadline and not exported.exists():
        session.alive()
        time.sleep(0.05)
    require(exported.exists(), "Export did not write the selected file")
    require(
        "- [ ] Imported and renamed" in exported.read_text(encoding="utf-8"),
        "Export missed the in-progress rename",
    )
    dialogs.choose(None)
    session.key("ctrl+o")
    dialogs.wait_request(3)

    # Enabled highlighting confirms the cancel callback reached the app.
    session.key("F10")
    session.wait_pixel("menu-import-cancel", 365, 80, SELECTION)
    session.key("Escape")
    session.key("ctrl+e")
    dialogs.wait_request(4)
    session.key("F10")
    session.wait_pixel("menu-export-cancel", 365, 80, SELECTION)
    session.key("Escape")
    session.wait_rows(
        "menu-cancel", [True, True, False, True, False, False, False, True]
    )
    session.quit()
    expected = [
        "- [x] Open Zodo",
        "- [x] Type in the filter box to search tasks",
        "- [ ] Renamed task",
        "- [x] Drop a text or Markdown file to import its lines",
        "- [ ] Buy oat milk",
        "- [ ] Call Sam or Call Sam",
        "- [ ] Imported and renamed",
        "- [x] Imported done",
    ]
    require(session.saved() == expected, f"unexpected saved tasks: {session.saved()}")
    session.launch()
    session.park_mouse()
    session.wait_rows("reload", [True, True, False, True, False, False, False, True])

    # The Quit menu item follows the same shutdown/save path as Ctrl+Q.
    session.click(MENU_X, MENU_Y)
    session.click(420, 166)
    require(session.app.wait(timeout=session.timeout) == 0, "menu Quit failed")
    return [
        "startup and rendering",
        "header menu, keyboard navigation, and dismissal",
        "adding tasks",
        "search filtering as you type",
        "clipboard copy and paste",
        "checkbox clicks and filters",
        "rename, delete, and toggle",
        "Markdown import/export and dialog cancellation",
        "export commits an in-progress rename",
        "clean Ctrl+Q shutdown",
        "saved tasks reload",
        "menu Quit shutdown",
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--binary",
        type=Path,
        default=default_binary(),
        help="executable path (default: native build in zig-out/bin)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10,
        help="timeout per operation in seconds (default: 10)",
    )
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("this smoke test requires Linux")
    if not 0 < args.timeout <= 60:
        parser.error("--timeout must be greater than 0 and at most 60")
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"executable not found: {binary}; build first with zig build")
    missing = [name for name in ("Xvfb", "xdotool", "import") if not shutil.which(name)]
    if missing:
        parser.error(
            f"missing tools: {', '.join(missing)}; install xvfb, xdotool, imagemagick"
        )
    directory = Path(tempfile.mkdtemp(prefix="zodo-ui-"))
    session = Session(binary, directory, args.timeout)
    try:
        checks = run(session)
    except (
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        KeyboardInterrupt,
    ) as error:
        print(f"FAIL: {error}\nLogs and screenshots: {directory}", file=sys.stderr)
        return 1
    finally:
        session.close()
    shutil.rmtree(directory)
    print(json.dumps({"status": "pass", "checks": checks}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
