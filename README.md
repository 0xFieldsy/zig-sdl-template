# Zig SDL Template

A template for desktop graphical applications using Zig [0.16.0](https://codeberg.org/ziglang/zig/src/tag/0.16.0), [SDL3](https://github.com/castholm/SDL), [SDL_ttf](https://github.com/libsdl-org/SDL_ttf), and [SDL_image](https://github.com/libsdl-org/SDL_image).

Zodo, a to-do list, is the demo application. It has text input, clipboard, mouse and keyboard focus, TrueType text, SVG icons, high-DPI scaling, file drops, and saving to the user's data directory.

## Usage

```sh
gh repo clone 0xFieldsy/zig-sdl-template your-app
cd your-app
zig build
```

The build downloads SDL, SDL_ttf, SDL_image, and FreeType as pinned in [build.zig.zon](build.zig.zon) and links them statically; you don't need separate installations. It also downloads the Inter 4.1 release archive and embeds its variable TrueType font, using the regular and semibold instances. Zig caches these dependencies for subsequent builds.

`zig build` installs the demo executable to `zig-out/bin/zodo-<arch>-<os>-<abi>`. For example, the default build on x86_64 Linux produces `zig-out/bin/zodo-x86_64-linux-gnu`. Architecture, OS, and ABI names follow Zig's target names. macOS has no ABI, so its binaries use `none`.

`zig build run` opens the app window and needs a working desktop display and graphics drivers. Builds and logic tests can run on a headless machine using the [UI smoke test](#ui-smoke-test).

The build defaults to the baseline CPU for the target architecture. This avoids requiring the destination machine to support the build machine's AVX instructions. Keep that default for binaries you distribute; the `-Dcpu=native` target is for binaries that will run on the build machine.

### Windows

Build for x86_64 Windows:

```bash
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

The output is `zig-out/bin/zodo-x86_64-windows-gnu.exe`. This target uses baseline x86_64 with the GNU ABI. Zig supplies the toolchain, so a separate MinGW installation isn't required.

### macOS

On an ARM64 Mac:

```bash
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
```

SDL compiles against Apple's framework headers, such as Cocoa, Metal, and Core Audio, so macOS builds require a Mac with Xcode or the Command Line Tools installed. The build locates the macOS SDK with `xcrun`. Cross-compiling for macOS from Linux or Windows isn't supported.

The output is `zig-out/bin/zodo-aarch64-macos-none`. It targets macOS 13 or later and uses baseline ARM64. App bundles, signing, and notarization require additional packaging work. macOS may require approval for an unsigned executable.

### Libraries

SDL_ttf, SDL_image, and FreeType publish release tarballs without Zig build files, so [build.zig](build.zig) compiles their C sources into static libraries:

- SDL_ttf renders text with FreeType. HarfBuzz and plutosvg are left out, so text uses FreeType's kerning without complex-script shaping, and color emoji aren't drawn.
- SDL_image loads PNG and JPEG with stb_image and SVG with nanosvg, which are bundled with SDL_image. macOS uses the same decoders instead of ImageIO.

[src/sdl.h](src/sdl.h) includes all three libraries' headers, which Zig translates into the `sdl` module.

## Testing

Format changed Zig files and run the logic tests:

```bash
zig fmt build.zig build.zig.zon src
zig build test
```

### UI Smoke Test

On Linux, the smoke script launches the demo on a private Xvfb display with SDL's software renderer. SDL is forced to use X11 so an inherited Wayland session can't bypass the private display, and saved tasks go to a temporary data directory. It types tasks and searches, copies and pastes, clicks checkboxes and filters, renames, deletes, exercises the header menu, and checks that the saved list reloads. Import, export, and cancellation run through SDL's Zenity backend with a temporary stand-in that supplies file paths, so the smoke test doesn't need a desktop portal or Zenity installation:

```bash
sudo apt-get install -y xvfb xdotool imagemagick
zig build
python3 scripts/smoke-ui.py
```

The default executable path selects the native Linux build in `zig-out/bin`.

The script prints a JSON result on success and removes temporary files. On failure it returns a nonzero exit code and prints the directory containing logs, PPM screenshots, and saved data.

Use `--binary PATH` to check a different Linux build of the demo or `--timeout SECONDS` to change the timeout per operation (default: 10 seconds). Update its checks when replacing the demo.

xdotool's non-ASCII keystrokes sometimes produce no SDL text event under Xvfb, so the script types ASCII; the logic tests cover Unicode editing.

## Zodo Demo

Type a task in the top field and press <kbd>Enter</kbd> to add it. Typing in the filter field narrows the list as you type, matching every word without regard to ASCII case and highlighting the matches. The _All_, _Active_, and _Done_ tabs filter by state. Click a checkbox to complete a task, double-click a task to rename it, and use × to delete it.

The hamburger button at the right of the header opens _Import Markdown…_, _Export Markdown…_, and _Quit_. Import adds tasks to the current list; export writes a Markdown copy to the selected file. Both use native file dialogs. Linux needs a working desktop file chooser through XDG Desktop Portal or Zenity. Tasks continue to autosave in the per-user data directory.

Press <kbd>F10</kbd> to toggle the menu, use <kbd>↑</kbd>/<kbd>↓</kbd> or <kbd>Home</kbd>/<kbd>End</kbd> to select an item, and press <kbd>Enter</kbd> or <kbd>Space</kbd> to activate it. <kbd>Esc</kbd>, <kbd>Tab</kbd>, or a click outside the menu dismisses it and restores input to the previous field.

| Key | Action |
| --- | --- |
| Tab / Shift+Tab | Move between the add field, the filter field, and the list |
| Ctrl+N / Ctrl+F | Focus the add field / the filter field |
| Ctrl+1 / 2 / 3 | Show all, active, or done tasks |
| Enter | Add a task, move from the filter to the list, rename the selected task, or finish renaming |
| Escape | Clear the field, cancel a rename, or clear the selection |
| Up / Down | Move between the fields and through the list |
| Space | Complete or reopen the selected task |
| F2 | Rename the selected task |
| Delete / Backspace | Delete the selected task |
| Ctrl+A / C / X / V | Select all, copy, cut, and paste in text fields |
| Ctrl+Left / Right, Ctrl+Backspace / Delete | Move or delete by word |
| Ctrl+O / Ctrl+E | Import / export Markdown through a file dialog |
| F10 | Open or close the header menu |
| Ctrl+Q | Quit |

On macOS, use <kbd>⌘</kbd> for the shortcuts and <kbd>Option</kbd> to move by word.

Text fields support selection with <kbd>Shift</kbd> and the mouse, double-click to select a word, and triple-click to select everything. Input method composition, such as for Japanese or Chinese, is drawn at the cursor, and the candidate window is placed beside the field.

Tasks are saved as a Markdown checklist (`- [ ] task`) in SDL's per-user data directory, under a single `zodo` directory:

| Platform | Task file |
| --- | --- |
| Linux | `$XDG_DATA_HOME/zodo/tasks.md` or `$HOME/.local/share/zodo/tasks.md` |
| macOS | `~/Library/Application Support/zodo/tasks.md` |
| Windows | `%APPDATA%\zodo\tasks.md` |

Dropping a text or Markdown file, or dragging text, onto the window adds each line as a task; checklist markers are kept.

The interface uses [Inter](https://rsms.me/inter/) (SIL Open Font License, see [assets/Inter-LICENSE.txt](assets/Inter-LICENSE.txt)) and SVG icons rasterized at the display's scale.
