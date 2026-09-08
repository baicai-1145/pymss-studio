# AGENTS.md

For AI agents and new maintainers. Architecture, commands, layout, and release packaging are in README.md.

## Relationship with upstream pymss

- pymss-studio is a thin wrapper; the core separation logic lives in the [pymss-project/pymss](https://github.com/pymss-project/pymss) package.
- Fix problems in pymss first; patching in pymss-studio is forbidden.
- **Add studio features sparingly.** For every new feature, ask first: does this belong in pymss? Installation, updates, and runtime environment management are studio's own domain; separation semantics, device selection, and model behavior belong to pymss.
- Changes touching pymss semantics (device, dependencies, model loading, output behavior) require the upstream author's confirmation.

## Local development

- Debugging pymss source: editable-install it into the active environment with `pip install -e <pymss source dir>`
- Interpreter override: `PYMSS_STUDIO_PYTHON`.
- Model directory: the `modelDir` setting, or `PYMSS_MODEL_DIR`.

## Verification

- Frontend: `pnpm build` + `pnpm test`
- Python worker: `python3 -m unittest discover -s tests/python -t tests -p "test_*.py"` (needs pymss + torch installed locally; if that is not possible, run `test_worker_bootstrap.py` at least)
- Rust: `cargo test --manifest-path src-tauri/Cargo.toml`
- Workflows / scripts: `actionlint .github/workflows/*.yml && shellcheck scripts/*.sh`
