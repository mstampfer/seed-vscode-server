#!/usr/bin/env bash
# =============================================================================
#  seed-vscode-server.sh
#  Pre-seed the VS Code Remote-SSH server for air-gapped / proxied hosts.
#
#  Author   : mstampfer  (https://github.com/mstampfer)
#  Repo      : https://gist.github.com/mstampfer
#  License  : MIT
#  Requires : bash 4+, tar, find, install; curl or wget only for --download
#  Target    : Linux remote (e.g. RHEL 8.10, glibc >= 2.28), x86_64
#
#  Why: recent VS Code dropped the old ~/.vscode-server/bin/<commit>/ layout for
#  ~/.vscode-server/cli/servers/Stable-<commit>/server/ plus a CLI bootstrap
#  binary. On a network that blocks update.code.visualstudio.com, the
#  first-connection server download fails; this script lays the two Microsoft
#  artifacts down at the exact paths the client probes, idempotently.
# =============================================================================
#
# seed-vscode-server.sh
#
# Idempotently pre-seed the VS Code Remote-SSH server into the MODERN
# (CLI-based) layout, so a proxied / locked-down host can connect without the
# first-connection download that your network blocks.
#
# Modern layout (VS Code >= ~1.85, i.e. anything that has NO ~/.vscode-server/bin):
#
#   ~/.vscode-server/
#   |-- code-<commit>                           # CLI bootstrap binary (static / musl)
#   `-- cli/servers/Stable-<commit>/server/     # the REH server (glibc >= 2.28)
#       `-- bin/code-server                     # integrity check: `code-server --version`
#
# You supply the two Microsoft artifacts for the EXACT commit your client wants
# (Help -> About on the client, or the "Using commit id ..." line in the
# Remote-SSH output channel):
#
#   server : https://update.code.visualstudio.com/commit:<commit>/server-linux-x64/stable
#   cli    : https://update.code.visualstudio.com/commit:<commit>/cli-alpine-x64/stable
#
# Typical air-gapped flow:
#   1. On a machine WITH internet (e.g. your Mac), download both tarballs for
#      the commit, then scp them to the RHEL box.
#   2. Run this script ON the RHEL box, as the user who connects over SSH.
#
# Usage:
#   seed-vscode-server.sh --commit <hash> --server <server.tgz> --cli <cli.tgz>
#   seed-vscode-server.sh --server <server.tgz> --cli <cli.tgz>     # auto-detect commit
#   seed-vscode-server.sh --commit <hash> --download               # only if host has egress
#
# Re-running is safe: if the server+CLI for that commit are already present and
# `code-server --version` succeeds, it does nothing.
#
set -euo pipefail

VSCODE_DIR="${VSCODE_SERVER_DIR:-${HOME}/.vscode-server}"
COMMIT=""
SERVER_TARBALL=""
CLI_TARBALL=""
DO_DOWNLOAD=0

log()  { printf '\033[1;34m[seed]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
seed-vscode-server.sh -- pre-seed the VS Code Remote-SSH server (modern layout)

  --commit <hash>     40-char commit hash (matches client Help->About).
                      If omitted, recovered from a leftover Stable-*.staging dir.
  --server <path>     path to server-linux-x64 tarball (.tar.gz)
  --cli <path>        path to cli-alpine-x64 tarball (.tar.gz)
  --download          fetch both from update.code.visualstudio.com for --commit
                      (only works if THIS host can reach that domain)
  -h, --help          this help

Examples:
  seed-vscode-server.sh --commit fcf6047... --server ./server.tgz --cli ./cli.tgz
  seed-vscode-server.sh --server ./server.tgz --cli ./cli.tgz   # auto-detect commit
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)   COMMIT="${2:?--commit needs a value}"; shift 2 ;;
    --server)   SERVER_TARBALL="${2:?--server needs a path}"; shift 2 ;;
    --cli)      CLI_TARBALL="${2:?--cli needs a path}"; shift 2 ;;
    --download) DO_DOWNLOAD=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (use --help)" ;;
  esac
done

# --- Resolve the commit -------------------------------------------------------
# If not supplied, try to recover it from a half-finished .staging directory
# that the blocked download left behind.
if [ -z "$COMMIT" ]; then
  staged="$(find "${VSCODE_DIR}/cli/servers" -maxdepth 1 -name 'Stable-*.staging' \
            -printf '%f\n' 2>/dev/null | head -n1 || true)"
  if [ -n "${staged:-}" ]; then
    COMMIT="${staged#Stable-}"; COMMIT="${COMMIT%.staging}"
    log "recovered commit from staging dir: ${COMMIT}"
  fi
fi
COMMIT="$(printf '%s' "$COMMIT" | tr 'A-Z' 'a-z')"
[ -n "$COMMIT" ] || die "no --commit given and none found under ${VSCODE_DIR}/cli/servers
       (read it from client Help->About or the Remote-SSH output log)"
case "$COMMIT" in
  *[!0-9a-f]*) die "commit '${COMMIT}' is not hex" ;;
esac
[ "${#COMMIT}" -eq 40 ] || die "commit '${COMMIT}' is ${#COMMIT} chars, expected 40"

