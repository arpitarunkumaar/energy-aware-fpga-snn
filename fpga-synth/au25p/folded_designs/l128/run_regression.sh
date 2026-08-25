#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
cd "$repo_root"
.venv/bin/pytest --import-mode=importlib \
    testing/folded/l128/test_runner.py -vv

