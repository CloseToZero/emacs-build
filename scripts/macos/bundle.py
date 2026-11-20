# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
"""Bundle Mach-O dependencies using loader-relative references, fail closed."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

from build import CONFIG, ROOT, WORK, COMPILE, PRODUCT, SOURCE, digest, patch_inventory, run, validate_prepared_source

APP = PRODUCT / "Emacs.app"
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as f:
        header = f.read(16)
    if header[:4] not in MAGIC:
        return False
    # Relocatable GCC CRT objects are link inputs, not loadable/signable images.
    if header[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") and int.from_bytes(header[12:16], "little") == 1:
        return False
    return True


def system_library(path):
    return path.startswith(("/usr/lib/", "/System/Library/"))


def inspect(path):
    text = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
    deps, rpaths, identifier, minimums = [], [], None, []
    for block in text.split("Load command ")[1:]:
        cmd = re.search(r"^\s*cmd (\S+)", block, re.M)
        if not cmd:
            continue
        cmd = cmd.group(1)
        if cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_ID_DYLIB"):
            name = re.search(r"^\s*name (.*?) \(offset \d+\)", block, re.M).group(1)
            if cmd == "LC_ID_DYLIB":
                identifier = name
            else:
                deps.append(name)
        elif cmd == "LC_RPATH":
            rpaths.append(re.search(r"^\s*path (.*?) \(offset \d+\)", block, re.M).group(1))
        elif cmd in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX"):
            field = "minos" if cmd == "LC_BUILD_VERSION" else "version"
            minimums.extend(re.findall(r"^\s*" + field + r" (\d+(?:\.\d+)+)", block, re.M))
    return deps, rpaths, identifier, minimums


def expand_token(name, loader, executable):
    for token, directory in (("@loader_path", loader.parent), ("@executable_path", executable.parent)):
        if name == token or name.startswith(token + "/"):
            return directory / name[len(token):].lstrip("/")
    if name.startswith("/"):
        return Path(name)
    return None


def resolve(name, original, executable, rpaths):
    direct = expand_token(name, original, executable)
    if direct is not None:
        if direct.is_file():
            return direct.resolve()
        raise RuntimeError(f"Missing dependency {name} from {original}")
    if name.startswith("@rpath/"):
        matches = []
        for rpath in rpaths:
            directory = expand_token(rpath, original, executable)
            if directory is None:
                continue
            candidate = directory / name[len("@rpath/"):]
            if candidate.is_file() and candidate.resolve() not in matches:
                matches.append(candidate.resolve())
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1 and len({digest(p) for p in matches}) == 1:
            return matches[0]
        raise RuntimeError(f"Unresolved or ambiguous dependency {name} from {original}: {matches}")
    raise RuntimeError(f"Unsupported dependency {name} from {original}")


def assert_minimum(versions, path):
    target = tuple(map(int, CONFIG["minimum_macos"].split(".")))
    for version in versions:
        parts = tuple(map(int, version.split(".")))
        if parts + (0,) * (3 - len(parts)) > target + (0,) * (3 - len(target)):
            raise RuntimeError(f"{path} requires macOS {version}, above {CONFIG['minimum_macos']}")


def relocate(app, originals):
    """Every dependency is resolved against its original loader before copying.

    No searching arbitrary Cellar versions, no silent missing dependencies, no
    absolute rpaths. Same-basename collisions with different content are fatal.
    """
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    main_original = originals[app / "Contents/MacOS/Emacs"]
    main_rpaths = inspect(main_original)[1]
    queued = list(originals)
    processed, names, provenance = set(), {}, []
    while queued:
        dest = queued.pop(0)
        if dest in processed:
            continue
        processed.add(dest)
        original = originals[dest]
        deps, rpaths, identifier, minimums = inspect(original)
        assert_minimum(minimums, original)
        args = ["/usr/bin/install_name_tool"]
        if identifier:
            args += ["-id", "@rpath/" + dest.name]
        for dep in deps:
            if system_library(dep):
                continue
            source = resolve(dep, original, main_original, [*rpaths, *main_rpaths])
            if source.name in names and names[source.name] != source:
                if digest(names[source.name]) != digest(source):
                    raise RuntimeError(f"Conflicting library basename: {source.name}")
            else:
                names[source.name] = source
            target = frameworks / source.name
            if target not in originals:
                if target.exists():
                    raise RuntimeError(f"Library would overwrite an existing file: {target}")
                shutil.copy2(source, target)
                target.chmod(0o755)
                originals[target] = source
                queued.append(target)
                provenance.append({"name": source.name, "source": str(source), "source_sha256": digest(source)})
            relative = os.path.relpath(target, dest.parent)
            args += ["-change", dep, "@loader_path/" + relative]
        for rpath in dict.fromkeys(inspect(dest)[1]):
            args += ["-delete_rpath", rpath]
        if len(args) > 1:
            run([*args, dest])
    return provenance


def audit(app):
    paths = []
    for path in app.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()) or not path.exists():
                raise RuntimeError(f"External or broken symlink: {path}")
        if not macho(path):
            continue
        deps, rpaths, _, minimums = inspect(path)
        assert_minimum(minimums, path)
        if rpaths:
            raise RuntimeError(f"Unexpected runtime search path: {path}: {rpaths}")
        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if CONFIG["architecture"] not in archs:
            raise RuntimeError(f"Wrong architecture: {path}: {archs}")
        for dep in deps:
            if system_library(dep):
                continue
            if not dep.startswith("@loader_path/"):
                raise RuntimeError(f"Non-relocatable load command: {path}: {dep}")
            target = (path.parent / dep[len("@loader_path/"):]).resolve()
            if not target.is_relative_to(app.resolve()) or not target.is_file():
                raise RuntimeError(f"Unbundled dependency: {path}: {dep}")
        paths.append(path)
    if not paths:
        raise RuntimeError("No Mach-O files found")
    return paths


def copy_toolchain(environment):
    gcc = Path(environment["gcc"])
    toolchain = APP / "Contents/Toolchain"
    binary, libraries = toolchain / "bin", toolchain / "lib"
    binary.mkdir(parents=True)
    libraries.mkdir()
    driver = Path(environment["gcc_driver"])
    # libgccjit generates machine code internally; cc1 and language frontends
    # are not needed. The driver, collect2, CRT objects and runtime archives are.
    shutil.copy2(driver, binary / driver.name)
    (binary / "gcc").symlink_to(driver.name)
    collect = Path(run([driver, "-print-prog-name=collect2"], capture=True))
    if not collect.is_file():
        raise RuntimeError("Cannot locate GCC collect2")
    shutil.copy2(collect, binary / "collect2")
    libdir = Path(environment["emutls_directory"])
    for pattern in ("libgcc*.a", "libemutls_w.a", "libheapt_w.a", "crt*.o"):
        for source in libdir.glob(pattern):
            shutil.copy2(source, libraries / source.name)
    runtime = gcc / "lib/gcc/current"
    for source in runtime.glob("libgcc_s*.dylib"):
        if not source.is_symlink():
            shutil.copy2(source, libraries / source.name)
    return {dest: (driver if dest.name == driver.name else collect) for dest in binary.iterdir() if macho(dest)} | {dest: runtime / dest.name for dest in libraries.iterdir() if macho(dest)}


def client_app():
    """Compile an AppleEvent-aware client against the advertised minimum OS."""
    client = PRODUCT / "Emacs Client.app"
    if client.exists():
        shutil.rmtree(client)
    contents = client / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-O2", "-framework", "AppKit",
         "-mmacosx-version-min=" + CONFIG["minimum_macos"], ROOT / "scripts/macos/client.m",
         "-o", contents / "MacOS/EmacsClient"])
    plist = dict(CFBundleIdentifier="org.gnu.EmacsClient", CFBundleName="Emacs Client",
                 CFBundleExecutable="EmacsClient", CFBundlePackageType="APPL", CFBundleInfoDictionaryVersion="6.0",
                 CFBundleShortVersionString=CONFIG["version"], CFBundleVersion=CONFIG["version"],
                 LSMinimumSystemVersion=CONFIG["minimum_macos"], LSUIElement=True,
                 CFBundleDocumentTypes=[{"CFBundleTypeName": "Text", "CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.text"]}],
                 CFBundleURLTypes=[{"CFBundleURLName": "Org Protocol", "CFBundleURLSchemes": ["org-protocol"]}])
    icon = APP / "Contents/Resources/Emacs.icns"
    if icon.exists():
        shutil.copy2(icon, contents / "Resources/Emacs.icns")
        plist["CFBundleIconFile"] = "Emacs.icns"
    with (contents / "Info.plist").open("wb") as f:
        plistlib.dump(plist, f)
    audit(client)
    run(["/usr/bin/codesign", "--force", "--sign", "-", client])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", client])


def bundle():
    if not (WORK / "build-environment.json").exists():
        raise RuntimeError("Run the build action first")
    environment = json.loads((WORK / "build-environment.json").read_text())
    validate_prepared_source()
    if environment["patches"] != patch_inventory():
        raise RuntimeError("Patch payloads changed since compilation")
    if PRODUCT.exists():
        shutil.rmtree(PRODUCT)
    PRODUCT.mkdir(parents=True)
    original_app = COMPILE / "nextstep/Emacs.app"
    shutil.copytree(original_app, APP, symlinks=True)
    originals = {p: original_app / p.relative_to(APP) for p in APP.rglob("*") if macho(p)}
    originals.update(copy_toolchain(environment))
    provenance = relocate(APP, originals)
    resources = APP / "Contents/Resources"
    (resources / "site-lisp").mkdir(exist_ok=True)
    shutil.copy2(ROOT / "scripts/macos/site-start.el", resources / "site-lisp/site-start.el")
    shutil.copy2(ROOT / "scripts/macos/fonts.conf", resources / "fonts.conf")
    cli = APP / "Contents/MacOS/bin"
    cli.mkdir(exist_ok=True)
    plist_path = APP / "Contents/Info.plist"
    with plist_path.open("rb") as f:
        plist = plistlib.load(f)
    plist.pop("LSEnvironment", None)
    plist.update(CFBundleVersion=CONFIG["version"], CFBundleShortVersionString=CONFIG["version"],
                 LSMinimumSystemVersion=CONFIG["minimum_macos"], NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac=True,
                 NSCameraUsageDescription="Emacs requires permission to access the camera.",
                 NSMicrophoneUsageDescription="Emacs requires permission to access the microphone.",
                 NSSpeechRecognitionUsageDescription="Emacs requires permission for speech recognition.")
    with plist_path.open("wb") as f:
        plistlib.dump(plist, f)
    license_dir = resources / "licenses"
    license_dir.mkdir(exist_ok=True)
    shutil.copy2(SOURCE / "COPYING", license_dir / "Emacs-GPL-3.0.txt")
    # Record every formula actually used by the bundled dependency closure.
    cellars = {Path(item["source"]).parts[4] for item in provenance if item["source"].startswith("/opt/homebrew/Cellar/")}
    cellars.update(("gcc", "libgccjit"))
    receipts = []
    for formula in sorted(cellars):
        candidates = list(Path("/opt/homebrew/Cellar", formula).glob("*/INSTALL_RECEIPT.json"))
        # Identify the actual installed version from the source paths, not a
        # random formula version. GCC/libgccjit are explicitly pinned above.
        used = [p for p in candidates if any(str(p.parent) + "/" in item["source"] for item in provenance) or str(p.parent) in (environment["gcc"], environment["libgccjit"])]
        if len(used) != 1:
            raise RuntimeError(f"Cannot determine exact dependency receipt: {formula}: {used}")
        prefix = used[0].parent
        target = license_dir / formula
        target.mkdir()
        for directory in (prefix / "share/licenses", prefix / ".brew"):
            if directory.exists():
                shutil.copytree(directory, target / directory.name, symlinks=False)
        for pattern in ("COPYING*", "LICENSE*", "LICENCE*", "AUTHORS*", "NOTICE*"):
            for notice in prefix.glob(pattern):
                if notice.is_file():
                    shutil.copy2(notice, target / notice.name)
        receipts.append({"formula": formula, "version": prefix.name, "receipt": json.loads(used[0].read_text())})
    (WORK / "dependency-inventory.json").write_text(json.dumps(receipts, indent=2) + "\n")
    from sources import collect, copy_rust_notices
    collect()
    copy_rust_notices(license_dir)
    shutil.copy2(ROOT / "LICENSE", license_dir / "emacs-build-MIT.txt")
    shutil.copy2(ROOT / "patches/macos/emacs-plus-LICENSE", license_dir / "emacs-plus-MIT.txt")
    public = {"upstream": CONFIG, "patches": environment["patches"], "signing": "ad-hoc; not notarized",
              "jit_requirements": "Xcode Command Line Tools (SDK, system assembler/linker); no Homebrew required",
              "dependencies": [{"formula": x["formula"], "version": x["version"]} for x in receipts],
              "native_lisp_files": len(list(APP.rglob("*.eln"))),
              "recipe_commit": run(["git", "rev-parse", "HEAD"], capture=True)}
    (resources / "build-info.json").write_text(json.dumps(public, indent=2) + "\n")
    (WORK / "bundled-libraries.json").write_text(json.dumps(provenance, indent=2) + "\n")
    finish_product()


def finish_product():
    # Apple treats everything below Contents/MacOS as nested code. Upstream
    # installs shell helpers there; keep those under Resources and use internal
    # compatibility symlinks so script signatures do not depend on xattrs.
    for name in ("bin", "libexec"):
        original = APP / "Contents/MacOS" / name
        target = APP / "Contents/Resources" / name
        if original.is_dir() and not original.is_symlink():
            if target.exists():
                raise RuntimeError(f"Cannot relocate helper directory over {target}")
            original.rename(target)
            original.symlink_to("../Resources/" + name)
    wrapper = APP / "Contents/Resources/bin/emacs"
    wrapper.write_text('#!/bin/sh\ncontents="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"\nexec "$contents/MacOS/Emacs" "$@"\n')
    wrapper.chmod(0o755)
    main = APP / "Contents/MacOS/Emacs"
    for path in audit(APP):
        if path != main:
            run(["/usr/bin/codesign", "--force", "--sign", "-", path])
    run(["/usr/bin/codesign", "--force", "--sign", "-", APP])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", APP])
    client_app()
    (PRODUCT / "README.txt").write_text((ROOT / "scripts/macos/package-readme.txt").read_text())
    (WORK / "bundle-identity.json").write_text(json.dumps(product_identity(), indent=2) + "\n")


def product_identity(root=PRODUCT):
    result = {}
    for path in sorted(root.rglob("*")):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[name] = {"sha256": digest(path), "mode": path.stat().st_mode & 0o777}
    return result


def archive():
    """Only archive the exact product that passed relocated verification."""
    verification = json.loads((WORK / "verification.json").read_text())
    if run(["git", "status", "--porcelain"], capture=True):
        raise RuntimeError("Commit the build recipe before producing release archives")
    public_info = json.loads((APP / "Contents/Resources/build-info.json").read_text())
    if public_info["recipe_commit"] != run(["git", "rev-parse", "HEAD"], capture=True):
        raise RuntimeError("Rebundle and verify against the committed build recipe")
    validate_prepared_source()
    if not verification.get("success") or verification["identity"] != product_identity():
        raise RuntimeError("Product differs from the verified relocated app")
    output = ROOT / "zips"
    output.mkdir(exist_ok=True)
    name = f"emacs-{CONFIG['version']}-macos{CONFIG['minimum_macos'].split('.')[0]}-arm64-{CONFIG['revision'][:8]}"
    binary = output / f"{name}.zip"
    if binary.exists():
        raise RuntimeError(f"Refusing to overwrite {binary}")
    tested_zip = Path(verification["state"]) / "round-trip.zip"
    if digest(tested_zip) != verification["archive_sha256"]:
        raise RuntimeError("The tested ZIP changed")
    shutil.copy2(tested_zip, binary)
    public_info["runtime"] = verification["runtime"]
    public_info["artifacts"] = {"Emacs": digest(APP / "Contents/MacOS/Emacs"),
                                "Emacs.pdmp": digest(APP / "Contents/MacOS/libexec/Emacs.pdmp")}
    (output / f"{name}-build-info.json").write_text(json.dumps(public_info, indent=2) + "\n")
    public_verification = {k: v for k, v in verification.items() if k not in ("identity", "state", "sandbox_denied")}
    public_verification["sandbox_denied"] = ["Homebrew", "source checkout", "build directory", "staging product"]
    (output / f"{name}-verification.json").write_text(json.dumps(public_verification, indent=2) + "\n")
    # Sources are exported from the exact patched checkout, including the build
    # recipe, never private signing keys, caches or personal configuration.
    sources = output / f"{name}-sources.tar.xz"
    tracked = run(["git", "ls-files", "-z"], cwd=SOURCE, capture=True).split("\0")
    recipe = run(["git", "ls-files", "-z"], capture=True).split("\0")
    source_manifest = {"upstream_revision": CONFIG["revision"], "recipe_commit": public_info["recipe_commit"], "files": {}}
    with tarfile.open(sources, "w:xz") as tar:
        for relative in tracked:
            if relative and (SOURCE / relative).is_file():
                tar.add(SOURCE / relative, arcname=f"emacs/{relative}", recursive=False)
                source_manifest["files"][f"emacs/{relative}"] = digest(SOURCE / relative)
        for relative in recipe:
            if relative and not relative.startswith(("certs/", ".git/")) and (ROOT / relative).is_file():
                # Export recipe bytes from the committed Git blob, not a
                # checkout's potentially normalized line endings.
                data = subprocess.check_output(["git", "show", "HEAD:" + relative], cwd=ROOT)
                entry = tarfile.TarInfo(f"build-recipe/{relative}")
                entry.size = len(data)
                entry.mode = (ROOT / relative).stat().st_mode & 0o777
                tar.addfile(entry, io.BytesIO(data))
                source_manifest["files"][entry.name] = hashlib.sha256(data).hexdigest()
        data = (json.dumps(source_manifest, indent=2) + "\n").encode()
        entry = tarfile.TarInfo("source-manifest.json")
        entry.size = len(data)
        tar.addfile(entry, io.BytesIO(data))
    from sources import pack
    dependencies = output / f"{name}-dependency-sources.tar"
    pack(dependencies)
    assets = [binary, sources, dependencies, output / f"{name}-build-info.json", output / f"{name}-verification.json"]
    (output / f"{name}-SHA256SUMS.txt").write_text("".join(f"{digest(p)}  {p.name}\n" for p in assets))
    print("Archives ready; no GitHub release was created automatically.")
