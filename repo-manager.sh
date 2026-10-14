#!/bin/bash
set -Eeuo pipefail
umask 077

REPO="${REPO:-/repo}"
KEYS="${KEYS:-/keys}"
APORTS="${APORTS:-/work/aports}"

# Architectures served by this repository.
ARCHES="${ARCHES:-x86 x86_64 armhf armv7 aarch64 ppc64le s390x riscv64 noarch}"

PRIVATE_KEY="$KEYS/repo.rsa"
PUBLIC_KEY="$KEYS/repo.rsa.pub"

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

trap cleanup EXIT

# Nginx runs as an unprivileged user. Ensure it can traverse
# directories and read published packages and indexes.
fix_repository_permissions() {
    [[ -d "$REPO" ]] || return 0

    find "$REPO" -type d -exec chmod 0755 {} +
    find "$REPO" -type f -exec chmod 0644 {} +
}

configure_signing() {
    [[ -f "$PRIVATE_KEY" ]] || die "Run keygen first."
    [[ -f "$PUBLIC_KEY" ]] || die "Public signing key is missing."

    chmod 0700 "$KEYS"
    chmod 0600 "$PRIVATE_KEY"
    chmod 0644 "$PUBLIC_KEY"

    install -D -m 0644 "$PUBLIC_KEY" /etc/apk/keys/repo.rsa.pub
    export PACKAGER_PRIVKEY="$PRIVATE_KEY"
}

get_package_arch() {
    local archive="$1"
    local metadata

    metadata="$(tar -xOzf "$archive" .PKGINFO 2>/dev/null)" ||
        die "Cannot read .PKGINFO from $archive"

    printf '%s\n' "$metadata" |
        sed -n 's/^arch = //p' |
        head -n 1
}

get_package_name() {
    local archive="$1"
    local metadata

    metadata="$(tar -xOzf "$archive" .PKGINFO 2>/dev/null)" ||
        die "Cannot read .PKGINFO from $archive"

    printf '%s\n' "$metadata" |
        sed -n 's/^pkgname = //p' |
        head -n 1
}

validate_arches() {
    local arch
    local -A seen=()

    [[ -n "$ARCHES" ]] || die "ARCHES cannot be empty."

    for arch in $ARCHES; do
        [[ "$arch" =~ ^[a-zA-Z0-9_-]+$ ]] ||
            die "Invalid architecture name: $arch"

        [[ -z "${seen[$arch]:-}" ]] ||
            die "Duplicate architecture: $arch"

        seen["$arch"]=1
    done
}

keygen() {
    [[ ! -e "$PRIVATE_KEY" && ! -e "$PUBLIC_KEY" ]] ||
        die "Signing key already exists."

    install -d -m 0700 "$KEYS"

    openssl genrsa -out "$PRIVATE_KEY" 4096
    openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY"

    chmod 0600 "$PRIVATE_KEY"
    chmod 0644 "$PUBLIC_KEY"

    printf 'Signing keys created.\n'
}

publish_package() {
    local archive="$1"
    local pkg_arch
    local pkg_name
    local arch
    local destination
    local published=0

    [[ -f "$archive" ]] || die "Package not found: $archive"

    pkg_name="$(get_package_name "$archive")"
    pkg_arch="$(get_package_arch "$archive")"

    [[ -n "$pkg_name" ]] || die "Missing pkgname in $archive"
    [[ -n "$pkg_arch" ]] || die "Missing arch in $archive"

    printf 'Package: %s\nArchitecture: %s\n' "$pkg_name" "$pkg_arch"

    if [[ "$pkg_arch" == "noarch" ]]; then
        for arch in $ARCHES; do
            destination="$REPO/v3/$arch"
            install -d -m 0755 "$destination"
            install -m 0644 "$archive" "$destination/${archive##*/}"

            printf 'Published noarch package to %s\n' "$destination"
            published=1
        done
    else
        for arch in $ARCHES; do
            if [[ "$pkg_arch" == "$arch" ]]; then
                destination="$REPO/v3/$arch"
                install -d -m 0755 "$destination"
                install -m 0644 "$archive" "$destination/${archive##*/}"

                printf 'Published package to %s\n' "$destination"
                published=1
                break
            fi
        done
    fi

    ((published == 1)) ||
        die "Architecture '$pkg_arch' is not configured in ARCHES='$ARCHES'."
}

