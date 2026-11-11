#!/usr/bin/env python3
"""Host-side contract tests for the Android glibc spawn bridge.

The native cases compile the production C file with only its path prefixes
redirected into a temporary directory. No Android device or root is required.
"""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "module/libexec/plugin_spawn.c"


def elf_with_interp(machine=183, interp="/lib/ld-linux-aarch64.so.1"):
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    header = struct.pack(
        "<16sHHIQQQIHHHHHH", ident, 2, machine, 1, 0, 64, 0, 0,
        64, 56, 1, 0, 0, 0,
    )
    raw = interp.encode() + b"\0"
    program = struct.pack("<IIQQQQQQ", 3, 4, 128, 0, 0, len(raw), len(raw), 1)
    return header + program + bytes(128 - len(header) - len(program)) + raw


class SourceContract(unittest.TestCase):
    def test_bun_runtime_root_and_process_cleanup_are_covered(self):
        source = SOURCE.read_text(encoding="utf-8")
        control = (ROOT / "module/libexec/control.sh").read_text(encoding="utf-8")
        fallback = (ROOT / "module/libexec/plugin.sh").read_text(encoding="utf-8")
        self.assertIn('A2A_HOME "data/runtimes/"', source)
        self.assertIn('"$DATADIR/runtimes/"', control)
        self.assertIn('"$_p/runtimes"', fallback)

    def test_wrapped_children_get_loader_local_bridge_not_global_preload(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn('out[j++]="--preload";out[j++]=BRIDGE;', source)
        self.assertNotIn("setenv(\"LD_PRELOAD\"", source)
        self.assertNotIn("LD_PRELOAD=", source)


@unittest.skipUnless(sys.platform.startswith("linux"), "native harness needs Linux")
class NativeBridge(unittest.TestCase):
    def setUp(self):
        self.cc = shutil.which("cc")
        if not self.cc:
            self.skipTest("C compiler is unavailable")
        self.temporary = tempfile.TemporaryDirectory(prefix="a2a-spawn-test-")
        self.base = Path(self.temporary.name)
        self.home = self.base / "home"
        self.bridge = self.base / "plugin-spawn.so"
        self.bridge.write_bytes(b"test placeholder")
        harness = self.base / "harness.c"
        harness.write_text(r'''
#include <stdio.h>
#include <string.h>
#include "plugin_spawn.c"
int main(int argc, char **argv) {
 char canonical[PATH_MAX];
 if (argc == 3 && !strcmp(argv[1], "eligible")) {
  int result = eligible(argv[2], canonical);
  if (result) printf("%s\n", canonical);
  return result ? 0 : 1;
 }
 if (argc == 3 && !strcmp(argv[1], "wrap")) {
  char *args[MAX_ARGS + 10];
  char *input[] = {(char *)"original-bun-argv0", (char *)"--version", 0};
  int result = wrap(argv[2], input, args);
  if (result) return 2;
  for (size_t i = 0; args[i]; i++) printf("%s\n", args[i]);
  return 0;
 }
 return 2;
}
''', encoding="utf-8")
        self.executable = self.base / "harness"
        subprocess.run([
            self.cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
            f"-DA2A_HOME=\"{self.home}/\"", f"-DBRIDGE=\"{self.bridge}\"",
            f"-I{SOURCE.parent}", str(harness), "-ldl", "-o", str(self.executable),
        ], check=True, text=True)

    def tearDown(self):
        self.temporary.cleanup()

    def fixture(self, relative, *, mode=0o755, machine=183, data=None):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(elf_with_interp(machine) if data is None else data)
        path.chmod(mode)
        return path

    def eligible(self, path):
        return subprocess.run([str(self.executable), "eligible", str(path)],
                              capture_output=True, text=True)

    def test_bun_and_legacy_plugin_paths_are_eligible(self):
        bun = self.fixture("data/runtimes/bun/1.4.2/bun-linux-aarch64/bun")
        plugin = self.fixture("data/plugins/pack/bin/provider")
        for path in (bun, plugin):
            with self.subTest(path=path):
                result = self.eligible(path)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(path.resolve()))

    def test_prefix_escape_outside_tree_nonexecutable_and_wrong_elf_are_rejected(self):
        outside = self.base / "outside"
        outside.write_bytes(elf_with_interp())
        outside.chmod(0o755)
        cases = [
            self.fixture("data/runtimes-evil/bun"),
            self.fixture("data/runtimes/bun/nonexecutable", mode=0o644),
            self.fixture("data/runtimes/bun/x86", machine=62),
            self.fixture("data/runtimes/bun/text", data=b"not an ELF"),
            outside,
        ]
        for path in cases:
            with self.subTest(path=path):
                self.assertNotEqual(self.eligible(path).returncode, 0)

    def test_realpath_cannot_escape_the_runtime_root(self):
        target = self.base / "outside-target"
        target.write_bytes(elf_with_interp())
        target.chmod(0o755)
        link = self.home / "data/runtimes/bun/link"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
        self.assertNotEqual(self.eligible(link).returncode, 0)

    def test_wrap_preserves_argv_and_preloads_bridge_for_nested_spawns(self):
        bun = self.fixture("data/runtimes/bun/1.4.2/bun-linux-aarch64/bun")
        result = subprocess.run([str(self.executable), "wrap", str(bun)],
                                check=True, capture_output=True, text=True)
        args = result.stdout.splitlines()
        self.assertEqual(args[:3], ["/data/a2a/ld.so", "--argv0", "original-bun-argv0"])
        preload = args.index("--preload")
        self.assertEqual(args[preload + 1], str(self.bridge))
        self.assertEqual(args[-2:], [str(bun), "--version"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
