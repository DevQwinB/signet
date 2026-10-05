#!/usr/bin/env bash
# Builds the signet CLI for every release target, stages each @signet/cli-<platform>
# npm package, writes cli/dist/checksums.txt, and pins the @signet/cli shim.
# With SIMULATOR_DIR set it also ships signet-simulator next to signet in each
# npm package and in a per-platform release archive (docs/CLI_RUST_BRIDGE.md
# section 5).
#
# Shared by .github/workflows/release-cli.yml (real release) and
# .github/workflows/release-cli-dry-run.yml (PR rehearsal) so the two cannot
# drift. It builds, stages, archives and pins only: publishing stays in
# release-cli.yml.
#
# Go cross-compiles from one host with just GOOS/GOARCH (no cgo, see
# cli/go.mod), so every target is built here in one pass. The Rust simulator
# does not cross-compile to macOS from Linux, so it is built natively per
# target by .github/workflows/build-simulator.yml and handed in via SIMULATOR_DIR.
#
# Env:
#   VERSION       required  release version, no `cli-v` prefix
#                           (e.g. 0.1.0 or 0.0.0-dryrun.abc1234)
#   COMMIT        optional  commit stamped into the binary (default: git rev-parse HEAD)
#   BUILD_ONLY    optional  space-separated npm package names (e.g. "cli-linux-x64")
#                           to build a subset, for local runs. CI leaves it unset
#                           (all targets). The shim pin step always runs.
#   SIMULATOR_DIR optional  directory holding the natively built simulators as
#                           downloaded from the artifacts of build-simulator.yml:
#                           <SIMULATOR_DIR>/simulator-<npm_pkg>/signet-simulator[.exe].
#                           Relative paths resolve against the caller's cwd.
#                           Set: each target's simulator is staged next to signet
#                           in its npm package, both are packed into
#                           cli/dist/signet-<VERSION>-<npm_pkg>.tar.gz (.zip for
#                           windows, both binaries at the top level), and
#                           checksums.txt covers those archives (they replace the
#                           bare binaries on the GitHub Release). A missing
#                           simulator for a built target fails the script.
#                           Unset: signet only, bare-binary checksums (local runs).
#
# Output: cli/dist/<npm_pkg>-<binary>, cli/dist/checksums.txt, staged
# cli/npm/<npm_pkg>/bin/*, the pinned cli/npm/cli/package.json and, with
# SIMULATOR_DIR, cli/dist/signet-<VERSION>-<npm_pkg>.{tar.gz,zip}.
set -euo pipefail

: "${VERSION:?VERSION is required (e.g. VERSION=0.0.0-dryrun.abc1234)}"

SIMULATOR_DIR="${SIMULATOR_DIR:-}"
if [[ -n "$SIMULATOR_DIR" ]]; then
  SIMULATOR_DIR="$(cd "$SIMULATOR_DIR" 2>/dev/null && pwd)" || {
    echo "::error::SIMULATOR_DIR does not exist" >&2
    exit 1
  }
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
COMMIT="${COMMIT:-$(git rev-parse HEAD)}"
BUILD_ONLY="${BUILD_ONLY:-}"

# goos goarch npm_pkg: one line per release target.
targets=(
  "linux   amd64 cli-linux-x64"
  "linux   arm64 cli-linux-arm64"
  "darwin  arm64 cli-darwin-arm64"
  "darwin  amd64 cli-darwin-x64"
  "windows amd64 cli-windows-x64"
)

# Builds ./cmd/signet for goos/goarch into the given path (relative to cli/).
build_signet() {
  local goos="$1" goarch="$2" out="$3"
  (
    cd cli
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build \
      -trimpath \
      -ldflags "-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o "$out" \
      ./cmd/signet
  )
}

# Stages the built binaries of one target into cli/npm/<npm_pkg>. A platform
# package holds several binaries (signet and signet-simulator), so each
# argument is "<built path relative to the repo root>=<name in bin/>".
stage_package() {
  local npm_pkg="$1"
  shift
  node scripts/release/stage-platform-package.mjs "cli/npm/${npm_pkg}" "${VERSION}" "$@"
}

# Packs "<built path>=<name>" files into cli/dist/<archive>, each under its
# real name at the archive's top level. .zip for windows, .tar.gz otherwise.
make_archive() {
  local archive="$1" spec tmp
  shift
  tmp="$(mktemp -d)"
  local names=()
  for spec in "$@"; do
    cp "${spec%%=*}" "$tmp/${spec#*=}"
    names+=("${spec#*=}")
  done
  rm -f "cli/dist/${archive}"
  case "$archive" in
    *.zip) (cd "$tmp" && zip -q -X "$repo_root/cli/dist/${archive}" "${names[@]}") ;;
    *) (cd "$tmp" && tar --owner=0 --group=0 --numeric-owner -czf "$repo_root/cli/dist/${archive}" "${names[@]}") ;;
  esac
  rm -rf "$tmp"
}

mkdir -p cli/dist
: > cli/dist/checksums.txt

for target in "${targets[@]}"; do
  read -r goos goarch npm_pkg <<< "$target"
  if [[ -n "$BUILD_ONLY" && " $BUILD_ONLY " != *" $npm_pkg "* ]]; then
    continue
  fi
  binname="signet"
  simname="signet-simulator"
  if [[ "$goos" == windows ]]; then
    binname="signet.exe"
    simname="signet-simulator.exe"
  fi
  out="dist/${npm_pkg}-${binname}"
  echo "::group::build ${goos}/${goarch}"
  build_signet "$goos" "$goarch" "$out"

  if [[ -z "$SIMULATOR_DIR" ]]; then
    # signet only: today's behaviour. Checksum lines carry the dist/-relative path.
    (cd cli && sha256sum "$out") >> cli/dist/checksums.txt
    stage_package "$npm_pkg" "cli/${out}=${binname}"
  else
    sim_src="${SIMULATOR_DIR}/simulator-${npm_pkg}/${simname}"
    if [[ ! -f "$sim_src" ]]; then
      echo "::error::simulator binary not found for ${npm_pkg}: ${sim_src}" >&2
      exit 1
    fi
    sim_out="dist/${npm_pkg}-${simname}"
    cp "$sim_src" "cli/${sim_out}"
    chmod +x "cli/${sim_out}" # upload-artifact does not preserve the exec bit
    stage_package "$npm_pkg" "cli/${out}=${binname}" "cli/${sim_out}=${simname}"

    ext="tar.gz"
    [[ "$goos" == windows ]] && ext="zip"
    archive="signet-${VERSION}-${npm_pkg}.${ext}"
    make_archive "$archive" "cli/${out}=${binname}" "cli/${sim_out}=${simname}"
    # The archives replace the bare binaries on the release, so the checksums
    # cover them, by bare file name so `sha256sum -c` works beside the downloads.
    (cd cli/dist && sha256sum "$archive") >> cli/dist/checksums.txt
  fi
  echo "::endgroup::"
done
cat cli/dist/checksums.txt

node scripts/release/pin-shim-version.mjs "${VERSION}"
