const std = @import("std");

pub fn build(b: *std.Build) void {
    // Avoid native CPU features to make the binaries portable.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zodo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.step("test", "Run tests");
    const artifact = b.addTest(.{ .root_module = mod });
    tests.dependOn(&b.addRunArtifact(artifact).step);

    const exe = addApp(b, target, optimize, mod) orelse return;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the app").dependOn(&run.step);
}

fn addApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
) ?*std.Build.Step.Compile {
    const inter_dep = b.lazyDependency("inter", .{});
    const assets = b.createModule(.{ .root_source_file = b.path("assets/assets.zig") });
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zodo", .module = mod },
            // Fonts and icons are embedded so the executable is self-contained.
            .{ .name = "assets", .module = assets },
        },
    });
    if (!addSdl(b, target, optimize, app)) return null;
    const inter = inter_dep orelse return null;
    assets.addAnonymousImport("inter_font", .{
        .root_source_file = inter.path("InterVariable.ttf"),
    });

    return b.addExecutable(.{
        .name = b.fmt("zodo-{s}-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        }),
        .root_module = app,
    });
}

fn sdkPath(b: *std.Build, sdk: []const u8, sub_path: []const u8) std.Build.LazyPath {
    return .{ .cwd_relative = b.pathJoin(&.{ sdk, sub_path }) };
}

fn addSdl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app: *std.Build.Module,
) bool {
    // SDL compiles against the macOS SDK and requires its paths for non-native targets, including
    // the default baseline CPU. Locate the local Xcode SDK, and report a missing one only for the
    // app steps, keeping tests usable.
    const sdk = if (target.result.os.tag == .macos and !target.query.isNative())
        std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse {
            const missing_sdk = b.addFail(
                "SDL builds for macOS require a Mac with Xcode or the Command Line Tools installed.",
            );
            b.getInstallStep().dependOn(&missing_sdk.step);
            b.step("run", "Run the app").dependOn(&missing_sdk.step);
            return false;
        }
    else
        null;

    // Request every lazy package before checking the results so a fresh checkout fetches them all.
    const sdl_dep = b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
        .system_include_path = if (sdk) |path| sdkPath(b, path, "usr/include") else @as(?std.Build.LazyPath, null),
        .system_framework_path = if (sdk) |path| sdkPath(b, path, "System/Library/Frameworks") else @as(?std.Build.LazyPath, null),
        .library_path = if (sdk) |path| sdkPath(b, path, "usr/lib") else @as(?std.Build.LazyPath, null),
    });
    const ttf_dep = b.lazyDependency("sdl_ttf", .{});
    const image_dep = b.lazyDependency("sdl_image", .{});
    const freetype_dep = b.lazyDependency("freetype", .{});
    const sources: CSources = .{
        .sdl = sdl_dep orelse return false,
        .ttf = ttf_dep orelse return false,
        .image = image_dep orelse return false,
        .freetype = freetype_dep orelse return false,
        .sdk = sdk,
    };
    const sdl_c = sources.sdl.artifact("SDL3");

    const bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    bindings.addIncludePath(sources.sdl.path("include"));
    bindings.addIncludePath(sources.ttf.path("include"));
    bindings.addIncludePath(sources.image.path("include"));

    if (target.result.os.tag == .windows and target.result.abi == .gnu) {
        // Zig 0.16 mistranslates MinGW's fortified wchar inline helpers.
        // Disable those wrappers only for header translation; SDL's C
        // compilation and the executable keep their optimization mode.
        bindings.defineCMacro("_FORTIFY_SOURCE", "0");
    }
    if (target.result.os.tag == .macos) {
        if (sdk) |path| bindings.addSystemIncludePath(sdkPath(b, path, "usr/include"));
        // Search paths on SDL's archive aren't inherited by the exe.
        for (sdl_c.root_module.include_dirs.items) |include_dir| switch (include_dir) {
            .framework_path => |path| app.addFrameworkPath(path),
            .framework_path_system => |path| app.addSystemFrameworkPath(path),
            else => {},
        };
        for (sdl_c.root_module.lib_paths.items) |path| app.addLibraryPath(path);
    }

    app.addImport("sdl", bindings.createModule());
    app.linkLibrary(addSdlTtf(b, target, optimize, sources));
    app.linkLibrary(addSdlImage(b, target, optimize, sources));
    app.linkLibrary(sdl_c);

    return true;
}

const CSources = struct {
    sdl: *std.Build.Dependency,
    ttf: *std.Build.Dependency,
    image: *std.Build.Dependency,
    freetype: *std.Build.Dependency,
    sdk: ?[]const u8,
};

