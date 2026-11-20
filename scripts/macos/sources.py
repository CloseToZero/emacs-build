# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
"""Collect checksummed corresponding dependency sources from installed SBOMs.

Never substitute today's brew formula for the version actually bundled.
"""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tomllib
import urllib.parse

from build import CONFIG, ROOT, WORK, digest, run

DIRECTORY = WORK / "dependency-sources"


def formula_blocks(text, keyword):
    lines = text.splitlines()
    for start, line in enumerate(lines):
        pattern = r'^\s*resource\s+"[^"]+"\s+do\s*$' if keyword == "resource" else r"^\s*patch\s+do\s*$"
        if not re.match(pattern, line):
            continue
        indent = len(line) - len(line.lstrip())
        end = next((n for n in range(start + 1, len(lines)) if lines[n] == " " * indent + "end"), None)
        if end is None:
            raise RuntimeError(f"Cannot parse installed formula {keyword} block")
        yield "\n".join(lines[start:end + 1])


def url_and_hash(text, version):
    url = re.search(r'^\s*url "([^"]+)"', text, re.M)
    sha = re.search(r'^\s*sha256 "([a-f0-9]{64})"', text, re.M)
    if not url or not sha:
        raise RuntimeError("A dependency resource/patch lacks an explicit URL and SHA256")
    address = url.group(1).replace("#{version}", version)
    if "#{" in address:
        raise RuntimeError(f"Unresolved formula interpolation: {address}")
    return {"url": address, "sha256": sha.group(1)}


def fetch(item):
    name = Path(urllib.parse.urlsplit(item["url"]).path).name
    target = DIRECTORY / "archives" / (item["sha256"][:12] + "-" + name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists() or digest(target) != item["sha256"]:
        part = target.with_name(target.name + ".part")
        urls = [item["url"]]
        if "zlib.net/" in item["url"] and "/fossils/" not in item["url"]:
            urls.insert(0, item["url"].replace("zlib.net/", "zlib.net/fossils/"))
        if "www.x.org/" in item["url"]:
            urls.insert(0, item["url"].replace("www.x.org/", "xorg.freedesktop.org/"))
        if "ftpmirror.gnu.org/" in item["url"]:
            suffix = item["url"].split("ftpmirror.gnu.org/", 1)[1].removeprefix("gnu/")
            urls = ["https://ftp.gnu.org/gnu/" + suffix, *urls]
        for url in urls:
            result = subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2",
                                     "--max-time", "600", "--silent", "--show-error", "--output", str(part), url])
            if result.returncode == 0:
                if digest(part) != item["sha256"]:
                    raise RuntimeError(f"Source checksum mismatch: {url}")
                part.replace(target)
                break
        else:
            raise RuntimeError(f"Cannot fetch corresponding source: {item['url']}")
    print("SOURCE", target.name, flush=True)
    return {**item, "file": str(target.relative_to(DIRECTORY))}


