# Changelog

Все заметные изменения проекта документируются в этом файле.

## 1.5.1 — 2026-09-18

### Changed
- Default bot repository updated after rename: `gorecvpn/GorecVPN-` → `gorecvpn/Gorec` (`BOT_REPOSITORY`).
- README links point to the renamed bot repo.

## 1.5.0 — 2026-09-18

### Fixed
- Bare `docker compose` from `/opt/gorec` no longer expands empty `${BOT_ENV}` / `${CONFIG_ROOT}`: install/apply/update/migrate now keep `/opt/gorec/.env` as a symlink to `stack.env` (Compose auto-loads it). CLI wrappers still pass `--env-file`.
- Install wizard no longer seeds Remnawave from sample/foreign hosts (`example.com`, `haybaadmin.haybavpn.ru`, bedolaga*). Placeholders are stripped from `bot.env` on sanitize; wizard requires a real URL + API key and optionally probes `GET /api/system/stats`.
- `gorec doctor` flags sample Remnawave URLs, probes the API, checks DNS A → this server for webhook/cabinet, ports 80/443, Compose `.env`, Caddy `/uploads`, and notes `ADMIN_NOTIFICATIONS_CHAT_ID` (no invented chat ids; sample `-1001234567890` cleared).
- Webhook Caddy site uses `handle { reverse_proxy … }` so ACME http-01 on `/.well-known` is not specially stolen; certificate failures still do not block install (surfaced via doctor/logs).

### Changed
- `gorec apply` / `start` / `update` re-copy `compose.yaml`, refresh `.env` symlink, and re-render Caddyfile (keeps `/uploads/*` → bot on cabinet domain).
- Compose template uses safer defaults (`${BOT_ENV:-bot.env}`, `${DATA_ROOT:-.}`, …) when interpolation env is incomplete.

### Migration
- After `gorec self-update` to v1.5.0 run: `gorec apply` (recreates `/opt/gorec/.env`, refreshes Caddy). Then `cd /opt/gorec && docker compose ps` works without `--env-file`.
- If Remnawave still points at a foreign/sample host, fix via `gorec config wizard` or edit `bot.env`, then `gorec apply`.

## 1.4.2 — 2026-09-18

### Fixed
- Caddy on the cabinet domain now proxies `/uploads/*` to the bot (StaticFiles). Without this, raffle prize photos uploaded via the Mini App were stored as `https://cabinet…/uploads/…` and rendered as blank white cards because `/uploads` fell through to the SPA.

## 1.4.0 — 2026-09-18

### Changed
- Layout **opt-max**: конфиги, данные и бэкапы по умолчанию под `/opt/gorec` (больше нет defaults на `/etc/gorec` и `/var/lib/gorec`).
- Исходники Bot → `/opt/bot`, Cabinet → `/opt/cabinet` (не под `/opt/gorec/sources/`).
- `BACKUP_ROOT` по умолчанию `/opt/gorec/backups`; миграция переносит `/var/lib/gorec/backups` и `/var/lib/bedolaga/backups`.
- При install/update/doctor/start/apply выполняется миграция legacy-путей (gorec и bedolaga) без слепой перезаписи.

### Migration
- `/opt/gorec/sources/bot` → `/opt/bot`, `/opt/gorec/sources/cabinet` → `/opt/cabinet`
- `/etc/gorec/*` → `/opt/gorec/`, `/var/lib/gorec/*` → `/opt/gorec/`
- Остатки bedolaga (`/opt|/etc|/var/lib/bedolaga`, CLI) обнаруживаются и переносятся/предлагаются к удалению

## 1.3.0 — 2026-08-07

- При запуске `gorec` Manager автоматически проверяет последний стабильный GitHub Release и безопасно устанавливает новую версию.
- Перед обновлением отображаются текущая и новая версии, направление перехода и три коротких пункта из `CHANGELOG.md` целевого релиза.
- Автообновление устанавливает архив конкретного стабильного тега, проверяет Bash-синтаксис и запуск, а при ошибке сохраняет предыдущую рабочую версию.
- Сетевая ошибка проверки не блокирует управление сервисами; результат проверки кэшируется на один час, а `GOREC_AUTO_UPDATE=0` отключает её для выбранного запуска.
- Ручная команда `gorec self-update` переведена на стабильные Releases и поддерживает явный тег вида `vX.Y.Z`.
- Главное меню получило новый широкий баннер, компактные панели, более заметную навигацию и понятные названия действий.
- Добавлены изолированные тесты семантического сравнения версий, release notes, кэша и сценария автоматического обновления.

## 1.2.0 — 2026-08-06

