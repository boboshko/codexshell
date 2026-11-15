#!/usr/bin/env bash

_update_valid_tag() {
    [[ "${1-}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

_update_cache_read() {
    local cache=$1 now=$2 stamp value extra size
    [[ -f "$cache" && ! -L "$cache" ]] || return 1
    size=$(wc -c < "$cache") || return 1
    (( size <= 256 )) || return 1
    {
        IFS= read -r stamp || return 1
        IFS= read -r value || return 1
        if IFS= read -r extra || [[ -n "$extra" ]]; then return 1; fi
    } < "$cache"
    [[ "$stamp" =~ ^(0|[1-9][0-9]{0,10})$ ]] || return 1
    (( stamp <= now && now - stamp < 3600 )) || return 1
    [[ "$value" == '-' ]] || _update_valid_tag "$value" || return 1
    _UPDATE_CACHED_TAG=$value
}

_update_cache_write() (
    umask 077
    local root=$1 now=$2 tag=$3 temporary=''
    [[ ! -L "$root/config" && ! -L "$root/config/update-cache" ]] || return 0
    mkdir -p -- "$root/config" 2>/dev/null || return 0
    temporary=$(mktemp "$root/config/.update-cache.XXXXXXXX") || return 0
    trap 'rm -f -- "$temporary"' EXIT
    trap 'exit 1' INT TERM HUP
    printf '%s\n%s\n' "$now" "$tag" > "$temporary" || return 0
    mv -f -- "$temporary" "$root/config/update-cache" 2>/dev/null || return 0
)

# shellcheck disable=SC2034
update_check() {
    local root=${1-} current=${2-} now tag='-' headers line location='' status='' count=0
    UPDATE_TAG=''
    UPDATE_VERSION=''
    [[ "${CODEXSHELL_NO_UPDATE_CHECK-}" != 1 ]] || return 0
    _update_valid_tag "$current" || return 0
    [[ -d "$root" && ! -L "$root/config" ]] || return 0
    now=$(date +%s 2>/dev/null) || return 0
    [[ "$now" =~ ^[1-9][0-9]{0,10}$ ]] || return 0
    if _update_cache_read "$root/config/update-cache" "$now"; then
        tag=$_UPDATE_CACHED_TAG
    else
        if command -v curl >/dev/null 2>&1; then
            if headers=$(curl --disable --silent --show-error --head --connect-timeout 3 --max-time 3 \
                --retry 0 --proto '=https' --max-redirs 0 \
                'https://github.com/boboshko/codexshell/releases/latest' 2>/dev/null); then
                while IFS= read -r line; do
                    line=${line%$'\r'}
                    case "$line" in
                        HTTP/*) status=${line#* }; status=${status%% *}; location=''; count=0 ;;
                        [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:*)
                            location=${line#*:}
                            location=${location# }
                            count=$((count + 1))
                            ;;
                    esac
                done <<< "$headers"
                if [[ "$status" =~ ^30[12378]$ && "$count" == 1 && \
                    "$location" == https://github.com/boboshko/codexshell/releases/tag/* ]]; then
                    tag=${location#https://github.com/boboshko/codexshell/releases/tag/}
                    _update_valid_tag "$tag" || tag='-'
                fi
            fi
        fi
        _update_cache_write "$root" "$now" "$tag" || :
    fi
    if [[ "$tag" != '-' ]]; then
        if ! command -v version_is_newer >/dev/null 2>&1; then
            source "$root/scripts/lib-version.sh" || return 0
        fi
        if version_is_newer "$tag" "$current"; then
            UPDATE_TAG=$tag
            UPDATE_VERSION=$tag
        fi
    fi
    return 0
}

update_install() {
    local root=${1-} tag=${2-}
    _update_valid_tag "$tag" || return 2
    [[ -f "$root/scripts/update.sh" && ! -L "$root/scripts" && ! -L "$root/scripts/update.sh" ]] || return 1
    if bash "$root/scripts/update.sh" "$tag"; then return 0; fi
    return 1
}
