#!/usr/bin/env bash
# Debian 12/13 BBR configuration, revised from ryman09/bbr/tcp2.sh.
# Uses the distribution's existing BBR; it does not install a custom kernel.
# Source reviewed: Git blob 685698c5fd83aa7e51a330de4e01139a3472e783.

OS_RELEASE_FILE=/etc/os-release
LEGACY_FILE=/etc/sysctl.conf
SYSCTL_FILE=/etc/sysctl.d/99-tcp2-bbr.conf
MODULES_FILE=/etc/modules-load.d/90-tcp2-bbr.conf
STATE_DIR=/var/lib/tcp2-bbr
LOCK_FILE=/var/lib/tcp2-bbr/lock
LOADER=''
WORK_DIR=''
TX_BACKUP=''
TX_ACTIVE=0
TARGETS=()

info() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

usage() {
  cat <<'HELP'
Usage: sudo bash tcp2.sh [--apply | --check | --dry-run | --rollback ID]

  --apply          Enable BBR + the fq default; persist at boot (default).
  --check          Read-only status and legacy-settings checks.
  --dry-run        Show planned settings; do not load modules or write files.
  --rollback ID    Restore a backup printed by a previous run; ID may be latest.
  --help           Show this help.

Supported: Debian 12 and Debian 13, with a kernel providing BBR and fq.
No downloads, kernel replacement, service restart, or reboot are performed.
Only two sysctl keys are managed. IPv6, forwarding, limits and PAM are untouched.
Active copies of these two keys in /etc/sysctl.conf are backed up and commented
out so a later 'sysctl -p' cannot silently override the new configuration.
Backups cover three configuration paths and the two pre-change runtime values.
Rollback does not undo the original script's unrelated historical settings.
HELP
}

detect_os() {
  local key value os_id='' os_version=''
  [[ -r "$OS_RELEASE_FILE" ]] || { fail "Cannot read $OS_RELEASE_FILE"; return 1; }
  while IFS='=' read -r key value; do
    value=${value%$'\r'}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    case "$key" in ID) os_id=$value ;; VERSION_ID) os_version=$value ;; esac
  done < "$OS_RELEASE_FILE"
  [[ "$os_id" == debian && ( "${os_version%%.*}" == 12 || "${os_version%%.*}" == 13 ) ]] || {
    fail "Supported systems: Debian 12/13. Detected: $os_id $os_version"; return 1;
  }
  info "System: Debian $os_version"
}

require_root() { [[ $EUID -eq 0 ]] || { fail 'Run with sudo or as root.'; return 1; }; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { fail "Missing command: $tool"; return 1; }
  done
}

find_loader() {
  local candidate
  for candidate in /usr/lib/systemd/systemd-sysctl /lib/systemd/systemd-sysctl; do
    if [[ -x "$candidate" ]]; then LOADER=$candidate; return 0; fi
  done
  fail 'systemd-sysctl is missing; boot persistence cannot be verified.'
}

render_sysctl() {
  cat <<'CONF'
# Managed by tcp2.sh; Debian 12/13 boot configuration.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
CONF
}

render_modules() {
  cat <<'CONF'
# Load before systemd-sysctl applies the BBR settings.
tcp_bbr
sch_fq
CONF
}

render_legacy() {
  # Match active assignments only; retain unrelated keys and existing comments.
  awk '/^[[:space:]]*-?net[./]core[./]default_qdisc[[:space:]]*=/ ||
       /^[[:space:]]*-?net[./]ipv4[./]tcp_congestion_control[[:space:]]*=/ {
         print "# Moved to 99-tcp2-bbr.conf: " $0; next
       } { print }' "$LEGACY_FILE"
}

legacy_notice() {
  if [[ -r "$LEGACY_FILE" ]] && grep -Eq \
    '^[[:space:]]*net[.]ipv4[.](tcp_fack|tcp_adv_win_scale|tcp_max_tw_buckets|conf[.]all[.]route_localnet)[[:space:]]*=' "$LEGACY_FILE"; then
    info 'NOTICE: legacy tuning entries remain in /etc/sysctl.conf; review them separately.'
  fi
}

show_status() {
  sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc
  local path
  for path in "$SYSCTL_FILE" "$MODULES_FILE"; do
    if [[ -r "$path" ]]; then info "--- $path"; cat "$path"; else info "Not configured by this script: $path"; fi
  done
  info 'The fq sysctl is a default; it does not replace the current interface qdisc.'
  legacy_notice
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -f -- "$WORK_DIR/sysctl" "$WORK_DIR/modules" "$WORK_DIR/legacy"
    rmdir -- "$WORK_DIR" 2>/dev/null || true
  fi
}

