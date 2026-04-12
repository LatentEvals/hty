#!/bin/sh
set -e

REPO="montanaflynn/hty"
INSTALL_DIR="${HTY_INSTALL_DIR:-/usr/local/bin}"

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Darwin) os="macos" ;;
  Linux)  os="linux" ;;
  *)      echo "error: unsupported OS: $OS" >&2; exit 1 ;;
esac

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) arch="aarch64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *)             echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

NAME="hty-${arch}-${os}"
URL="https://github.com/${REPO}/releases/latest/download/${NAME}.tar.gz"

echo "downloading ${NAME}..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

curl -fsSL "$URL" -o "$TMPDIR/${NAME}.tar.gz"
tar -xzf "$TMPDIR/${NAME}.tar.gz" -C "$TMPDIR"

if [ -w "$INSTALL_DIR" ]; then
  mv "$TMPDIR/hty" "$INSTALL_DIR/hty"
else
  echo "installing to ${INSTALL_DIR} (requires sudo)..."
  sudo mv "$TMPDIR/hty" "$INSTALL_DIR/hty"
fi

chmod +x "$INSTALL_DIR/hty"
echo "installed hty to ${INSTALL_DIR}/hty"
echo ""
"$INSTALL_DIR/hty" --help | head -3
