#!/usr/bin/env bash

_version_valid() {
    [[ "${1-}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

version_read() {
    local version
    [[ -f "$1/VERSION" ]] || return 1
    version=$(cat -- "$1/VERSION") || return 1
    _version_valid "$version" || return 1
    printf '%s\n' "$version"
}

version_is_newer() {
    local candidate=${1-} current=${2-} left right index
    local LC_ALL=C
    local -a candidate_parts current_parts
    _version_valid "$candidate" && _version_valid "$current" || return 2
    IFS=. read -r -a candidate_parts <<< "${candidate#v}"
    IFS=. read -r -a current_parts <<< "${current#v}"
    for index in 0 1 2; do
        left=${candidate_parts[$index]}
        right=${current_parts[$index]}
        if (( ${#left} > ${#right} )); then return 0; fi
        if (( ${#left} < ${#right} )); then return 1; fi
        if [[ "$left" > "$right" ]]; then return 0; fi
        if [[ "$left" < "$right" ]]; then return 1; fi
    done
    return 1
}
