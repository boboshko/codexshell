#!/usr/bin/env bash

menu_cleanup() {
  if [[ "${_MENU_ACTIVE:-0}" == 1 ]]; then
    _MENU_ACTIVE=0
    if [[ -n "${_MENU_STTY:-}" ]]; then
      stty "$_MENU_STTY" 2>/dev/null || true
    fi
    printf '%s%s' "${_MENU_CURSOR_SHOW:-}" "${_MENU_SCREEN_LEAVE:-}"
  fi
  return 0
}

_menu_prepare() {
  [[ -t 0 && -t 1 && -n "${TERM:-}" && "$TERM" != dumb ]] || return 1
  command -v tput >/dev/null 2>&1 || return 1
  command -v stty >/dev/null 2>&1 || return 1
  _MENU_SCREEN_ENTER="$(tput smcup 2>/dev/null)" || return 1
  _MENU_SCREEN_LEAVE="$(tput rmcup 2>/dev/null)" || return 1
  _MENU_CURSOR_HIDE="$(tput civis 2>/dev/null)" || return 1
  _MENU_CURSOR_SHOW="$(tput cnorm 2>/dev/null)" || return 1
  _MENU_HOME="$(tput cup 0 0 2>/dev/null)" || return 1
  _MENU_CLEAR="$(tput ed 2>/dev/null)" || return 1
  _MENU_HIGHLIGHT="$(tput smso 2>/dev/null)" || return 1
  _MENU_NORMAL="$(tput rmso 2>/dev/null)" || return 1
  _MENU_STTY="$(stty -g 2>/dev/null)" || return 1
  _MENU_ACTIVE=1
  if ! stty -echo -icanon min 1 time 0 2>/dev/null; then
    menu_cleanup
    return 1
  fi
  printf '%s%s' "$_MENU_SCREEN_ENTER" "$_MENU_CURSOR_HIDE"
}

