#!/usr/bin/env bash
set -euo pipefail

unset TAR_OPTIONS
umask 077

UPDATE_ROOT=''
UPDATE_STAGE=''
UPDATE_LOCK=''
UPDATE_COMPLETE=0
UPDATE_CHANGED=('')
UPDATE_CREATED_DIRS=('')

update_error() {
    printf 'Update failed: %s\n' "$1" >&2
    return 1
}

update_cleanup() {
    local status=$? item failed=0 index
    trap - EXIT INT TERM HUP
    if [[ "$UPDATE_COMPLETE" != 1 && -n "$UPDATE_STAGE" ]]; then
        for ((index=${#UPDATE_CHANGED[@]}-1; index>=0; index--)); do
            item=${UPDATE_CHANGED[$index]}
            [[ -n "$item" ]] || continue
            if [[ -f "$UPDATE_STAGE/backup/$item" ]]; then
                if ! mv -f -- "$UPDATE_STAGE/backup/$item" "$UPDATE_ROOT/$item"; then failed=1; fi
            else
                if ! rm -f -- "$UPDATE_ROOT/$item"; then failed=1; fi
            fi
        done
        for ((index=${#UPDATE_CREATED_DIRS[@]}-1; index>=0; index--)); do
            item=${UPDATE_CREATED_DIRS[$index]}
            [[ -n "$item" ]] || continue
            rmdir -- "$UPDATE_ROOT/$item" 2>/dev/null || :
        done
    fi
    if [[ "$failed" == 1 ]]; then
        printf 'Rollback needs manual recovery from %s/backup.\n' "$UPDATE_STAGE" >&2
        status=1
    elif [[ -n "$UPDATE_STAGE" ]]; then
        rm -rf -- "$UPDATE_STAGE" || status=1
    fi
    if [[ -n "$UPDATE_LOCK" ]]; then rmdir -- "$UPDATE_LOCK" || status=1; fi
    exit "$status"
}

update_validate_archive() {
    local archive=$1 prefix=$2 name normalized entry first root_seen=0
    LC_ALL=C tar -tzf "$archive" > "$UPDATE_STAGE/paths" || return 1
    LC_ALL=C tar -tvzf "$archive" > "$UPDATE_STAGE/types" || return 1
    exec 3< "$UPDATE_STAGE/types"
    : > "$UPDATE_STAGE/normalized" || return 1
    while IFS= read -r name; do
        IFS= read -r entry <&3 || return 1
        first=${entry:0:1}
        [[ "$first" == '-' || "$first" == d ]] || return 1
        [[ "$name" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
        normalized=${name%/}
        case "$normalized" in
            /*|*//*|.|..|*/../*|../*|*/..|*/./*|./*|*/.) return 1 ;;
        esac
        case "$normalized" in "$prefix"|"$prefix/"*) ;; *) return 1 ;; esac
        if [[ "$normalized" == "$prefix" ]]; then
            [[ "$first" == d ]] || return 1
            root_seen=1
        fi
        printf '%s\n' "$normalized" >> "$UPDATE_STAGE/normalized" || return 1
    done < "$UPDATE_STAGE/paths"
    if IFS= read -r entry <&3 || [[ -n "$entry" ]]; then return 1; fi
    exec 3<&-
    [[ "$root_seen" == 1 ]] || return 1
    LC_ALL=C sort "$UPDATE_STAGE/normalized" | uniq -d > "$UPDATE_STAGE/duplicates" || return 1
    [[ ! -s "$UPDATE_STAGE/duplicates" ]]
}

update_destination_safe() {
    local item=$1 parent
    [[ ! -L "$UPDATE_ROOT/$item" ]] || return 1
    if [[ -e "$UPDATE_ROOT/$item" && ! -f "$UPDATE_ROOT/$item" ]]; then return 1; fi
    parent=$item
    while [[ "$parent" == */* ]]; do
        parent=${parent%/*}
        [[ ! -L "$UPDATE_ROOT/$parent" ]] || return 1
        if [[ -e "$UPDATE_ROOT/$parent" && ! -d "$UPDATE_ROOT/$parent" ]]; then return 1; fi
    done
}
update_create_parent() {
    local parent=$1 ancestor
    [[ -n "$parent" ]] || return 0
    if [[ "$parent" == */* ]]; then
        ancestor=${parent%/*}
        update_create_parent "$ancestor" || return 1
    fi
    [[ ! -L "$UPDATE_ROOT/$parent" ]] || return 1
    if [[ ! -e "$UPDATE_ROOT/$parent" ]]; then
        UPDATE_CREATED_DIRS+=("$parent")
        mkdir -- "$UPDATE_ROOT/$parent" || return 1
    fi
    [[ -d "$UPDATE_ROOT/$parent" ]]
}

update_main() {
    local tag=${1-} prefix item version script_dir
    local -a required optional manifest archive_members
    [[ "$#" == 1 && "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
        printf 'Usage: update.sh vMAJOR.MINOR.PATCH\n' >&2
        return 2
    }
    [[ ! -L "${BASH_SOURCE[0]}" && ! -L "$(dirname -- "${BASH_SOURCE[0]}")" ]] || return 1
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    UPDATE_ROOT=$(cd -- "$script_dir/.." && pwd -P) || return 1
    for item in curl tar mktemp sort uniq cp mv chmod mkdir rmdir rm cat grep dirname; do
        command -v "$item" >/dev/null 2>&1 || { update_error "missing dependency: $item"; return 1; }
    done
    if ! mkdir -- "$UPDATE_ROOT/.codexshell-update.lock" 2>/dev/null; then
        update_error 'another update is running or the installation is not writable'
        return 1
    fi
    UPDATE_LOCK=$UPDATE_ROOT/.codexshell-update.lock
    UPDATE_STAGE=$(mktemp -d "$UPDATE_ROOT/.codexshell-update.XXXXXXXX") || return 1
    prefix=codexshell-${tag#v}
    required=(install.sh start.sh VERSION scripts/lib-menu.sh scripts/lib-version.sh scripts/lib-update.sh scripts/update.sh
        scripts/lib-tools.sh scripts/lib-build.sh scripts/tools-catalog.tsv
        scripts/platform/macos/lib-xcode-bridge.sh scripts/platform/macos/xcode-bridge.py
        docker/Dockerfile docker/install-tools.sh docker/entrypoint.sh docker/codex-session.sh docker/firewall.sh docker/allowed-domains.txt
        docker/xcode-shims/xcodebuild docker/xcode-shims/xcrun docker/xcode-shims/simctl docker/xcode-shims/bridge-client.mjs)
    optional=(README.md CHANGELOG.md docs/tools.md)
    if ! curl --disable --silent --show-error --fail --connect-timeout 10 --max-time 60 \
        --retry 0 --proto '=https' --max-redirs 0 --max-filesize 20971520 \
        --output "$UPDATE_STAGE/release.tar.gz" \
        "https://codeload.github.com/boboshko/codexshell/tar.gz/refs/tags/$tag"; then
        update_error 'could not download the selected release'
        return 1
    fi
    if ! update_validate_archive "$UPDATE_STAGE/release.tar.gz" "$prefix"; then
        update_error 'unsafe or malformed release archive'
        return 1
    fi
    manifest=("${required[@]}")
    for item in "${optional[@]}"; do
        if LC_ALL=C grep -Fqx -- "$prefix/$item" "$UPDATE_STAGE/normalized"; then
            manifest+=("$item")
        fi
    done
    archive_members=('')
    for item in "${manifest[@]}"; do
        LC_ALL=C grep -Fqx -- "$prefix/$item" "$UPDATE_STAGE/normalized" || {
            update_error "release is missing $item"; return 1;
        }
        archive_members+=("$prefix/$item")
    done
    mkdir -- "$UPDATE_STAGE/unpack" "$UPDATE_STAGE/backup" || return 1
    if ! tar -xzf "$UPDATE_STAGE/release.tar.gz" -C "$UPDATE_STAGE/unpack" \
        --no-same-owner --no-same-permissions -- "${archive_members[@]:1}"; then
        update_error 'could not extract the release'
        return 1
    fi
    for item in "${manifest[@]}"; do
        [[ -f "$UPDATE_STAGE/unpack/$prefix/$item" && ! -L "$UPDATE_STAGE/unpack/$prefix/$item" ]] || {
            update_error "release requires a regular file: $item"; return 1;
        }
        update_destination_safe "$item" || { update_error "unsafe destination: $item"; return 1; }
    done
    version=$(cat -- "$UPDATE_STAGE/unpack/$prefix/VERSION") || return 1
    [[ "$version" == "$tag" ]] || { update_error 'release VERSION does not match the selected tag'; return 1; }
    for item in "${manifest[@]}"; do
        case "$item" in
            *.sh|docker/xcode-shims/xcodebuild|docker/xcode-shims/xcrun|docker/xcode-shims/simctl) chmod 755 -- "$UPDATE_STAGE/unpack/$prefix/$item" || return 1 ;;
            *) chmod 644 -- "$UPDATE_STAGE/unpack/$prefix/$item" || return 1 ;;
        esac
        if [[ -f "$UPDATE_ROOT/$item" ]]; then
            case "$item" in
                */*) mkdir -p -- "$UPDATE_STAGE/backup/${item%/*}" || return 1 ;;
            esac
            cp -p -- "$UPDATE_ROOT/$item" "$UPDATE_STAGE/backup/$item" || return 1
        fi
    done
    for item in "${manifest[@]}"; do
        if [[ "$item" == */* ]]; then update_create_parent "${item%/*}" || return 1; fi
    done
    for item in "${manifest[@]}"; do
        update_destination_safe "$item" || { update_error "destination changed: $item"; return 1; }
        UPDATE_CHANGED+=("$item")
        mv -f -- "$UPDATE_STAGE/unpack/$prefix/$item" "$UPDATE_ROOT/$item" || return 1
    done
    UPDATE_COMPLETE=1
    printf 'Installed CodexShell %s.\n' "$tag"
}

trap update_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
update_main "$@"
