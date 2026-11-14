#!/bin/sh
# Build and publish zellij release artifacts (no-web builds only) without GitHub Actions.
#
# Artifacts use the upstream release workflow's names, which install.sh and
# install.ps1 download:
#   zellij-no-web-<target>.tar.gz   (.zip on Windows) archive holding the zellij binary
#   zellij-no-web-<target>.sha256sum  "<sha256>  zellij" for the binary inside it
#
# Release flow, e.g. for v0.44.4. Each `build` runs in a checkout whose HEAD is the tag;
# artifacts land in target/release-assets/<tag>/.
#   1. Linux x86_64 host with Docker and cargo-xwin:
#        ./release.sh build v0.44.4     # Linux musl x86_64, Windows x86_64
#   2. macOS host:
#        ./release.sh build v0.44.4     # macOS aarch64 + x86_64
#   3. Copy the Linux host's target/release-assets/v0.44.4/* into the same directory
#      on the macOS host, then from there:
#        ./release.sh publish v0.44.4

set -eu

REPO="${ZELLIJ_REPO:-kruseio/zellij}"
ALL_TARGETS="x86_64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin x86_64-pc-windows-msvc"

usage() {
    cat <<EOF
Build and publish zellij no-web release artifacts for https://github.com/${REPO}

USAGE:
    release.sh build <TAG> [TARGET...]
        Build and package TARGETs into target/release-assets/<TAG>/.
        HEAD must be the tagged commit with no uncommitted changes to tracked files.
        Builds always use ./target, ignoring CARGO_TARGET_DIR, and rewrite the bundled
        plugins in zellij-utils/assets/plugins, so prefer a dedicated worktree:
            git worktree add ../zellij-<TAG> <TAG>
        Default targets: on Linux x86_64-unknown-linux-musl x86_64-pc-windows-msvc;
        on macOS aarch64-apple-darwin x86_64-apple-darwin.

    release.sh publish <TAG> [--draft]
        Verify that target/release-assets/<TAG>/ holds checksummed artifacts for every
        target, create the GitHub release if needed, upload them (replacing existing
        assets of the same name), and publish it unless --draft is given.

TARGETS:
    ${ALL_TARGETS}

ENVIRONMENT:
    ZELLIJ_REPO    GitHub owner/repo to publish to [default: kruseio/zellij]
EOF
}

say() { printf 'release: %s\n' "$1"; }
err() {
    printf 'release: error: %s\n' "$1" >&2
    exit 1
}
has() { command -v "$1" >/dev/null 2>&1; }
need() { has "$1" || err "need '$1' (command not found)"; }

archive_name() {
    case "$1" in
        *-windows-*) printf 'zellij-no-web-%s.zip' "$1" ;;
        *) printf 'zellij-no-web-%s.tar.gz' "$1" ;;
    esac
}
checksum_name() { printf 'zellij-no-web-%s.sha256sum' "$1"; }
exe_name() {
    case "$1" in
        *-windows-*) printf 'zellij.exe' ;;
        *) printf 'zellij' ;;
    esac
}

sha256_of() {
    if has sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif has shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        err "need 'sha256sum' or 'shasum'"
    fi
}

# cd to the repository root and set: root, version, assets.
enter_repo() { # <tag>
    need git
    root=$(git rev-parse --show-toplevel) || err "not inside a git checkout"
    cd "$root"
    case "$1" in
        v[0-9]*) ;;
        *) err "tag must look like v1.2.3, got '$1'" ;;
    esac
    version=$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -n 1)
    assets="${root}/target/release-assets/$1"
}