/// Creates a static C library that can include SDL's headers.
fn addCLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sources: CSources,
    name: []const u8,
) *std.Build.Step.Compile {
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(sources.sdl.path("include"));
    if (sources.sdk) |path| lib_mod.addSystemIncludePath(sdkPath(b, path, "usr/include"));
    if (target.result.os.tag == .windows) {
        lib_mod.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
        lib_mod.addCMacro("_CRT_NONSTDC_NO_WARNINGS", "1");
    }
    return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = lib_mod });
}

/// SDL_ttf with a vendored FreeType. HarfBuzz and plutosvg are disabled, so shaping is FreeType's
/// basic kerning and color emoji aren't drawn.
fn addSdlTtf(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sources: CSources,
) *std.Build.Step.Compile {
    const lib = addCLibrary(b, target, optimize, sources, "SDL3_ttf");
    const lib_mod = lib.root_module;
    lib_mod.addIncludePath(sources.ttf.path("include"));
    lib_mod.addIncludePath(sources.freetype.path("include"));
    lib_mod.addCSourceFiles(.{
        .root = sources.ttf.path("src"),
        .files = &.{
            "SDL_hashtable.c",
            "SDL_hashtable_ttf.c",
            "SDL_gpu_textengine.c",
            "SDL_renderer_textengine.c",
            "SDL_surface_textengine.c",
            "SDL_ttf.c",
        },
    });

    // FreeType's portable stream and debug implementations avoid the configure-generated headers
    // its Unix and Windows variants expect.
    lib_mod.addCSourceFiles(.{
        .root = sources.freetype.path("src"),
        .files = &.{
            "autofit/autofit.c",
            "base/ftbase.c",
            "base/ftbbox.c",
            "base/ftbdf.c",
            "base/ftbitmap.c",
            "base/ftcid.c",
            "base/ftdebug.c",
            "base/ftfstype.c",
            "base/ftgasp.c",
            "base/ftglyph.c",
            "base/ftgxval.c",
            "base/ftinit.c",
            "base/ftmm.c",
            "base/ftotval.c",
            "base/ftpatent.c",
            "base/ftpfr.c",
            "base/ftstroke.c",
            "base/ftsynth.c",
            "base/ftsystem.c",
            "base/fttype1.c",
            "base/ftwinfnt.c",
            "bdf/bdf.c",
            "cache/ftcache.c",
            "cff/cff.c",
            "cid/type1cid.c",
            "gzip/ftgzip.c",
            "hvf/hvf.c",
            "lzw/ftlzw.c",
            "pcf/pcf.c",
            "pfr/pfr.c",
            "psaux/psaux.c",
            "pshinter/pshinter.c",
            "psnames/psnames.c",
            "raster/raster.c",
            "sdf/sdf.c",
            "sfnt/sfnt.c",
            "smooth/smooth.c",
            "svg/svg.c",
            "truetype/truetype.c",
            "type1/type1.c",
            "type42/type42.c",
            "winfonts/winfnt.c",
        },
        .flags = &.{"-DFT2_BUILD_LIBRARY"},
    });

    return lib;
}

/// SDL_image with its built-in decoders: stb_image for PNG and JPEG, and nanosvg for SVG.
/// Saving and formats needing external libraries are off.
fn addSdlImage(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sources: CSources,
) *std.Build.Step.Compile {
    const lib = addCLibrary(b, target, optimize, sources, "SDL3_image");
    const lib_mod = lib.root_module;
    lib_mod.addIncludePath(sources.image.path("include"));
    lib_mod.addCMacro("USE_STBIMAGE", "1");

    // Use stb_image on macOS too, rather than the ImageIO framework.
    lib_mod.addCMacro("SDL_IMAGE_USE_COMMON_BACKEND", "1");

    for ([_][]const u8{ "LOAD_PNG", "LOAD_JPG", "LOAD_SVG" }) |format| lib_mod.addCMacro(format, "1");
    for ([_][]const u8{ "SAVE_PNG", "SAVE_JPG" }) |format| lib_mod.addCMacro(format, "0");

    lib_mod.addCSourceFiles(.{
        .root = sources.image.path("src"),
        .files = &.{
            "IMG.c",
            "IMG_WIC.c",
            "IMG_ani.c",
            "IMG_anim_encoder.c",
            "IMG_anim_decoder.c",
            "IMG_avif.c",
            "IMG_bmp.c",
            "IMG_gif.c",
            "IMG_gpu.c",
            "IMG_jpg.c",
            "IMG_jxl.c",
            "IMG_lbm.c",
            "IMG_pcx.c",
            "IMG_png.c",
            "IMG_pnm.c",
            "IMG_qoi.c",
            "IMG_stb.c",
            "IMG_svg.c",
            "IMG_tga.c",
            "IMG_tif.c",
            "IMG_webp.c",
            "IMG_xcf.c",
            "IMG_xpm.c",
            "IMG_xv.c",
            "IMG_libpng.c",
            "xmlman.c",
        },
    });

    return lib;
}
