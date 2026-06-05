#!/usr/bin/env bash
# CI entry point for the wasm differential digest, wired into
# .github/workflows/emscripten.yml: native vs wasm-scalar vs wasm-simd128
# deterministic-digest comparison. emcc and node are provided on PATH by the
# setup-emsdk action.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash "$ROOT/tools/run_wasm_differential_test.sh"