- Добавлена опциональная установка Xray Checker и Xray Checker Status Page (`go-build`) из основного мастера.
- Добавлено отдельное меню `gorec xray` для установки, запуска, статуса, логов, обновления, отключения и удаления модуля.
- Реализована изолированная схема общей network namespace: обязательная upstream-связь через loopback работает без публикации портов 2112/8080/8081 на сервере.
- Status Page собирается из официальной ветки `go-build`, сохраняя поддержку AMD64 и ARM64 независимо от архитектуры готового GHCR-образа.
- Status Page автоматически публикуется через Caddy на отдельном HTTPS-домене.
- Добавлена настройка подписок, интервала проверок и опционального отдельного Telegram-бота Status Page.
- Диагностика, общий статус, логи и health checks теперь учитывают включённые Xray-сервисы.
- Постоянные данные Status Page включены в создание и восстановление резервных копий.
- Добавлена валидация URL подписок, домена, интервала, image references и запрет повторного использования токена основного GorecBot.

## 1.1.1 — 2026-08-05

- Исправлено добавление новых upstream-переменных в `.env`, сохранённый без завершающего перевода строки.
- Добавлен гарантированный автооткат исходников и пересборка предыдущих образов при ошибке запуска обновлённого стека.
- Перед заменой рабочей версии Manager установщик теперь проверяет синтаксис и пробный запуск загруженного архива.
- Усилена валидация вручную отредактированных значений `stack.env` и `bot.env`.
- Исправлена валидация одноуровневых часовых поясов, включая `UTC` и `GMT`.
- Добавлена команда `gorec config paths` для быстрого поиска конфигурационных файлов.
- Проверка SSH-порта теперь отклоняет значения вне диапазона `1–65535`, а UFW не изменяется до подтверждения пользователя.
- Имена бэкапов защищены от перезаписи при создании нескольких копий в одну секунду.
- Telegram Bot Token больше не передаётся через аргументы `curl` и не виден в списке процессов сервера.
- GitHub Actions переведены на актуальный `actions/checkout@v7`, а Release workflow дополнен UI- и платформенными тестами.

## 1.1.0 — 2026-08-05

- Добавлен единый терминальный UI-модуль `lib/ui.sh` с эмодзи, цветами, секциями и ASCII fallback.
- Полностью переработаны главное меню, выбор сервисов, `status`, `versions` и `doctor`.
- Добавлены этапы установки, индикаторы прогресса и итоговая карточка с адресами сервисов.
- Добавлена поддержка `NO_COLOR=1` и `GOREC_EMOJI=0|1|auto`.
- Добавлены отдельные UI-тесты в общую и платформенную CI-матрицу.

## 1.0.4 — 2026-08-05

- Добавлена нормализация несовместимых placeholder-значений опциональных числовых параметров upstream Bot.
- Сохранены корректные пользовательские числовые значения, включая отрицательные Telegram topic ID.
- Нормализация применяется при установке, запуске, применении конфигурации и обновлении Bot.
- При ошибке `docker compose up` Manager теперь выводит статусы и последние логи сервисов.

## 1.0.3 — 2026-08-05

- Исправлена потеря значений, введённых через интерактивный мастер конфигурации.
- Устранено перекрытие переменной вызывающего кода локальным буфером функций `read_tty` и `read_secret_tty`.
- Добавлен регрессионный тест обычного и скрытого ввода через псевдотерминал.

## 1.0.2 — 2026-08-05

- Добавлен выбор скрытого или видимого режима для ввода Telegram Bot Token и API key.
- Добавлено переключение на видимый режим без перезапуска мастера, если web-консоль блокирует вставку в скрытое поле.
- Видимый режим ограничен текущим запуском мастера и не записывает секреты в лог или историю команд.

## 1.0.1 — 2026-08-05

- Добавлена явная подсказка о скрытом вводе Telegram Bot Token и других секретов.
- После успешного чтения секретного поля установщик показывает безопасное подтверждение без вывода значения.

## 1.0.0 — 2026-08-05

- Полностью заменён монолитный повреждённый скрипт модульным Gorec Manager.
- Добавлен one-line bootstrap и постоянная команда `gorec`.
- Добавлена идемпотентная установка Bot, Cabinet, PostgreSQL, Redis и Caddy.
- Добавлен интерактивный мастер с валидацией и локальной генерацией секретов.
- Закрыты host-порты Bot, Cabinet, PostgreSQL и Redis.
- Добавлены health checks, `doctor`, статусы и логи.
- Добавлены pre-update backup, безопасные detached checkout и rollback.
- Добавлены целевые бэкапы, SHA-256, restore и systemd timer.
- Добавлены ShellCheck, smoke-тесты и Compose-проверка в CI.
