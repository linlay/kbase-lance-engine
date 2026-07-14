#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(sed -nE 's/^version = "([^"]+)"/\1/p' "$REPO_ROOT/Cargo.toml" | head -n 1)"
OUTPUT_ROOT="$REPO_ROOT/dist"
TARGET_OS=""
TARGET_ARCH=""
CARGO_TARGET_DIR=""

die() {
  echo "[kbase-lance-release] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --os darwin|linux|windows --arch amd64|arm64 [options]

Builds one verified, versioned sidecar archive. Cross-compilation never installs
toolchains; invoke this on a runner that already has the requested Rust target
and linker/SDK.

Options:
  --output DIR      Release artifact root (default: dist)
  --cargo-target-dir DIR
                    Cargo target cache (default: <repo>/target)
EOF
}

rust_target() {
  case "$1/$2" in
    darwin/amd64) echo x86_64-apple-darwin ;;
    darwin/arm64) echo aarch64-apple-darwin ;;
    linux/amd64) echo x86_64-unknown-linux-gnu ;;
    linux/arm64) echo aarch64-unknown-linux-gnu ;;
    windows/amd64) echo x86_64-pc-windows-msvc ;;
    windows/arm64) echo aarch64-pc-windows-msvc ;;
    *) die "unsupported target: $1/$2" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) TARGET_OS="${2:-}"; shift 2 ;;
    --arch) TARGET_ARCH="${2:-}"; shift 2 ;;
    --output) OUTPUT_ROOT="${2:-}"; shift 2 ;;
    --cargo-target-dir) CARGO_TARGET_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$VERSION" ]] || die "package version is missing from Cargo.toml"
[[ -n "$TARGET_OS" && -n "$TARGET_ARCH" ]] || { usage >&2; exit 2; }
command -v cargo >/dev/null 2>&1 || die "cargo is required"
command -v rustup >/dev/null 2>&1 || die "rustup is required"
command -v protoc >/dev/null 2>&1 || die "protoc is required by locked LanceDB dependencies"

triple="$(rust_target "$TARGET_OS" "$TARGET_ARCH")"
if ! rustup target list --installed | grep -Fxq "$triple"; then
  die "Rust target $triple is not installed; provision it on the release runner"
fi

binary_name="kbase-lance-engine"
archive_format="tar.gz"
if [[ "$TARGET_OS" == windows ]]; then
  binary_name+=".exe"
  archive_format="zip"
fi

echo "[kbase-lance-release] building $TARGET_OS/$TARGET_ARCH ($triple)"
if [[ -z "$CARGO_TARGET_DIR" ]]; then
  CARGO_TARGET_DIR="$REPO_ROOT/target"
fi
mkdir -p "$CARGO_TARGET_DIR"
cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --locked --target "$triple" --target-dir "$CARGO_TARGET_DIR"
built_path="$CARGO_TARGET_DIR/$triple/release/$binary_name"
[[ -f "$built_path" ]] || die "Cargo completed but binary is missing: $built_path"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/kbase-lance-release.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
cp "$built_path" "$stage_dir/$binary_name"
chmod 0755 "$stage_dir/$binary_name"
cargo metadata --manifest-path "$REPO_ROOT/Cargo.toml" --locked --format-version 1 >"$stage_dir/cargo-metadata.json"
command -v syft >/dev/null 2>&1 || die "Syft is required to create a release artifact"
syft "$stage_dir/$binary_name" -o "cyclonedx-json=$stage_dir/sbom.cdx.json"
cp "$REPO_ROOT/LICENSE-APACHE-2.0" "$stage_dir/LICENSE-APACHE-2.0"
cp "$REPO_ROOT/NOTICE" "$stage_dir/NOTICE"

artifact_dir="$OUTPUT_ROOT/v$VERSION"
mkdir -p "$artifact_dir"
archive="$artifact_dir/kbase-lance-engine_v${VERSION}_${TARGET_OS}_${TARGET_ARCH}.${archive_format}"
rm -f "$archive" "$archive.sha256"
if [[ "$archive_format" == tar.gz ]]; then
  tar -czf "$archive" -C "$stage_dir" "$binary_name" cargo-metadata.json sbom.cdx.json LICENSE-APACHE-2.0 NOTICE
else
  (cd "$stage_dir" && zip -q "$archive" "$binary_name" cargo-metadata.json sbom.cdx.json LICENSE-APACHE-2.0 NOTICE)
fi
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive" | awk -v name="$(basename "$archive")" '{print $1 "  " name}' >"$archive.sha256"
else
  shasum -a 256 "$archive" | awk -v name="$(basename "$archive")" '{print $1 "  " name}' >"$archive.sha256"
fi
echo "[kbase-lance-release] artifact: $archive"
