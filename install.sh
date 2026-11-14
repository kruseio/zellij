#!/bin/sh
# Install a prebuilt zellij (no-web build) from the kruseio/zellij GitHub releases.
#
#   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/kruseio/zellij/HEAD/install.sh | sh
#
# Pass options after `sh -s --`, for example:
#
#   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/kruseio/zellij/HEAD/install.sh \
#     | sh -s -- --version v0.44.4 --bin-dir "$HOME/.local/bin"
#
# Supports Linux x86_64, macOS x86_64/aarch64, and Windows x86_64 from Git Bash,
# MSYS2 or Cygwin. In native PowerShell use install.ps1 instead.
#
# Everything runs from main() at the bottom, so a partially downloaded script
# never executes.

set -eu

REPO="${ZELLIJ_REPO:-kruseio/zellij}"

usage() {
    cat <<EOF
Install a prebuilt zellij (no-web build) from https://github.com/${REPO}/releases

USAGE:
    install.sh [OPTIONS]

OPTIONS:
    -v, --version <TAG>    Release to install, e.g. v0.44.4 [default: latest]
    -b, --bin-dir <DIR>    Install directory [default: the directory of the zellij
                           already on your PATH, so it is upgraded/downgraded in
                           place; otherwise /usr/local/bin, or \$HOME/.local/bin
                           on Windows]
    -h, --help             Print this help

ENVIRONMENT:
    ZELLIJ_VERSION         Same as --version
    ZELLIJ_INSTALL_DIR     Same as --bin-dir
    ZELLIJ_REPO            GitHub owner/repo to download from [default: kruseio/zellij]
EOF
}

say() { printf 'zellij-install: %s\n' "$1"; }
warn() { printf 'zellij-install: warning: %s\n' "$1" >&2; }
err() {
    printf 'zellij-install: error: %s\n' "$1" >&2
    exit 1
}
has() { command -v "$1" >/dev/null 2>&1; }
need() { has "$1" || err "need '$1' (command not found)"; }

