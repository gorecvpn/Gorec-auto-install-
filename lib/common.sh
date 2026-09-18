#!/usr/bin/env bash

if [[ -n "${GOREC_COMMON_LOADED:-}" ]]; then
  return 0
fi
GOREC_COMMON_LOADED=1

# Переменные ниже используются другими файлами после source.
# shellcheck disable=SC2034
readonly GOREC_VERSION="1.5.0"
readonly GOREC_REPOSITORY="${GOREC_REPOSITORY:-gorecvpn/Gorec-auto-install-}"
readonly BOT_REPOSITORY="${BOT_REPOSITORY:-https://github.com/gorecvpn/GorecVPN-.git}"
readonly CABINET_REPOSITORY="${CABINET_REPOSITORY:-https://github.com/gorecvpn/Gorec-Cabinet.git}"
readonly XRAY_STATUS_REPOSITORY="${XRAY_STATUS_REPOSITORY:-https://github.com/Mrvibecodic/xray-checker-statuspage.git}"

# opt-max layout: config + data + backups under /opt/gorec;
# bot/cabinet *source* checkouts live at /opt/bot and /opt/cabinet (not under sources/).
# shellcheck disable=SC2034
INSTALL_ROOT="${GOREC_INSTALL_ROOT:-/opt/gorec}"
CONFIG_ROOT="${GOREC_CONFIG_ROOT:-${INSTALL_ROOT}}"
DATA_ROOT="${GOREC_DATA_ROOT:-${INSTALL_ROOT}}"
BACKUP_ROOT="${GOREC_BACKUP_ROOT:-${INSTALL_ROOT}/backups}"
SOURCE_ROOT="${INSTALL_ROOT}/sources"
BOT_SOURCE_DIR="${GOREC_BOT_SOURCE_DIR:-/opt/bot}"
CABINET_SOURCE_DIR="${GOREC_CABINET_SOURCE_DIR:-/opt/cabinet}"
XRAY_STATUS_SOURCE_DIR="${GOREC_XRAY_STATUS_SOURCE_DIR:-${SOURCE_ROOT}/xray-statuspage}"
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
  mkdir -p "$INSTALL_ROOT" "$CONFIG_ROOT" "$DATA_ROOT" "$BACKUP_ROOT" "$SOURCE_ROOT" "$STATE_ROOT" \
    "$(dirname "$BOT_SOURCE_DIR")" "$(dirname "$CABINET_SOURCE_DIR")"
  # When config lives inside INSTALL_ROOT (opt-max), tighten state and env files rather than the whole tree.
  if [[ "$(readlink -m "$CONFIG_ROOT")" == "$(readlink -m "$INSTALL_ROOT")" ]]; then
    chmod 755 "$INSTALL_ROOT" 2>/dev/null || true
    chmod 700 "$STATE_ROOT" "$BACKUP_ROOT" 2>/dev/null || true
  else
    chmod 700 "$CONFIG_ROOT" "$STATE_ROOT"
  fi
}

