# Настройка ноды на Alpine Linux

Скрипты `00-hardening.sh` / `20-node-install.sh` / `30-selfsteal.sh` писаны под
Debian/Ubuntu (`apt`, `ufw`, `systemd`) и **не отработают** на Alpine без
адаптации — Alpine использует `apk`, OpenRC вместо systemd, и без `ufw`
(только `iptables`/`nftables` напрямую или `awall`). Этот документ — то же
самое по смыслу, что и `00→20(→30)`-конвейер, но пошагово руками под Alpine.

Проверено дважды в этом проекте (переустановка ru-entry и exit-ноды Finland)
— все команды ниже реально отработали на Alpine 3.24.

---

## 0. До того как закрыть консоль хостинга

Убедитесь, что в `/root/.ssh/authorized_keys` уже лежит ваш публичный ключ
(или сможете добавить его через консоль провайдера). Переустановка ОС стирает
и его тоже — если полагаться только на пароль, легко потерять доступ.

---

## 1. Базовые пакеты

Community-репозиторий на свежем Alpine иногда закомментирован — проверьте и
включите при необходимости:

```bash
cat /etc/apk/repositories
# если community закомментирован:
sed -i 's|^#\(.*community\)|\1|' /etc/apk/repositories

apk update
apk upgrade --available
```

Базовый набор (без firewall/fail2ban — см. §6):

```bash
apk add bash curl wget ca-certificates jq htop ncdu bind-tools chrony \
        libqrencode-tools socat dcron docker docker-cli-compose
```

Название пакета `libqrencode-tools`, не `qrencode` (в Alpine CLI-утилита
отдельно от библиотеки — `apk search qrencode`, если название снова
разойдётся с ожиданием).

Только для **RU-входа** (self-steal) дополнительно:

```bash
apk add nginx certbot
```

---

## 2. Сервисы через OpenRC

Alpine не использует systemd — `systemctl enable --now X` не работает,
вместо этого:

```bash
rc-update add docker default   && rc-service docker start
rc-update add chronyd default  && rc-service chronyd start
rc-update add dcron default    && rc-service dcron start
```

Timezone на свежем Alpine обычно уже UTC (`/etc/localtime` — симлинк на
`/etc/zoneinfo/UTC`) — отдельно менять не нужно, но стоит проверить `date -u`.

Проверить синхронизацию времени: `chronyc tracking` (рассинхрон часов ломает
TLS/Reality).

---

## 3. sysctl-тюнинг (BBR, буферы)

Тот же файл, что и в `00-hardening.sh`, применяется идентично:

```bash
cat > /etc/sysctl.d/99-xray-tuning.conf << "EOF"
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_syncookies = 1

net.ipv4.ip_forward = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 0

fs.file-max = 1000000
vm.swappiness = 10
EOF
sysctl -p /etc/sysctl.d/99-xray-tuning.conf

# Проверка, что ядро реально поддерживает BBR:
sysctl net.ipv4.tcp_congestion_control   # должно быть "bbr"
lsmod | grep bbr
```

Сервис `sysctl` у Alpine обычно уже в runlevel `boot` (`rc-status boot`) —
настройка переживёт перезагрузку сама, отдельно включать не нужно.

Swap — часто уже есть на VPS-образе (`free -h`, смотреть Swap). Если нет:

```bash
[ "$(swapon -s 2>/dev/null | wc -l)" -le 1 ] && {
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
}
```

---

## 4. Лимиты файловых дескрипторов

Alpine **без PAM** — `/etc/security/limits.d/` не существует и не будет
прочитан, даже если создать файл руками. Лимит нужно задавать иначе, двумя
способами сразу:

```bash
# 1. Общий системный потолок (влияет и на docker-демон)
if grep -q '^#rc_ulimit' /etc/rc.conf; then
  sed -i 's|^#rc_ulimit=.*|rc_ulimit="-n 1000000"|' /etc/rc.conf
elif grep -q '^rc_ulimit' /etc/rc.conf; then
  sed -i 's|^rc_ulimit=.*|rc_ulimit="-n 1000000"|' /etc/rc.conf
else
  echo 'rc_ulimit="-n 1000000"' >> /etc/rc.conf
fi

# 2. Явный лимит для контейнеров по умолчанию
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << "EOF"
{
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1000000, "Soft": 1000000 }
  }
}
EOF
rc-service docker restart
```

---

## 5. Remnanode

Каталог, `docker-compose.yml` и `.env` — идентичны тому, что генерирует
`20-node-install.sh` для Debian (эта часть не зависит от дистрибутива):

```bash
mkdir -p /opt/remnanode/xray-assets
cd /opt/remnanode

cat > docker-compose.yml << "EOF"
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    env_file: .env
    volumes:
      - ./xray-assets:/usr/local/share/xray
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
EOF

cat > .env << "EOF"
NODE_PORT=2222
SECRET_KEY=PASTE_SECRET_KEY_FROM_PANEL_HERE
EOF
chmod 600 .env

for f in geoip.dat geosite.dat; do
  curl -fsSL -o "xray-assets/$f" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f"
done
```