def collect():
    inventory = json.loads((WORK / "dependency-inventory.json").read_text())
    DIRECTORY.mkdir(exist_ok=True)
    requests, formulas = [], []
    for entry in inventory:
        name, version = entry["formula"], entry["version"]
        prefix = Path("/opt/homebrew/Cellar", name, version)
        sbom = json.loads((prefix / "sbom.spdx.json").read_text())
        package = next(p for p in sbom["packages"] if p["name"] == name)
        sha = next(h["checksumValue"] for h in package["checksums"] if h["algorithm"] == "SHA256")
        primary = {"url": package["downloadLocation"], "sha256": sha}
        recipe = prefix / ".brew" / (name + ".rb")
        text = recipe.read_text()
        target = DIRECTORY / "recipes" / name
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(recipe, target / recipe.name)
        shutil.copy2(prefix / "sbom.spdx.json", target / "sbom.spdx.json")
        requests.append(primary)
        extras = []
        for block in formula_blocks(text, "patch"):
            local = re.search(r'^\s*file "([^"]+)"', block, re.M)
            if local:
                key = local.group(1)
                if key not in CONFIG["homebrew_file_patches"]:
                    raise RuntimeError(f"Need an audited Homebrew file patch: {key}")
                item = CONFIG["homebrew_file_patches"][key]
            else:
                item = url_and_hash(block, package["versionInfo"])
            extras.append(item)
        for block in formula_blocks(text, "resource"):
            extras.append(url_and_hash(block, package["versionInfo"]))
        requests.extend(extras)
        formulas.append({"formula": name, "version": version, "primary": primary,
                         "extras": extras, "license": package.get("licenseConcluded")})
    unique = {r["sha256"]: r for r in requests}
    with ThreadPoolExecutor(max_workers=4) as pool:
        artifacts = list(pool.map(fetch, unique.values()))
    # librsvg statically links Rust crates. The release tarball contains the
    # lockfile but not their source; include every locked registry crate, not
    # only the top-level C library. Checksums come from that exact lockfile.
    crates = {}
    for artifact in artifacts:
        if "librsvg-" not in artifact["file"]:
            continue
        with tarfile.open(DIRECTORY / artifact["file"]) as tar:
            member = next(m for m in tar.getmembers() if m.name.endswith("/Cargo.lock"))
            lock = tomllib.loads(tar.extractfile(member).read().decode())
        for package in lock["package"]:
            if "source" not in package:
                continue
            if package["source"] != "registry+https://github.com/rust-lang/crates.io-index":
                raise RuntimeError(f"Uncollected non-registry Rust source: {package}")
            name, version = package["name"], package["version"]
            crates[package["checksum"]] = {"url": f"https://static.crates.io/crates/{name}/{name}-{version}.crate",
                                            "sha256": package["checksum"], "crate": f"{name}-{version}"}
    with ThreadPoolExecutor(max_workers=6) as pool:
        artifacts.extend(pool.map(fetch, crates.values()))
    manifest = {"formulas": formulas, "artifacts": artifacts, "rust_crates": len(crates)}
    (DIRECTORY / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Collected {len(artifacts)} source artifacts for {len(formulas)} formulas")


def copy_rust_notices(license_dir):
    manifest = json.loads((DIRECTORY / "manifest.json").read_text())
    for item in manifest["artifacts"]:
        if "crate" not in item:
            continue
        target = license_dir / "rust" / item["crate"]
        with tarfile.open(DIRECTORY / item["file"]) as tar:
            for member in tar.getmembers():
                name = Path(member.name).name
                notice = name.upper().startswith(("COPYING", "LICENSE", "LICENCE", "NOTICE"))
                root_manifest = name == "Cargo.toml" and len(Path(member.name).parts) == 2
                if not member.isfile() or not (notice or root_manifest):
                    continue
                target.mkdir(parents=True, exist_ok=True)
                # Preserve nested notices without basename collisions, and never
                # extract an archive-controlled filesystem path.
                data = tar.extractfile(member).read()
                safe_name = "__".join(Path(member.name).parts[1:])
                if safe_name in ("", ".", "..") or "/" in safe_name:
                    raise RuntimeError(f"Invalid crate notice path: {member.name}")
                (target / safe_name).write_bytes(data)


def pack(output):
    manifest = json.loads((DIRECTORY / "manifest.json").read_text())
    selected = json.loads((WORK / "dependency-inventory.json").read_text())
    if {(p["formula"], p["version"]) for p in manifest["formulas"]} != {(p["formula"], p["version"]) for p in selected}:
        raise RuntimeError("Dependency sources do not match the bundled versions")
    for item in manifest["artifacts"]:
        if digest(DIRECTORY / item["file"]) != item["sha256"]:
            raise RuntimeError(f"Dependency source changed: {item['file']}")
    with tarfile.open(output, "w") as tar:
        tar.add(DIRECTORY / "manifest.json", arcname="dependency-sources/manifest.json")
        tar.add(DIRECTORY / "recipes", arcname="dependency-sources/recipes")
        for item in manifest["artifacts"]:
            tar.add(DIRECTORY / item["file"], arcname="dependency-sources/" + item["file"], recursive=False)


if __name__ == "__main__":
    collect()
