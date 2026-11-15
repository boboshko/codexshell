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