check_checkout() { # <tag>
    tag_commit=$(git rev-parse -q --verify "refs/tags/$1^{commit}") ||
        err "tag $1 not found (git fetch --tags?)"
    [ "$(git rev-parse HEAD)" = "$tag_commit" ] ||
        err "HEAD is not at $1; build from a checkout of the tag, e.g. git worktree add ../zellij-$1 $1"
    # The build itself rewrites the bundled plugins in zellij-utils/assets/plugins, so
    # those are allowed to differ (e.g. when building several targets in a row).
    [ -z "$(git status --porcelain --untracked-files=no -- . ':(exclude)zellij-utils/assets/plugins')" ] ||
        err "tracked files have uncommitted changes; release builds must match the tag exactly"
    [ "v${version}" = "$1" ] || err "Cargo.toml version ${version} does not match tag $1"
}

# Comma-separated default features of the zellij crate, minus web_server_capability.
no_web_features() {
    _defaults=$(sed -n 's/^default *= *\[\(.*\)\]/\1/p' Cargo.toml | head -n 1 | tr -d '" ' | tr ',' ' ')
    case " ${_defaults} " in
        *" web_server_capability "*) ;;
        *) err "could not find web_server_capability in the default features in Cargo.toml" ;;
    esac
    _features=""
    for _f in $_defaults; do
        [ "$_f" = web_server_capability ] || _features="${_features:+${_features},}${_f}"
    done
    printf '%s' "$_features"
}

build_target() { # <target>
    say "building $1"
    rustup target add "$1"
    case "$1" in
        *-pc-windows-msvc)
            has cargo-xwin || err "need cargo-xwin to build $1 (cargo install --locked cargo-xwin)"
            # C dependencies need llvm-lib, which Debian/Ubuntu only ship in a versioned dir
            # unless the unversioned `llvm` package is installed.
            if ! has llvm-lib; then
                for _d in $(printf '%s\n' /usr/lib/llvm-*/bin | sort -t- -k2,2nr); do
                    if [ -x "${_d}/llvm-lib" ]; then
                        PATH="${_d}:${PATH}"
                        export PATH
                        break
                    fi
                done
            fi
            has llvm-lib || err "need llvm-lib to build $1 (install LLVM, e.g. apt install llvm)"
            _features=$(no_web_features)
            cargo xtask build --release --plugins-only --no-web
            # Static CRT, as in the upstream workflow, so zellij.exe needs no VC++ runtime.
            RUSTFLAGS="-C target-feature=+crt-static" \
                cargo xwin build --release --target "$1" --no-default-features --features "$_features"
            ;;
        *)
            # Same entry point as the upstream release workflow: builds the plugins, then
            # the binary with `cross` (Docker for Linux targets, plain cargo for macOS).
            cargo xtask ci cross "$1" --no-web
            ;;
    esac
}

package_target() { # <target>
    _exe=$(exe_name "$1")
    _bin="${root}/target/$1/release/${_exe}"
    [ -f "$_bin" ] || err "build did not produce ${_bin}"
    _archive="${assets}/$(archive_name "$1")"
    _stage=$(mktemp -d)
    cp "$_bin" "${_stage}/${_exe}"
    chmod 0755 "${_stage}/${_exe}"
    rm -f "$_archive"
    case "$_archive" in
        *.zip)
            if has zip; then
                (cd "$_stage" && zip -q -X "$_archive" "$_exe")
            else
                python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], sys.argv[3])' "$_archive" "${_stage}/${_exe}" "$_exe"
            fi
            ;;
        *) COPYFILE_DISABLE=1 tar --no-xattrs -czf "$_archive" -C "$_stage" "$_exe" ;;
    esac
    printf '%s  %s\n' "$(sha256_of "${_stage}/${_exe}")" "$_exe" >"${assets}/$(checksum_name "$1")"
    rm -rf "$_stage"
    say "packaged $(basename "$_archive")"
}

# Re-extract the archive and check its binary against the checksum file.
verify_target() { # <target>
    _archive="${assets}/$(archive_name "$1")"
    _sum="${assets}/$(checksum_name "$1")"
    _exe=$(exe_name "$1")
    _tmp=$(mktemp -d)
    case "$_archive" in
        *.zip) unzip -q "$_archive" -d "$_tmp" ;;
        *) tar -xzf "$_archive" -C "$_tmp" ;;
    esac
    [ -f "${_tmp}/${_exe}" ] || err "$(basename "$_archive") does not contain ${_exe}"
    _expected=$(awk 'NR == 1 {print $1}' "$_sum")
    _actual=$(sha256_of "${_tmp}/${_exe}")
    rm -rf "$_tmp"
    [ "$_expected" = "$_actual" ] || err "checksum mismatch for $(basename "$_archive")"
}

