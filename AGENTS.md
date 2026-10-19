# AGENTS.md / CLAUDE.md

This is a reusable Zig and SDL3 template with SDL_ttf and SDL_image. Zodo, a to-do list with search filtering, is the demo.

## Architecture

- Keep application logic independent of SDL and platform I/O in `src/root.zig`. This lets logic tests run without a display. `src/main.zig` owns the layout, drawing, mouse handling, key mapping, and saving. `src/platform.zig` wraps the SDL3, SDL_ttf, and SDL_image calls the demo uses for windows, events, text input, clipboard, files, drawing, text, and icons; extend it for new features or call the C API through `platform.sdl`.
- Keep native file-dialog callbacks in `src/platform.zig` and pass their results through SDL's event queue. Callbacks can run on another thread; don't access `Ui`, `App`, or their allocator there. Release each `FileDialogResult` with `deinit` on the main thread.
- `src/sdl.h` is translated into the `sdl` module at build time. Add other SDL headers there.
- `assets/` holds SVG icons and `Inter-LICENSE.txt`; `assets/assets.zig` exposes the icons and the Inter font to `src/platform.zig` through the `assets` module. The build fetches the Inter 4.1 release archive as a pinned lazy dependency and exposes `InterVariable.ttf` through an anonymous import. Keep the local license file. When upgrading Inter, verify the named instance indices in `src/platform.zig` (instance 6 is SemiBold; the default face is Regular).
- When building a different app, replace the Zodo logic, UI, assets, tests, and documentation to match that app. Preserve the reusable build support unless the task calls for changing it.
- The demo executable names use `zodo-<arch>-<os>-<abi>` in `build.zig`, matching Zig's target names; the module/import and package name remain `zodo`. Keep the module name and its import in `src/main.zig` in sync when renaming them. A package rename in `build.zig.zon` also requires updating its fingerprint to the value suggested by Zig's validation.
- Zodo saves tasks to `zodo/tasks.md` in SDL's per-user data directory (`SDL_GetPrefPath`). Keep `pref_org` empty to omit an organization subdirectory; change `pref_app` in `src/main.zig` for another app.
- Update `scripts/smoke-ui.py` when replacing the demo or changing its UI. Its window dimensions, colors, list coordinates, key sequences, saved-file path, and assertions are specific to Zodo. `--binary` only changes the executable path; it does not adapt the checks to another app.
- Keep shared smoke-test display, input, logging, and process helpers in `scripts/lib/`. The smoke script imports the `lib` package (`scripts/lib/__init__.py`); adapt its binary name and window search when replacing the demo.
- Update this file and [README.md](README.md) when commands or architecture change. Keep instructions portable across project folder names.

## Building

- Use Zig 0.16.0 and the SDL dependency pinned in `build.zig.zon`: castholm/SDL `v0.6.0+3.4.18`. Its manifest lists Zig 0.17, but the tag supports this template's Zig 0.16 build.
- SDL_ttf 3.2.2, SDL_image 3.4.8, and FreeType 2.15.0 are release tarballs without Zig build files. `build.zig` compiles them as static libraries. SDL_ttf uses FreeType without HarfBuzz or plutosvg; SDL_image uses its built-in stb_image and nanosvg decoders for PNG, JPEG, and SVG. Update the source lists in `build.zig` when upgrading them.
- Run `zig fmt` on changed Zig files and `zig build` for source or build changes. Run `zig build test` for application logic changes; it runs the tests in `src/root.zig` without initializing the GUI.
- All targets install to `zig-out/bin` with names `zodo-{aarch64,x86_64}-{linux,macos,windows}-{gnu,msvc,musl,none}` (`.exe` on Windows). macOS uses `none` for the ABI. `msvc` can only be compiled on Windows. The smoke test defaults to the native Linux build; pass `--binary` for another path.
- `zig build` defaults to the host OS and architecture. Select cross-build targets with `-Dtarget`. macOS builds need a Mac with Xcode or the Command Line Tools; `build.zig` locates the SDK with `xcrun`.
- The smoke script forces SDL's X11 video driver and software renderer so it uses the private Xvfb display, and sets `XDG_DATA_HOME` to a temporary directory so it doesn't touch saved tasks.
- File-dialog smoke checks use `scripts/lib/__init__.py` to supply a temporary Zenity stand-in. Keep this override confined to the smoke session; the app uses SDL's native dialog selection.
- Under Xvfb, xdotool's non-ASCII keystrokes sometimes produce no SDL text event, so the smoke test types ASCII. Cover Unicode text handling with tests in `src/root.zig`.

## Boundaries

- Keep baseline CPU targeting for distributable binaries. Native CPU features can cause illegal-instruction failures when copying binaries between machines.
- Inter, SDL, SDL_ttf, SDL_image, and FreeType are declared lazy. Keep `build.zig` handling the null result `lazyDependency` returns before Zig has fetched each package, and request all packages before returning for a missing dependency.
- Report a missing macOS SDK through the install and run steps instead of failing build-graph configuration, so logic tests remain available.
- Preserve the macOS framework/library-path forwarding in `build.zig` when refactoring the build. Search paths on SDL's static archive aren't inherited by the executable.
- Keep the MinGW `_FORTIFY_SOURCE=0` workaround limited to header translation. It avoids a Zig 0.16 translation bug without changing SDL's C compilation.
- Keep `build.zig.zon`'s `.paths` list in sync when adding files needed by the packaged project.
- Don't cross-compile unless explicitly asked to.
