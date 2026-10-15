#!/bin/sh
# Installs the ellinet13 Alpine repo signing key and adds the repo.
set -eu

KEY_URL="https://alpine.ellinet13.com/repo.rsa.pub"
REPO_URL="https://alpine.ellinet13.com/v3"
KEY_PATH="/etc/apk/keys/repo.rsa.pub"
REPOS_FILE="/etc/apk/repositories"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: you must run this script as root" >&2
    echo "error: try sudo curl https://alpine.ellinet13.com/install-repo.sh | sh" >&2
    echo "error: or doas curl https://alpine.ellinet13.com/install-repo.sh | sh" >&2
    echo "error: or how ever else you become root" >&2
    exit 1
fi

fetch() {
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    else
        echo "error: neither wget nor curl found" >&2
        exit 1
    fi
}

echo "Installing key to $KEY_PATH"
mkdir -p /etc/apk/keys
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
fetch "$KEY_URL" "$tmp"
if [ ! -s "$tmp" ]; then
    echo "error: downloaded key is empty" >&2
    exit 1
fi
install -m 644 "$tmp" "$KEY_PATH"

if grep -qxF "$REPO_URL" "$REPOS_FILE" 2>/dev/null; then
    echo "Repository already present in $REPOS_FILE"
else
    echo "Adding repository $REPO_URL"
    printf '%s\n' "$REPO_URL" >> "$REPOS_FILE"
fi

apk update
echo "Done."