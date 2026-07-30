#!/usr/bin/env bash
#
# 00-hardening.sh — базовая подготовка любого узла (Debian 12 / Ubuntu 22.04+)
#
# Применяется НА ВСЕХ серверах до установки панели/нод.
#
#   sudo bash 00-hardening.sh --role node  --panel-ip 1.2.3.4 --ssh-port 22022
#   sudo bash 00-hardening.sh --role panel --ssh-port 22022
#   sudo bash 00-hardening.sh --role node  --panel-ip 1.2.3.4 --ru-entry --exit-ips "5.6.7.8"
#
# На сервере, где уже работает что-то своё (например x-ui) — режим сосуществования:
#   sudo bash 00-hardening.sh --role node --panel-ip 1.2.3.4 --exit-ips "5.6.7.8" \
#        --transit-port 8443 --no-fw-reset
#
set -euo pipefail

ROLE=""
PANEL_IP=""
SSH_PORT="22022"
RU_ENTRY=0
EXIT_IPS=""
NODE_PORT="2222"
TRANSIT_PORT="443"
NO_FW_RESET=0
DISABLE_IPV6=0

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)      ROLE="$2"; shift 2 ;;
    --panel-ip)  PANEL_IP="$2"; shift 2 ;;
    --ssh-port)  SSH_PORT="$2"; shift 2 ;;
    --node-port) NODE_PORT="$2"; shift 2 ;;
    --ru-entry)  RU_ENTRY=1; shift ;;
    --exit-ips)  EXIT_IPS="$2"; shift 2 ;;
    --transit-port) TRANSIT_PORT="$2"; shift 2 ;;
    --no-fw-reset)  NO_FW_RESET=1; shift ;;
    --disable-ipv6) DISABLE_IPV6=1; shift ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"
[[ -n "$ROLE" ]]  || die "Укажите --role node|panel"
[[ "$ROLE" == "node" && -z "$PANEL_IP" ]] && die "Для роли node нужен --panel-ip"

# ── Проверка SSH-ключа до того, как отключим пароли ────────────────────────
if [[ ! -s /root/.ssh/authorized_keys ]] && [[ -z "${SUDO_USER:-}" || ! -s "/home/${SUDO_USER:-nobody}/.ssh/authorized_keys" ]]; then
  die "Не найден authorized_keys. Сначала загрузите SSH-ключ, иначе потеряете доступ к серверу."
fi

# ── Система ────────────────────────────────────────────────────────────────
log "Обновление пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget ca-certificates gnupg lsb-release \
    ufw fail2ban unattended-upgrades \
    jq htop ncdu net-tools dnsutils chrony \
    qrencode socat cron

# ── Время: рассинхрон часов ломает TLS ─────────────────────────────────────
log "Синхронизация времени"
timedatectl set-timezone UTC
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd

# ── Ядро: BBR + fq, лимиты, антиспуф ───────────────────────────────────────
log "Тюнинг ядра (BBR, fq, буферы)"
cat > /etc/sysctl.d/99-xray-tuning.conf <<'EOF'
# Congestion control — заметно улучшает пропускную способность на длинных RTT
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Буферы под высокоскоростные соединения
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535

# TCP
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_syncookies = 1

# Форвардинг нужен для транзитной ноды
net.ipv4.ip_forward = 1

# Антиспуф
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 0

# Файловые дескрипторы
fs.file-max = 1000000
EOF

if [[ $DISABLE_IPV6 -eq 1 ]]; then
  cat >> /etc/sysctl.d/99-xray-tuning.conf <<'EOF'

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
fi

sysctl --system >/dev/null

if lsmod | grep -q tcp_bbr || sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  log "BBR активен"
else
  warn "BBR не активировался — проверьте, поддерживает ли ядро (нужно 4.9+)"
fi

log "Лимиты файловых дескрипторов"
cat > /etc/security/limits.d/99-xray.conf <<'EOF'
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1000000
EOF

# ── SSH ────────────────────────────────────────────────────────────────────
log "Настройка SSH (порт $SSH_PORT, только ключи)"
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOF
sshd -t || die "Конфиг sshd невалиден — изменения НЕ применены"
systemctl restart ssh 2>/dev/null || systemctl restart sshd
warn "SSH теперь на порту $SSH_PORT. НЕ ЗАКРЫВАЙТЕ текущую сессию, пока не проверите вход в новом окне."

# ── Firewall ───────────────────────────────────────────────────────────────
log "Настройка ufw"
if [[ $NO_FW_RESET -eq 1 ]]; then
  warn "Режим сосуществования (--no-fw-reset): ufw НЕ сбрасывается и default-policy не трогается."
  warn "На сервере уже что-то работает (например x-ui) — ниже только ДОБАВЛЯЮТСЯ нужные правила поверх текущих."
  if ! ufw status | grep -q '^Status: active'; then
    warn "ufw сейчас неактивен. Проверьте вручную перед включением: ufw status verbose, iptables -L -n."
  fi
