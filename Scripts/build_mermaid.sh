#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CARGO=${CARGO:-"$HOME/.cargo/bin/cargo"}
if [[ ! -x "$CARGO" ]]; then CARGO=$(command -v cargo); fi
# Match Hanshi's deployment target; the resulting archive is linked into the one executable.
export MACOSX_DEPLOYMENT_TARGET=15.0
"$CARGO" build --release --locked --manifest-path "$TASK_ROOT/Native/Mermaid/Cargo.toml" --target-dir "$TASK_ROOT/.build/mermaid"
