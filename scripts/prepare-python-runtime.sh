#!/usr/bin/env bash
set -euo pipefail

VARIANT="${1:-cuda}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RUNTIME_DIR="${RUNTIME_DIR:-python-runtime}"
RUNTIME_HOME="$(cd "$(dirname "$RUNTIME_DIR")" && pwd)/$(basename "$RUNTIME_DIR")"
# Optional overrides. When unset, the torch requirement and index URL come from
# python/runtime-manifest.json — the single source of truth shared with the in-app
# installer (worker_bootstrap.py). Hardcoded copies here would drift.
TORCH_VERSION="${TORCH_VERSION:-}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-}"
PBS_TAG="${PBS_TAG:-20260602}"
PBS_PYTHON_VERSION="${PBS_PYTHON_VERSION:-3.12.13}"

MANIFEST_PATH="$(cd "$(dirname "$0")/.." && pwd)/python/runtime-manifest.json"

rm -rf "$RUNTIME_DIR"

RUNTIME_ENVS_DIR="${RUNTIME_ENVS_DIR:-$RUNTIME_DIR/runtime-envs}"
INITIAL_BACKEND="${INITIAL_BACKEND:-}"

# The mps/mlx build variants correspond to the manifest's mlx backend: a CPU torch
# build plus the mlx extra.
case "$VARIANT" in
  cuda) BACKEND="cuda" ;;
  default) BACKEND="cpu" ;;
  rocm) BACKEND="rocm" ;;
  mps | mlx) BACKEND="mlx" ;;
  *) BACKEND="cpu" ;;
esac
if [[ -n "$INITIAL_BACKEND" ]]; then
  BACKEND="$INITIAL_BACKEND"
fi

if [[ "$OSTYPE" == darwin* ]]; then
  ARCHIVE="cpython-${PBS_PYTHON_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
  URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ARCHIVE//+/%2B}"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -L --fail --retry 3 --retry-delay 2 -o "$TMP_DIR/pbs.tar.gz" "$URL"
  tar -xzf "$TMP_DIR/pbs.tar.gz" -C "$TMP_DIR"
  mv "$TMP_DIR/python" "$RUNTIME_DIR"
  PY="$RUNTIME_DIR/bin/python3"
  if [[ ! -x "$PY" ]]; then
    echo "Bundled macOS standalone python executable not found in $RUNTIME_DIR/bin/python3" >&2
    exit 1
  fi
else
  "$PYTHON_BIN" -m venv "$RUNTIME_DIR"
  PY="$RUNTIME_DIR/bin/python"
fi

# --- manifest queries (stdlib json only; no pip required) -------------------
manifest_query() {
  PYTHONHOME="$RUNTIME_HOME" PYMSS_BACKEND="$BACKEND" "$PY" - "$MANIFEST_PATH" "$1" <<'PYEOF'
import json, os, sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
backend = manifest["backends"][os.environ["PYMSS_BACKEND"]]
query = sys.argv[2]
torch = backend.get("torch", {})
if query == "torch-requirement":
    print(torch.get("requirement") or "")
elif query == "torch-index-url":
    print(torch.get("indexUrl") or "")
elif query == "common":
    for name, requirement in manifest["common"].items():
        if name not in ("pymss", "pymss-core"):
            print(requirement)
elif query == "pymss-requirements":
    print(manifest["common"]["pymss"])
    print(manifest["common"]["pymss-core"])
elif query == "extras":
    for extra in backend.get("extras", []):
        print(extra)
elif query == "rocm-sdk-requirements":
    for url in torch.get("rocmRequirements", []):
        print(url)
elif query == "rocm-torch-requirements":
    for url in torch.get("requirements", []):
        print(url)
else:
    raise SystemExit(f"unknown manifest query: {query}")
PYEOF
}

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "runtime manifest not found at $MANIFEST_PATH" >&2
  exit 1
fi

if [[ "$OSTYPE" == darwin* && -z "$INITIAL_BACKEND" && "$VARIANT" != "mlx" && "$VARIANT" != "mps" ]]; then
  PYTHONHOME="$RUNTIME_HOME" "$PY" -m ensurepip --upgrade
  PYTHONHOME="$RUNTIME_HOME" "$PY" -m pip install --upgrade pip setuptools wheel
  bash "$(dirname "$0")/prune-python-runtime.sh" "$RUNTIME_DIR" --keep-venv

  PYTHONHOME="$RUNTIME_HOME" "$PY" -m pip --version
  exit 0
fi

PYTHONHOME="$RUNTIME_HOME" "$PY" -m pip install --upgrade pip setuptools wheel

pip_install() {
  echo "pip install $*"
  PYTHONHOME="$RUNTIME_HOME" "$PY" -m pip install --no-cache-dir "$@"
}

# --- torch ------------------------------------------------------------------
if [[ "$BACKEND" == "rocm" ]]; then
  # shellcheck disable=SC2207
  ROCM_SDK_URLS=($(manifest_query rocm-sdk-requirements))
  # shellcheck disable=SC2207
  ROCM_TORCH_URLS=($(manifest_query rocm-torch-requirements))
  # shellcheck disable=SC2086
  pip_install ${ROCM_SDK_URLS[@]+"${ROCM_SDK_URLS[@]}"}
  pip_install --no-deps ${ROCM_TORCH_URLS[@]+"${ROCM_TORCH_URLS[@]}"}
