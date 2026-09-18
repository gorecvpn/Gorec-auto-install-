#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export GOREC_INSTALL_ROOT="$TEST_ROOT/opt/gorec"
export GOREC_CONFIG_ROOT="$TEST_ROOT/opt/gorec"
export GOREC_DATA_ROOT="$TEST_ROOT/opt/gorec"
export GOREC_BOT_SOURCE_DIR="$TEST_ROOT/opt/bot"
export GOREC_CABINET_SOURCE_DIR="$TEST_ROOT/opt/cabinet"
export GOREC_LIB_ROOT="$PROJECT_ROOT"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/config.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/security.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/backup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

ensure_runtime_dirs
touch "$STACK_ENV" "$BOT_ENV"
dotenv_set "$STACK_ENV" SIMPLE "value"
dotenv_set "$STACK_ENV" WITH_SPACES "VPN Cabinet"
dotenv_set "$STACK_ENV" WITH_QUOTES 'A "quoted" value'
assert_equal "$(dotenv_get "$STACK_ENV" SIMPLE)" "value"
assert_equal "$(dotenv_get "$STACK_ENV" WITH_SPACES)" "VPN Cabinet"
assert_equal "$(dotenv_get "$STACK_ENV" WITH_QUOTES)" 'A "quoted" value'
payload="\$(touch $TEST_ROOT/must-not-exist)"
dotenv_set "$STACK_ENV" INERT_COMMAND "$payload"
load_stack_env
assert_equal "$INERT_COMMAND" "$payload"
[[ ! -e "$TEST_ROOT/must-not-exist" ]] || fail "stack.env executed shell code"

defaults="$TEST_ROOT/defaults.env"
printf 'SIMPLE=overwritten\nNEW_DEFAULT=added\n' >"$defaults"
dotenv_merge_missing "$STACK_ENV" "$defaults"
assert_equal "$(dotenv_get "$STACK_ENV" SIMPLE)" "value"
assert_equal "$(dotenv_get "$STACK_ENV" NEW_DEFAULT)" "added"

no_newline="$TEST_ROOT/no-newline.env"
printf 'EXISTING=value' >"$no_newline"
dotenv_merge_missing "$no_newline" "$defaults"
assert_equal "$(dotenv_get "$no_newline" EXISTING)" "value"
assert_equal "$(dotenv_get "$no_newline" NEW_DEFAULT)" "added"

dotenv_set "$BOT_ENV" ADMIN_REPORTS_TOPIC_ID '# ID топика для отчетов'
dotenv_set "$BOT_ENV" MULENPAY_SHOP_ID '<ID магазина>'
dotenv_set "$BOT_ENV" FREEKASSA_SHOP_ID ''
dotenv_set "$BOT_ENV" LOG_ROTATION_TOPIC_ID '-100123'
sanitize_bot_env
! grep -q '^ADMIN_REPORTS_TOPIC_ID=' "$BOT_ENV" || fail "comment placeholder was not removed"
! grep -q '^MULENPAY_SHOP_ID=' "$BOT_ENV" || fail "text placeholder was not removed"
! grep -q '^FREEKASSA_SHOP_ID=' "$BOT_ENV" || fail "empty optional integer was not removed"
assert_equal "$(dotenv_get "$BOT_ENV" LOG_ROTATION_TOPIC_ID)" '-100123'
dotenv_unset "$BOT_ENV" LOG_ROTATION_TOPIC_ID
! grep -q '^LOG_ROTATION_TOPIC_ID=' "$BOT_ENV" || fail "dotenv_unset did not remove key"

validate_domain "cabinet.example.com" || fail "valid domain rejected"
! validate_domain "https://cabinet.example.com" || fail "invalid domain accepted"
validate_https_url "https://panel.example.com/api" || fail "valid URL rejected"
validate_https_url_list "https://one.example.com/sub,https://two.example.com/sub" || fail "valid URL list rejected"
! validate_https_url_list "https://one.example.com/sub,http://unsafe.example.com/sub" || fail "unsafe URL list accepted"
validate_check_interval 300 || fail "valid check interval rejected"
! validate_check_interval 10 || fail "too short check interval accepted"
validate_image_reference "ghcr.io/example/service:latest" || fail "valid image reference rejected"
validate_bot_token "1234567:abcdefghijklmnopqrstuvwxyz_123456" || fail "valid token rejected"
validate_admin_ids "123,456" || fail "valid admin IDs rejected"
! validate_admin_ids "123,abc" || fail "invalid admin IDs accepted"
validate_api_key "abcDEF_123.456-xyz" || fail "valid API key rejected"
# shellcheck disable=SC2016
! validate_api_key '$(unsafe)' || fail "unsafe API key accepted"
validate_app_name "My VPN" || fail "valid app name rejected"
if [[ -f /usr/share/zoneinfo/UTC ]]; then
  validate_timezone "UTC" || fail "UTC timezone rejected"