# Prints the package manager that owns an existing zellij at <path>, if any.
package_owner() { # <path>
    _real=$1
    if [ -L "$1" ] && has readlink; then
        _real=$(readlink "$1")
    fi
    case "${1}:${_real}" in
        */nix/store/* | */.nix-profile/*) echo "Nix" ;;
        */Cellar/*) echo "Homebrew (brew uninstall zellij)" ;;
        *:/usr/bin/snap) echo "Snap (sudo snap remove zellij)" ;;
        */.cargo/bin/*) echo "cargo (cargo uninstall zellij)" ;;
        *)
            if has dpkg && dpkg -S "$1" >/dev/null 2>&1; then
                echo "apt/dpkg (sudo apt remove zellij)"
            elif has rpm && rpm -qf "$1" >/dev/null 2>&1; then
                echo "rpm (remove the zellij package)"
            elif has pacman && pacman -Qo "$1" >/dev/null 2>&1; then
                echo "pacman (sudo pacman -R zellij)"
            fi
            ;;
    esac
}

# Sets: os (linux|macos|windows), target (Rust target triple).
detect_platform() {
    _uname_s=$(uname -s)
    _arch=$(uname -m)

    case "$_uname_s" in
        Linux) os=linux ;;
        Darwin)
            os=macos
            # Under Rosetta 2 uname reports x86_64 on Apple Silicon; prefer the native build.
            if [ "$_arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
                _arch=arm64
            fi
            ;;
        MINGW* | MSYS* | CYGWIN* | Windows_NT) os=windows ;;
        *) err "unsupported operating system: $_uname_s" ;;
    esac

    case "$_arch" in
        x86_64 | amd64) _arch=x86_64 ;;
        aarch64 | arm64) _arch=aarch64 ;;
        *) _arch=unsupported ;;
    esac

    # Published builds: Linux and Windows x86_64 only; macOS x86_64 and aarch64.
    case "${os}-${_arch}" in
        linux-x86_64) target="x86_64-unknown-linux-musl" ;;
        windows-x86_64) target="x86_64-pc-windows-msvc" ;;
        macos-x86_64 | macos-aarch64) target="${_arch}-apple-darwin" ;;
        macos-*) err "unsupported architecture: $(uname -m) (macOS builds exist for x86_64 and aarch64)" ;;
        *) err "unsupported architecture: $(uname -m) (${os} builds exist for x86_64 only)" ;;
    esac
}

download() { # <url> <dest>
    if has curl; then
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"
    elif has wget; then
        if wget --help 2>&1 | grep -q -- '--https-only'; then
            wget --https-only --secure-protocol=TLSv1_2 -q -O "$2" "$1"
        else
            wget -q -O "$2" "$1" # BusyBox wget
        fi
    else
        err "need 'curl' or 'wget' (command not found)"
    fi
}

sha256_of() { # <file>
    if has sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif has shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        err "need 'sha256sum' or 'shasum' to verify the download"
    fi
}

extract() { # <archive> <dest-dir>
    case "$1" in
        *.tar.gz) tar -xzf "$1" -C "$2" ;;
        *.zip)
            if has unzip; then
                unzip -q -o "$1" -d "$2"
            elif has powershell.exe && has cygpath; then
                powershell.exe -NoProfile -NonInteractive -Command \
                    "Expand-Archive -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")' -Force"
            else
                err "need 'unzip' to extract $1"
            fi
            ;;
    esac
}

main() {
    version="${ZELLIJ_VERSION:-latest}"
    bin_dir="${ZELLIJ_INSTALL_DIR:-}"

    while [ $# -gt 0 ]; do
        case "$1" in
            -v | --version)
                [ $# -ge 2 ] || err "$1 needs a value"
                version="$2"
                shift 2
                ;;
            --version=*)
                version="${1#*=}"
                shift
                ;;
            -b | --bin-dir)
                [ $# -ge 2 ] || err "$1 needs a value"
                bin_dir="$2"
                shift 2
                ;;
            --bin-dir=*)
                bin_dir="${1#*=}"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) err "unknown option: $1 (see --help)" ;;
        esac
    done

    need uname
    need awk
    need mktemp
    need install

    detect_platform

    # Without an explicit --bin-dir, replace the zellij already on PATH (whether an
    # official build or this fork), so the selected version is the one that runs.
    existing=$(command -v zellij 2>/dev/null || true)
    case "$existing" in
        /*) [ -n "$bin_dir" ] || bin_dir=$(dirname "$existing") ;;
    esac

    if [ "$os" = windows ]; then
        asset="zellij-no-web-${target}.zip"
        exe="zellij.exe"
        : "${bin_dir:=$HOME/.local/bin}"
    else
        need tar
        asset="zellij-no-web-${target}.tar.gz"
        exe="zellij"
        : "${bin_dir:=/usr/local/bin}"
    fi
    checksum="zellij-no-web-${target}.sha256sum"
    [ "$bin_dir" = / ] || bin_dir="${bin_dir%/}"
    dest="${bin_dir}/${exe}"

    current=""
    owner=""
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        current=$("$dest" --version 2>/dev/null || true)
        : "${current:=zellij (unknown version)}"
        owner=$(package_owner "$dest")
        case "$owner" in
            Nix*) err "${dest} is managed by Nix and cannot be replaced; remove it from your Nix profile or pass --bin-dir" ;;
        esac
    fi

    case "$version" in
        latest) base="https://github.com/${REPO}/releases/latest/download" ;;
        v*) base="https://github.com/${REPO}/releases/download/${version}" ;;
        *)
            version="v${version}"
            base="https://github.com/${REPO}/releases/download/${version}"
            ;;
    esac

    tmp=$(mktemp -d 2>/dev/null || mktemp -d -t zellij-install)
    trap 'rm -rf "$tmp"' EXIT
    trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

    say "downloading ${asset} (${version}) from github.com/${REPO}"
    download "${base}/${asset}" "${tmp}/${asset}" ||
        err "download failed: ${base}/${asset} (does release '${version}' exist and include this asset?)"
    download "${base}/${checksum}" "${tmp}/${checksum}" ||
        err "download failed: ${base}/${checksum}"

    mkdir "${tmp}/extract"
    extract "${tmp}/${asset}" "${tmp}/extract"
    [ -f "${tmp}/extract/${exe}" ] || err "${asset} does not contain ${exe}"

    # The published checksum covers the binary itself, not the archive.
    expected=$(awk 'NR == 1 {print tolower($1)}' "${tmp}/${checksum}")
    case "$expected" in
        *[!0-9a-f]* | "") err "malformed checksum file ${checksum}" ;;
    esac
    [ ${#expected} -eq 64 ] || err "malformed checksum file ${checksum}"
    actual=$(sha256_of "${tmp}/extract/${exe}")
    [ "$actual" = "$expected" ] ||
        err "checksum mismatch for ${exe}: expected ${expected}, got ${actual}"
    say "verified sha256 ${actual}"

    sudo=""
    if mkdir -p "$bin_dir" 2>/dev/null && [ -w "$bin_dir" ]; then
        :
    elif [ "$os" != windows ] && [ "$(id -u)" -ne 0 ] && has sudo; then
        say "${bin_dir} is not writable, using sudo"
        sudo="sudo"
        $sudo mkdir -p "$bin_dir"
    else
        err "cannot write to ${bin_dir}; rerun with --bin-dir \"\$HOME/.local/bin\""
    fi

    if [ -n "$current" ]; then
        if [ -L "$dest" ]; then
            say "replacing ${current} at ${dest} (a symlink to $(readlink "$dest" 2>/dev/null || echo '?'))"
        else
            say "replacing ${current} at ${dest}"
        fi
    fi

    # install(1) replaces the file (or symlink) rather than writing into it, so
    # running zellij sessions keep working.
    $sudo rm -f "${dest}.zellij-install-old"
    if [ -L "$dest" ]; then
        # Replace the link itself, never the file it points to.
        $sudo mv -f "$dest" "${dest}.zellij-install-old"
    fi
    if ! $sudo install -m 0755 "${tmp}/extract/${exe}" "$dest"; then
        if [ -L "${dest}.zellij-install-old" ]; then
            $sudo mv -f "${dest}.zellij-install-old" "$dest"
        fi
        err "failed to install ${dest}"
    fi
    $sudo rm -f "${dest}.zellij-install-old"

    installed=$("$dest" --version 2>/dev/null || true)
    if [ -n "$current" ]; then
        say "replaced ${current} with ${installed:-zellij} at ${dest}"
    else
        say "installed ${installed:-zellij} to ${dest}"
    fi
    if [ -n "$owner" ]; then
        warn "the zellij you replaced came from ${owner}; that package manager may put its own version back when it upgrades. To switch for good, uninstall it there and rerun this script."
    fi

    case ":${PATH}:" in
        *":${bin_dir}:"*)
            found=$(command -v zellij 2>/dev/null || true)
            if [ -n "$found" ] && [ "$found" != "${bin_dir}/zellij" ] && [ "$found" != "${bin_dir}/zellij.exe" ]; then
                warn "'zellij' on your PATH resolves to ${found}, which takes precedence over ${dest}"
            fi
            ;;
        *)
            warn "${bin_dir} is not on your PATH; add it with: export PATH=\"${bin_dir}:\$PATH\""
            ;;
    esac
}

main "$@"