index_one() {
    local arch="$1"
    local arch_dir="$REPO/v3/$arch"
    local package
    local pkg_arch
    local pkg_name
    local -a packages=()

    install -d -m 0755 "$arch_dir"

    shopt -s nullglob
    packages=("$arch_dir"/*.apk)
    shopt -u nullglob

    if ((${#packages[@]} == 0)); then
        printf 'Skipping %s: no packages published yet.\n' "$arch"
        return 0
    fi

    printf '\nIndexing %s (%d packages)\n' \
        "$arch" "${#packages[@]}"

    for package in "${packages[@]}"; do
        pkg_name="$(get_package_name "$package")"
        pkg_arch="$(get_package_arch "$package")"

        [[ -n "$pkg_name" && -n "$pkg_arch" ]] ||
            die "Invalid package metadata: $package"

        if [[ "$pkg_arch" != "noarch" && "$pkg_arch" != "$arch" ]]; then
            die "$package declares arch=$pkg_arch but is in $arch_dir"
        fi
    done

    TMP_DIR="$(mktemp -d "$arch_dir/.index.XXXXXX")"

    apk index \
        --output "$TMP_DIR/APKINDEX.tar.gz" \
        "${packages[@]}"

    abuild-sign -k "$PRIVATE_KEY" "$TMP_DIR/APKINDEX.tar.gz"

    chmod 0644 "$TMP_DIR/APKINDEX.tar.gz"

    # Publish the complete signed index atomically.
    mv -f "$TMP_DIR/APKINDEX.tar.gz" "$arch_dir/APKINDEX.tar.gz"

    cleanup
    TMP_DIR=""

    chmod 0755 "$arch_dir"
    chmod 0644 "$arch_dir"/*.apk "$arch_dir/APKINDEX.tar.gz"

    printf 'Published index: %s/APKINDEX.tar.gz\n' "$arch_dir"
}

index() {
    local arch

    configure_signing
    validate_arches

    install -d -m 0755 "$REPO"
    fix_repository_permissions

    for arch in $ARCHES; do
        index_one "$arch"
    done

    fix_repository_permissions

    printf '\nRepository indexing complete.\n'
}

# Build one package and publish its artifacts.
# Indexing is performed separately after all requested builds finish.
build_one() {
    local package="$1"
    local source_dir
    local file
    local pkg_name
    local -a built=()

    source_dir="$APORTS/$package"

    [[ -f "$source_dir/APKBUILD" ]] ||
        die "APKBUILD not found: $source_dir/APKBUILD"

    printf '\n========== Building %s ==========\n' "$package"

    (
        cd "$source_dir"
        abuild -F -r
    )

    while IFS= read -r -d '' file; do
        pkg_name="$(get_package_name "$file")"

        if [[ "$pkg_name" == "$package" ]]; then
            built+=("$file")
        fi
    done < <(
        find /root/packages -type f -name '*.apk' -print0
    )

    ((${#built[@]} > 0)) ||
        die "No built artifact for '$package' found under /root/packages."

    for file in "${built[@]}"; do
        publish_package "$file"
    done

    printf 'Finished building %s.\n' "$package"
}

# Build one or more explicitly named packages.
build() {
    local package

    (($# > 0)) || die "Usage: build PACKAGE_NAME [PACKAGE_NAME ...]"

    configure_signing
    validate_arches

    for package in "$@"; do
        [[ "$package" =~ ^[a-zA-Z0-9_.+-]+$ ]] ||
            die "Invalid package name: $package"

        build_one "$package"
    done

    index
}

# Build every package directory under APORTS, except excluded packages.
#
# Usage:
#   build-all
#   build-all --exclude PACKAGE
#   build-all --exclude PACKAGE1 --exclude PACKAGE2
#   build-all -e PACKAGE1 -e PACKAGE2
build_all() {
    local arg
    local package
    local directory
    local -A excluded=()
    local -a directories=()
    local -a packages=()

    while (($# > 0)); do
        arg="$1"
        shift

        case "$arg" in
            --exclude|-e)
                (($# > 0)) ||
                    die "Missing package name after $arg"

                package="$1"
                shift

                [[ "$package" =~ ^[a-zA-Z0-9_.+-]+$ ]] ||
                    die "Invalid excluded package name: $package"

                excluded["$package"]=1
                ;;
            --)
                (($# == 0)) ||
                    die "Unexpected arguments after --: $*"
                ;;
            -*)
                die "Unknown build-all option: $arg"
                ;;
            *)
                die "Unexpected argument '$arg'. Use --exclude PACKAGE."
                ;;
        esac
    done

    [[ -d "$APORTS" ]] ||
        die "APORTS directory not found: $APORTS"

    configure_signing
    validate_arches

    # Only consider immediate child directories containing APKBUILD.
    shopt -s nullglob
    directories=("$APORTS"/*/)
    shopt -u nullglob

    for directory in "${directories[@]}"; do
        [[ -f "$directory/APKBUILD" ]] || continue

        package="${directory%/}"
        package="${package##*/}"

        if [[ -n "${excluded[$package]:-}" ]]; then
            printf 'Excluding package: %s\n' "$package"
            continue
        fi

        packages+=("$package")
    done

    ((${#packages[@]} > 0)) ||
        die "No packages to build under $APORTS after applying exclusions."

    printf 'Packages to build: %d\n' "${#packages[@]}"

    local succeeded=0

    for package in "${packages[@]}"; do
        build_one "$package"
        ((succeeded += 1))
    done

    printf '\nBuilt and published %d packages.\n' "$succeeded"

    # Index once after all packages have been published.
    index
}

case "${1:-}" in
    keygen)
        shift
        (($# == 0)) || die "Usage: keygen"
        keygen
        ;;
    index)
        shift
        (($# == 0)) || die "Usage: index"
        index
        ;;
    build)
        shift
        build "$@"
        ;;
    build-all)
        shift
        build_all "$@"
        ;;
    *)
        printf 'Usage:\n' >&2
        printf '  %s keygen\n' "$0" >&2
        printf '  %s index\n' "$0" >&2
        printf '  %s build PACKAGE_NAME [PACKAGE_NAME ...]\n' "$0" >&2
        printf '  %s build-all [--exclude PACKAGE]... \n' "$0" >&2
        exit 2
        ;;
esac