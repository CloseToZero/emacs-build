# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
"""Portable unit tests: python3 -m unittest discover -s scripts/macos -p 'test_*.py'."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build
import bundle
import sources


class MacOSRecipeTests(unittest.TestCase):
    def test_locked_selection(self):
        items = build.patch_inventory()
        self.assertEqual(len(items), 12)
        self.assertEqual(sum(p["path"].startswith("patches/macos/") for p in items), 3)
        self.assertFalse(any(p["path"].split("/")[-1].startswith(("0001-", "0008-", "0025-")) for p in items))

    def test_series_missing_duplicate_escape_and_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "p.patch").write_text("patch")
            series = root / "series"
            with patch.object(build, "ROOT", root), patch.dict(build.CONFIG, {"series": "series"}):
                for text in ("absent.patch\n", "p.patch\np.patch\n", "../outside.patch\n", "# empty\n"):
                    series.write_text(text)
                    with self.assertRaises(RuntimeError):
                        build.patch_inventory()
                series.write_bytes(b"# comment\r\np.patch\r\n")
                self.assertEqual(len(build.patch_inventory()), 1)

    def test_loader_and_executable_relative_resolution(self):
        with tempfile.TemporaryDirectory(prefix="spaces here-") as directory:
            root = Path(directory).resolve()
            (root / "a").mkdir()
            (root / "b").mkdir()
            library = root / "b/library.dylib"
            library.write_bytes(b"fixture")
            loader = root / "a/loader"
            self.assertEqual(bundle.resolve("@loader_path/../b/library.dylib", loader, loader, []), library)
            self.assertEqual(bundle.resolve("@rpath/library.dylib", loader, loader, ["@loader_path/../b"]), library)
            with self.assertRaises(RuntimeError):
                bundle.resolve("@rpath/missing.dylib", loader, loader, [])
            with self.assertRaises(RuntimeError):
                bundle.resolve("library.dylib", loader, loader, [])

    def test_ambiguous_rpath_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("a", "b"):
                (root / name).mkdir()
                (root / name / "lib.dylib").write_text(name)
            with self.assertRaises(RuntimeError):
                bundle.resolve("@rpath/lib.dylib", root / "loader", root / "loader", [str(root / "a"), str(root / "b")])

    def test_minimum_os_not_silently_raised(self):
        bundle.assert_minimum(["11.0", "14.0.0"], Path("fixture"))
        with self.assertRaises(RuntimeError):
            bundle.assert_minimum(["15.0"], Path("fixture"))

    def test_external_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Emacs.app"
            app.mkdir()
            (root / "outside").write_text("outside")
            (app / "escape").symlink_to("../outside")
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                bundle.audit(app)

    def test_resource_stage_is_not_a_declaration(self):
        text = '  resource "x" do\n    url "https://example.invalid/x"\n  end\n  resource("x").stage do\n    run\n  end\n'
        blocks = list(sources.formula_blocks(text, "resource"))
        self.assertEqual(len(blocks), 1)
        self.assertNotIn("stage", blocks[0])

    def test_source_hash_and_interpolation_fail_closed(self):
        sha = "0" * 64
        self.assertEqual(sources.url_and_hash(f'url "https://example.invalid/#{{version}}"\nsha256 "{sha}"', "1")["url"], "https://example.invalid/1")
        for text in ('url "https://example.invalid/x"', f'url "https://example.invalid/#{{unknown}}"\nsha256 "{sha}"'):
            with self.assertRaises(RuntimeError):
                sources.url_and_hash(text, "1")

    def test_build_version_does_not_parse_linker_tool_version(self):
        output = """Load command 1
      cmd LC_BUILD_VERSION
    minos 14.0
      sdk 14.5
   ntools 1
     tool 3
  version 1053.12
"""
        with patch.object(bundle.subprocess, "check_output", return_value=output):
            self.assertEqual(bundle.inspect(Path("fixture"))[3], ["14.0"])

    def test_relocation_command_includes_input_file(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Emacs.app"
            dest = app / "Contents/MacOS/Emacs"
            dest.parent.mkdir(parents=True)
            dest.write_text("fixture")
            with patch.object(bundle, "inspect", return_value=([], ["/absolute/build/path"], None, ["14.0"])), patch.object(bundle, "run") as run:
                bundle.relocate(app, {dest: dest})
                self.assertEqual(run.call_args.args[0][-1], dest)

    def test_macho_object_is_not_a_signable_image(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "crt.o"
            path.write_bytes(b"\xcf\xfa\xed\xfe" + bytes(8) + (1).to_bytes(4, "little"))
            self.assertFalse(bundle.macho(path))

    def test_macho_detection_does_not_follow_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "binary").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
            (root / "alias").symlink_to("binary")
            self.assertTrue(bundle.macho(root / "binary"))
            self.assertFalse(bundle.macho(root / "alias"))


if __name__ == "__main__":
    unittest.main()