_menu_draw() {
  local title="$1" selected="$2" index=0 key label
  shift 2
  printf '%s%s%s\n\n' "$_MENU_HOME" "$_MENU_CLEAR" "$title"
  while (( $# > 0 )); do
    key="$1" label="$2"
    shift 2
    if (( index == selected )); then
      printf '%s> %s. %s%s\n' "$_MENU_HIGHLIGHT" "$key" "$label" "$_MENU_NORMAL"
    else
      printf '  %s. %s\n' "$key" "$label"
    fi
    index=$((index + 1))
  done
  printf '\nUp/Down: navigate | Enter: select | q: back/exit | number: select\n'
}

# shellcheck disable=SC2034
menu_select() {
  menu_cleanup
  MENU_KEY=''
  (( $# >= 3 && $# % 2 == 1 )) || return 1
  local title="$1" selected=0 count index key reply prefix suffix status
  shift
  local -a options=("$@")
  count=$(( $# / 2 ))
  if ! _menu_prepare; then
    while true; do
      printf '\n%s\n\n' "$title"
      for (( index=0; index<count; index++ )); do
        printf '%s. %s\n' "${options[$((index * 2))]}" "${options[$((index * 2 + 1))]}"
      done
      printf '\nSelect an option (q to back/exit): '
      IFS= read -r reply || return 1
      if [[ "$reply" == q ]]; then MENU_KEY=0; return 0; fi
      for (( index=0; index<count; index++ )); do
        if [[ "$reply" == "${options[$((index * 2))]}" ]]; then
          MENU_KEY="$reply"
          return 0
        fi
      done
      printf 'Invalid selection.\n'
    done
  fi
  while true; do
    _menu_draw "$title" "$selected" "${options[@]}"
    if ! IFS= read -r -n 1 reply; then
      menu_cleanup
      return 1
    fi
    if [[ "$reply" == $'\033' ]]; then
      prefix=''
      if IFS= read -r -n 1 -t 1 prefix; then
        if [[ "$prefix" == '[' || "$prefix" == O ]]; then
          suffix=''
          if IFS= read -r -n 1 -t 1 suffix; then
            case "$suffix" in
              A) selected=$(( (selected + count - 1) % count )) ;;
              B) selected=$(( (selected + 1) % count )) ;;
            esac
          else
            status=$?
            if (( status == 1 )); then menu_cleanup; return 1; fi
          fi
          continue
        fi
        reply="$prefix"
      else
        status=$?
        if (( status == 1 )); then menu_cleanup; return 1; fi
        continue
      fi
    fi
    case "$reply" in
      ''|$'\r'|$'\n') MENU_KEY="${options[$((selected * 2))]}"; menu_cleanup; return 0 ;;
      q) MENU_KEY=0; menu_cleanup; return 0 ;;
      $'\004') menu_cleanup; return 1 ;;
    esac
    for (( index=0; index<count; index++ )); do
      key="${options[$((index * 2))]}"
      if [[ "$reply" == "$key" ]]; then
        MENU_KEY="$key"
        menu_cleanup
        return 0
      fi
    done
  done
}

menu_tools() {
  local root=$1 i j count selected=0 reply prefix suffix status group='' n height top focus row mark
  local -a indexes=() rows=() row_selection=() selection_row=()
  for ((i=0; i<${#TOOLS_SLUGS[@]}; i++)); do
    if [[ "${TOOLS_PLATFORMS[$i]}" == macos && "$(uname -s)" != Darwin ]]; then continue; fi
    indexes+=("$i")
  done
  count=${#indexes[@]}
  while true; do
    if ! _menu_prepare; then
      menu_cleanup
      printf '\nTools\n'
      if [[ -n "${TOOLS_MESSAGE:-}" ]]; then printf '%s\n' "$TOOLS_MESSAGE"; fi
      group=''
      for ((j=0; j<count; j++)); do
        i=${indexes[$j]}
        if [[ "$group" != "${TOOLS_GROUPS[$i]}" ]]; then group=${TOOLS_GROUPS[$i]}; printf '\n%s\n' "$group"; fi
        mark=' '; [[ "${TOOLS_VALUES[$i]}" == off ]] || mark='*'
        printf '%d. [%s] %s\n' "$((j+1))" "$mark" "${TOOLS_LABELS[$i]}"
      done
      printf '\nNumber: toggle | save/back/Enter: save | cancel/q: discard\n> '
      IFS= read -r reply || return 4
      case "$reply" in ''|save|back) return 0 ;; cancel|q) return 3 ;; esac
      if [[ "$reply" =~ ^[1-9][0-9]?$ ]]; then
        n=$((10#$reply))
        if ((n>=1 && n<=count)); then _tools_toggle "$root" "${TOOLS_SLUGS[${indexes[$((n-1))]}]}" || true; fi
      fi
      continue
    fi
    while true; do
      rows=() row_selection=() selection_row=() group=''
      for ((j=0; j<count; j++)); do
        i=${indexes[$j]}
        if [[ "$group" != "${TOOLS_GROUPS[$i]}" ]]; then
          group=${TOOLS_GROUPS[$i]}; rows+=("$group"); row_selection+=(-1)
        fi
        selection_row+=("${#rows[@]}")
        mark=' '; [[ "${TOOLS_VALUES[$i]}" == off ]] || mark='*'
        printf -v row '%d. [%s] %s' "$((j+1))" "$mark" "${TOOLS_LABELS[$i]}"
        rows+=("$row") row_selection+=("$j")
      done
      selection_row+=("${#rows[@]}") rows+=('Back (save)') row_selection+=("$count")
      height=$(tput lines 2>/dev/null) || height=24
      [[ "$height" =~ ^[0-9]+$ ]] || height=24
      height=$((height-6))
      ((height>=1)) || height=1
      focus=${selection_row[$selected]}
      top=$((focus-height+1)); ((top>=0)) || top=0
      printf '%s%sTools\n' "$_MENU_HOME" "$_MENU_CLEAR"
      for ((j=top; j<${#rows[@]} && j<top+height; j++)); do
        if [[ "${row_selection[$j]}" == "$selected" ]]; then printf '%s> %s%s\n' "$_MENU_HIGHLIGHT" "${rows[$j]}" "$_MENU_NORMAL";
        else printf '  %s\n' "${rows[$j]}"; fi
      done
      printf '\n%s\nUp/Down: navigate | Space: toggle\nEnter: save | q/Esc: cancel\n' "${TOOLS_MESSAGE:-}"
      if ! IFS= read -r -n 1 reply; then menu_cleanup; return 4; fi
      if [[ "$reply" == $'\033' ]]; then
        prefix=''; suffix=''
        if IFS= read -r -n 1 -t 1 prefix; then
          if [[ "$prefix" == '[' || "$prefix" == O ]]; then
            if IFS= read -r -n 1 -t 1 suffix; then
              case "$suffix" in A) selected=$(((selected+count)%(count+1))) ;; B) selected=$(((selected+1)%(count+1))) ;; esac
              continue
            fi
            status=$?
            menu_cleanup
            ((status==1)) && return 4
            return 3
          fi
          menu_cleanup; return 3
        fi
        menu_cleanup; return 3
      fi
      case "$reply" in
        q|$'\004') menu_cleanup; return 3 ;;
        ''|$'\r'|$'\n') menu_cleanup; return 0 ;;
        ' ')
          if ((selected==count)); then menu_cleanup; return 0; fi
          _tools_toggle "$root" "${TOOLS_SLUGS[${indexes[$selected]}]}" || true
          if [[ "${_MENU_ACTIVE:-0}" == 1 ]]; then continue; fi
          break
          ;;
      esac
    done
  done
}