# Move source → dest when dest is absent. If both are directories, move missing children only.
migrate_move_if_absent() {
  local from="$1"
  local to="$2"
  local item base
  [[ -e "$from" ]] || return 0
  if [[ ! -e "$to" ]]; then
    mkdir -p "$(dirname "$to")"
    mv -- "$from" "$to"
    info "Мигрировано: $from → $to"
    return 0
  fi
  if [[ -d "$from" && -d "$to" ]]; then
    local nullglob_was=0 dotglob_was=0
    shopt -q nullglob && nullglob_was=1
    shopt -q dotglob && dotglob_was=1
    shopt -s nullglob dotglob
    for item in "$from"/*; do
      base="$(basename "$item")"
      [[ "$base" == "." || "$base" == ".." ]] && continue
      if [[ ! -e "$to/$base" ]]; then
        mv -- "$item" "$to/$base"
        info "Мигрировано: $item → $to/$base"
      else
        warn "Пропуск (уже есть): $to/$base ← $item"
      fi
    done
    [[ "$nullglob_was" -eq 1 ]] || shopt -u nullglob
    [[ "$dotglob_was" -eq 1 ]] || shopt -u dotglob
    rmdir "$from" 2>/dev/null || true
    return 0
  fi
  warn "Пропуск: $to уже существует, не затираю $from"
}

migrate_refresh_stack_env_paths() {
  [[ -f "$STACK_ENV" ]] || return 0
  declare -F dotenv_set >/dev/null 2>&1 || return 0
  dotenv_set "$STACK_ENV" BOT_SOURCE_DIR "$BOT_SOURCE_DIR"
  dotenv_set "$STACK_ENV" CABINET_SOURCE_DIR "$CABINET_SOURCE_DIR"
  dotenv_set "$STACK_ENV" CONFIG_ROOT "$CONFIG_ROOT"
  dotenv_set "$STACK_ENV" DATA_ROOT "$DATA_ROOT"
  dotenv_set "$STACK_ENV" BOT_ENV "$BOT_ENV"
  if declare -F dotenv_get >/dev/null 2>&1; then
    local xray_src
    xray_src="$(dotenv_get "$STACK_ENV" XRAY_STATUS_SOURCE_DIR 2>/dev/null || true)"
    if [[ -n "$xray_src" ]]; then
      dotenv_set "$STACK_ENV" XRAY_STATUS_SOURCE_DIR "$XRAY_STATUS_SOURCE_DIR"
    fi
  fi
  ensure_compose_dotenv
}

# Detect previous Gorec (/etc,/var/lib, sources under /opt/gorec) and bedolaga trees; migrate into opt-max.
# GOREC_LEGACY_PREFIX (tests only) prefixes absolute legacy paths, e.g. $TEST_ROOT.
migrate_legacy_layout() {
  local prefix="${GOREC_LEGACY_PREFIX:-}"
  local legacy_opt_gorec="${prefix}/opt/gorec"
  local legacy_etc_gorec="${prefix}/etc/gorec"
  local legacy_var_gorec="${prefix}/var/lib/gorec"
  local legacy_opt_bedolaga="${prefix}/opt/bedolaga"
  local legacy_etc_bedolaga="${prefix}/etc/bedolaga"
  local legacy_var_bedolaga="${prefix}/var/lib/bedolaga"
  local legacy_bin_bedolaga="${prefix}/usr/local/bin/bedolaga"
  local legacy_lib_bedolaga="${prefix}/usr/local/lib/bedolaga-manager"
  local legacy_detected=0

  if [[ -e "$legacy_opt_gorec/sources/bot" || -e "$legacy_opt_gorec/sources/cabinet" \
    || -e "$legacy_etc_gorec" || -e "$legacy_var_gorec" \
    || -e "$legacy_opt_bedolaga" || -e "$legacy_etc_bedolaga" || -e "$legacy_var_bedolaga" ]]; then
    legacy_detected=1
  fi
  [[ "$legacy_detected" -eq 1 ]] || return 0

  info "Обнаружена прежняя структура каталогов — выполняю миграцию в opt-max (/opt/gorec, /opt/bot, /opt/cabinet)."

  migrate_move_if_absent "$legacy_opt_gorec/sources/bot" "$BOT_SOURCE_DIR"
  migrate_move_if_absent "$legacy_opt_gorec/sources/cabinet" "$CABINET_SOURCE_DIR"
  migrate_move_if_absent "$legacy_opt_bedolaga/sources/bot" "$BOT_SOURCE_DIR"
  migrate_move_if_absent "$legacy_opt_bedolaga/sources/cabinet" "$CABINET_SOURCE_DIR"
  migrate_move_if_absent "$legacy_opt_bedolaga/sources/xray-statuspage" "$XRAY_STATUS_SOURCE_DIR"

  if [[ "$(readlink -m "$legacy_etc_gorec")" != "$(readlink -m "$CONFIG_ROOT")" ]]; then
    migrate_move_if_absent "$legacy_etc_gorec" "$CONFIG_ROOT"
  fi
  if [[ -d "$legacy_etc_bedolaga" ]]; then
    migrate_move_if_absent "$legacy_etc_bedolaga/stack.env" "$CONFIG_ROOT/stack.env"
    migrate_move_if_absent "$legacy_etc_bedolaga/bot.env" "$CONFIG_ROOT/bot.env"
    migrate_move_if_absent "$legacy_etc_bedolaga/Caddyfile" "$CONFIG_ROOT/Caddyfile"
    migrate_move_if_absent "$legacy_etc_bedolaga" "$CONFIG_ROOT"
  fi

  if [[ -d "$legacy_var_gorec" ]]; then
    migrate_move_if_absent "$legacy_var_gorec/bot" "$DATA_ROOT/bot"
    migrate_move_if_absent "$legacy_var_gorec/xray-statuspage" "$DATA_ROOT/xray-statuspage"
    migrate_move_if_absent "$legacy_var_gorec/state" "$STATE_ROOT"
    migrate_move_if_absent "$legacy_var_gorec/manager.log" "$LOG_FILE"
    migrate_move_if_absent "$legacy_var_gorec/backups" "$BACKUP_ROOT"
    migrate_move_if_absent "$legacy_var_gorec" "$DATA_ROOT"
  fi
  if [[ -d "$legacy_var_bedolaga" ]]; then
    migrate_move_if_absent "$legacy_var_bedolaga/bot" "$DATA_ROOT/bot"
    migrate_move_if_absent "$legacy_var_bedolaga/xray-statuspage" "$DATA_ROOT/xray-statuspage"
    migrate_move_if_absent "$legacy_var_bedolaga/state" "$STATE_ROOT"
    migrate_move_if_absent "$legacy_var_bedolaga/manager.log" "$LOG_FILE"
    migrate_move_if_absent "$legacy_var_bedolaga/backups" "$BACKUP_ROOT"
    migrate_move_if_absent "$legacy_var_bedolaga" "$DATA_ROOT"
  fi

  if [[ -d "$legacy_opt_bedolaga" ]]; then
    migrate_move_if_absent "$legacy_opt_bedolaga/compose.yaml" "$COMPOSE_FILE"
    migrate_move_if_absent "$legacy_opt_bedolaga/sources/xray-statuspage" "$XRAY_STATUS_SOURCE_DIR"
    if [[ "$(readlink -m "$legacy_opt_bedolaga")" != "$(readlink -m "$INSTALL_ROOT")" ]]; then
      migrate_move_if_absent "$legacy_opt_bedolaga" "$INSTALL_ROOT"
    fi
  fi

  if [[ -z "$prefix" ]] && { [[ -e /usr/local/bin/bedolaga ]] || [[ -d /usr/local/lib/bedolaga-manager ]]; }; then
    warn "Найдены остатки bedolaga CLI: /usr/local/bin/bedolaga и/или /usr/local/lib/bedolaga-manager"
    if declare -F confirm >/dev/null 2>&1 && tty_available; then
      if confirm "Удалить устаревшие bedolaga CLI (gorec уже установлен)?"; then
        rm -f -- /usr/local/bin/bedolaga
        rm -rf -- /usr/local/lib/bedolaga-manager /usr/local/lib/bedolaga-manager.previous
        success "Устаревший bedolaga CLI удалён."
      fi
    else
      warn "Удалите вручную: rm -f /usr/local/bin/bedolaga; rm -rf /usr/local/lib/bedolaga-manager"
    fi
  elif [[ -n "$prefix" ]] && { [[ -e "$legacy_bin_bedolaga" ]] || [[ -d "$legacy_lib_bedolaga" ]]; }; then
    warn "Найдены остатки bedolaga CLI в тестовом префиксе ($prefix)."
  fi

  ensure_runtime_dirs
  migrate_refresh_stack_env_paths
  success "Миграция путей в opt-max завершена (существующие файлы не перезаписывались)."
}

template_dir() {
  printf '%s/templates\n' "$GOREC_LIB_ROOT"
}


# Docker Compose auto-loads $INSTALL_ROOT/.env for ${VAR} interpolation in compose.yaml.
# Without it, bare `cd /opt/gorec && docker compose …` expands BOT_ENV/CONFIG_ROOT empty
# ("env file not found: stat : no such file").
ensure_compose_dotenv() {
  local compose_dotenv="${INSTALL_ROOT}/.env"
  [[ -f "$STACK_ENV" ]] || return 0
  mkdir -p "$INSTALL_ROOT"
  local stack_real
  stack_real="$(readlink -m "$STACK_ENV")"
  if [[ "$(readlink -m "$compose_dotenv")" == "$stack_real" ]]; then
    return 0
  fi
  # Prefer symlink so stack.env remains the single source of truth.
  ln -sfn "$stack_real" "$compose_dotenv"
  chmod 600 "$STACK_ENV" 2>/dev/null || true
}

compose() {
  [[ -f "$COMPOSE_FILE" ]] || die "Не найден $COMPOSE_FILE. Сначала выполните gorec install."
  [[ -f "$STACK_ENV" ]] || die "Не найден $STACK_ENV. Сначала выполните gorec install."
  ensure_compose_dotenv
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
