#!/bin/sh
set -eu

# install.sh — download and install the latest hty release binary.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/montanaflynn/hty/main/scripts/install.sh | sh
#   sh install.sh --version v0.2.0
#   sh install.sh --install-dir ~/.local/bin
#   HTY_INSTALL_DIR=~/.local/bin sh install.sh
#
# Options:
#   --version VERSION    Release tag to install (default: latest)
#   --install-dir DIR    Install directory (default: ~/.local/bin or HTY_INSTALL_DIR)
#   --verify MODE        auto | always | never — checksum verification (default: auto)
#   --color MODE         auto | always | never (default: auto)
#   --force              Overwrite existing binary without prompting
#   --silent             Suppress normal output
#   --json               Emit structured JSON lines instead of human output
#   --dry-run            Print what would happen without changing the system
#   --help               Show this help
#
# Environment variables:
#   HTY_INSTALL_DIR      Override the default install directory
#   NO_COLOR             Disable color output when set

REPO="montanaflynn/hty"
BINARY_NAME="hty"
GITHUB_BASE_URL="https://github.com"
INSTALL_DIR="${HTY_INSTALL_DIR:-${HOME}/.local/bin}"
VERSION="latest"
FORCE=0
DRY_RUN=0
SILENT=0
JSON=0
VERIFY="auto"
COLOR_MODE="auto"
TMPDIR_CREATED=""

usage() {
  cat <<'EOF'
Usage:
  sh install.sh [options]

Options:
  --version VERSION    Release tag (default: latest)
  --install-dir DIR    Install directory (default: ~/.local/bin)
  --verify MODE        auto | always | never (default: auto)
  --color MODE         auto | always | never (default: auto)
  --force              Overwrite existing binary
  --silent             Suppress normal output
  --json               Emit structured JSON lines
  --dry-run            Show planned actions without changing the system
  --help               Show this help

Environment:
  HTY_INSTALL_DIR      Override default install directory
  NO_COLOR             Disable color output
EOF
}

cleanup() {
  if [ -n "$TMPDIR_CREATED" ] && [ -d "$TMPDIR_CREATED" ]; then
    rm -rf "$TMPDIR_CREATED"
  fi
}

trap cleanup EXIT INT HUP TERM

# --- output helpers ---------------------------------------------------------

should_use_color() {
  case "$COLOR_MODE" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)
      [ -z "${NO_COLOR:-}" ] && [ -t 2 ]
      return
      ;;
  esac
}

color_code() {
  if should_use_color; then
    printf '%b' "$1"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

log_event() {
  _level="$1"; shift
  _event="$1"; shift
  _msg="$*"

  if [ "$JSON" -eq 1 ]; then
    printf '{"level":"%s","event":"%s","message":"%s"}\n' \
      "$(json_escape "$_level")" \
      "$(json_escape "$_event")" \
      "$(json_escape "$_msg")"
    return
  fi

  [ "$SILENT" -eq 1 ] && [ "$_level" != "error" ] && return

  _reset="$(color_code '\033[0m')"
  case "$_level" in
    info)    _prefix="$(color_code '\033[34m')info${_reset}" ;;
    warn)    _prefix="$(color_code '\033[33m')warn${_reset}" ;;
    error)   _prefix="$(color_code '\033[31m')error${_reset}" ;;
    success) _prefix="$(color_code '\033[32m')ok${_reset}" ;;
    *)       _prefix="$_level" ;;
  esac

  printf '%s %s\n' "$_prefix" "$_msg" >&2
}

info()    { log_event info    "$@"; }
warn()    { log_event warn    "$@"; }
error()   { log_event error   "$@"; }
success() { log_event success "$@"; }

die() {
  error fatal "$*"
  exit 1
}

# --- core helpers -----------------------------------------------------------

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info dry_run "$*"
    return 0
  fi
  "$@"
}

fetch() {
  _url="$1"
  _output="$2"

  if command -v curl >/dev/null 2>&1; then
    if [ "$SILENT" -eq 1 ] || [ "$JSON" -eq 1 ]; then
      run curl -fsSL "$_url" -o "$_output"
    else
      run curl -fL --progress-bar "$_url" -o "$_output"
    fi
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    if [ "$SILENT" -eq 1 ] || [ "$JSON" -eq 1 ]; then
      run wget -q "$_url" -O "$_output"
    else
      run wget "$_url" -O "$_output"
    fi
    return
  fi

  die "curl or wget is required"
}

