#!/usr/bin/env bash

doctor_check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  %b%s%b %s\n' "$C_GREEN" "$(ui_icon success)" "$C_RESET" "$label"
    return 0
  fi
  printf '  %b%s%b %s\n' "$C_RED" "$(ui_icon error)" "$C_RESET" "$label"
  return 1
}

doctor_note() {
  printf '  %b%s%b %s\n' "$C_YELLOW" "$(ui_icon warning 2>/dev/null || printf '!')" "$C_RESET" "$1"
}

check_https_url() {
  curl -fsS --max-time 15 -o /dev/null "$1"
}

check_remnawave_not_sample() {
  local url
  url="$(dotenv_get "$BOT_ENV" REMNAWAVE_API_URL 2>/dev/null || true)"
  [[ -n "$url" ]] || return 1
  ! is_placeholder_remnawave_url "$url"
}

check_remnawave_reachable() {
  local url key
  url="$(dotenv_get "$BOT_ENV" REMNAWAVE_API_URL 2>/dev/null || true)"
  key="$(dotenv_get "$BOT_ENV" REMNAWAVE_API_KEY 2>/dev/null || true)"
  [[ -n "$url" && -n "$key" ]] || return 1
  is_placeholder_remnawave_url "$url" && return 1
  probe_remnawave_api "$url" "$key"
}

check_dns_points_here() {
  local domain="$1"
  local dns_ip server_ip
  dns_ip="$(dns_ipv4 "$domain")"
  [[ -n "$dns_ip" ]] || return 1
  server_ip="$(public_ipv4)"
  [[ -z "$server_ip" || "$dns_ip" == "$server_ip" ]]
}

check_host_port_open() {
  local port="$1"
  if command_exists ss; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
  else
    return 0
  fi
}

check_telegram_webhook() {
  local token expected actual
  [[ -n "${WEBHOOK_DOMAIN:-}" && -f "$BOT_ENV" ]] || return 1
  token="$(dotenv_get "$BOT_ENV" BOT_TOKEN)"
  expected="https://${WEBHOOK_DOMAIN}/webhook"
  actual="$(telegram_api_request "$token" getWebhookInfo 2>/dev/null | jq -r '.result.url // empty')"
  [[ "$actual" == "$expected" ]]
}

check_cors_configuration() {
  local expected cabinet_origins api_origins
  [[ -n "${CABINET_DOMAIN:-}" && -f "$BOT_ENV" ]] || return 1
  expected="https://${CABINET_DOMAIN}"
  cabinet_origins="$(dotenv_get "$BOT_ENV" CABINET_ALLOWED_ORIGINS)"
  api_origins="$(dotenv_get "$BOT_ENV" WEB_API_ALLOWED_ORIGINS)"
  [[ "$cabinet_origins" == "$expected" && "$api_origins" == "$expected" ]]
}

check_uploads_caddy_route() {
  [[ -f "$CADDY_FILE" ]] || return 1
  grep -qE 'handle[[:space:]]+/uploads/\*' "$CADDY_FILE"
}

check_compose_dotenv_present() {
  local compose_dotenv="${INSTALL_ROOT}/.env"
  [[ -e "$compose_dotenv" && -f "$STACK_ENV" ]] || return 1
  [[ -s "$compose_dotenv" || -L "$compose_dotenv" ]]
}

check_admin_notifications_chat() {
  local enabled chat_id
  [[ -f "$BOT_ENV" ]] || return 0
  enabled="$(dotenv_get "$BOT_ENV" ADMIN_NOTIFICATIONS_ENABLED 2>/dev/null || true)"
  [[ "$enabled" == true ]] || return 0
  chat_id="$(dotenv_get "$BOT_ENV" ADMIN_NOTIFICATIONS_CHAT_ID 2>/dev/null || true)"
  if [[ -z "$chat_id" ]] || is_placeholder_admin_chat_id "$chat_id"; then
    return 1
  fi
  return 0
}

