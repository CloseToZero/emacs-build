#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
"""Pinned macOS build. Never installs to /Applications or publishes implicitly."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import re
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CONFIG = json.loads((ROOT / "scripts/macos/config.json").read_text())
WORK = ROOT / "build/macos"
SOURCE = ROOT / "git/macos-emacs-31"
COMPILE = WORK / "compile"
PRODUCT = WORK / "product"


def run(args, *, cwd=ROOT, env=None, capture=False):
    args = [str(a) for a in args]
    print("+", " ".join(args), flush=True)
    result = subprocess.run(args, cwd=cwd, env=env, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            text=True)
    return result.stdout.strip() if capture else None


def digest(path):
    with Path(path).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(f.read()).hexdigest()


def patch_inventory():
    items = []
    for line in (ROOT / CONFIG["series"]).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        path = (ROOT / line).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise RuntimeError(f"Invalid selected patch: {line}")
        if any(p["path"] == line for p in items):
            raise RuntimeError(f"Duplicate selected patch: {line}")
        items.append({"path": line, "sha256": digest(path)})
    if not items:
        raise RuntimeError("Refusing an empty patch series")
    return items


def prepare():
    identity = {"base": CONFIG["revision"], "patches": patch_inventory()}
    marker = WORK / "prepared.json"
    WORK.mkdir(parents=True, exist_ok=True)
    if marker.exists():
        if json.loads(marker.read_text()) != identity:
            raise RuntimeError("Patch selection changed; use a fresh source/build directory")
        if run(["git", "rev-parse", "HEAD"], cwd=SOURCE, capture=True) != CONFIG["revision"]:
            raise RuntimeError("Prepared source revision changed")
        print("Using the prepared pinned source", flush=True)
        return
    if not (SOURCE / ".git").exists():
        SOURCE.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "-q", SOURCE])
        run(["git", "remote", "add", "origin", CONFIG["repository"]], cwd=SOURCE)
    if run(["git", "status", "--porcelain"], cwd=SOURCE, capture=True):
        raise RuntimeError("Source has unrecorded changes; refusing to reset it")
    if subprocess.run(["git", "cat-file", "-e", CONFIG["revision"]], cwd=SOURCE,
                      stderr=subprocess.DEVNULL).returncode:
        run(["git", "fetch", "--depth=1", "origin", CONFIG["revision"]], cwd=SOURCE)
    run(["git", "-c", "core.autocrlf=false", "checkout", "--detach", CONFIG["revision"]], cwd=SOURCE)
    for patch in identity["patches"]:
        run(["git", "apply", "--check", ROOT / patch["path"]], cwd=SOURCE)
        run(["git", "apply", ROOT / patch["path"]], cwd=SOURCE)
    marker.write_text(json.dumps(identity, indent=2) + "\n")


def validate_prepared_source():
    """Reconstruct affected files from the locked Git base, then compare bytes."""
    patches = patch_inventory()
    paths = set()
    for item in patches:
        text = (ROOT / item["path"]).read_text()
        paths.update(re.findall(r"^--- a/(.+)$", text, re.M))
        paths.update(re.findall(r"^\+\+\+ b/(.+)$", text, re.M))
    changed = set(run(["git", "diff", "--name-only", "HEAD", "-z"], cwd=SOURCE, capture=True).split("\0")) - {""}
    if changed - paths:
        raise RuntimeError(f"Unexpected source modifications: {sorted(changed - paths)}")
    with tempfile.TemporaryDirectory(prefix="emacs-patch-replay-") as directory:
        replay = Path(directory)
        for relative in paths:
            result = subprocess.run(["git", "show", CONFIG["revision"] + ":" + relative], cwd=SOURCE,
                                    check=True, capture_output=True)
            target = replay / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(result.stdout)
        for item in patches:
            run(["git", "apply", ROOT / item["path"]], cwd=replay)
        for relative in paths:
            if digest(replay / relative) != digest(SOURCE / relative):
                raise RuntimeError(f"Source differs from the selected patch payloads: {relative}")


def brew_prefix(name):
    return Path(run(["brew", "--prefix", name], capture=True))


def build(jobs):
    prepare()
    env = os.environ.copy()
    # Prefer Apple's linker/compiler to unrelated tools in a personal PATH.
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + str(brew_prefix("make") / "libexec/gnubin") + ":" + str(brew_prefix("autoconf") / "bin") + ":" + os.environ["PATH"]
    env["CC"] = run(["xcrun", "--find", "clang"], capture=True)
    env["SDKROOT"] = run(["xcrun", "--show-sdk-path"], capture=True)
    env["MACOSX_DEPLOYMENT_TARGET"] = CONFIG["minimum_macos"]
    env["LC_ALL"] = "C"
    gcc = brew_prefix("gcc")
    jit = brew_prefix("libgccjit")
    sqlite = brew_prefix("sqlite")
    gcc_exes = sorted(p for p in (gcc / "bin").glob("gcc-*") if p.name[4:].isdigit())
    if len(gcc_exes) != 1:
        raise RuntimeError("Expected one versioned GCC driver")
    driver = gcc_exes[0]
    emutls = Path(run([driver, "-print-file-name=libemutls_w.a"], capture=True)).resolve()
    if not emutls.is_file():
        raise RuntimeError("Cannot locate libemutls_w.a")
    libraries = [emutls.parent, gcc / "lib/gcc/current", jit / "lib/gcc/current", sqlite / "lib"]
    env["LIBRARY_PATH"] = ":".join(map(str, libraries))
    env["LDFLAGS"] = " ".join(f"-L{p}" for p in libraries) + f" -Wl,-rpath,{jit}/lib/gcc/current -Wl,-headerpad_max_install_names"
    packages = ["gnutls", "librsvg", "little-cms2", "tree-sitter", "webp", "sqlite", "jpeg", "giflib", "libpng", "libtiff", "gmp", "zlib"]
    prefixes = [brew_prefix(p) for p in packages]
    env["LDFLAGS"] += " " + " ".join(f"-L{p}/lib" for p in prefixes)
    env["PKG_CONFIG_PATH"] = ":".join(str(p / "lib/pkgconfig") for p in prefixes)
    env["CFLAGS"] = f"-O2 -g -fdebug-prefix-map={ROOT}=/usr/src/emacs-build -DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT " + " ".join(f"-I{p}/include" for p in [gcc, jit, *prefixes])
    env["CPPFLAGS"] = " ".join(f"-I{p}/include" for p in prefixes)
    run([SOURCE / "autogen.sh"], cwd=SOURCE, env=env)
    COMPILE.mkdir(parents=True, exist_ok=True)
    options = ["--with-ns", "--enable-ns-self-contained", "--with-native-compilation=aot",
               "--with-modules", "--with-tree-sitter", "--with-sqlite3", "--with-gnutls",
               "--with-xml2", "--with-rsvg", "--with-webp", "--with-lcms2", "--without-dbus",
               "--without-imagemagick", "--without-xwidgets", "--without-compress-install",
               "--enable-build-details"]
    run([SOURCE / "configure", *options], cwd=COMPILE, env=env)
    gmake = shutil.which("gmake")
    run([gmake, f"-j{jobs}"], cwd=COMPILE, env=env)
    run([gmake, "install"], cwd=COMPILE, env=env)
    info = {"config": CONFIG, "patches": patch_inventory(), "configure": options,
            "gcc": str(gcc.resolve()), "gcc_driver": str(driver), "emutls_directory": str(emutls.parent),
            "libgccjit": str(jit.resolve()), "sdk": env["SDKROOT"], "compiler": env["CC"],
            "dependencies": json.loads(run(["brew", "info", "--json=v2", "--installed"], capture=True))}
    (WORK / "build-environment.json").write_text(json.dumps(info, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "build", "bundle", "sources", "verify", "archive", "all"], nargs="?", default="all")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 2, 8))
    args = parser.parse_args()
    if args.action != "prepare" and (platform.system() != "Darwin" or platform.machine() != CONFIG["architecture"]):
        parser.error("Building and packaging currently require an Apple Silicon macOS host")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.action == "prepare":
        prepare()
    elif args.action == "build":
        build(args.jobs)
    elif args.action == "sources":
        from sources import collect
        collect()
    else:
        from bundle import bundle, archive
        from verify import verify
        if args.action == "all":
            build(args.jobs)
        if args.action in ("bundle", "all"):
            bundle()
        if args.action in ("verify", "all"):
            verify()
        if args.action in ("archive", "all"):
            archive()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