# --- platform detection -----------------------------------------------------

detect_platform() {
  _os_raw=$(uname -s)
  _arch_raw=$(uname -m)

  case "$_os_raw" in
    Linux)  OS_NAME="linux" ;;
    Darwin) OS_NAME="macos" ;;
    *)      die "unsupported OS: $_os_raw" ;;
  esac

  case "$_arch_raw" in
    x86_64|amd64)  ARCH_NAME="x86_64" ;;
    arm64|aarch64) ARCH_NAME="aarch64" ;;
    *)             die "unsupported architecture: $_arch_raw" ;;
  esac
}

# --- url resolution ---------------------------------------------------------

resolve_urls() {
  ASSET_NAME="${BINARY_NAME}-${ARCH_NAME}-${OS_NAME}.tar.gz"
  CHECKSUM_ASSET="${ASSET_NAME}.sha256"

  case "$VERSION" in
    latest)
      ASSET_URL="${GITHUB_BASE_URL}/${REPO}/releases/latest/download/${ASSET_NAME}"
      CHECKSUM_URL="${GITHUB_BASE_URL}/${REPO}/releases/latest/download/${CHECKSUM_ASSET}"
      ;;
    *)
      ASSET_URL="${GITHUB_BASE_URL}/${REPO}/releases/download/${VERSION}/${ASSET_NAME}"
      CHECKSUM_URL="${GITHUB_BASE_URL}/${REPO}/releases/download/${VERSION}/${CHECKSUM_ASSET}"
      ;;
  esac
}

# --- installation -----------------------------------------------------------

ensure_install_dir() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi
  if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
    info install "creating ${INSTALL_DIR} requires elevated privileges"
    sudo mkdir -p "$INSTALL_DIR" || die "failed to create install directory: ${INSTALL_DIR}"
  fi
}

checksum_verify() {
  _archive_path="$1"
  _checksum_path="$2"

  if [ ! -s "$_checksum_path" ]; then
    case "$VERIFY" in
      always) die "checksum verification required but checksum file is empty" ;;
      auto)   warn checksum "checksum file empty, skipping verification"; return 0 ;;
      never)  return 0 ;;
    esac
  fi

  _archive_base=$(basename "$_archive_path")
  _expected=$(grep " ${_archive_base}\$" "$_checksum_path" | awk '{print $1}' || true)

  if [ -z "$_expected" ]; then
    case "$VERIFY" in
      always) die "no checksum entry for $_archive_base" ;;
      auto)   warn checksum "no checksum entry for $_archive_base, skipping"; return 0 ;;
      never)  return 0 ;;
    esac
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    _actual=$(sha256sum "$_archive_path" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    _actual=$(shasum -a 256 "$_archive_path" | awk '{print $1}')
  else
    case "$VERIFY" in
      always) die "no sha256 tool available for verification" ;;
      auto)   warn checksum "no sha256 tool available, skipping verification"; return 0 ;;
      never)  return 0 ;;
    esac
  fi

  if [ "$_expected" != "$_actual" ]; then
    die "checksum mismatch for $_archive_base (expected: $_expected, got: $_actual)"
  fi

  success checksum "verified $_archive_base"
}

install_binary() {
  _src="$1"
  _dst="$2"

  if [ -e "$_dst" ] && [ "$FORCE" -ne 1 ]; then
    die "$_dst already exists (use --force to overwrite)"
  fi

  if [ -w "$(dirname "$_dst")" ]; then
    run install -m 0755 "$_src" "$_dst"
  else
    info install "writing to $_dst requires elevated privileges"
    run sudo install -m 0755 "$_src" "$_dst"
  fi
}

detect_shell_profile() {
  _shell="${SHELL:-/bin/sh}"
  _shell_name=$(basename "$_shell")

  case "$_shell_name" in
    zsh)
      if [ -f "${HOME}/.zshrc" ]; then
        printf '%s' "${HOME}/.zshrc"
      else
        printf '%s' "${HOME}/.zprofile"
      fi
      ;;
    bash)
      if [ -f "${HOME}/.bashrc" ]; then
        printf '%s' "${HOME}/.bashrc"
      elif [ -f "${HOME}/.bash_profile" ]; then
        printf '%s' "${HOME}/.bash_profile"
      else
        printf '%s' "${HOME}/.profile"
      fi
      ;;
    fish)
      printf '%s' "${HOME}/.config/fish/config.fish"
      ;;
    *)
      printf '%s' "${HOME}/.profile"
      ;;
  esac
}