else
  if [[ -n "$TORCH_VERSION" ]]; then
    TORCH_REQUIREMENT="torch==${TORCH_VERSION}"
  else
    TORCH_REQUIREMENT="$(manifest_query torch-requirement)"
  fi
  if [[ -z "$TORCH_REQUIREMENT" ]]; then
    TORCH_REQUIREMENT="torch"
  fi
  if [[ -n "$TORCH_INDEX_URL" ]]; then
    TORCH_INDEX="$TORCH_INDEX_URL"
  else
    TORCH_INDEX="$(manifest_query torch-index-url)"
  fi
  if [[ -n "$TORCH_INDEX" ]]; then
    pip_install "$TORCH_REQUIREMENT" --index-url "$TORCH_INDEX"
  else
    pip_install "$TORCH_REQUIREMENT"
  fi
fi

# --- common dependencies (requirement strings from the manifest) ------------
# Requirement strings never contain spaces, so plain word splitting is safe here.
# The @+ guard keeps an empty/unset array legal under "set -u" on macOS bash 3.2.
# shellcheck disable=SC2207
COMMON_PACKAGES=($(manifest_query common))
if [[ ${#COMMON_PACKAGES[@]} -gt 0 ]]; then
  # shellcheck disable=SC2086
  pip_install --only-binary=:all: --prefer-binary ${COMMON_PACKAGES[@]+"${COMMON_PACKAGES[@]}"}
fi

# --- backend extras ----------------------------------------------------------
manifest_query extras | while IFS= read -r BACKEND_EXTRA; do
  [[ -z "$BACKEND_EXTRA" ]] && continue
  pip_install "$BACKEND_EXTRA"
done

# --- pymss core with dependency resolution, torch pinned by constraint ------
TORCH_VERSION_INSTALLED="$(PYTHONHOME="$RUNTIME_HOME" "$PY" -c "from importlib.metadata import version; print(version('torch'))")"
CONSTRAINTS_FILE="$(mktemp "${TMPDIR:-/tmp}/pymss-constraints.XXXXXX")"
echo "torch==$TORCH_VERSION_INSTALLED" > "$CONSTRAINTS_FILE"
PYMSS_REQUIREMENTS=($(manifest_query pymss-requirements))
# shellcheck disable=SC2207 disable=SC2086
pip_install --upgrade --only-binary=:all: --prefer-binary --constraint "$CONSTRAINTS_FILE" ${PYMSS_REQUIREMENTS[@]+"${PYMSS_REQUIREMENTS[@]}"}
rm -f "$CONSTRAINTS_FILE"

bash "$(dirname "$0")/prune-python-runtime.sh" "$RUNTIME_DIR" --keep-venv
PYTHONHOME="$RUNTIME_HOME" "$PY" -m pip --version

if [[ "$OSTYPE" == darwin* && "$VARIANT" == "mlx" ]]; then
  mkdir -p "$RUNTIME_ENVS_DIR"
  PYTHONHOME="$RUNTIME_HOME" "$PY" - "$RUNTIME_ENVS_DIR" "$(dirname "$0")/../python/runtime-manifest.json" <<'PY'
import json
import platform
import sys
from datetime import datetime, timezone
from importlib import metadata
from pathlib import Path

envs = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
package_versions = {}
packages = {}
for name in (*manifest["common"], "mlx"):
    try:
        package_versions[name] = metadata.version(name)
        packages[name] = True
    except metadata.PackageNotFoundError:
        package_versions[name] = None
        packages[name] = False
if not all(packages.values()):
    missing = [name for name, available in packages.items() if not available]
    raise SystemExit(f"Bundled MLX runtime is missing packages: {missing}")
installed_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
state = {
    "backend": "mlx",
    "manifestVersion": manifest["manifestVersion"],
    "stateVersion": 2,
    "installedAt": installed_at,
    "pythonVersion": platform.python_version(),
    "torchVersion": package_versions.get("torch"),
    "torchBackend": "cpu",
    "acceleratorAvailable": False,
    "packages": packages,
    "packageVersions": package_versions,
    "pymssVersion": package_versions.get("pymss"),
    "pymssCoreVersion": package_versions.get("pymss-core"),
}
(envs / "active-runtime.json").write_text(
    json.dumps({**state, "pythonPath": "../bin/python3", "source": "bundled"}, indent=2) + "\n",
    encoding="utf-8",
)
PY
fi
PYTHONDONTWRITEBYTECODE=1 PYTHONHOME="$RUNTIME_HOME" "$PY" - <<'PY'
import importlib.util
import pymss, pymss.graph, torch, librosa, av, yaml, tqdm
print('pymss', getattr(pymss, '__version__', 'unknown'), pymss.__file__)
print('torch', torch.__version__, 'cuda', torch.version.cuda, 'cuda_available', torch.cuda.is_available())
print('librosa', librosa.__version__)
print('av', av.__version__)
print('mlx', importlib.util.find_spec('mlx') is not None)
PY
bash "$(dirname "$0")/prune-python-runtime.sh" "$RUNTIME_DIR" --keep-venv
PYTHONHOME="$RUNTIME_HOME" "$PY" -m pip --version
