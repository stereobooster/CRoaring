#!/usr/bin/env bash
# Run CodeQL C++ analysis inside Docker — default build matches upstream CodeQL CI
# roughly (CMake with ENABLE_ROARING_TESTS=ON, like .github/workflows/codeql.yml +
# autobuild defaults). This traces unit tests and benchmarks on 64-bit Linux, not
# wasm_diff_harness.c (that file is not a CMake target; use run_wasm_differential_test.sh).
#
# Why Docker: Apple Silicon Homebrew CodeQL ships an osx64 tracer that fails here
# ("Unknown system error -86"); the official linux64 bundle works under:
#   docker run --platform linux/amd64 ...
#
# Baseline / scc: CodeQL may log "Failed to calculate baseline information" if the
# bundled `scc` tool panics under emulation. That step is only for LoC baseline
# metadata and is non-fatal—extraction + query evaluation still proceed. See logs
# under <db>/log if needed.
#
# Usage (from repo root):
#   bash tools/run_codeql_cpp_docker.sh
#
# Env:
#   CODEQL_BUNDLE_TAG   — default codeql-bundle-v2.25.5 (must match a github/codeql-action release tag)
#   CODEQL_SUITE        — default codeql/cpp-queries:codeql-suites/cpp-security-and-quality.qls
#   SKIP_DOWNLOAD       — if 1 and _codeql_linux_bundle/codeql exists, skip download+extract
#   CODEQL_LIBRARY_ONLY — if 1, use ENABLE_ROARING_TESTS=OFF (faster; not CI-equivalent)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEQL_BUNDLE_TAG="${CODEQL_BUNDLE_TAG:-codeql-bundle-v2.25.5}"
CODEQL_SUITE="${CODEQL_SUITE:-codeql/cpp-queries:codeql-suites/cpp-security-and-quality.qls}"
TGZ="${ROOT}/_codeql_bundle_linux64.tgz"
BUILD="${ROOT}/build-codeql-docker"
DB="${ROOT}/_codeql_db_linux"
SARIF_OUT="${ROOT}/_codeql_results.sarif"

SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
CODEQL_LIBRARY_ONLY="${CODEQL_LIBRARY_ONLY:-0}"

echo "Repo:       $ROOT"
echo "Bundle tag: $CODEQL_BUNDLE_TAG"
echo "Suite:      $CODEQL_SUITE"
echo "Tests:      $([[ "${CODEQL_LIBRARY_ONLY:-0}" == "1" ]] && echo OFF || echo ON)"
echo ""

if ! docker version >/dev/null 2>&1; then
  echo "Docker is required. Install Docker Desktop and retry." >&2
  exit 2
fi

docker run --rm \
  --platform linux/amd64 \
  -v "${ROOT}:/work" \
  -w /work \
  -e DEBIAN_FRONTEND=noninteractive \
  -e "CODEQL_BUNDLE_TAG=${CODEQL_BUNDLE_TAG}" \
  -e "CODEQL_SUITE=${CODEQL_SUITE}" \
  -e "SKIP_DOWNLOAD=${SKIP_DOWNLOAD}" \
  -e "CODEQL_LIBRARY_ONLY=${CODEQL_LIBRARY_ONLY}" \
  ubuntu:24.04 bash -ec '
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq git cmake g++ make wget ca-certificates tar python3 file bash >/dev/null

export PATH="${PATH}:/work/_codeql_linux_bundle"

HAVE_BUNDLE=0
[[ -x /work/_codeql_linux_bundle/codeql ]] && HAVE_BUNDLE=1

if [[ "${SKIP_DOWNLOAD}" == "1" && "${HAVE_BUNDLE}" == "1" ]]; then
  echo "Reusing extracted bundle (SKIP_DOWNLOAD=1)."
elif [[ "${HAVE_BUNDLE}" == "0" ]]; then
  if [[ ! -f "/work/_codeql_bundle_linux64.tgz" ]]; then
    URL="https://github.com/github/codeql-action/releases/download/${CODEQL_BUNDLE_TAG}/codeql-bundle-linux64.tar.gz"
    echo "Downloading CodeQL bundle (${CODEQL_BUNDLE_TAG})..."
    wget -nv -O "/work/_codeql_bundle_linux64.tgz" "${URL}"
  fi
  rm -rf "/work/_codeql_linux_bundle"
  mkdir -p "/work/_codeql_linux_bundle"
  echo "Extracting bundle..."
  tar -xzf "/work/_codeql_bundle_linux64.tgz" -C "/work/_codeql_linux_bundle" --strip-components=1
fi

codeql version

rm -rf "/work/build-codeql-docker" "/work/_codeql_db_linux"
if [[ "${CODEQL_LIBRARY_ONLY}" == "1" ]]; then
  TEST_OPT=( -DENABLE_ROARING_TESTS=OFF )
  echo "CODEQL_LIBRARY_ONLY=1 → tracing library only (tests disabled)."
else
  TEST_OPT=( -DENABLE_ROARING_TESTS=ON )
  echo "ENABLE_ROARING_TESTS=ON (mirror CodeQL autobuild / CMake default)."
fi
cmake -S /work -B /work/build-codeql-docker \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "${TEST_OPT[@]}"

echo "== codeql database create =="
codeql database create "/work/_codeql_db_linux" \
  --language=cpp \
  --overwrite \
  --command="cmake --build /work/build-codeql-docker --parallel" \
  --source-root=/work
# Baseline / scc can log errors under qemu; require a sane DB artifact.
if [[ ! -f /work/_codeql_db_linux/codeql-database.yml ]]; then
  echo "codeql database create failed (no codeql-database.yml)." >&2
  exit 1
fi

echo "== codeql database analyze =="
rm -f /work/_codeql_results.sarif
codeql database analyze "/work/_codeql_db_linux" "${CODEQL_SUITE}" \
  --format=sarifv2.1.0 \
  --output=/work/_codeql_results.sarif \
  --threads=0

echo "== summarize SARIF =="
python3 /work/tools/codeql_summarize_sarif.py /work/_codeql_results.sarif
'

echo ""
echo "OK. SARIF: ${SARIF_OUT}"
echo "Database: ${DB}"