snapshot() {
  local index
  TX_BACKUP=$(mktemp -d "$STATE_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  for index in "${!TARGETS[@]}"; do
    if [[ -e "${TARGETS[$index]}" || -L "${TARGETS[$index]}" ]]; then
      cp -a -- "${TARGETS[$index]}" "$TX_BACKUP/file.$index"
    else
      : > "$TX_BACKUP/absent.$index"
    fi
  done
  sysctl -n net.ipv4.tcp_congestion_control > "$TX_BACKUP/runtime-cc"
  sysctl -n net.core.default_qdisc > "$TX_BACKUP/runtime-qdisc"
  : > "$TX_BACKUP/complete"
}

atomic_install() {
  local source=$1 target=$2 preserve=${3:-0} staging
  staging=$(mktemp "${target}.tmp.XXXXXX")
  if [[ "$preserve" == 1 ]]; then
    if ! cp -a -- "$target" "$staging" || ! cat "$source" > "$staging"; then
      rm -f -- "$staging"; return 1
    fi
  elif ! install -m 0644 -- "$source" "$staging"; then
    rm -f -- "$staging"; return 1
  fi
  if ! mv -fT -- "$staging" "$target"; then
    rm -f -- "$staging"; return 1
  fi
}

restore_snapshot() {
  local backup=$1 index target staging old_cc old_qdisc errors=0
  [[ -f "$backup/complete" ]] || { fail 'Incomplete backup; refusing restoration.'; return 1; }
  old_cc=$(< "$backup/runtime-cc"); old_qdisc=$(< "$backup/runtime-qdisc")
  [[ "$old_cc" =~ ^[a-zA-Z0-9_]+$ && "$old_qdisc" =~ ^[a-zA-Z0-9_]+$ ]] || {
    fail 'Invalid runtime values in backup.'; return 1;
  }
  for index in "${!TARGETS[@]}"; do
    target=${TARGETS[$index]}
    if [[ -e "$backup/file.$index" || -L "$backup/file.$index" ]]; then
      staging=$(mktemp "${target}.restore.XXXXXX") || { errors=1; continue; }
      rm -f -- "$staging"
      if ! cp -a -- "$backup/file.$index" "$staging" || ! mv -fT -- "$staging" "$target"; then
        rm -f -- "$staging"; errors=1
      fi
    elif [[ -f "$backup/absent.$index" ]]; then
      rm -f -- "$target" || errors=1
    else
      fail "Missing backup record for $target"; errors=1
    fi
  done
  sysctl -q -w "net.ipv4.tcp_congestion_control=$old_cc" || errors=1
  sysctl -q -w "net.core.default_qdisc=$old_qdisc" || errors=1
  return "$errors"
}

abort_transaction() {
  local code=${1:-1}
  trap - ERR INT TERM
  set +e
  if [[ "$TX_ACTIVE" == 1 ]]; then
    info "Restoring pre-change settings from: $TX_BACKUP" >&2
    if ! restore_snapshot "$TX_BACKUP"; then
      info "Restoration needs attention. Retained backup: $TX_BACKUP" >&2
    fi
  fi
  exit "$code"
}

verify_boot_settings() {
  # Re-read standard boot files, but apply only the two managed keys.
  "$LOADER" --prefix=/net/ipv4/tcp_congestion_control --prefix=/net/core/default_qdisc
  [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr &&
     $(sysctl -n net.core.default_qdisc) == fq ]] || {
    fail 'Another boot configuration overrides BBR/fq. Check sysctl.d files.'; return 1;
  }
}