Cron на еженедельное обновление geoip/geosite (`crontab` того же синтаксиса,
что и в Debian-версии — `dcron` его понимает):

```bash
cat > /usr/local/bin/update-xray-assets.sh << "EOF"
#!/bin/bash
set -e
DIR=/opt/remnanode
for f in geoip.dat geosite.dat; do
  curl -fsSL -o "$DIR/xray-assets/$f.new" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" &&
  mv "$DIR/xray-assets/$f.new" "$DIR/xray-assets/$f"
done
docker restart remnanode
EOF
chmod +x /usr/local/bin/update-xray-assets.sh
( crontab -l 2>/dev/null | grep -v update-xray-assets; \
  echo "31 3 * * 1 /usr/local/bin/update-xray-assets.sh >> /var/log/xray-assets.log 2>&1" ) | crontab -
```

**SECRET_KEY** берётся только из панели, отдельного поля под него в UI нет:
Nodes → создайте/выберите ноду → **«Copy docker-compose.yml»** → возьмите
оттуда только значение `SECRET_KEY`, вставьте в `.env` вместо плейсхолдера.

```bash
cd /opt/remnanode && docker compose up -d
docker compose logs -f   # проверить, что "XRay Core ... is up and running"
```

Проверка со стороны панели: Nodes → нода должна показать `isConnected: true`
в течение нескольких секунд.

---

## 6. Firewall (опционально, не по умолчанию)

В этом проекте firewall на Alpine-нодах сознательно не настраивался — ufw
для Alpine не существует, штатная замена — `iptables` напрямую или `awall`
(YAML-обёртка над nftables, специфичная для Alpine). Если понадобится позже:

```bash
apk add awall
# правила писать в /etc/awall/optional/*.json, затем:
# awall enable <profile> && awall activate
```

Пока firewall не настроен, все открытые Xray-портами порты доступны без
ограничений — держите это в уме при добавлении новых inbound'ов (см.
ARCHITECTURE.md §4, §10).

---

## 7. Только для роли RU-входа: self-steal

Если новая нода — точка входа для клиентов (не просто выходная), то
дополнительно нужен self-steal (ADR-0003) — nginx на `127.0.0.1:8443` с
настоящим сертификатом:

```bash
rm -f /etc/nginx/http.d/default.conf
mkdir -p /var/www/selfsteal /var/www/certbot /run/nginx
rc-update add nginx default && rc-service nginx start

# временный ACME-конфиг → certbot certonly --webroot → боевой конфиг
# (полная последовательность — см. scripts/30-selfsteal.sh, синтаксис nginx
# идентичен, отличаются только пути: /etc/nginx/http.d/*.conf вместо
# sites-available/sites-enabled, и rc-service nginx reload вместо systemctl)
```

Ключевые отличия от Debian-версии `30-selfsteal.sh`:
- Конфиг кладётся прямо в `/etc/nginx/http.d/имя.conf` — отдельного
  `sites-enabled`-механизма в Alpine нет, файл с расширением `.conf` в
  `http.d` уже подключён автоматически (`include` в `/etc/nginx/nginx.conf`).
- `ssl_session_cache shared:SSL:2m;` уже объявлен в базовом `nginx.conf`
  Alpine — если в своём server-блоке используете `ssl_session_cache`, имя
  зоны должно **отличаться** (`shared:selfsteal_ssl:10m`), иначе конфликт
  размеров зоны и `nginx -t` падает.
- `listen ... ssl http2;` — на nginx 1.30 (текущая версия в Alpine 3.24)
  это уже deprecated-синтаксис (warning, не ошибка) — рабочий вариант:
  `listen ... ssl;` + отдельная строка `http2 on;`.
- Автообновление сертификата — через cron (`certbot.timer` из systemd нет):
  ```bash
  echo "17 3 * * * certbot renew --quiet >> /var/log/letsencrypt-renew.log 2>&1" \
    | crontab -
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << "EOF"
  #!/bin/sh
  rc-service nginx reload
  EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  ```

---

## 8. Reality-ключи

Генерируются так же, как на Debian — через сам образ ноды:

```bash
docker exec remnanode xray x25519
```

Полученный `privateKey` идёт в соответствующий inbound config-профиля в
панели (через API или UI), `publicKey` — клиентам (в Host панели он либо
хранится явно, либо панель вычисляет его на лету из `privateKey`, в
зависимости от типа inbound — см. ARCHITECTURE.md §10 для устройства
inbound'ов transit/client/raw на выходных нодах).

---

## 9. После установки

- Обновите `scripts/deploy.conf` (не в git, но держите актуальным) — пометьте
  узел как Alpine, чтобы не пытаться прогнать по нему `00-hardening.sh`/
  `20-node-install.sh` как есть.
- `scripts/50-preflight.sh` и `scripts/90-healthcheck.sh` работают как обычно
  — они бьют по панели/сети, а не по локальной ОС ноды, дистрибутив для них
  не важен.
