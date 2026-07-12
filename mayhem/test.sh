#!/usr/bin/env bash
#
# rust-ipfs/mayhem/test.sh — RUN rs-ipfs/rust-ipfs's own test suite (`cargo test
# --workspace`: ipfs + ipfs-bitswap + ipfs-http + ipfs-unixfs) and emit a CTRF summary.
# exit 0 iff no test failed.
#
# PATCH-grade oracle: rust-ipfs ships a real assertion suite —
#   - src unit tests (ipld round-trips, dag-cbor known-answer decodes, path resolution,
#     unixfs adder golden CIDs, keystore, repo/pinstore semantics);
#   - tests/: multi-node swarm integration tests over loopback (bitswap block exchange,
#     kademlia queries, pubsub subscribe/publish, connectivity, wantlist cancellation)
#     asserting exchanged block contents / peer lists / message payloads;
#   - ipfs-http unit tests (v0 API arg parsing, refs formatting — asserted values);
#   - ipfs-unixfs unit tests + doctests (golden CIDs for file/dir trees).
# These assert concrete values, so a no-op / "exit(0)" patch cannot pass.
#
# Skipped upstream tests (recorded, not run):
#   - conformance/ — the js-ipfs-http-api interop conformance suite: a JavaScript/npm
#     harness (mocha) driving the ipfs-http daemon; not a cargo test, needs node+npm and
#     network fetch of js-ipfs at test time — cannot run air-gapped as part of cargo test.
#   - feature-gated interop tests (features test_go_interop / test_js_interop) — need a
#     running go-ipfs/js-ipfs peer; upstream disables them by default (non-default features).
#   - benches/ (criterion) — benchmarks, not correctness tests.
# This script only RUNS the suite; build.sh pre-compiled it with `cargo test --no-run`.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

# build.sh placed the pinned lockfile at the workspace root and pre-built the suite.
if [ ! -f Cargo.lock ]; then
  echo "Cargo.lock missing — mayhem/build.sh did not run (it copies mayhem/Cargo.lock)" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test --workspace (rust-ipfs unit + integration suite) ==="
# Image-default toolchain (the Dockerfile pins the same nightly the fuzz build uses).
# --no-fail-fast so every test is counted; RUSTFLAGS cleared so nothing leaks in from the
# sanitizer build (same flags as build.sh's `cargo test --no-run` → cached, no recompile).
# The swarm integration tests talk over loopback only — offline-safe.
out="$(RUSTFLAGS="" cargo test --locked --workspace --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 87 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; ...
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
