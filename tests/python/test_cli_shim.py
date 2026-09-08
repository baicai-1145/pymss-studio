"""Behavioral tests for the macOS/Linux pymss CLI shim (scripts/cli-shims/pymss).

The shim is a plain bash script; these tests exercise it end to end with a stub
"python3" on PATH and stub managed environments, asserting resolution order and
env-var injection without needing the real runtime."""

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SHIM = REPO / "scripts" / "cli-shims" / "pymss"

# `python3` on PATH forwards to the real interpreter; the payload script carries the
# assertions. Keeping them separate avoids any self-referential exec chains.
STUB_PYTHON = "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n"
PAYLOAD_PYTHON = r'''import json, os, sys
if len(sys.argv) > 2 and sys.argv[1] == "-c":
    # The shim asks the interpreter to read active-runtime.json; answer from the file.
    print(json.load(open(sys.argv[2])).get("pythonPath", ""))
    sys.exit(0)
print(json.dumps({
    "argv": sys.argv[1:],
    "PYMSS_MODEL_DIR": os.environ.get("PYMSS_MODEL_DIR"),
    "PYMSS_USER_MODELS": os.environ.get("PYMSS_USER_MODELS"),
}))
'''


class CliShimTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        stub = self.bin_dir / "python3"
        stub.write_text(STUB_PYTHON, encoding="utf-8")
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)        # The shim resolves the runtime relative to its own location (bin/../python-runtime),
        # mirroring the packaged layout — so install a copy of it into the fake layout.
        self.shim = self.bin_dir / "pymss"
        self.shim.write_text(SHIM.read_text(encoding="utf-8"), encoding="utf-8")
        self.shim.chmod(self.shim.stat().st_mode | stat.S_IEXEC)
        self.env = {
            **os.environ,
            "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
            "HOME": str(self.root / "home"),
        }
        # App-support data root lives under HOME on macOS.
        (self.root / "home" / "Library" / "Application Support" / "studio.pymss.desktop" / "models").mkdir(parents=True)
        (self.root / "home" / "Library" / "Application Support" / "studio.pymss.desktop" / "settings").mkdir(parents=True)

    def tearDown(self):
        subprocess.run(["chmod", "-R", "u+w", str(self.root)], check=False)
        import shutil
        shutil.rmtree(self.root, ignore_errors=True)

    def _stage_runtime(self, name: str, python_rel: str) -> Path:
        envs = self.root / "python-runtime" / "runtime-envs"
        env_dir = envs / name
        python = env_dir / python_rel
        python.parent.mkdir(parents=True)
        payload = env_dir / "_stub_payload.py"
        payload.write_text(PAYLOAD_PYTHON, encoding="utf-8")
        # The managed env's python runs the payload: python3 <payload> <user args> means
        # sys.argv[1:] is exactly the user args the shim forwarded.
        python.write_text(f'#!/bin/sh\nexec "{self.bin_dir / "python3"}" "{payload}" "$@"\n', encoding="utf-8")
        python.chmod(python.stat().st_mode | stat.S_IEXEC)
        return python

    def _run_shim(self, *args: str) -> dict:
        result = subprocess.run(
            [str(self.shim), *args],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        self.assertTrue(lines, result.stderr)
        return json.loads(lines[-1])

    def test_uses_the_active_runtime_python_and_shares_the_model_cache(self):
        python = self._stage_runtime("cpu", "bin/python3")
        envs = self.root / "python-runtime" / "runtime-envs"
        (envs / "active-runtime.json").write_text(
            json.dumps({"backend": "cpu", "pythonPath": str(python)}), encoding="utf-8"
        )
        (self.root / "home" / "Library" / "Application Support" / "studio.pymss.desktop" / "settings" / "user_models.json").write_text("{}", encoding="utf-8")

        payload = self._run_shim("separate", "--input", "song.wav")

        self.assertEqual(payload["argv"], ["-m", "pymss", "separate", "--input", "song.wav"])
        self.assertEqual(payload["PYMSS_MODEL_DIR"], str(self.root / "home" / "Library" / "Application Support" / "studio.pymss.desktop" / "models"))
        self.assertEqual(payload["PYMSS_USER_MODELS"], str(self.root / "home" / "Library" / "Application Support" / "studio.pymss.desktop" / "settings" / "user_models.json"))

    def test_falls_back_to_scanning_environments_when_active_is_missing(self):
        self._stage_runtime("cuda", "bin/python3")
        payload = self._run_shim("list")
        self.assertEqual(payload["argv"], ["-m", "pymss", "list"])

    def test_fails_closed_with_guidance_when_no_environment_exists(self):
        result = subprocess.run([str(self.shim)], capture_output=True, text=True, env=self.env, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no managed runtime environment", result.stderr)


if __name__ == "__main__":
    unittest.main()