fi
# shellcheck disable=SC2016
! validate_app_name '$(touch /tmp/unsafe)' || fail "unsafe app name accepted"

curl_args="$TEST_ROOT/curl-args"
curl_config="$TEST_ROOT/curl-config"
curl() {
  printf '%s\n' "$*" >"$curl_args"
  cat >"$curl_config"
  printf '%s\n' '{"ok":true,"result":{"username":"test_bot"}}'
}
telegram_response="$(telegram_api_request '1234567:abcdefghijklmnopqrstuvwxyz_123456' getMe)"
[[ "$telegram_response" == *'"username":"test_bot"'* ]] || fail "Telegram API response was lost"
! grep -q '1234567:' "$curl_args" || fail "Telegram token leaked into curl arguments"
grep -q '1234567:' "$curl_config" || fail "Telegram request URL was not passed through curl config"
safe_realpath_under "$BACKUP_ROOT/test.tar.gz" "$BACKUP_ROOT" || fail "safe child rejected"
! safe_realpath_under "/etc/passwd" "$BACKUP_ROOT" || fail "unsafe path accepted"
[[ "$BACKUP_ROOT" == "$INSTALL_ROOT/backups" ]] || fail "BACKUP_ROOT default is not under INSTALL_ROOT"
[[ "$BOT_SOURCE_DIR" == "$TEST_ROOT/opt/bot" ]] || fail "BOT_SOURCE_DIR not opt-max"
[[ "$CABINET_SOURCE_DIR" == "$TEST_ROOT/opt/cabinet" ]] || fail "CABINET_SOURCE_DIR not opt-max"
[[ "$CONFIG_ROOT" == "$INSTALL_ROOT" ]] || fail "CONFIG_ROOT should match INSTALL_ROOT in opt-max tests"
[[ "$DATA_ROOT" == "$INSTALL_ROOT" ]] || fail "DATA_ROOT should match INSTALL_ROOT in opt-max tests"

command_exists() {
  [[ "$1" != sshd ]] && command -v "$1" >/dev/null 2>&1
}
SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 2222'
assert_equal "$(detect_ssh_port)" '2222'
SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 70000'
assert_equal "$(detect_ssh_port)" '22'
unset SSH_CONNECTION

first_backup="$(backup_archive_name manual)"
touch "$first_backup"
second_backup="$(backup_archive_name manual)"
[[ "$first_backup" != "$second_backup" ]] || fail "backup name collision was not avoided"

dotenv_set "$STACK_ENV" ACME_EMAIL "admin@example.com"
dotenv_set "$STACK_ENV" WEBHOOK_DOMAIN "hooks.example.com"
dotenv_set "$STACK_ENV" CABINET_DOMAIN "cabinet.example.com"
dotenv_set "$STACK_ENV" VITE_TELEGRAM_BOT_USERNAME "test_bot"
dotenv_set "$STACK_ENV" XRAY_MONITORING_ENABLED false
render_caddyfile
grep -q 'hooks.example.com' "$CADDY_FILE" || fail "webhook domain not rendered"
grep -q 'cabinet.example.com' "$CADDY_FILE" || fail "cabinet domain not rendered"
! grep -q '@@' "$CADDY_FILE" || fail "template placeholder remains"
! grep -q 'status.example.com' "$CADDY_FILE" || fail "disabled Xray route was rendered"
validate_stack_values || fail "valid stack values rejected"
dotenv_set "$STACK_ENV" CABINET_DOMAIN "hooks.example.com"
if validate_stack_values >/dev/null 2>&1; then
  fail "identical webhook and Cabinet domains accepted"
fi
dotenv_set "$STACK_ENV" CABINET_DOMAIN "cabinet.example.com"