apply_bbr() {
  local unchanged=0
  # Module loading is deliberately before configuration changes.
  modprobe tcp_bbr
  modprobe sch_fq
  case " $(sysctl -n net.ipv4.tcp_available_congestion_control) " in
    *' bbr '*) ;; *) fail 'This running kernel does not provide BBR.'; return 1 ;;
  esac
  [[ ! -L "$LEGACY_FILE" ]] || {
    fail '/etc/sysctl.conf is a symlink; resolve its two BBR entries manually first.'; return 1;
  }
  WORK_DIR=$(mktemp -d /tmp/tcp2-bbr.XXXXXX)
  render_sysctl > "$WORK_DIR/sysctl"
  render_modules > "$WORK_DIR/modules"
  [[ ! -f "$LEGACY_FILE" ]] || render_legacy > "$WORK_DIR/legacy"
  if cmp -s "$WORK_DIR/sysctl" "$SYSCTL_FILE" && cmp -s "$WORK_DIR/modules" "$MODULES_FILE" &&
     { [[ ! -f "$LEGACY_FILE" ]] || cmp -s "$WORK_DIR/legacy" "$LEGACY_FILE"; } &&
     [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr && $(sysctl -n net.core.default_qdisc) == fq ]]; then
    unchanged=1
  fi
  # Even a no-op run can encounter a newly added conflicting boot file.
  # Snapshot before the prefix reload so runtime values can be restored on error.
  snapshot
  TX_ACTIVE=1
  if [[ "$unchanged" == 0 ]]; then
    atomic_install "$WORK_DIR/sysctl" "$SYSCTL_FILE"
    atomic_install "$WORK_DIR/modules" "$MODULES_FILE"
    if [[ -f "$LEGACY_FILE" ]] && ! cmp -s "$WORK_DIR/legacy" "$LEGACY_FILE"; then
      atomic_install "$WORK_DIR/legacy" "$LEGACY_FILE" 1
    fi
    sysctl -p "$SYSCTL_FILE"
  fi
  verify_boot_settings
  printf '%s\n' "${TX_BACKUP##*/}" > "$STATE_DIR/latest"
  TX_ACTIVE=0
  info "SUCCESS: BBR + fq default configured. Backup ID: ${TX_BACKUP##*/}"
  info "Rollback: sudo bash tcp2.sh --rollback ${TX_BACKUP##*/}"
  info 'No reboot required. Existing connections/listeners may retain their previous algorithm.'
  info 'The current interface qdisc and running services were not replaced/restarted.'
  legacy_notice
}

rollback_bbr() {
  local id=$1 selected
  if [[ "$id" == latest ]]; then
    [[ -f "$STATE_DIR/latest" ]] || { fail 'No latest backup is recorded.'; return 1; }
    id=$(< "$STATE_DIR/latest")
  fi
  [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{6}$ ]] || { fail 'Invalid backup ID.'; return 1; }
  selected=$STATE_DIR/backups/$id
  [[ -d "$selected" && ! -L "$selected" && -f "$selected/complete" ]] || { fail 'Backup not found or incomplete.'; return 1; }
  snapshot
  TX_ACTIVE=1
  restore_snapshot "$selected"
  printf '%s\n' "${TX_BACKUP##*/}" > "$STATE_DIR/latest"
  TX_ACTIVE=0
  info "Restored backup: $id"
  info "Undo this rollback with: sudo bash tcp2.sh --rollback ${TX_BACKUP##*/}"
  info 'Already loaded kernel modules are left loaded; no services are restarted.'
}

main() {
  set -Eeuo pipefail
  local action=${1:---apply} backup_id=''
  case "$action" in
    --help|-h) usage; return 0 ;;
    --apply|--check|--dry-run) [[ $# -le 1 ]] || { fail 'Too many arguments.'; return 1; } ;;
    --rollback) [[ $# -eq 2 ]] || { fail 'Use --rollback BACKUP_ID or --rollback latest.'; return 1; }; backup_id=$2 ;;
    *) usage >&2; fail "Unknown option: $action"; return 1 ;;
  esac
  detect_os
  require_tools sysctl cat grep
  case "$action" in
    --check) show_status; return 0 ;;
    --dry-run)
      info "Write $SYSCTL_FILE:"; render_sysctl
      info "Write $MODULES_FILE:"; render_modules
      info 'Back up and comment only active BBR/qdisc assignments in /etc/sysctl.conf.'
      info 'Existing IPv6, forwarding, limits, PAM and rc.local settings are retained.'
      legacy_notice; return 0 ;;
  esac
  require_root
  require_tools modprobe install mktemp cmp cp mv rm rmdir awk date flock
  find_loader
  TARGETS=("$SYSCTL_FILE" "$MODULES_FILE" "$LEGACY_FILE")
  umask 077
  # Preserve permissions on shared configuration directories. Keep our lock in
  # a private state directory, not a predictable file in world-writable /run/lock.
  local directory
  for directory in "${SYSCTL_FILE%/*}" "${MODULES_FILE%/*}"; do
    [[ -d "$directory" ]] || install -d -m 0755 "$directory"
  done
  install -d -m 0700 "$STATE_DIR" "$STATE_DIR/backups"
  exec 9> "$LOCK_FILE"
  flock -n 9 || { fail 'Another tcp2.sh operation is already running.'; return 1; }
  trap cleanup EXIT
  trap 'abort_transaction $?' ERR
  trap 'abort_transaction 130' INT
  trap 'abort_transaction 143' TERM
  if [[ "$action" == --rollback ]]; then rollback_bbr "$backup_id"; else apply_bbr; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