else
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
fi
ufw allow "$SSH_PORT"/tcp comment 'SSH'

case "$ROLE" in
  panel)
    ufw allow 80/tcp  comment 'ACME'
    ufw allow 443/tcp comment 'Panel HTTPS'
    ;;
  node)
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel -> node'
    ufw allow 80/tcp comment 'ACME'
    if [[ $RU_ENTRY -eq 1 ]]; then
      # Входная нода: 443 открыт всему интернету — сюда идут клиенты
      ufw allow 443/tcp comment 'Client entry (Reality)'
      log "Роль: RU-ВХОД. Порт 443 открыт публично."
    else
      # Выходная нода: транзитный порт только с российской ноды.
      # По умолчанию 443, но при сосуществовании с уже занятым портом
      # (см. --no-fw-reset) укажите свободный через --transit-port.
      if [[ -n "$EXIT_IPS" ]]; then
        for ip in $EXIT_IPS; do
          ufw allow from "$ip" to any port "$TRANSIT_PORT" proto tcp comment 'Transit from RU gate'
        done
        log "Роль: ВЫХОД. Порт $TRANSIT_PORT открыт только для: $EXIT_IPS"
        [[ "$TRANSIT_PORT" != "443" ]] && warn "Транзитный порт нестандартный ($TRANSIT_PORT) — убедитесь, что xray-transit-outbound.json на RU-ноде и config-profile этой ноды в панели используют тот же порт (см. ARCHITECTURE.md)."
      else
        warn "Не указан --exit-ips: порт $TRANSIT_PORT НЕ открыт. Транзит работать не будет."
        warn "Добавьте вручную: ufw allow from <IP_RU_НОДЫ> to any port $TRANSIT_PORT proto tcp"
      fi
    fi
    ;;
  *) die "Неизвестная роль: $ROLE" ;;
esac

# КРИТИЧНО для белого IP: закрываем исходящий SMTP.
# Спам через ваш сервер = абузы = потеря адреса из белых списков.
log "Блокировка исходящего SMTP (защита от спам-абуз)"
ufw deny out 25/tcp  comment 'no outbound SMTP'
ufw deny out 465/tcp comment 'no outbound SMTP'
ufw deny out 587/tcp comment 'no outbound SMTP'

ufw --force enable
ufw status verbose

# ── Лимит одновременных подключений с одного IP ────────────────────────────
if [[ "$ROLE" == "node" && $RU_ENTRY -eq 1 ]]; then
  log "Лимит соединений с одного клиентского IP"
  cat > /etc/ufw/before.rules.connlimit <<'EOF'
# Вставьте в /etc/ufw/before.rules перед COMMIT, в таблицу *filter:
# -A ufw-before-input -p tcp --dport 443 -m connlimit --connlimit-above 64 --connlimit-mask 32 -j DROP
EOF
  warn "Шаблон connlimit сохранён в /etc/ufw/before.rules.connlimit — примените вручную после проверки."
fi

# ── fail2ban ───────────────────────────────────────────────────────────────
log "Настройка fail2ban"
if [[ $NO_FW_RESET -eq 1 && -f /etc/fail2ban/jail.local ]]; then
  cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak-$(date +%s)"
  warn "/etc/fail2ban/jail.local уже существовал — сохранён бэкап рядом перед перезаписью"
fi
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 4
backend  = systemd
ignoreip = 127.0.0.1/8 ::1 ${PANEL_IP}

[sshd]
enabled = true
port    = $SSH_PORT
EOF
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban

# ── Автообновления безопасности ────────────────────────────────────────────
log "Включение автообновлений безопасности"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ── Docker ─────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "Установка Docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  log "Docker уже установлен"
fi

# ── Swap (если нет) ────────────────────────────────────────────────────────
if [[ $(swapon --show | wc -l) -eq 0 ]]; then
  log "Создание swap 2G"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  echo 'vm.swappiness = 10' >> /etc/sysctl.d/99-xray-tuning.conf
fi

# ── Итог ───────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════════════════════════
  Подготовка завершена. Роль: $ROLE
════════════════════════════════════════════════════════════════
  SSH порт        : $SSH_PORT  (только по ключу)
  Firewall        : ufw активен$([[ $NO_FW_RESET -eq 1 ]] && echo ' (режим сосуществования: default-policy не менялась)')
  Транзитный порт : $TRANSIT_PORT
  Congestion ctrl : $(sysctl -n net.ipv4.tcp_congestion_control)
  Docker          : $(docker --version 2>/dev/null || echo 'не установлен')
  Исходящий SMTP  : заблокирован

  ПРОВЕРЬТЕ ВХОД В НОВОМ ОКНЕ, прежде чем закрыть текущую сессию:
     ssh -p $SSH_PORT root@<этот-сервер>

  Дальше:
    панель  → 10-panel-install.sh
    нода    → 20-node-install.sh
    RU-вход → 20-node-install.sh, затем 30-selfsteal.sh
════════════════════════════════════════════════════════════════
EOF
