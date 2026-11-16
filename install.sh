#!/usr/bin/env bash
set -euo pipefail

unset TAR_OPTIONS
umask 077

REPOSITORY='boboshko/codexshell'
FALLBACK_BRANCH='master'
INSTALL_TMP=''
INSTALL_TARGET=''
INSTALL_CANDIDATE=''
INSTALL_FILE_TEMP=''
INSTALL_LOCK=''
INSTALL_MODE=''
INSTALL_COMPLETE=0
INSTALL_CHANGED=('')
INSTALL_CREATED_DIRS=('')

install_error() {
    printf 'Installation failed: %s\n' "$1" >&2
    return 1
}

install_cleanup() {
    local status=$? item index failed=0
    trap - EXIT INT TERM HUP
    if [[ "$INSTALL_COMPLETE" != 1 && "$INSTALL_MODE" == overlay && -n "$INSTALL_TMP" ]]; then
        for ((index=${#INSTALL_CHANGED[@]}-1; index>=0; index--)); do
            item=${INSTALL_CHANGED[$index]}
            [[ -n "$item" ]] || continue
            if [[ -f "$INSTALL_TMP/backup/$item" ]]; then
                install_copy_replace "$INSTALL_TMP/backup/$item" "$INSTALL_TARGET/$item" || failed=1
            else
                rm -f -- "$INSTALL_TARGET/$item" || failed=1
            fi
        done
        for ((index=${#INSTALL_CREATED_DIRS[@]}-1; index>=0; index--)); do
            item=${INSTALL_CREATED_DIRS[$index]}
            [[ -n "$item" ]] || continue
            rmdir -- "$INSTALL_TARGET/$item" 2>/dev/null || :
        done
    fi
    if [[ -n "$INSTALL_FILE_TEMP" && -f "$INSTALL_FILE_TEMP" ]]; then
        rm -f -- "$INSTALL_FILE_TEMP" || failed=1
    fi
    if [[ -n "$INSTALL_CANDIDATE" && -d "$INSTALL_CANDIDATE" ]]; then
        rm -rf -- "$INSTALL_CANDIDATE" || failed=1
    fi
    if [[ -n "$INSTALL_LOCK" && -d "$INSTALL_LOCK" ]]; then
        rmdir -- "$INSTALL_LOCK" 2>/dev/null || failed=1
    fi
    if [[ "$failed" == 0 && -n "$INSTALL_TMP" && -d "$INSTALL_TMP" ]]; then
        rm -rf -- "$INSTALL_TMP" || failed=1
    fi
    if [[ "$failed" == 1 ]]; then
        printf 'Installation cleanup or rollback needs manual attention: %s\n' "$INSTALL_TMP" >&2
        status=1
    fi
    exit "$status"
}

install_download() {
    local url=$1 destination=$2 limit=$3 size
    if [[ "$INSTALL_CLIENT" == curl ]]; then
        curl --disable --silent --show-error --fail --connect-timeout 10 \
            --max-time 60 --retry 0 --proto '=https' --max-redirs 0 \
            --max-filesize "$limit" --output "$destination" "$url"
    else
        wget --no-config --quiet --https-only --max-redirect=0 --timeout=10 \
            --tries=1 --output-document="$destination" "$url"
    fi || return 1
    size=$(wc -c < "$destination" | tr -d '[:space:]') || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -le "$limit" ]]
}

install_required_files() {
    printf '%s\n' \
        install.sh start.sh VERSION \
        scripts/lib-menu.sh scripts/lib-version.sh scripts/lib-update.sh scripts/update.sh \
        scripts/lib-tools.sh scripts/lib-build.sh scripts/tools-catalog.tsv \
        scripts/platform/macos/lib-xcode-bridge.sh scripts/platform/macos/xcode-bridge.py \
        docker/Dockerfile docker/install-tools.sh docker/entrypoint.sh docker/codex-session.sh \
        docker/firewall.sh docker/allowed-domains.txt \
        docker/xcode-shims/xcodebuild docker/xcode-shims/xcrun docker/xcode-shims/simctl \
        docker/xcode-shims/bridge-client.mjs
}

install_protected_path() {
    case "$1" in
        config|config/*|.git|.git/*|.codex|.codex/*|.agents|.agents/*|.pipeline|.pipeline/*|dist|dist/*|.codexshell-install.*|.codexshell-update.*) return 0 ;;
        *) return 1 ;;
    esac
}

install_path_has_symlink() {
    local input=$1 current='/' rest component
    if [[ "$input" == /* ]]; then rest=${input#/}; else rest=${PWD#/}/$input; fi
    while [[ -n "$rest" ]]; do
        component=${rest%%/*}
        if [[ "$rest" == */* ]]; then rest=${rest#*/}; else rest=''; fi
        case "$component" in
            ''|.) continue ;;
            ..)
                current=${current%/*}
                [[ -n "$current" ]] || current='/'
                ;;
            *)
                if [[ "$current" == / ]]; then current=/$component; else current=$current/$component; fi
                [[ ! -L "$current" ]] || return 0
                ;;
        esac
    done
    return 1
}

install_validate_archive() {
    local archive=$1 prefix=$2 name normalized entry first relative root_seen=0
    tar -tzf "$archive" > "$INSTALL_TMP/paths" || return 1
    tar -tvzf "$archive" > "$INSTALL_TMP/types" || return 1
    : > "$INSTALL_TMP/normalized"
    : > "$INSTALL_TMP/files"
    : > "$INSTALL_TMP/dirs"
    exec 3< "$INSTALL_TMP/types"
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
        printf '%s\n' "$normalized" >> "$INSTALL_TMP/normalized"
        if [[ "$normalized" == "$prefix" ]]; then
            [[ "$first" == d ]] || return 1
            root_seen=1
            continue
        fi
        relative=${normalized#"$prefix/"}
        install_protected_path "$relative" && return 1
        if [[ "$first" == d ]]; then
            printf '%s\n' "$relative" >> "$INSTALL_TMP/dirs"
        else
            printf '%s\n' "$relative" >> "$INSTALL_TMP/files"
        fi
    done < "$INSTALL_TMP/paths"
    if IFS= read -r entry <&3 || [[ -n "$entry" ]]; then return 1; fi
    exec 3<&-
    [[ "$root_seen" == 1 ]] || return 1
    LC_ALL=C sort "$INSTALL_TMP/normalized" | uniq -d > "$INSTALL_TMP/duplicates" || return 1
    [[ ! -s "$INSTALL_TMP/duplicates" ]] || return 1
    while IFS= read -r relative; do
        grep -Fqx -- "$relative" "$INSTALL_TMP/files" || return 1
    done < <(install_required_files)
}

install_prepare_source() {
    local prefix=$1 item source
    source=$INSTALL_TMP/unpack/$prefix
    mkdir -- "$INSTALL_TMP/unpack" "$INSTALL_TMP/backup" || return 1
    tar -xzf "$INSTALL_TMP/source.tar.gz" -C "$INSTALL_TMP/unpack" || return 1
    [[ -d "$source" && ! -L "$source" ]] || return 1
    chmod 755 -- "$source" || return 1
    while IFS= read -r item; do
        [[ -d "$source/$item" && ! -L "$source/$item" ]] || return 1
        chmod 755 -- "$source/$item" || return 1
    done < "$INSTALL_TMP/dirs"
    while IFS= read -r item; do
        [[ -f "$source/$item" && ! -L "$source/$item" ]] || return 1
        chmod 644 -- "$source/$item" || return 1
    done < "$INSTALL_TMP/files"
    for item in install.sh start.sh scripts/update.sh docker/install-tools.sh \
        docker/entrypoint.sh docker/codex-session.sh docker/firewall.sh \
        docker/xcode-shims/xcodebuild docker/xcode-shims/xcrun docker/xcode-shims/simctl \
        tests/test.sh tests/test-auth.sh; do
        [[ ! -f "$source/$item" ]] || chmod 755 -- "$source/$item" || return 1
    done
}

install_destination_safe() {
    local relative=$1 current=$INSTALL_TARGET rest component
    [[ ! -L "$INSTALL_TARGET/$relative" ]] || return 1
    if [[ -e "$INSTALL_TARGET/$relative" && ! -f "$INSTALL_TARGET/$relative" ]]; then return 1; fi
    rest=${relative%/*}
    [[ "$rest" != "$relative" ]] || return 0
    while [[ -n "$rest" ]]; do
        component=${rest%%/*}
        if [[ "$rest" == */* ]]; then rest=${rest#*/}; else rest=''; fi
        current=$current/$component
        [[ ! -L "$current" && -d "$current" ]] || return 1
    done
}

install_copy_replace() {
    local source=$1 destination=$2 parent
    parent=${destination%/*}
    INSTALL_FILE_TEMP=$(mktemp "$parent/.codexshell-file.XXXXXXXX") || return 1
    if ! cp -p -- "$source" "$INSTALL_FILE_TEMP"; then
        rm -f -- "$INSTALL_FILE_TEMP" || :
        INSTALL_FILE_TEMP=''
        return 1
    fi
    if ! mv -f -- "$INSTALL_FILE_TEMP" "$destination"; then
        rm -f -- "$INSTALL_FILE_TEMP" || :
        INSTALL_FILE_TEMP=''
        return 1
    fi
    INSTALL_FILE_TEMP=''
}

install_fresh() {
    local source=$1 parent=$2 lock candidate_name
    INSTALL_MODE=fresh
    lock=$parent/.codexshell-install.lock
    mkdir -- "$lock" || { install_error 'another installation is running'; return 1; }
    INSTALL_LOCK=$lock
    INSTALL_CANDIDATE=$(mktemp -d "$parent/.codexshell-install.XXXXXXXX")
    cp -Rp -- "$source"/. "$INSTALL_CANDIDATE"/
    chmod 755 -- "$INSTALL_CANDIDATE"
    printf '%s\n' "$$" > "$INSTALL_CANDIDATE/.codexshell-install-owner"
    candidate_name=${INSTALL_CANDIDATE##*/}
    [[ ! -e "$INSTALL_TARGET" && ! -L "$INSTALL_TARGET" ]] || return 1
    mv -- "$INSTALL_CANDIDATE" "$INSTALL_TARGET"
    if [[ ! -f "$INSTALL_TARGET/.codexshell-install-owner" ]]; then
        if [[ -d "$INSTALL_TARGET/$candidate_name" ]]; then
            INSTALL_CANDIDATE=$INSTALL_TARGET/$candidate_name
        else
            INSTALL_CANDIDATE=''
        fi
        install_error 'destination changed during installation'
        return 1
    fi
    rm -f -- "$INSTALL_TARGET/.codexshell-install-owner"
    INSTALL_CANDIDATE=''
}

install_overlay() {
    local source=$1 item parent lock
    INSTALL_MODE=overlay
    lock=$INSTALL_TARGET/.codexshell-install.lock
    mkdir -- "$lock" || { install_error 'another installation is running'; return 1; }
    INSTALL_LOCK=$lock
    LC_ALL=C sort "$INSTALL_TMP/dirs" > "$INSTALL_TMP/dirs.sorted"
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        [[ ! -L "$INSTALL_TARGET/$item" ]] || return 1
        if [[ ! -e "$INSTALL_TARGET/$item" ]]; then
            mkdir -- "$INSTALL_TARGET/$item"
            chmod 755 -- "$INSTALL_TARGET/$item"
            INSTALL_CREATED_DIRS+=("$item")
        fi
        [[ -d "$INSTALL_TARGET/$item" ]] || return 1
    done < "$INSTALL_TMP/dirs.sorted"
    LC_ALL=C sort "$INSTALL_TMP/files" > "$INSTALL_TMP/files.sorted"
    while IFS= read -r item; do
        install_destination_safe "$item" || { install_error "unsafe destination: $item"; return 1; }
        if [[ -f "$INSTALL_TARGET/$item" ]]; then
            case "$item" in */*) mkdir -p -- "$INSTALL_TMP/backup/${item%/*}" ;; esac
            cp -p -- "$INSTALL_TARGET/$item" "$INSTALL_TMP/backup/$item"
        fi
        INSTALL_CHANGED+=("$item")
        install_copy_replace "$source/$item" "$INSTALL_TARGET/$item"
    done < "$INSTALL_TMP/files.sorted"
}

install_target_nonempty() {
    local item
    for item in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [[ -e "$item" || -L "$item" ]] && return 0
    done
    return 1
}

install_main() {
    local target_input parent base source_kind latest_tag='' prefix source confirm item target_state
    [[ "$#" -le 1 ]] || { printf 'Usage: install.sh [destination]\n' >&2; return 2; }
    target_input=${1:-./codexshell}
    [[ -n "$target_input" && "$target_input" != / && "$target_input" != *$'\n'* && "$target_input" != *$'\r'* ]] || {
        install_error 'invalid destination'; return 1;
    }
    while [[ "$target_input" == */ && "$target_input" != / ]]; do target_input=${target_input%/}; done
    base=$(basename -- "$target_input")
    parent=$(dirname -- "$target_input")
    [[ "$base" != . && "$base" != .. ]] || { install_error 'invalid destination'; return 1; }
    if install_path_has_symlink "$parent"; then install_error 'destination ancestors cannot be symbolic links'; return 1; fi
    if [[ -L "$target_input" ]]; then install_error 'destination cannot be a symbolic link'; return 1; fi
    if [[ -e "$target_input" && ! -d "$target_input" ]]; then install_error 'destination is not a directory'; return 1; fi
    printf 'Installing CodexShell into: %s\n' "$target_input"
    if [[ -d "$target_input" ]]; then
        if install_target_nonempty "$target_input"; then
            target_state=overlay
            IFS= read -r -p 'Install/update on top of it? (y/N) ' confirm || confirm=''
            case "$confirm" in y|Y) ;; *) printf 'Cancelled.\n'; return 1 ;; esac
        else
            target_state=empty
        fi
    else
        target_state=absent
    fi
    for item in tar mktemp mkdir rmdir rm cp mv chmod dirname basename grep sed sort uniq wc tr cat; do
        command -v "$item" >/dev/null 2>&1 || { install_error "missing dependency: $item"; return 1; }
    done
    if command -v curl >/dev/null 2>&1; then INSTALL_CLIENT=curl
    elif command -v wget >/dev/null 2>&1; then INSTALL_CLIENT=wget
    else install_error 'curl or wget is required'; return 1
    fi
    INSTALL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/codexshell-install.XXXXXXXX")
    printf 'Looking up the latest release...\n'
    if install_download "https://api.github.com/repos/$REPOSITORY/releases/latest" "$INSTALL_TMP/release.json" 1048576; then
        latest_tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INSTALL_TMP/release.json")
        [[ "$latest_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || latest_tag=''
    fi
    if [[ -n "$latest_tag" ]]; then
        printf 'Latest release: %s. Downloading...\n' "$latest_tag"
        if install_download "https://codeload.github.com/$REPOSITORY/tar.gz/refs/tags/$latest_tag" "$INSTALL_TMP/source.tar.gz" 26214400; then
            source_kind=$latest_tag
            prefix=codexshell-${latest_tag#v}
        else
            printf 'Could not download %s; falling back to %s.\n' "$latest_tag" "$FALLBACK_BRANCH"
            latest_tag=''
        fi
    fi
    if [[ -z "$latest_tag" ]]; then
        printf 'Downloading branch %s...\n' "$FALLBACK_BRANCH"
        install_download "https://codeload.github.com/$REPOSITORY/tar.gz/refs/heads/$FALLBACK_BRANCH" "$INSTALL_TMP/source.tar.gz" 26214400 || {
            install_error "could not download $REPOSITORY"; return 1;
        }
        source_kind=$FALLBACK_BRANCH
        prefix=codexshell-$FALLBACK_BRANCH
    fi
    install_validate_archive "$INSTALL_TMP/source.tar.gz" "$prefix" || {
        install_error 'unsafe or malformed source archive'; return 1;
    }
    install_prepare_source "$prefix" || { install_error 'could not prepare source archive'; return 1; }
    source=$INSTALL_TMP/unpack/$prefix
    mkdir -p -- "$parent"
    parent=$(cd -- "$parent" && pwd -P)
    INSTALL_TARGET=$parent/$base
    [[ ! -L "$INSTALL_TARGET" ]] || { install_error 'destination cannot be a symbolic link'; return 1; }
    case "$target_state" in
        absent)
            [[ ! -e "$INSTALL_TARGET" && ! -L "$INSTALL_TARGET" ]] || {
                install_error 'destination changed during installation'; return 1;
            }
            install_fresh "$source" "$parent"
            ;;
        empty)
            [[ -d "$INSTALL_TARGET" && ! -L "$INSTALL_TARGET" ]] || {
                install_error 'destination changed during installation'; return 1;
            }
            if install_target_nonempty "$INSTALL_TARGET"; then
                install_error 'destination changed during installation'; return 1
            fi
            install_overlay "$source"
            ;;
        overlay)
            [[ -d "$INSTALL_TARGET" && ! -L "$INSTALL_TARGET" ]] || {
                install_error 'destination changed during installation'; return 1;
            }
            install_overlay "$source"
            ;;
    esac
    INSTALL_COMPLETE=1
    printf '\nDone! CodexShell %s is installed at: %s\n\n' "$source_kind" "$INSTALL_TARGET"
    printf 'Next:\n  cd %q\n  ./start.sh\n' "$target_input"
}

trap install_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
install_main "$@"
