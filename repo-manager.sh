#!/bin/bash
set -Eeuo pipefail
umask 077

REPO=/repo
KEYS=/keys
ARCH=x86_64
ARCH_DIR="$REPO/v3/$ARCH"
PRIVATE_KEY="$KEYS/repo.rsa"
PUBLIC_KEY="$KEYS/repo.rsa.pub"

export PACKAGER_PRIVKEY="$PRIVATE_KEY"

# Global so the EXIT trap can access it safely.
TMP_DIR=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

configure_signing() {
    [[ -f "$PRIVATE_KEY" ]] ||
        die "Run keygen first."
    [[ -f "$PUBLIC_KEY" ]] ||
        die "Public signing key is missing."

    install -D -m 0644 "$PUBLIC_KEY" \
        /etc/apk/keys/repo.rsa.pub

    export PACKAGER_PRIVKEY="$PRIVATE_KEY"
}

keygen() {
    [[ ! -e "$PRIVATE_KEY" && ! -e "$PUBLIC_KEY" ]] ||
        die "Signing key already exists."

    mkdir -p "$KEYS"

    openssl genrsa -out "$PRIVATE_KEY" 4096
    openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY"

    chmod 0600 "$PRIVATE_KEY"
    chmod 0644 "$PUBLIC_KEY"

    echo "Signing keys created."
}

index() {
    configure_signing
    mkdir -p "$ARCH_DIR"

    TMP_DIR="$(mktemp -d "$ARCH_DIR/.index.XXXXXX")"

    shopt -s nullglob
    local packages=("$ARCH_DIR"/*.apk)
    shopt -u nullglob

    ((${#packages[@]} > 0)) ||
        die "No APK packages found in $ARCH_DIR."

    apk index -o "$TMP_DIR/APKINDEX.tar.gz" "${packages[@]}"
    abuild-sign -k "$PRIVATE_KEY" "$TMP_DIR/APKINDEX.tar.gz"

    chmod 0644 "$TMP_DIR/APKINDEX.tar.gz"
    mv -f "$TMP_DIR/APKINDEX.tar.gz" "$ARCH_DIR/APKINDEX.tar.gz"

    cleanup
    TMP_DIR=""

    echo "Repository index published."
}

build() {
    local package="${1:-}"

    [[ -n "$package" ]] ||
        die "Usage: build PACKAGE_NAME"

    [[ -f "/work/aports/$package/APKBUILD" ]] ||
        die "APKBUILD not found for $package"

    configure_signing

    cd "/work/aports/$package"

    # Build the package. abuild may also attempt to update its
    # own temporary/local repository index under /root/packages.
    abuild -F -r

    local built=()
    while IFS= read -r -d '' file; do
        built+=("$file")
    done < <(
        find /root/packages -type f \
            -name "$package-*.apk" -print0
    )

    ((${#built[@]} > 0)) ||
        die "No package artifact found; inspect abuild output."

    mkdir -p "$ARCH_DIR"
    cp -f "${built[@]}" "$ARCH_DIR/"

    index
}

# Clean up an index staging directory if the script exits early.
trap cleanup EXIT

case "${1:-}" in
    keygen)
        keygen
        ;;
    index)
        index
        ;;
    build)
        shift
        build "$@"
        ;;
    *)
        echo "Usage: repo-manager.sh {keygen|index|build PACKAGE_NAME}" >&2
        exit 2
        ;;
esac
