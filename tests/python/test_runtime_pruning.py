from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class RuntimePruningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, True))

    def _write_sample_runtime(self) -> Path:
        runtime = self.root / "runtime"
        meta_dir = runtime / "Lib" / "site-packages" / "samplepkg-1.0.0.dist-info"
        meta_dir.mkdir(parents=True)
        (meta_dir / "RECORD").write_text("samplepkg/__init__.py,,\n", encoding="utf-8")
        (meta_dir / "WHEEL").write_text("Wheel-Version: 1.0\n", encoding="utf-8")
        (meta_dir / "entry_points.txt").write_text("[console_scripts]\n", encoding="utf-8")
        (meta_dir / "INSTALLER").write_text("pip\n", encoding="utf-8")
        (meta_dir / "REQUESTED").write_text("", encoding="utf-8")
        (meta_dir / "LICENSE").write_text("sample license\n", encoding="utf-8")
        (meta_dir / "licenses").mkdir()
        (runtime / "Lib" / "site-packages" / "cachepkg").mkdir(parents=True)
        (runtime / "Lib" / "site-packages" / "cachepkg" / "__pycache__").mkdir(parents=True)
        (runtime / "Lib" / "site-packages" / "cachepkg" / "__pycache__" / "x.pyc").write_bytes(b"pyc")
        (runtime / "Lib" / "site-packages" / "cachepkg" / "tests").mkdir(parents=True)
        (runtime / "Lib" / "site-packages" / "cachepkg" / "tests" / "test_x.py").write_text("pass", encoding="utf-8")
        return runtime

    def test_windows_prune_keeps_install_metadata_and_removes_cache_files(self) -> None:
        runtime = self._write_sample_runtime()
        script = Path(__file__).resolve().parents[2] / "scripts" / "prune-python-runtime.ps1"
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if powershell is None:
            self.skipTest("PowerShell is required for the Windows pruning script test")
        command = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            "-RuntimeDir",
            str(runtime),
            "-KeepScripts",
            "-KeepVenv",
        ]
        subprocess.run(command, check=True, cwd=runtime, env={**os.environ, "OS": "Windows_NT"})

        meta_dir = runtime / "Lib" / "site-packages" / "samplepkg-1.0.0.dist-info"
        self.assertTrue((meta_dir / "RECORD").exists())
        self.assertTrue((meta_dir / "WHEEL").exists())
        self.assertTrue((meta_dir / "entry_points.txt").exists())
        self.assertTrue((meta_dir / "INSTALLER").exists())
        self.assertTrue((meta_dir / "REQUESTED").exists())
        self.assertTrue((meta_dir / "LICENSE").exists())
        self.assertTrue((meta_dir / "licenses").exists())
        self.assertFalse((runtime / "Lib" / "site-packages" / "cachepkg" / "__pycache__").exists())
        self.assertFalse((runtime / "Lib" / "site-packages" / "cachepkg" / "tests").exists())