SERVER_DIR="${VSCODE_DIR}/cli/servers/Stable-${COMMIT}/server"
CLI_BIN="${VSCODE_DIR}/code-${COMMIT}"

# --- Helpers ------------------------------------------------------------------
# The launcher is normally bin/code-server; some builds ship bin/code-server-oss.
launcher_in() {  # launcher_in <server_dir>  -> prints path or returns 1
  if   [ -x "$1/bin/code-server" ];     then printf '%s\n' "$1/bin/code-server"
  elif [ -x "$1/bin/code-server-oss" ]; then printf '%s\n' "$1/bin/code-server-oss"
  else return 1; fi
}
verify_server() {  # verify_server <server_dir>
  local l; l="$(launcher_in "$1")" || return 1
  "$l" --version >/dev/null 2>&1
}

# --- Idempotency check --------------------------------------------------------
if verify_server "$SERVER_DIR" && [ -x "$CLI_BIN" ]; then
  log "server + CLI for ${COMMIT} already present and runnable -- nothing to do."
  "$(launcher_in "$SERVER_DIR")" --version | sed 's/^/[seed]   /'
  exit 0
fi

# --- Temp workspace -----------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Optionally download ------------------------------------------------------
fetch() {  # fetch <url> <dest>
  if   command -v curl >/dev/null 2>&1; then curl -fSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -O "$2" "$1"
  else die "neither curl nor wget available for --download"; fi
}
if [ "$DO_DOWNLOAD" -eq 1 ]; then
  base="https://update.code.visualstudio.com/commit:${COMMIT}"
  if [ -z "$SERVER_TARBALL" ]; then
    SERVER_TARBALL="${TMP}/server.tgz"; log "downloading server..."
    fetch "${base}/server-linux-x64/stable" "$SERVER_TARBALL"
  fi
  if [ -z "$CLI_TARBALL" ]; then
    CLI_TARBALL="${TMP}/cli.tgz"; log "downloading cli..."
    fetch "${base}/cli-alpine-x64/stable" "$CLI_TARBALL"
  fi
fi

[ -n "$SERVER_TARBALL" ] || die "no --server tarball (and --download not set)"
[ -n "$CLI_TARBALL" ]    || die "no --cli tarball (and --download not set)"
[ -f "$SERVER_TARBALL" ] || die "server tarball not found: ${SERVER_TARBALL}"
[ -f "$CLI_TARBALL" ]    || die "cli tarball not found: ${CLI_TARBALL}"

# --- Place the server (atomic: extract to .staging, verify, then rename) ------
if ! verify_server "$SERVER_DIR"; then
  staging="${VSCODE_DIR}/cli/servers/Stable-${COMMIT}.staging"
  log "extracting server -> ${staging}/server"
  rm -rf "$staging"
  mkdir -p "${staging}/server"
  # strip the top-level vscode-server-linux-x64/ folder
  tar -xzf "$SERVER_TARBALL" -C "${staging}/server" --strip-components 1
  l="$(launcher_in "${staging}/server")" \
    || die "extracted server has no bin/code-server -- wrong tarball? (need server-linux-x64)"
  chmod +x "$l" 2>/dev/null || true
  "$l" --version >/dev/null 2>&1 \
    || die "server fails 'code-server --version' -- arch/glibc mismatch? (need x64, glibc>=2.28)"
  rm -rf "${VSCODE_DIR}/cli/servers/Stable-${COMMIT}"
  mkdir -p "${VSCODE_DIR}/cli/servers"
  mv "$staging" "${VSCODE_DIR}/cli/servers/Stable-${COMMIT}"
  log "server in place."
else
  log "server already valid -- leaving it."
fi

# --- Place the CLI bootstrap binary ------------------------------------------
if [ ! -x "$CLI_BIN" ]; then
  log "extracting cli -> ${CLI_BIN}"
  cli_tmp="${TMP}/cli"; mkdir -p "$cli_tmp"
  tar -xzf "$CLI_TARBALL" -C "$cli_tmp"
  # cli-alpine-x64 contains a single 'code' binary (top level)
  src="$(find "$cli_tmp" -maxdepth 2 -type f -name 'code' | head -n1 || true)"
  [ -n "$src" ] || die "cli tarball has no 'code' binary -- wrong tarball? (need cli-alpine-x64)"
  mkdir -p "$VSCODE_DIR"
  install -m 0755 "$src" "$CLI_BIN"
  log "cli in place."
else
  log "cli already present -- leaving it."
fi

# --- Final verification -------------------------------------------------------
log "verifying..."
ver="$("$(launcher_in "$SERVER_DIR")" --version 2>&1 | head -n1 || true)"
[ -n "$ver" ] || die "final integrity check failed: code-server --version produced no output"
log "OK -- server reports: ${ver}"
log "placed:"
printf '       %s\n' "${CLI_BIN}" "$(launcher_in "$SERVER_DIR")"
log "Reconnect with Remote-SSH; it should skip the download for ${COMMIT}."
log "If it still tries to download, open the Remote-SSH output channel and"
log "confirm the commit + path it wants match what was seeded above."
