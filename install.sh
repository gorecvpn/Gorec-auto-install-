#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

REPOSITORY="${GOREC_REPOSITORY:-gorecvpn/Gorec-auto-install-}"
REF="${GOREC_REF:-main}"
MANAGER_HOME="${GOREC_MANAGER_HOME:-/usr/local/lib/gorec-manager}"
COMMAND_PATH="${GOREC_COMMAND_PATH:-/usr/local/bin/gorec}"
RUN_WIZARD=1

for argument in "$@"; do
  case "$argument" in
    --no-wizard) RUN_WIZARD=0 ;;
    --help | -h)
      printf 'Использование: install.sh [--no-wizard]\n'
      exit 0
      ;;
    *) printf 'Неизвестный аргумент: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { printf 'Запустите установщик от root или через sudo.\n' >&2; exit 1; }
case "$MANAGER_HOME" in /usr/local/lib/gorec-manager) ;; *) printf 'Небезопасный путь MANAGER_HOME: %s\n' "$MANAGER_HOME" >&2; exit 1 ;; esac
case "$COMMAND_PATH" in /usr/local/bin/gorec) ;; *) printf 'Небезопасный путь COMMAND_PATH: %s\n' "$COMMAND_PATH" >&2; exit 1 ;; esac

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates tar gzip
fi

temporary_root="$(mktemp -d)"
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT

archive="$temporary_root/manager.tar.gz"
if [[ -n "${GOREC_ARCHIVE_URL:-}" ]]; then
  archive_url="$GOREC_ARCHIVE_URL"
elif [[ "$REF" == v[0-9]* ]]; then
  archive_url="https://github.com/${REPOSITORY}/archive/refs/tags/${REF}.tar.gz"
else
  archive_url="https://github.com/${REPOSITORY}/archive/refs/heads/${REF}.tar.gz"
fi
printf 'Загружаю Gorec Manager (%s)...\n' "$REF"
curl -fsSL --retry 3 --connect-timeout 15 "$archive_url" -o "$archive"
if [[ -n "${GOREC_ARCHIVE_SHA256:-}" ]]; then
  printf '%s  %s\n' "$GOREC_ARCHIVE_SHA256" "$archive" | sha256sum -c -
fi
tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))' && { printf 'Архив содержит небезопасные пути.\n' >&2; exit 1; }
tar -xzf "$archive" -C "$temporary_root"

source_root="$(find "$temporary_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -x "$source_root/gorec" || -f "$source_root/gorec" ]] || { printf 'В архиве отсутствует gorec.\n' >&2; exit 1; }
[[ -f "$source_root/lib/common.sh" && -f "$source_root/lib/ui.sh" && -f "$source_root/lib/xray.sh" \
  && -f "$source_root/templates/compose.yaml" && -f "$source_root/templates/Caddyfile.xray.tmpl" ]] || {
  printf 'Архив Manager неполный.\n' >&2
  exit 1
}
if ! bash -n "$source_root/gorec" "$source_root/install.sh" "$source_root"/lib/*.sh; then
  printf 'Архив Manager содержит синтаксически некорректные скрипты.\n' >&2
  exit 1
fi

staging="/usr/local/lib/.gorec-manager.new.$$"
previous="/usr/local/lib/gorec-manager.previous"
mkdir -p "$staging"
cp -a "$source_root/." "$staging/"
chmod 755 "$staging/gorec" "$staging/install.sh"
find "$staging/lib" -type f -name '*.sh' -exec chmod 644 {} +

rm -rf -- "$previous"
if [[ -d "$MANAGER_HOME" ]]; then
  mv "$MANAGER_HOME" "$previous"
fi
if ! mv "$staging" "$MANAGER_HOME"; then
  [[ -d "$previous" ]] && mv "$previous" "$MANAGER_HOME"
  printf 'Не удалось установить Manager. Предыдущая версия восстановлена.\n' >&2
  exit 1
fi
if ! "$MANAGER_HOME/gorec" version >/dev/null 2>&1 || ! ln -sfn "$MANAGER_HOME/gorec" "$COMMAND_PATH"; then
  rm -rf -- "$MANAGER_HOME"
  if [[ -d "$previous" ]]; then
    mv "$previous" "$MANAGER_HOME"
  else
    rm -f -- "$COMMAND_PATH"
  fi
  printf 'Новая версия Manager не прошла проверку запуска. Предыдущая версия восстановлена.\n' >&2
  exit 1
fi

printf 'Gorec Manager установлен: %s\n' "$COMMAND_PATH"
if [[ "${GOREC_NO_WIZARD:-0}" != 1 && "$RUN_WIZARD" -eq 1 ]]; then
  exec "$COMMAND_PATH" install
fi
printf 'Запуск: sudo gorec menu\n'
