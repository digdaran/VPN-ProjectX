#!/usr/bin/env bash
#
# deploy.sh — оркестратор развёртывания по SSH поверх существующих скриптов
# 00-hardening.sh / 10-panel-install.sh / 20-node-install.sh / 30-selfsteal.sh.
#
# Ничего нового не устанавливает сам — на каждом сервере из инвентаря просто
# прогоняет по SSH те же шаги, что описаны в README §5, с нужными для роли
# флагами. Сами скрипты никуда не копируются: содержимое передаётся в stdin
# удалённого bash (как и одиночный запуск через curl | bash, только без curl).
#
# Осознанно НЕ автоматизирует:
#   - смену SSH-порта "на лету" — если хотите её сделать, это отдельный ручной
#     шаг с проверкой входа в новом окне (см. README §5.1); подключение к
#     удалённому серверу происходит на порт из инвентаря, и remote script
#     получает тот же порт через --ssh-port — то есть 00-hardening.sh только
#     закрепляет текущий порт, не переезжает на новый;
#   - шаги в UI панели (создание суперадмина, Nodes → Management → +,
#     копирование docker-compose.yml/SSL_CERT, назначение config-profile) —
#     их через недоверенный канал автоматизировать дороже, чем сделать руками;
#   - scripts/40-keygen.sh, scripts/50-preflight.sh, scripts/60-entry-test.sh,
#     scripts/90-healthcheck.sh — идут отдельными шагами после (см. вывод
#     в конце и README §5).
#
# Формат инвентаря — scripts/deploy.conf.example.
#
#   bash deploy.sh --inventory deploy.conf --dry-run     # сначала так
#   bash deploy.sh --inventory deploy.conf --only ru-1   # один сервер
#   bash deploy.sh --inventory deploy.conf --yes         # без подтверждения
#
set -euo pipefail

INVENTORY="deploy.conf"
ONLY=""
DRY_RUN=0
ASSUME_YES=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) INVENTORY="$2"; shift 2 ;;
    --only)      ONLY="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yes)       ASSUME_YES=1; shift ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ -f "$INVENTORY" ]] || die "Не найден инвентарь: $INVENTORY (шаблон — scripts/deploy.conf.example)"

# extra "k1=v1;k2=v2" -> значение по ключу, или дефолт вторым аргументом.
extra_get() {
  local extra="$1" key="$2" default="${3:-}" pair
  local -a pairs
  IFS=';' read -ra pairs <<< "$extra"
  for pair in "${pairs[@]}"; do
    [[ "$pair" == "$key="* ]] && { echo "${pair#*=}"; return 0; }
  done
  echo "$default"
}

# Прогоняет локальный скрипт на удалённом хосте: содержимое — в stdin,
# аргументы — как позиционные параметры удалённого bash. На диске у сервера
# ничего не остаётся. Аргументы не должны содержать пробелов/спецсимволов
# shell — ssh склеивает их в одну командную строку на удалённой стороне.
remote_run() {
  local user="$1" host="$2" port="$3" script="$4"; shift 4
  local -a args=("$@")
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] ssh -p $port $user@$host 'sudo bash -s' -- ${args[*]:-} < $(basename "$script")"
    return 0
  fi
  ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" \
      "sudo bash -s" -- "${args[@]}" < "$script"
}

deploy_panel() {
  local name="$1" host="$2" user="$3" port="$4" extra="$5"
  local domain sub_domain email
  domain="$(extra_get "$extra" domain)"
  sub_domain="$(extra_get "$extra" sub_domain "$domain")"
  email="$(extra_get "$extra" email)"
  [[ -n "$domain" && -n "$email" ]] || die "[$name] нужны domain и email в extra"

  log "[$name] панель — hardening"
  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/00-hardening.sh" \
    --role panel --ssh-port "$port"

  log "[$name] панель — установка Remnawave"
  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/10-panel-install.sh" \
    --domain "$domain" --sub-domain "$sub_domain" --email "$email"

  warn "[$name] РУЧНОЙ шаг: откройте https://$domain и СРАЗУ создайте суперадмина (регистрация открыта до первого админа)"
}

deploy_ru_entry() {
  local name="$1" host="$2" user="$3" port="$4" extra="$5"
  local panel_ip domain email node_port
  panel_ip="$(extra_get "$extra" panel_ip)"
  domain="$(extra_get "$extra" domain)"
  email="$(extra_get "$extra" email)"
  node_port="$(extra_get "$extra" node_port 2222)"
  [[ -n "$panel_ip" && -n "$domain" && -n "$email" ]] || die "[$name] нужны panel_ip, domain и email в extra"

  log "[$name] RU-вход — hardening (443 публичный)"
  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/00-hardening.sh" \
    --role node --panel-ip "$panel_ip" --ssh-port "$port" --node-port "$node_port" --ru-entry

  log "[$name] RU-вход — self-steal (nginx + Let's Encrypt)"
  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/30-selfsteal.sh" \
    --domain "$domain" --email "$email"
  warn "[$name] РУЧНОЙ шаг: замените шаблонный контент /var/www/selfsteal на $host на что-то уникальное"

  log "[$name] RU-вход — установка Remnanode"
  warn "[$name] РУЧНОЙ шаг ПЕРЕД этим: Nodes → Management → + в панели, скопировать docker-compose.yml"
  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/20-node-install.sh" \
    --panel-ip "$panel_ip" --node-port "$node_port"
  warn "[$name] РУЧНОЙ шаг: вставьте SSL_CERT из панели в /opt/remnanode/.env на $host, затем docker compose up -d"
}