dotenv_set "$STACK_ENV" XRAY_MONITORING_ENABLED true
dotenv_set "$STACK_ENV" XRAY_STATUS_DOMAIN "status.example.com"
dotenv_set "$STACK_ENV" XRAY_SUBSCRIPTION_URL "https://panel.example.com/sub/secret"
dotenv_set "$STACK_ENV" XRAY_CHECK_INTERVAL "300"
dotenv_set "$STACK_ENV" XRAY_STATUS_BOT_TOKEN ""
dotenv_set "$STACK_ENV" XRAY_STATUS_ADMIN_IDS ""
dotenv_set "$STACK_ENV" XRAY_CHECKER_IMAGE "kutovoys/xray-checker:latest"
dotenv_set "$STACK_ENV" XRAY_STATUS_SOURCE_DIR "$XRAY_STATUS_SOURCE_DIR"
dotenv_set "$STACK_ENV" XRAY_STATUS_REF "go-build"
dotenv_set "$STACK_ENV" XRAY_STATUS_VERSION "go-build-test"
render_caddyfile
grep -q 'status.example.com' "$CADDY_FILE" || fail "enabled Xray route was not rendered"
grep -q 'reverse_proxy xray-statuspage:8080' "$CADDY_FILE" || fail "Xray reverse proxy was not rendered"
validate_stack_values || fail "valid Xray settings rejected"
mapfile -t active_services < <(managed_services)
[[ " ${active_services[*]} " == *' xray-statuspage '* && " ${active_services[*]} " == *' xray-checker '* ]] || fail "Xray services are not active"
copy_compose_template
docker() { printf '%s\n' "$*"; }
compose_args="$(compose config --quiet)"
[[ "$compose_args" == *'--profile xray-monitoring'* ]] || fail "Xray Compose profile was not enabled"
dotenv_set "$STACK_ENV" XRAY_STATUS_DOMAIN "cabinet.example.com"
if validate_stack_values >/dev/null 2>&1; then
  fail "duplicate Xray Status Page domain accepted"
fi
dotenv_set "$STACK_ENV" XRAY_STATUS_DOMAIN "status.example.com"
dotenv_set "$STACK_ENV" XRAY_MONITORING_ENABLED false
compose_args="$(compose config --quiet)"
[[ "$compose_args" != *'--profile xray-monitoring'* ]] || fail "disabled Xray Compose profile was enabled"
dotenv_set "$STACK_ENV" XRAY_MONITORING_ENABLED true

dotenv_set "$BOT_ENV" BOT_TOKEN "1234567:abcdefghijklmnopqrstuvwxyz_123456"
dotenv_set "$BOT_ENV" ADMIN_IDS "123,456"
dotenv_set "$BOT_ENV" REMNAWAVE_API_URL "https://panel.myvpn.ru"
dotenv_set "$BOT_ENV" REMNAWAVE_API_KEY "abcDEF_123.456-xyz"
validate_bot_values || fail "valid Bot values rejected"
dotenv_set "$BOT_ENV" ADMIN_IDS "123,unsafe"
if validate_bot_values >/dev/null 2>&1; then
  fail "invalid ADMIN_IDS accepted"
fi

# Проверяем передачу введённого значения из функций чтения в переменную вызывающего кода.
# util-linux script создаёт настоящий псевдотерминал, включая скрытый режим read -s.
if command_exists script; then
  export GOREC_TEST_PROJECT_ROOT="$PROJECT_ROOT"
  tty_probe="$TEST_ROOT/tty-probe.sh"
  cat >"$tty_probe" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export GOREC_LIB_ROOT="$GOREC_TEST_PROJECT_ROOT"
# shellcheck disable=SC1091
source "$GOREC_TEST_PROJECT_ROOT/lib/common.sh"
value=''
read_tty value ''
printf 'VISIBLE_RESULT=%s\n' "$value"
value=''
read_secret_tty value ''
printf 'SECRET_RESULT=%s\n' "$value"
EOF
  chmod 700 "$tty_probe"
  tty_output="$(printf 'visible-input\nsecret-input\n' | script -qec "bash '$tty_probe'" /dev/null | tr -d '\r')"
  grep -q '^VISIBLE_RESULT=visible-input$' <<<"$tty_output" || fail "read_tty lost caller value"
  grep -q '^SECRET_RESULT=secret-input$' <<<"$tty_output" || fail "read_secret_tty lost caller value"
fi


# --- opt-max legacy migration (move-if-missing) ---
legacy_root="$TEST_ROOT/legacy-prefix"
mkdir -p "$legacy_root/opt/gorec/sources/bot" "$legacy_root/etc/gorec" \
  "$legacy_root/var/lib/gorec/bot" "$legacy_root/var/lib/gorec/backups" \
  "$legacy_root/var/lib/bedolaga/backups"
