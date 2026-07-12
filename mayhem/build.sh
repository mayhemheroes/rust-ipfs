#!/usr/bin/env bash
#
# rust-ipfs/mayhem/build.sh — build rs-ipfs/rust-ipfs's cargo-fuzz target as a sanitized
# libFuzzer binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the
# project's own test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache (runtime exports
#     CARGO_NET_OFFLINE=true) — so do NOT hard-code `--offline` here.
#   - mayhem/Cargo.lock pins the whole dependency graph (upstream ships no lockfile;
#     the resolution must be pinned because the `core2` crate — a transitive dep via
#     libp2p→multiaddr→multihash — has had ALL its crates.io versions yanked, and an
#     unpinned re-resolution would fail).
#
# Targets (upstream's own fuzz/ crate — fuzz/fuzz_targets/decode_ipld.rs):
#   decode_ipld — Arbitrary-decodes a (&str, &[u8]) pair, parses the &str as a CID and
#                 runs ipfs::ipld::decode_ipld() (dag-cbor / dag-pb / raw decode) on the
#                 payload against that CID's codec.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Upstream ships NO Cargo.lock; the additive one lives at mayhem/Cargo.lock. Place a copy
# at the workspace root so every cargo invocation (fuzz build, test build, test run) uses
# the pinned graph. The copy is additive at runtime (root Cargo.lock is untracked).
cp -f mayhem/Cargo.lock Cargo.lock

# ── DWARF < 4 debug-info contract (§6.2 item 10) ───────────────────────────────
# The rlenv runtime may export RUST_DEBUG_FLAGS before re-running build.sh offline; the
# default (applied when unset/empty) forces DWARF 2 so Mayhem triage reads source lines.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

# Rust's ASan runtime (librustc-nightly_rt.asan.a) is built with the nightly's bundled
# LLVM (DWARF 5) and is linked before project code — strip its debug sections so it
# contributes no DWARF ≥ 4 CUs to the final binary.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
  echo "Stripping debug info from Rust ASan runtime: $ASAN_RT"
  objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate — force DWARF 3 there too.
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# Upstream's own cargo-fuzz crate (fuzz/) builds on the pinned nightly — use it as-is.
FUZZ_DIR="fuzz"
FUZZ_TARGETS=(decode_ipld)
TRIPLE="x86_64-unknown-linux-gnu"

# Sanitizer wiring: rust-ipfs is pure Rust, so the base's clang $SANITIZER_FLAGS
# (ASan+UBSan for C/C++) don't apply to rustc — ASan is enabled the cargo-fuzz way,
# via RUSTFLAGS -Zsanitizer=address (the OSS-Fuzz FUZZING_LANGUAGE=rust path).
# cargo-fuzz sets the ASan flag itself, but we pin it explicitly. --cfg fuzzing
# matches libfuzzer-sys; RUST_DEBUG_FLAGS keeps DWARF < 4.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# The fuzz crate is its own workspace (upstream sets [workspace] members=["."] in
# fuzz/Cargo.toml) — pin its graph too with the additive mayhem/fuzz-Cargo.lock.
cp -f mayhem/fuzz-Cargo.lock "$FUZZ_DIR/Cargo.lock"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it) — a `+toolchain` override
# would make rustup try to install another channel into the locked /opt/toolchains/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
done

# Resolve the fuzz crate's target dir robustly via cargo metadata.
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    ls -la "$REL" >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Pre-build the project's OWN test suite (normal flags, no sanitizer) ────────
# The whole workspace (ipfs + ipfs-bitswap + ipfs-http + ipfs-unixfs): unit tests,
# integration tests (tests/), and doctests all compile here so mayhem/test.sh only RUNS.
echo "=== cargo test --no-run --workspace (normal flags, pre-building the test suite) ==="
RUSTFLAGS="" cargo test --no-run --locked --workspace --jobs "$MAYHEM_JOBS"

echo "build.sh complete:"
ls -la /mayhem/decode_ipld
