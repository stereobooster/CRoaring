#!/usr/bin/env bash
# WASM differential test: same harness + amalgamated roaring.c built natively and
# with emcc (scalar wasm + -msimd128 wasm). Compares deterministic stdout digests.
#
# The harness (tests/wasm_diff_harness.c) includes meta_* lines: bounded-universe
# pairwise OR/AND/XOR/ANDNOT membership oracles, iterator-vs-export checks, inplace
# parity, cardinality laws, portable round-trip OR oracle — all exercised on every leg.
#
# Exit codes: 0 success (digests agree), 1 digest mismatch / compare failure,
#   2 missing toolchain (no emcc or node), 3 missing wasm output next to emitted .js.
#
# Requirements: bash, cc (or $CC), emcc (or $EMCC), node (or $NODE).
#
# The -msimd128 leg is now the project's default wasm SIMD path, so the test is
# the three-way digest comparison itself: native, wasm-scalar, and wasm-simd128
# must produce identical output. (Earlier revisions also ran wasm-objdump/LLVM-IR
# SIMD-presence guards to prove the SIMD leg wasn't vacuously scalar during
# bring-up; those are no longer needed now that the SIMD paths have landed.)
#
# Local dev (macOS/Linux): from repo root,
#   bash tools/run_wasm_differential_test.sh
#
# Related (structural preprocessor hygiene, CI emscripten workflow):
#   bash tools/check_wasm_simd_neon_pairing.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-cc}"
EMCC="${EMCC:-emcc}"
NODE="${NODE:-node}"

if ! command -v "$EMCC" >/dev/null 2>&1; then
  echo "run_wasm_differential_test.sh: emcc not found (set EMCC or install Emscripten)." >&2
  exit 2
fi
if ! command -v "$NODE" >/dev/null 2>&1; then
  echo "run_wasm_differential_test.sh: node not found (set NODE)." >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/croaring-wasm-diff.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

AMALG="$WORK/amalg"
mkdir -p "$AMALG"
bash "$ROOT/amalgamation.sh" "$AMALG"

HARNESS="$ROOT/tests/wasm_diff_harness.c"
ROARING_C="$AMALG/roaring.c"
NATIVE_OUT="$WORK/wasm_diff_harness.native"
SCALAR_JS="$WORK/wasm_diff_scalar.js"
SIMD_JS="$WORK/wasm_diff_simd.js"
NATIVE_TXT="$WORK/native.txt"
SCALAR_TXT="$WORK/wasm_scalar.txt"
SIMD_TXT="$WORK/wasm_simd.txt"

echo "== Native ($CC) =="
"$CC" -std=c11 -O2 -Wall -Wextra -DCROARING_AMALGAMATED=1 -I"$AMALG" \
  "$ROARING_C" "$HARNESS" -o "$NATIVE_OUT"
"$NATIVE_OUT" >"$NATIVE_TXT"

echo "== WebAssembly scalar (emcc, no -msimd128) =="
"$EMCC" -std=c11 -O2 -DCROARING_AMALGAMATED=1 -I"$AMALG" \
  "$ROARING_C" "$HARNESS" \
  -sALLOW_MEMORY_GROWTH=1 \
  -sSTACK_SIZE=8388608 \
  -sINITIAL_MEMORY=67108864 \
  -o "$SCALAR_JS"
scalar_wasm_file="${SCALAR_JS%.js}.wasm"
if [[ ! -f "$scalar_wasm_file" ]]; then
  echo "run_wasm_differential_test.sh: expected $scalar_wasm_file" >&2
  exit 3
fi
"$NODE" "$SCALAR_JS" >"$SCALAR_TXT"

echo "== WebAssembly SIMD (emcc -msimd128) =="
cat >"$WORK/simd_preproc.c" <<'EOF'
#if !defined(__wasm_simd128__)
#error "expected __wasm_simd128__ when compiling with -msimd128"
#endif
int main(void) { return 0; }
EOF
"$EMCC" -msimd128 -c "$WORK/simd_preproc.c" -o "$WORK/simd_preproc.o"

"$EMCC" -std=c11 -O2 -msimd128 -DCROARING_AMALGAMATED=1 -I"$AMALG" \
  "$ROARING_C" "$HARNESS" \
  -sALLOW_MEMORY_GROWTH=1 \
  -sSTACK_SIZE=8388608 \
  -sINITIAL_MEMORY=67108864 \
  -o "$SIMD_JS"
simd_wasm_file="${SIMD_JS%.js}.wasm"
if [[ ! -f "$simd_wasm_file" ]]; then
  echo "run_wasm_differential_test.sh: expected $simd_wasm_file" >&2
  exit 3
fi
"$NODE" "$SIMD_JS" >"$SIMD_TXT"

compare_digests() {
  local a="$1"
  local b="$2"
  local label="$3"
  if cmp -s "$a" "$b"; then
    return 0
  fi
  echo "run_wasm_differential_test.sh: digest mismatch: $label" >&2
  echo "diff -u (first 80 lines):" >&2
  (diff -u "$a" "$b" || true) | sed -n '1,80p' >&2
  exit 1
}

echo "== Compare digests =="
compare_digests "$NATIVE_TXT" "$SCALAR_TXT" "native vs wasm scalar"
compare_digests "$NATIVE_TXT" "$SIMD_TXT" "native vs wasm -msimd128"
compare_digests "$SCALAR_TXT" "$SIMD_TXT" "wasm scalar vs wasm -msimd128"
echo "OK: native, wasm scalar, and wasm -msimd128 digests match."
