#!/usr/bin/env bash
set -euo pipefail

umask 077
READY_TEMP=''
SIGNAL_TEMP=''

cleanup() {
  if [[ -n "$READY_TEMP" ]]; then rm -f -- "$READY_TEMP"; fi
  if [[ -n "$SIGNAL_TEMP" ]]; then rm -f -- "$SIGNAL_TEMP"; fi
}

record_signal() {
  local signal=$1 status=$2
  trap - INT TERM
  SIGNAL_TEMP="$(mktemp /workspace/.signal.XXXXXXXX)"
  printf 'SIGNAL=%s\nSTATUS=%s\n' "$signal" "$status" > "$SIGNAL_TEMP"
  mv -f -- "$SIGNAL_TEMP" /workspace/signal
  SIGNAL_TEMP=''
  exit "$status"
}

trap cleanup EXIT
trap 'record_signal SIGINT 130' INT
trap 'record_signal SIGTERM 143' TERM

cap_inh=''
cap_prm=''
cap_eff=''
cap_bnd=''
cap_amb=''
no_new_privs=''
while IFS=$'\t ' read -r key value _; do
  case "$key" in
    CapInh:) cap_inh=$value ;;
    CapPrm:) cap_prm=$value ;;
    CapEff:) cap_eff=$value ;;
    CapBnd:) cap_bnd=$value ;;
    CapAmb:) cap_amb=$value ;;
    NoNewPrivs:) no_new_privs=$value ;;
  esac
done < "/proc/$$/status"

pid1_comm=''
pid1_exe=''
pid1_exe_status=0
IFS= read -r pid1_comm < /proc/1/comm || true
if ! pid1_exe="$(readlink /proc/1/exe 2>/dev/null)"; then
  pid1_exe_status=1
fi
READY_TEMP="$(mktemp /workspace/.ready.XXXXXXXX)"
{
  printf 'READY=1\n'
  printf 'PID=%s\nPPID=%s\nUID=%s\nGID=%s\n' "$$" "$PPID" "$(id -u)" "$(id -g)"
  printf 'PID1=1\nPID1_COMM=%s\nPID1_EXE=%s\nPID1_EXE_STATUS=%s\n' "$pid1_comm" "$pid1_exe" "$pid1_exe_status"
  printf 'NO_NEW_PRIVS=%s\n' "$no_new_privs"
  printf 'CAP_INH=%s\nCAP_PRM=%s\nCAP_EFF=%s\nCAP_BND=%s\nCAP_AMB=%s\n' "$cap_inh" "$cap_prm" "$cap_eff" "$cap_bnd" "$cap_amb"
} > "$READY_TEMP"
mv -f -- "$READY_TEMP" /workspace/ready
READY_TEMP=''

while true; do
  sleep 1
done
