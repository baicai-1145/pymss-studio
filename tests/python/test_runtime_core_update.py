from __future__ import annotations

import contextlib
import io
import json
import tempfile
import sys
import unittest
from pathlib import Path
from unittest import mock

import worker_bootstrap


COMMON_PACKAGES = ("av", "librosa", "numpy", "pymss", "pymss-core")


def _manifest():
    return {
        "manifestVersion": "test-1",
        "common": {
            "av": "av",
            "librosa": "librosa",
            "numpy": "numpy",
            "pymss": "pymss[proxy]>=2.1.4",
            "pymss-core": "pymss-core>=0.1.6",
        },
        "backends": {
            "cpu": {"platforms": ["win32", "linux", "darwin"], "torch": {"requirement": "torch==2.7.1"}},
            "cuda": {"platforms": ["win32", "linux"], "torch": {"requirement": "torch==2.7.1+cu128"}},
            "rocm": {"platforms": ["win32", "linux"], "torch": {"requirement": "torch==2.7.1+rocm6.3"}},
            "mlx": {"platforms": ["darwin"], "torch": {"requirement": "torch==2.7.1"}},
        },
    }


def _probe_result(backend: str) -> dict[str, object]:
    torch_backend = "cpu" if backend == "mlx" else backend
    # "rocm" is not a manifest backend anymore; the fallback keeps legacy-environment
    # fixtures (state files written by older releases) representable.
    torch_version = {
        "cpu": "2.7.1",
        "cuda": "2.7.1+cu128",
        "rocm": "2.7.1+rocm6.3",
        "mlx": "2.7.1",
    }[backend]
    return {
        "pythonVersion": "3.12.0",
        "torchVersion": torch_version,
        "torchBackend": torch_backend,
        "acceleratorAvailable": backend in {"cuda", "rocm"},
        "packages": {name: True for name in COMMON_PACKAGES},
        "packageVersions": {name: "2.0.0" for name in COMMON_PACKAGES},
        "pymssVersion": "2.1.4",
        "pymssCoreVersion": "0.1.6",
        "pymssGraphAvailable": True,
    }


class RuntimeCoreUpdateTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.envs_dir = self.root / "runtime-envs"
        self.envs_dir.mkdir()
        self.active_file = self.envs_dir / "active-runtime.json"
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, True))

    def _make_env(self, backend: str, *, state_version: int = worker_bootstrap.ENV_STATE_VERSION):
        env_dir = self.envs_dir / backend
        (env_dir / "Scripts").mkdir(parents=True)
        python_path = env_dir / "Scripts" / "python.exe"
        python_path.write_text("stub", encoding="utf-8")
        (env_dir / "pymss-runtime-state.json").write_text(json.dumps({
            "backend": backend,
            "manifestVersion": "old-1",
            "stateVersion": state_version,
            "torchVersion": _probe_result(backend)["torchVersion"],
            "torchBackend": _probe_result(backend)["torchBackend"],
            "acceleratorAvailable": _probe_result(backend)["acceleratorAvailable"],
            "packages": {name: True for name in COMMON_PACKAGES},
            "packageVersions": {name: "2.0.0" for name in COMMON_PACKAGES},
            "pymssVersion": "2.1.3",
            "pymssCoreVersion": "0.1.6",
            "pymssGraphAvailable": True,
        }), encoding="utf-8")
        self.active_file.write_text(json.dumps({
            "backend": backend,
            "pythonPath": str(python_path),
            "manifestVersion": "old-1",
            "stateVersion": state_version,
        }), encoding="utf-8")
        return env_dir, python_path

    def _run_update(self, backend: str, *, missing_records: dict[str, str] | None, popen_outputs: list[str] | None = None):
        env_dir, python_path = self._make_env(backend)
        outputs = popen_outputs or ["metadata repaired\n", "upgrade complete\n"]
        popen_calls: list[list[str]] = []
        missing_probe = iter([missing_records or {}, {}])

        def popen(command, **kwargs):
            popen_calls.append(command)
            del kwargs
            return mock.Mock(
                stdout=iter(outputs.pop(0) for _ in range(1)),
                wait=mock.Mock(return_value=0),
                returncode=0,
                poll=mock.Mock(return_value=0),
            )

        with mock.patch.object(worker_bootstrap, "RUNTIME_ENVS_DIR", self.envs_dir), \
             mock.patch.object(worker_bootstrap, "ACTIVE_RUNTIME_FILE", self.active_file), \
             mock.patch.object(worker_bootstrap, "_manifest", return_value=_manifest()), \
             mock.patch.object(worker_bootstrap, "_latest_pypi_version", side_effect=lambda name: {"pymss": "2.1.4", "pymss-core": "0.1.6"}[name]), \
             mock.patch.object(worker_bootstrap, "_probe_python_runtime", return_value=_probe_result(backend)), \
             mock.patch.object(worker_bootstrap, "_runtime_core_missing_records", side_effect=lambda _path: next(missing_probe, {})), \
             mock.patch.object(worker_bootstrap, "_ensure_runtime_pip"), \
             mock.patch.object(worker_bootstrap.subprocess, "Popen", side_effect=popen), \
             mock.patch.object(sys, "platform", "win32"), \
             contextlib.redirect_stdout(io.StringIO()):
            result = worker_bootstrap.cmd_update_runtime_core({"backend": backend, "mirror": "pypi", "pythonPath": str(python_path)})

        return result, popen_calls, env_dir, python_path

    def test_update_core_repairs_missing_record_then_runs_normal_upgrade(self):
        result, popen_calls, env_dir, _python_path = self._run_update(
            "cuda",
            missing_records={"pymss": "2.1.3", "pymss-core": "0.1.6"},
        )

        self.assertEqual(result, 0)
        self.assertGreaterEqual(len(popen_calls), 2)
        repair_cmd = popen_calls[0]
        upgrade_cmd = popen_calls[1]
        self.assertIn("--ignore-installed", repair_cmd)
        self.assertIn("--no-deps", repair_cmd)
        self.assertIn("--only-binary=:all:", repair_cmd)
        self.assertNotIn("--ignore-installed", upgrade_cmd)
        self.assertIn("--upgrade", upgrade_cmd)
        self.assertIn("pymss[proxy]==2.1.4", upgrade_cmd)
        self.assertIn("pymss-core==0.1.6", upgrade_cmd)
        self.assertTrue((env_dir / "pymss-core-update.log").is_file())

    def test_update_core_skips_repair_when_records_are_present(self):
        result, popen_calls, _env_dir, _python_path = self._run_update("cpu", missing_records={})

        self.assertEqual(result, 0)
        self.assertEqual(len(popen_calls), 1)
        self.assertNotIn("--ignore-installed", popen_calls[0])
        self.assertIn("--upgrade", popen_calls[0])

    def test_update_core_does_not_continue_when_repair_remains_incomplete(self):
        env_dir, python_path = self._make_env("cuda")
        popen_calls: list[list[str]] = []

        def popen(command, **kwargs):
            popen_calls.append(command)
            del kwargs
            return mock.Mock(stdout=iter(()), wait=mock.Mock(return_value=0), returncode=0, poll=mock.Mock(return_value=0))

        with mock.patch.object(worker_bootstrap, "RUNTIME_ENVS_DIR", self.envs_dir), \
             mock.patch.object(worker_bootstrap, "ACTIVE_RUNTIME_FILE", self.active_file), \
             mock.patch.object(worker_bootstrap, "_manifest", return_value=_manifest()), \
             mock.patch.object(worker_bootstrap, "_latest_pypi_version", side_effect=lambda name: {"pymss": "2.1.4", "pymss-core": "0.1.6"}[name]), \
             mock.patch.object(worker_bootstrap, "_probe_python_runtime", return_value=_probe_result("cuda")), \
             mock.patch.object(worker_bootstrap, "_runtime_core_missing_records", side_effect=[{"pymss": "2.1.3"}, {"pymss": "2.1.3"}]), \
             mock.patch.object(worker_bootstrap, "_ensure_runtime_pip"), \
             mock.patch.object(worker_bootstrap.subprocess, "Popen", side_effect=popen), \
             mock.patch.object(sys, "platform", "win32"), \
             contextlib.redirect_stdout(io.StringIO()):
            result = worker_bootstrap.cmd_update_runtime_core({"backend": "cuda", "mirror": "pypi", "pythonPath": str(python_path)})

        self.assertNotEqual(result, 0)
        self.assertEqual(len(popen_calls), 1)
        self.assertIn("--ignore-installed", popen_calls[0])
        self.assertEqual(
            json.loads((env_dir / "pymss-runtime-state.json").read_text(encoding="utf-8"))["pymssVersion"],
            "2.1.3",
        )

    def test_update_core_preserves_torch_constraints_for_mlx(self):
        with mock.patch.object(worker_bootstrap.Path, "unlink", autospec=True, side_effect=lambda self, missing_ok=False: None):
            result, popen_calls, env_dir, _python_path = self._run_update("mlx", missing_records=None)

        self.assertEqual(result, 0)
        self.assertEqual(len(popen_calls), 1)
        upgrade_cmd = popen_calls[0]
        self.assertIn("--constraint", upgrade_cmd)
        self.assertEqual((env_dir / ".pymss-core-update-constraints.txt").read_text(encoding="utf-8"), "torch==2.7.1\n")
        self.assertIn("pymss[proxy]==2.1.4", upgrade_cmd)
        self.assertIn("pymss-core==0.1.6", upgrade_cmd)

    def test_missing_record_helper_keeps_only_core_packages(self):
        python_path = self.root / "python.exe"
        python_path.write_text("stub", encoding="utf-8")
        payload = json.dumps({"pymss": "2.1.3", "pymss-core": "0.1.6", "torch": "999"})
        with mock.patch.object(worker_bootstrap.subprocess, "check_output", return_value=payload):
            self.assertEqual(worker_bootstrap._runtime_core_missing_records(python_path), {"pymss": "2.1.3", "pymss-core": "0.1.6"})