# mode: exit-fresh | exit-coexist
deploy_exit() {
  local mode="$1" name="$2" host="$3" user="$4" port="$5" extra="$6"
  local panel_ip ru_ip node_port transit_port
  local -a fw_flag=()
  panel_ip="$(extra_get "$extra" panel_ip)"
  ru_ip="$(extra_get "$extra" ru_ip)"
  node_port="$(extra_get "$extra" node_port 2222)"
  transit_port="$(extra_get "$extra" transit_port 443)"
  [[ -n "$panel_ip" && -n "$ru_ip" ]] || die "[$name] нужны panel_ip и ru_ip в extra"

  if [[ "$mode" == "exit-coexist" ]]; then
    [[ "$transit_port" == "443" ]] && warn "[$name] сосуществование, но transit_port=443 — обычно этот порт уже занят x-ui; проверьте 'ss -tlnp' на сервере перед запуском"
    fw_flag=(--no-fw-reset)
    log "[$name] выход (сосуществование с уже работающим сервисом) — hardening без сброса firewall, транзит на порту $transit_port"
  else
    log "[$name] выход (чистый сервер) — hardening"
  fi

  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/00-hardening.sh" \
    --role node --panel-ip "$panel_ip" --ssh-port "$port" --node-port "$node_port" \
    --exit-ips "$ru_ip" --transit-port "$transit_port" "${fw_flag[@]}"

  log "[$name] выход — установка Remnanode"
  warn "[$name] РУЧНОЙ шаг ПЕРЕД этим: Nodes → Management → + в панели, скопировать docker-compose.yml"
  remote_run "$user" "$host" "$port" "$SCRIPT_DIR/20-node-install.sh" \
    --panel-ip "$panel_ip" --node-port "$node_port"
  warn "[$name] РУЧНОЙ шаг: вставьте SSL_CERT из панели в /opt/remnanode/.env на $host, затем docker compose up -d"

  if [[ "$mode" == "exit-coexist" ]]; then
    warn "[$name] Config-profile этой ноды в панели должен использовать xray-exit-node.json с inbound transit-in на порту $transit_port — сверьте с соответствующим out-* в xray-transit-outbound.json на RU-ноде (ARCHITECTURE.md, DECISIONS.md ADR-0014) и прогоните scripts/50-preflight.sh перед выкаткой"
  fi
}

# ── Подтверждение ────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  echo "Это внесёт реальные изменения (firewall, пакеты, Docker) на серверах из $INVENTORY."
  read -r -p "Продолжить? [yes/N] " reply
  [[ "$reply" == "yes" ]] || die "Отменено"
fi

# ── Основной цикл ────────────────────────────────────────────────────────
count=0
while IFS='|' read -r name role host user port extra; do
  [[ -z "$name" ]] && continue
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  count=$((count + 1))

  case "$role" in
    panel)        deploy_panel        "$name" "$host" "$user" "$port" "$extra" ;;
    ru-entry)     deploy_ru_entry     "$name" "$host" "$user" "$port" "$extra" ;;
    exit-fresh)   deploy_exit exit-fresh   "$name" "$host" "$user" "$port" "$extra" ;;
    exit-coexist) deploy_exit exit-coexist "$name" "$host" "$user" "$port" "$extra" ;;
    *) bad "[$name] неизвестная роль '$role' — пропущено"; continue ;;
  esac
  echo
done < <(grep -vE '^\s*(#|$)' "$INVENTORY")

[[ $count -gt 0 ]] || die "В инвентаре не нашлось подходящих строк (проверьте --only и формат файла)"

cat <<'EOF'
════════════════════════════════════════════════════════════════
Готово (или показано выше, если --dry-run). Дальше — вручную:
  1. Создать суперадмина панели, если ещё не сделали
  2. В панели: Nodes → добавить ноды (если не сделали до 20-node-install.sh),
     применить конфиги из configs/ready/ через config-profile
     (для exit-coexist — конфиг с портом transit_port из инвентаря)
  3. bash scripts/40-keygen.sh --name <нода> --sni <донор> [--port <порт>]
  4. bash scripts/50-preflight.sh — перед тем как применять конфиги в панели
  5. bash scripts/60-entry-test.sh --hosts "..." — ИЗ РОССИИ, не с сервера
  6. Настроить scripts/90-healthcheck.sh по cron (см. README §9)
════════════════════════════════════════════════════════════════
EOF
