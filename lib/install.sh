#!/usr/bin/env bash

install_stack() {
  require_root
  with_lock
  migrate_legacy_layout
  ui_banner 'Автоматическая установка Bot + Cabinet'
  ui_section 'Подготовка'
  ui_step pending 'Проверка сервера и системных зависимостей'
  ui_step pending 'Загрузка исходного кода компонентов'
  ui_step pending 'Настройка проекта'
  ui_step pending 'Сборка и запуск Docker-сервисов'
  ui_step pending 'Проверка работоспособности и HTTPS'

  ui_progress 1 7 'Проверка сервера'
  preflight
  ui_step 'done' 'Сервер готов к установке'

  ui_progress 2 7 'Загрузка компонентов'
  prepare_sources
  ui_step 'done' 'Исходный код Bot и Cabinet подготовлен'

  ui_progress 3 7 'Подготовка конфигурации'
  initialize_env_files
  copy_compose_template
  ui_step 'done' 'Шаблоны и конфигурационные файлы готовы'

  ui_progress 4 7 'Интерактивная настройка'
  configuration_wizard
  xray_offer_during_install
  if xray_monitoring_enabled; then
    mkdir -p "$DATA_ROOT/xray-statuspage"
    chmod 700 "$DATA_ROOT/xray-statuspage"
  fi
  ui_step 'done' 'Конфигурация сохранена и проверена'

  local dns_ok=1
  ui_progress 5 7 'Проверка DNS'
  load_stack_env
  check_domain_dns "$WEBHOOK_DOMAIN" || dns_ok=0
  check_domain_dns "$CABINET_DOMAIN" || dns_ok=0
  if xray_monitoring_enabled; then
    check_domain_dns "$XRAY_STATUS_DOMAIN" || dns_ok=0
  fi
  if [[ "$dns_ok" -eq 0 ]]; then
    confirm "DNS ещё не готов. Продолжить сборку и запуск?" || {
      success "Конфигурация сохранена. После настройки DNS выполните: gorec start"
      return 0
    }
  fi
  ui_step 'done' 'Проверка DNS завершена'

  ui_progress 6 7 'Сборка и запуск сервисов'
  validate_configuration || die "Сгенерированная конфигурация некорректна."
  compose_up_or_diagnose -d --build --remove-orphans || return 1
  ui_step 'done' 'Docker-сервисы созданы и запущены'

  ui_progress 7 7 'Проверка работоспособности'
  if wait_for_health 300; then
    local bot_username backup_status='Включены'
    bot_username="$(dotenv_get "$BOT_ENV" BOT_USERNAME 2>/dev/null || printf 'не определён')"
    ui_step 'done' 'Все сервисы прошли health checks'
    if ! backup_schedule enable; then
      backup_status='Не включены'
      warn "Не удалось включить ежедневный бэкап. Это можно сделать: gorec schedule enable"
    fi
    doctor || true
    local xray_url=''
    xray_monitoring_enabled && xray_url="https://${XRAY_STATUS_DOMAIN}"
    ui_install_success "$bot_username" "https://${CABINET_DOMAIN}" "https://${WEBHOOK_DOMAIN}/webhook" "$backup_status" "$xray_url"
    ui_hint "Добавьте домен ${CABINET_DOMAIN} в BotFather → Bot Settings → Domain."
    success "Все сервисы запущены и готовы к работе."
  else
    error "Контейнеры созданы, но не все health checks пройдены."
    compose ps
    printf '\nЗапустите диагностику: gorec doctor\n'
    return 1
  fi
}

uninstall_stack() {
  require_root
  local purge="${1:-}"
  if [[ "$purge" == "--purge-data" ]]; then
    confirm_phrase "Будут удалены контейнеры, база, конфигурация, исходники и бэкапы." "PURGE-GOREC" || die "Отменено."
  else
    confirm "Удалить контейнеры и программу, сохранив конфигурацию, данные и бэкапы?" || die "Отменено."
  fi
  with_lock
  if [[ -f "$COMPOSE_FILE" && -f "$STACK_ENV" ]]; then
    if [[ "$purge" == "--purge-data" ]]; then
      compose down --remove-orphans --volumes
    else
      compose down --remove-orphans
    fi
  fi
  systemctl disable --now gorec-backup.timer >/dev/null 2>&1 || true
  rm -f -- /usr/local/bin/gorec
  rm -rf -- /usr/local/lib/gorec-manager /usr/local/lib/gorec-manager.previous

  # Source checkouts live outside INSTALL_ROOT in opt-max; remove them on any uninstall
  # (they are re-cloned on next install). Config/data/backups stay unless --purge-data.
  for _gorec_src in "$BOT_SOURCE_DIR" "$CABINET_SOURCE_DIR" "$XRAY_STATUS_SOURCE_DIR"; do
    if [[ -e "$_gorec_src" ]]; then
      safe_realpath_child "$_gorec_src" /opt || die "Небезопасный путь исходников: $_gorec_src"
      rm -rf -- "$_gorec_src"
    fi
  done

  if [[ "$purge" == "--purge-data" ]]; then
    safe_realpath_child "$INSTALL_ROOT" /opt || die "Небезопасный INSTALL_ROOT: $INSTALL_ROOT"
    rm -rf -- "$INSTALL_ROOT"
    # Legacy trees (pre-opt-max / bedolaga)
    [[ -d /etc/gorec ]] && rm -rf -- /etc/gorec
    [[ -d /var/lib/gorec ]] && rm -rf -- /var/lib/gorec
    [[ -d /opt/bedolaga ]] && safe_realpath_child /opt/bedolaga /opt && rm -rf -- /opt/bedolaga
    [[ -d /etc/bedolaga ]] && rm -rf -- /etc/bedolaga
    [[ -d /var/lib/bedolaga ]] && rm -rf -- /var/lib/bedolaga
    success "Gorec и все управляемые данные удалены без возможности восстановления."
  else
    # Keep opt-max config+data under INSTALL_ROOT; only drop compose file if present
    rm -f -- "$COMPOSE_FILE"
    success "Программа удалена. Конфигурация и данные сохранены в $CONFIG_ROOT (бэкапы: $BACKUP_ROOT)."
  fi
}
