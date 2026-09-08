#!/usr/bin/env python3
"""Runtime manifest sanity gate, shared by CI and ci-lite.

Keeps the workflow YAMLs from drifting apart: both fast-check jobs run this
same file. Checks structure and the requirements-ci.txt <-> manifest pin
contract that historically drifted silently."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    manifest = json.loads((ROOT / "python" / "runtime-manifest.json").read_text(encoding="utf-8"))
    assert manifest.get("manifestVersion"), "manifestVersion missing"
    assert manifest.get("python"), "python version missing"
    for name, requirement in manifest["common"].items():
        assert isinstance(requirement, str) and requirement.strip(), f"common.{name} has an empty requirement"

    # requirements-ci.txt pins the subset of manifest packages the test environment
    # needs; its bounds must match the manifest exactly or the two drift apart.
    ci_requirements = {}
    ci_path = ROOT / "python" / "requirements-ci.txt"
    if ci_path.is_file():
        for line in ci_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name = line.split("[")[0].split(">")[0].split("=")[0].split("<")[0].strip()
            ci_requirements[name] = line
        for name, requirement in ci_requirements.items():
            expected = manifest["common"].get(name)
            assert expected == requirement, (
                f"requirements-ci.txt '{requirement}' does not match manifest "
                f"common.{name}='{expected}'"
            )

    for name, spec in manifest["backends"].items():
        assert spec.get("platforms"), f"backend {name} lacks platforms"
        torch = spec.get("torch") or {}
        has_torch = bool(torch.get("requirement") or torch.get("requirements"))
        assert has_torch, f"backend {name} has no torch requirement"
    print("runtime-manifest.json OK:", ", ".join(manifest["backends"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
