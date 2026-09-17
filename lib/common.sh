#!/usr/bin/env bash

if [[ -n "${GOREC_COMMON_LOADED:-}" ]]; then
  return 0
fi
GOREC_COMMON_LOADED=1

# Переменные ниже используются другими файлами после source.
# shellcheck disable=SC2034
readonly GOREC_VERSION="1.3.0"
readonly GOREC_REPOSITORY="${GOREC_REPOSITORY:-gorecvpn/Gorec-auto-install-}"
readonly BOT_REPOSITORY="${BOT_REPOSITORY:-https://github.com/gorecvpn/GorecVPN-.git}"
readonly CABINET_REPOSITORY="${CABINET_REPOSITORY:-https://github.com/gorecvpn/Gorec-Cabinet.git}"
readonly XRAY_STATUS_REPOSITORY="${XRAY_STATUS_REPOSITORY:-https://github.com/Mrvibecodic/xray-checker-statuspage.git}"

# shellcheck disable=SC2034
INSTALL_ROOT="${GOREC_INSTALL_ROOT:-/opt/gorec}"
CONFIG_ROOT="${GOREC_CONFIG_ROOT:-/etc/gorec}"
DATA_ROOT="${GOREC_DATA_ROOT:-/var/lib/gorec}"
BACKUP_ROOT="${GOREC_BACKUP_ROOT:-${DATA_ROOT}/backups}"
SOURCE_ROOT="${INSTALL_ROOT}/sources"
BOT_SOURCE_DIR="${SOURCE_ROOT}/bot"
CABINET_SOURCE_DIR="${SOURCE_ROOT}/cabinet"
XRAY_STATUS_SOURCE_DIR="${SOURCE_ROOT}/xray-statuspage"
COMPOSE_FILE="${INSTALL_ROOT}/compose.yaml"
CADDY_FILE="${CONFIG_ROOT}/Caddyfile"
STACK_ENV="${CONFIG_ROOT}/stack.env"
BOT_ENV="${CONFIG_ROOT}/bot.env"
STATE_ROOT="${DATA_ROOT}/state"
UPDATE_STATE="${STATE_ROOT}/last-update.env"
MANAGER_UPDATE_CHECK_STATE="${STATE_ROOT}/manager-update-check"
LOCK_FILE="${STATE_ROOT}/manager.lock"
LOG_FILE="${DATA_ROOT}/manager.log"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[0;34m'
  C_CYAN='\033[0;36m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_CYAN=''
  C_BOLD=''
  C_RESET=''
fi

# Эти значения намеренно объявлены в общем модуле и используются после source
# другими модулями менеджера.
: "$GOREC_VERSION" "$BOT_SOURCE_DIR" "$CABINET_SOURCE_DIR" "$XRAY_STATUS_SOURCE_DIR" "$CADDY_FILE" "$BOT_ENV" "$UPDATE_STATE" "$MANAGER_UPDATE_CHECK_STATE" "$C_CYAN" "$C_BOLD"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_line() {
  local level="$1"
  shift
  local message="$*"
  if [[ -d "$DATA_ROOT" && -w "$DATA_ROOT" ]]; then
    printf '%s [%s] %s\n' "$(timestamp)" "$level" "$message" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

info() { printf "%b[i]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; log_line INFO "$*"; }
success() { printf "%b[✓]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; log_line OK "$*"; }
warn() { printf "%b[!]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; log_line WARN "$*"; }
error() { printf "%b[✗]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; log_line ERROR "$*"; }
die() { error "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Команда требует root. Запустите её через sudo."
}

ensure_runtime_dirs() {
  mkdir -p "$INSTALL_ROOT" "$CONFIG_ROOT" "$DATA_ROOT" "$BACKUP_ROOT" "$SOURCE_ROOT" "$STATE_ROOT"
  chmod 700 "$CONFIG_ROOT" "$STATE_ROOT"
}

template_dir() {
  printf '%s/templates\n' "$GOREC_LIB_ROOT"
}

compose() {
  [[ -f "$COMPOSE_FILE" ]] || die "Не найден $COMPOSE_FILE. Сначала выполните gorec install."
  [[ -f "$STACK_ENV" ]] || die "Не найден $STACK_ENV. Сначала выполните gorec install."
  local -a profile_args=()
  if xray_monitoring_enabled; then
    profile_args=(--profile xray-monitoring)
  fi
  docker compose --project-name gorec --env-file "$STACK_ENV" -f "$COMPOSE_FILE" "${profile_args[@]}" "$@"
}

xray_monitoring_enabled() {
  [[ -f "$STACK_ENV" ]] || return 1
  [[ "$(dotenv_get "$STACK_ENV" XRAY_MONITORING_ENABLED 2>/dev/null || true)" == true ]]
}

managed_services() {
  printf '%s\n' postgres redis bot cabinet caddy
  if xray_monitoring_enabled; then
    printf '%s\n' xray-statuspage xray-checker
  fi
}

with_lock() {
  ensure_runtime_dirs
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другая операция Gorec уже выполняется."
  fi
}

tty_available() { [[ -r /dev/tty && -w /dev/tty ]]; }

read_tty() {
  local variable_name="$1"
  local prompt_text="$2"
  local _gorec_tty_input=''
  tty_available || die "Для этой команды требуется интерактивная SSH-сессия."
  printf '%b' "$prompt_text" >/dev/tty
  IFS= read -r _gorec_tty_input </dev/tty
  printf -v "$variable_name" '%s' "$_gorec_tty_input"
}

read_secret_tty() {
  local variable_name="$1"
  local prompt_text="$2"
  local _gorec_tty_input=''
  tty_available || die "Для этой команды требуется интерактивная SSH-сессия."
  printf '%b\n' "${C_YELLOW}  ↳ Ввод скрыт: символы не отображаются. Вставьте значение и нажмите Enter.${C_RESET}" >/dev/tty
  printf '%b' "$prompt_text" >/dev/tty
  IFS= read -r -s _gorec_tty_input </dev/tty
  printf '\n' >/dev/tty
  printf -v "$variable_name" '%s' "$_gorec_tty_input"
}

confirm() {
  local prompt_text="${1:-Продолжить?}"
  local answer=''
  read_tty answer "${C_YELLOW}${prompt_text} [y/N]: ${C_RESET}"
  [[ "$answer" =~ ^[YyДд]$ ]]
}

confirm_phrase() {
  local prompt_text="$1"
  local phrase="$2"
  local answer=''
  read_tty answer "${C_RED}${prompt_text} Введите ${phrase}: ${C_RESET}"
  [[ "$answer" == "$phrase" ]]
}

random_hex() {
  local bytes="${1:-32}"
  openssl rand -hex "$bytes"
}

human_bytes() {
  local bytes="$1"
  if command_exists numfmt; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    printf '%s bytes\n' "$bytes"
  fi
}

safe_realpath_under() {
  local candidate="$1"
  local parent="$2"
  local resolved_candidate resolved_parent
  resolved_candidate="$(readlink -m "$candidate")"
  resolved_parent="$(readlink -m "$parent")"
  [[ "$resolved_candidate" == "$resolved_parent" || "$resolved_candidate" == "$resolved_parent/"* ]]
}

safe_realpath_child() {
  local candidate="$1"
  local parent="$2"
  local resolved_candidate resolved_parent
  resolved_candidate="$(readlink -m "$candidate")"
  resolved_parent="$(readlink -m "$parent")"
  [[ "$resolved_candidate" == "$resolved_parent/"* ]]
}

load_stack_env() {
  [[ -f "$STACK_ENV" ]] || return 1
  local line key value
  # dotenv_get только читает тот же файл; запись в этом цикле не выполняется.
  # shellcheck disable=SC2094
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[A-Z][A-Z0-9_]*= ]] || continue
    key="${line%%=*}"
    value="$(dotenv_get "$STACK_ENV" "$key")"
    export "$key=$value"
  done <"$STACK_ENV"
}

git_commit() {
  local directory="$1"
  git -C "$directory" rev-parse HEAD 2>/dev/null || printf 'not-installed\n'
}

git_short_commit() {
  local directory="$1"
  git -C "$directory" rev-parse --short HEAD 2>/dev/null || printf 'not-installed\n'
}

on_error() {
  local exit_code=$?
  local line_number="${1:-unknown}"
  error "Операция завершилась с кодом $exit_code (строка $line_number)."
  exit "$exit_code"
}
