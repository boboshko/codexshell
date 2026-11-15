#!/usr/bin/env bash

_build_hash() (
  set -o pipefail
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else printf 'Build: no SHA-256 tool available.\n' >&2; return 1; fi
)
build_fingerprint() (
  set -o pipefail
  local root=$1 version=$2 file i digest files links
  [[ -d "$root/docker" && ! -L "$root/docker" ]] || return 1
  links=$(find "$root/docker" -type l -print) || return 1
  [[ -z "$links" ]] || { printf 'Build: image inputs must not be symlinks.\n' >&2; return 1; }
  for file in Dockerfile install-tools.sh entrypoint.sh codex-session.sh firewall.sh allowed-domains.txt xcode-shims/xcodebuild xcode-shims/xcrun xcode-shims/simctl xcode-shims/bridge-client.mjs; do
    [[ -f "$root/docker/$file" ]] || { printf 'Build: missing image input %s.\n' "$file" >&2; return 1; }
  done
  files=$(cd "$root/docker" && find . -type f ! -name '.DS_Store' ! -name '._*') || return 1
  files=$(printf '%s\n' "$files" | LC_ALL=C sort) || return 1
  {
    printf 'codexshell-build-v1\nVERSION:%s\n' "$version"
    for ((i=0; i<${#TOOLS_SLUGS[@]}; i++)); do
      [[ "${TOOLS_KINDS[$i]}" == image ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${TOOLS_SLUGS[$i]}" "${TOOLS_GROUPS[$i]}" "${TOOLS_LABELS[$i]}" "${TOOLS_KINDS[$i]}" "${TOOLS_PLATFORMS[$i]}" "${TOOLS_REQUIRES[$i]}" "${TOOLS_VALUES[$i]}"
    done
    while IFS= read -r file; do
      [[ -f "$root/docker/$file" && ! -L "$root/docker/$file" ]] || return 1
      digest=$(_build_hash < "$root/docker/$file") || return 1
      printf 'FILE:%s\nSHA256:%s\n' "$file" "$digest"
    done <<< "$files"
  } | _build_hash
)

build_cleanup() {
  if [[ -n "${BUILD_TEMP:-}" ]]; then rm -f -- "$BUILD_TEMP"; BUILD_TEMP=''; fi
  if [[ -n "${BUILD_LOCK:-}" ]]; then rmdir -- "$BUILD_LOCK" 2>/dev/null || true; BUILD_LOCK=''; fi
}
_build_validate_recipes() {
  local root=$1 line slug i count=0 found declared_count=0
  local -a declared=()
  [[ -f "$root/docker/Dockerfile" ]] || return 2
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == 'ARG TOOL_'* ]] || continue
    [[ "$line" =~ ^ARG\ TOOL_([A-Z][A-Z0-9_]*)=0$ ]] || { printf 'Build: invalid optional Docker argument.\n' >&2; return 2; }
    slug=${BASH_REMATCH[1]}
    for found in ${declared[@]+"${declared[@]}"}; do [[ "$found" != "$slug" ]] || return 2; done
    declared+=("$slug")
    declared_count=$((declared_count+1))
    _tools_index "$slug" || { printf 'Build: recipe argument absent from catalog: %s.\n' "$slug" >&2; return 2; }
    [[ "${TOOLS_KINDS[$TOOLS_INDEX]}" == image ]] || return 2
  done < "$root/docker/Dockerfile"
  for ((i=0; i<${#TOOLS_SLUGS[@]}; i++)); do
    [[ "${TOOLS_KINDS[$i]}" == image ]] || continue
    count=$((count+1)); found=0
    for slug in ${declared[@]+"${declared[@]}"}; do [[ "$slug" != "${TOOLS_SLUGS[$i]}" ]] || found=1; done
    [[ "$found" == 1 ]] || { printf 'Build: no recipe argument for %s.\n' "${TOOLS_SLUGS[$i]}" >&2; return 2; }
  done
  [[ "$count" == "$declared_count" ]]
}
build_ensure() {
  local root=$1 version=$2 fingerprint image_id record expected
  tools_load "$root" || return 2
  tools_build_args || return 2
  _build_validate_recipes "$root" || return 2
  [[ ! -L "$root/config" && ( ! -e "$root/config" || -d "$root/config" ) && ! -L "$root/config/build-fingerprint" && ( ! -e "$root/config/build-fingerprint" || -f "$root/config/build-fingerprint" ) ]] || { printf 'Build: unsafe cache destination.\n' >&2; return 2; }
  if ! mkdir -- "$root/.codexshell-update.lock" 2>/dev/null; then printf 'Build: another build/update/settings operation is active.\n' >&2; return 1; fi
  BUILD_LOCK=$root/.codexshell-update.lock
  if ! mkdir -p -- "$root/config"; then build_cleanup; return 1; fi
  fingerprint=$(build_fingerprint "$root" "$version") || { build_cleanup; return 1; }
  image_id=$(docker image inspect --format '{{.Id}}' codexshell:local 2>/dev/null) || image_id=''
  record=''
  if [[ -f "$root/config/build-fingerprint" ]]; then record=$(cat "$root/config/build-fingerprint") || { build_cleanup; return 1; }; fi
  printf -v expected 'codexshell-build-v1\n%s\n%s' "$fingerprint" "$image_id"
  if [[ -n "$image_id" && "$record" == "$expected" ]]; then
    printf 'Build: reusing verified local image.\n'
    build_cleanup; return 0
  fi
  printf 'Build: building CodexShell image...\n'
  if ! docker build --progress=plain --build-arg "APP_VERSION=$version" ${TOOLS_BUILD_ARGS[@]+"${TOOLS_BUILD_ARGS[@]}"} -t codexshell:local "$root/docker"; then
    printf 'Build: image build failed.\n' >&2; build_cleanup; return 1
  fi
  image_id=$(docker image inspect --format '{{.Id}}' codexshell:local 2>/dev/null) || { build_cleanup; return 1; }
  [[ -n "$image_id" && "$image_id" != *$'\n'* ]] || { build_cleanup; return 1; }
  BUILD_TEMP=$(umask 077; mktemp "$root/config/.build.XXXXXXXX") || { build_cleanup; return 1; }
  if ! printf 'codexshell-build-v1\n%s\n%s\n' "$fingerprint" "$image_id" > "$BUILD_TEMP" || ! mv -f -- "$BUILD_TEMP" "$root/config/build-fingerprint"; then build_cleanup; return 1; fi
  BUILD_TEMP=''; build_cleanup
}