doctor() {
  require_root
  migrate_legacy_layout
  ensure_compose_dotenv || true
  local failures=0 webhook_domain cabinet_domain xray_status_domain chat_id
  ui_banner 'Комплексная диагностика'
  ui_section 'Проверки'
  doctor_check "Docker daemon" docker info || ((failures += 1))
  doctor_check "Docker Compose v2" docker compose version || ((failures += 1))
  doctor_check "Файл конфигурации Stack" test -s "$STACK_ENV" || ((failures += 1))
  doctor_check "Файл конфигурации Bot" test -s "$BOT_ENV" || ((failures += 1))
  doctor_check "Compose .env (для bare docker compose)" check_compose_dotenv_present || ((failures += 1))
  doctor_check "Caddyfile" test -s "$CADDY_FILE" || ((failures += 1))
  doctor_check "Caddy /uploads → bot" check_uploads_caddy_route || ((failures += 1))
  doctor_check "Docker Compose config" validate_configuration || ((failures += 1))

  if load_stack_env; then
    webhook_domain="${WEBHOOK_DOMAIN:-}"
    cabinet_domain="${CABINET_DOMAIN:-}"
    xray_status_domain="${XRAY_STATUS_DOMAIN:-}"
    if [[ -n "$webhook_domain" ]]; then
      doctor_check "DNS webhook → этот сервер: $webhook_domain" check_dns_points_here "$webhook_domain" || ((failures += 1))
    fi
    if [[ -n "$cabinet_domain" ]]; then
      doctor_check "DNS Cabinet → этот сервер: $cabinet_domain" check_dns_points_here "$cabinet_domain" || ((failures += 1))
    fi
    if xray_monitoring_enabled && [[ -n "$xray_status_domain" ]]; then
      doctor_check "DNS Xray Status Page → этот сервер: $xray_status_domain" check_dns_points_here "$xray_status_domain" || ((failures += 1))
    fi
  fi

  doctor_check "Порт 80 слушается (ACME http-01)" check_host_port_open 80 || ((failures += 1))
  doctor_check "Порт 443 слушается" check_host_port_open 443 || ((failures += 1))

  local service
  while IFS= read -r service; do
    doctor_check "Контейнер $service: $(service_state "$service" 2>/dev/null || true)" service_state "$service" || ((failures += 1))
  done < <(managed_services)

  if [[ -n "${webhook_domain:-}" ]]; then
    doctor_check "HTTPS webhook" check_https_url "https://${webhook_domain}/health" || ((failures += 1))
  fi
  if [[ -n "${cabinet_domain:-}" ]]; then
    doctor_check "HTTPS Cabinet" check_https_url "https://${cabinet_domain}/" || ((failures += 1))
    doctor_check "Маршрут Cabinet API" check_https_url "https://${cabinet_domain}/api/health" || ((failures += 1))
  fi
  if xray_monitoring_enabled && [[ -n "${xray_status_domain:-}" ]]; then
    doctor_check "HTTPS Xray Status Page" check_https_url "https://${xray_status_domain}/healthz" || ((failures += 1))
  fi
  doctor_check "Telegram webhook зарегистрирован" check_telegram_webhook || ((failures += 1))
  doctor_check "CORS соответствует домену Cabinet" check_cors_configuration || ((failures += 1))
  doctor_check "Remnawave URL не sample/чужой" check_remnawave_not_sample || ((failures += 1))
  doctor_check "Доступность Remnawave API (/api/system/stats)" check_remnawave_reachable || ((failures += 1))

  if [[ -f "$BOT_ENV" ]] && [[ "$(dotenv_get "$BOT_ENV" ADMIN_NOTIFICATIONS_ENABLED 2>/dev/null || true)" == true ]]; then
    chat_id="$(dotenv_get "$BOT_ENV" ADMIN_NOTIFICATIONS_CHAT_ID 2>/dev/null || true)"
    if check_admin_notifications_chat; then
      doctor_check "ADMIN_NOTIFICATIONS_CHAT_ID задан (не placeholder)" true
      doctor_note "ADMIN_NOTIFICATIONS_CHAT_ID=${chat_id}: бот должен быть участником чата (иначе Telegram: chat not found). Manager не создаёт chat id."
    else
      doctor_check "ADMIN_NOTIFICATIONS_CHAT_ID задан (не placeholder)" false || ((failures += 1))
      doctor_note "Заполните реальный ADMIN_NOTIFICATIONS_CHAT_ID в bot.env или отключите ADMIN_NOTIFICATIONS_ENABLED."
    fi
  fi

  printf '\n'
  if [[ "$failures" -eq 0 ]]; then
    success "Проблем не обнаружено."
    return 0
  fi
  error "Обнаружено проблем: $failures"
  ui_hint "Подробные логи: gorec logs <service> или gorec xray logs"
  ui_hint "ACME/HTTPS: DNS A → IP сервера, порты 80/443 открыты; сбой сертификата не откатывает установку — смотрите gorec logs caddy."
  ui_hint "Bare docker compose из /opt/gorec работает благодаря .env → stack.env (gorec apply обновляет ссылку)."
  return 1
}