cmd_build() {
    [ $# -ge 1 ] || err "usage: release.sh build <TAG> [TARGET...]"
    tag=$1
    shift
    enter_repo "$tag"
    check_checkout "$tag"
    need cargo
    need rustup
    # Always build into this checkout's own target dir (even if CARGO_TARGET_DIR points at a
    # shared cache), so the packaged binaries can only come from this checkout.
    CARGO_TARGET_DIR="${root}/target"
    export CARGO_TARGET_DIR

    if [ $# -eq 0 ]; then
        case "$(uname -s)" in
            Linux) set -- x86_64-unknown-linux-musl x86_64-pc-windows-msvc ;;
            Darwin) set -- aarch64-apple-darwin x86_64-apple-darwin ;;
            *) err "no default targets for $(uname -s); pass them explicitly" ;;
        esac
    fi
    for t in "$@"; do
        case " ${ALL_TARGETS} " in
            *" $t "*) ;;
            *) err "unknown target: $t" ;;
        esac
    done

    mkdir -p "$assets"
    for t in "$@"; do
        build_target "$t"
        package_target "$t"
        verify_target "$t"
    done
    say "artifacts for ${tag} in ${assets}:"
    ls -l "$assets"
}

cmd_publish() {
    [ $# -ge 1 ] || err "usage: release.sh publish <TAG> [--draft]"
    tag=$1
    shift
    draft=0
    for a in "$@"; do
        case "$a" in
            --draft) draft=1 ;;
            *) err "unknown option: $a" ;;
        esac
    done
    enter_repo "$tag"
    need gh

    missing=""
    set --
    for t in $ALL_TARGETS; do
        if [ -f "${assets}/$(archive_name "$t")" ] && [ -f "${assets}/$(checksum_name "$t")" ]; then
            verify_target "$t"
            set -- "$@" "${assets}/$(archive_name "$t")" "${assets}/$(checksum_name "$t")"
        else
            missing="${missing} $t"
        fi
    done
    [ -z "$missing" ] || err "missing artifacts in ${assets} for:${missing}"
    say "verified $(($# / 2)) artifacts in ${assets}"

    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        say "release ${tag} already exists on ${REPO}; replacing its assets"
    else
        notes=$(mktemp)
        awk -v v="${tag#v}" '
            index($0, "## [" v "]") == 1 { on = 1; next }
            on && /^## \[/ { exit }
            on { print }
        ' CHANGELOG.md >"$notes"
        [ -s "$notes" ] || printf 'Release %s\n' "$tag" >"$notes"
        # Create as a draft so the release only becomes visible once every asset is uploaded.
        gh release create "$tag" --repo "$REPO" --verify-tag --draft \
            --title "Release ${tag}" --notes-file "$notes"
        rm -f "$notes"
    fi

    gh release upload "$tag" --repo "$REPO" --clobber "$@"

    if [ "$draft" = 1 ]; then
        say "uploaded to draft release ${tag}; publish it with: gh release edit ${tag} --repo ${REPO} --draft=false"
    else
        gh release edit "$tag" --repo "$REPO" --draft=false >/dev/null
        say "published https://github.com/${REPO}/releases/tag/${tag}"
    fi
}

main() {
    [ $# -ge 1 ] || {
        usage
        exit 1
    }
    cmd=$1
    shift
    case "$cmd" in
        build) cmd_build "$@" ;;
        publish) cmd_publish "$@" ;;
        -h | --help | help) usage ;;
        *) err "unknown command: $cmd (see --help)" ;;
    esac
}

main "$@"