printf 'old-bot\n' >"$legacy_root/opt/gorec/sources/bot/README"
printf 'from-etc\n' >"$legacy_root/etc/gorec/migrated-from-etc.marker"
printf 'data\n' >"$legacy_root/var/lib/gorec/bot/keep.txt"
printf 'bak-g\n' >"$legacy_root/var/lib/gorec/backups/old-gorec.tar.gz"
printf 'bak-b\n' >"$legacy_root/var/lib/bedolaga/backups/old-bedolaga.tar.gz"
# Newer file already at destination must not be clobbered
mkdir -p "$DATA_ROOT/bot"
printf 'newer\n' >"$DATA_ROOT/bot/keep.txt"
export GOREC_LEGACY_PREFIX="$legacy_root"
migrate_legacy_layout
unset GOREC_LEGACY_PREFIX
[[ -f "$BOT_SOURCE_DIR/README" ]] || fail "bot source was not migrated to BOT_SOURCE_DIR"
[[ ! -e "$legacy_root/opt/gorec/sources/bot" ]] || fail "legacy bot source still present"
[[ -f "$CONFIG_ROOT/migrated-from-etc.marker" ]] || fail "etc/gorec marker was not migrated"
assert_equal "$(cat "$CONFIG_ROOT/migrated-from-etc.marker")" "from-etc"
assert_equal "$(cat "$DATA_ROOT/bot/keep.txt")" "newer"
[[ -f "$BACKUP_ROOT/old-gorec.tar.gz" ]] || fail "gorec backups not migrated under /opt"
[[ -f "$BACKUP_ROOT/old-bedolaga.tar.gz" ]] || fail "bedolaga backups not migrated under /opt"
[[ "$BACKUP_ROOT" == "$INSTALL_ROOT/backups" ]] || fail "backups must live under INSTALL_ROOT"


# --- harden: compose .env symlink, Remnawave placeholders, uploads, admin chat ---
ensure_compose_dotenv
[[ -L "${INSTALL_ROOT}/.env" ]] || fail "INSTALL_ROOT/.env symlink was not created"
[[ "$(readlink -f "${INSTALL_ROOT}/.env")" == "$(readlink -f "$STACK_ENV")" ]] || fail ".env does not point at stack.env"

grep -qE 'handle[[:space:]]+/uploads/\*' "$CADDY_FILE" || fail "Caddy /uploads route missing after render"

is_placeholder_remnawave_url "https://panel.example.com" || fail "example.com not detected as placeholder"
is_placeholder_remnawave_url "https://haybaadmin.haybavpn.ru" || fail "haybaadmin not detected as placeholder"
is_placeholder_remnawave_url "https://panel.myvpn.ru" && fail "real host rejected as placeholder"
is_placeholder_remnawave_key "your_api_key_here" || fail "placeholder key not detected"
! is_placeholder_remnawave_key "abcDEF_123.456-xyz" || fail "valid key treated as placeholder"
is_placeholder_admin_chat_id "-1001234567890" || fail "sample admin chat id not detected"

dotenv_set "$BOT_ENV" REMNAWAVE_API_URL "https://haybaadmin.haybavpn.ru"
dotenv_set "$BOT_ENV" REMNAWAVE_API_KEY "your_api_key_here"
dotenv_set "$BOT_ENV" ADMIN_NOTIFICATIONS_ENABLED "true"
dotenv_set "$BOT_ENV" ADMIN_NOTIFICATIONS_CHAT_ID "-1001234567890"
sanitize_bot_env
! grep -q '^REMNAWAVE_API_URL=' "$BOT_ENV" || fail "sample Remnawave URL was not cleared"
! grep -q '^REMNAWAVE_API_KEY=' "$BOT_ENV" || fail "placeholder Remnawave key was not cleared"
! grep -q '^ADMIN_NOTIFICATIONS_CHAT_ID=' "$BOT_ENV" || fail "sample admin chat id was not cleared"
assert_equal "$(dotenv_get "$BOT_ENV" ADMIN_NOTIFICATIONS_ENABLED)" "false"

dotenv_set "$BOT_ENV" REMNAWAVE_API_URL "https://haybaadmin.haybavpn.ru"
dotenv_set "$BOT_ENV" REMNAWAVE_API_KEY "abcDEF_123.456-xyz"
dotenv_set "$BOT_ENV" BOT_TOKEN "1234567:abcdefghijklmnopqrstuvwxyz_123456"
dotenv_set "$BOT_ENV" ADMIN_IDS "123,456"
if validate_bot_values >/dev/null 2>&1; then
  fail "haybaadmin Remnawave URL accepted by validate_bot_values"
fi
dotenv_set "$BOT_ENV" REMNAWAVE_API_URL "https://panel.example.com"
if validate_bot_values >/dev/null 2>&1; then
  fail "example.com Remnawave URL accepted by validate_bot_values"
fi
dotenv_set "$BOT_ENV" REMNAWAVE_API_URL "https://panel.myvpn.ru"
dotenv_set "$BOT_ENV" REMNAWAVE_API_KEY "abcDEF_123.456-xyz"
validate_bot_values || fail "valid Remnawave values rejected"

# shellcheck disable=SC2016
grep -Fq '${BOT_ENV:-bot.env}' "$PROJECT_ROOT/templates/compose.yaml" || fail "compose env_file default missing"
grep -q 'handle {' "$PROJECT_ROOT/templates/Caddyfile.tmpl" || fail "webhook handle block missing for ACME safety"

printf 'Smoke tests passed.\n'