path_export_line() {
  _shell="${SHELL:-/bin/sh}"
  _shell_name=$(basename "$_shell")

  case "$_shell_name" in
    fish)
      printf 'fish_add_path "%s"' "$INSTALL_DIR"
      ;;
    *)
      printf 'export PATH="%s:$PATH"' "$INSTALL_DIR"
      ;;
  esac
}

path_hint() {
  case ":${PATH}:" in
    *:"${INSTALL_DIR}":*) ;;
    *)
      _profile=$(detect_shell_profile)
      _export=$(path_export_line)

      if [ "$JSON" -eq 1 ]; then
        printf '{"level":"info","event":"path_hint","message":"%s is not on PATH","profile":"%s","command":"%s"}\n' \
          "$(json_escape "$INSTALL_DIR")" \
          "$(json_escape "$_profile")" \
          "$(json_escape "$_export")"
      elif [ "$SILENT" -eq 0 ]; then
        printf '\n' >&2
        printf '  Run this to add hty to your PATH (or restart your shell):\n' >&2
        printf '\n' >&2
        printf '  echo '\''%s'\'' >> %s && source %s\n' "$_export" "$_profile" "$_profile" >&2
      fi
      ;;
  esac
}

# --- argument parsing -------------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || die "missing value for --version"
        VERSION="$2"; shift 2 ;;
      --install-dir)
        [ "$#" -ge 2 ] || die "missing value for --install-dir"
        INSTALL_DIR="$2"; shift 2 ;;
      --verify)
        [ "$#" -ge 2 ] || die "missing value for --verify"
        VERIFY="$2"; shift 2 ;;
      --color)
        [ "$#" -ge 2 ] || die "missing value for --color"
        COLOR_MODE="$2"; shift 2 ;;
      --silent)  SILENT=1; shift ;;
      --json)    JSON=1; SILENT=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force)   FORCE=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *)         die "unknown argument: $1" ;;
    esac
  done

  case "$VERIFY" in
    auto|always|never) ;;
    *) die "invalid --verify mode: $VERIFY (expected: auto, always, never)" ;;
  esac

  case "$COLOR_MODE" in
    auto|always|never) ;;
    *) die "invalid --color mode: $COLOR_MODE (expected: auto, always, never)" ;;
  esac
}

# --- main -------------------------------------------------------------------

main() {
  parse_args "$@"

  need_cmd uname
  need_cmd mktemp
  need_cmd tar
  need_cmd install

  detect_platform
  resolve_urls

  info start "installing hty for ${OS_NAME}/${ARCH_NAME}"

  ensure_install_dir

  TMPDIR_CREATED=$(mktemp -d)
  _archive_path="${TMPDIR_CREATED}/${ASSET_NAME}"
  _checksum_path="${TMPDIR_CREATED}/${CHECKSUM_ASSET}"
  _extract_dir="${TMPDIR_CREATED}/extract"
  _dest_path="${INSTALL_DIR}/${BINARY_NAME}"

  [ "$DRY_RUN" -eq 0 ] && mkdir -p "$_extract_dir"

  info download "fetching ${ASSET_URL}"
  fetch "$ASSET_URL" "$_archive_path"

  case "$VERIFY" in
    never)
      info checksum "checksum verification disabled"
      ;;
    *)
      if fetch "$CHECKSUM_URL" "$_checksum_path" 2>/dev/null; then
        checksum_verify "$_archive_path" "$_checksum_path"
      else
        case "$VERIFY" in
          always) die "failed to fetch checksum: ${CHECKSUM_URL}" ;;
          auto)   warn checksum "checksum not available, skipping verification" ;;
        esac
      fi
      ;;
  esac

  info extract "extracting archive"
  run tar -xzf "$_archive_path" -C "$_extract_dir"

  if [ "$DRY_RUN" -eq 0 ] && [ ! -f "${_extract_dir}/${BINARY_NAME}" ]; then
    die "binary not found in archive"
  fi

  info install "installing to ${_dest_path}"
  install_binary "${_extract_dir}/${BINARY_NAME}" "$_dest_path"

  success done "installed hty to ${_dest_path}"
  path_hint

  if [ "$DRY_RUN" -eq 0 ]; then
    if "$_dest_path" --help >/dev/null 2>&1; then
      success smoke_test "binary runs ok"
    else
      warn smoke_test "installed but smoke test failed: ${_dest_path} --help"
    fi
  fi
}

main "$@"
