# Этап 3 — Точный перечень данных, команд и имен файлов

## Принцип
Диагностика должна быть **полной**, даже если `ssclash` — лишь частичный фактор.
Поэтому собираем:
1. полный baseline системы;
2. полный runtime-снимок сети/маршрутизации/fw;
3. отдельные маркеры того, что обычно трогают скрипты уровня `clash-rules`.

## 1) Дерево артефактов

```text
${OUT_DIR}/${SESSION_ID}/
  ├─ 00_static/
  ├─ 10_mode_Clash_OFF/
  ├─ 11_mode_Clash_ON/
  └─ meta/
```

`SESSION_ID` формат: `YYYYmmdd-HHMMSS_<hostname>`.

---

## 2) Статические файлы (`00_static/`, снимаются один раз)

### 2.1 Система и платформа
- `01_system_baseline.log`
  - `date -Iseconds`
  - `uname -a`
  - `cat /etc/openwrt_release`
  - `cat /etc/os-release`
  - `ubus call system board`
  - `uptime`
  - `cat /proc/cpuinfo`
  - `free -h`
  - `df -h`

### 2.2 Пакеты и бинарники
- `02_packages_and_binaries.log`
  - `command -v opkg || true`
  - `command -v apk || true`
  - `opkg list-installed` (если `opkg`)
  - `apk info -vv` (если `apk`)
  - `which nft ip iptables ip6tables fw4 tailscale mihomo clash dnsmasq logread ubus uci`

### 2.3 Модули ядра и netfilter
- `03_kernel_modules.log`
  - `lsmod`
  - `modinfo nft_tproxy 2>/dev/null || true`
  - `modinfo nf_tproxy_ipv4 2>/dev/null || true`
  - `modinfo nf_tproxy_ipv6 2>/dev/null || true`
  - `modinfo nft_socket 2>/dev/null || true`

### 2.4 Постоянные конфиги UCI
- `04_uci_network_firewall_dhcp_system.log`
  - `uci export network`
  - `uci export firewall`
  - `uci export dhcp`
  - `uci export system`

### 2.5 Конфиги сервисов
- `05_service_configs.log`
  - `cat /etc/config/tailscale 2>/dev/null`
  - `cat /etc/config/mihomo 2>/dev/null`
  - `cat /etc/config/openclash 2>/dev/null`
  - `cat /etc/config/passwall 2>/dev/null`
  - `cat /etc/config/passwall2 2>/dev/null`

### 2.6 Автозапуск и init
- `06_init_and_startup.log`
  - `ls -l /etc/init.d`
  - `for s in tailscale mihomo openclash; do /etc/init.d/$s enabled 2>/dev/null; done`
  - `cat /etc/rc.local 2>/dev/null`

---

## 3) Режимные файлы (`10_mode_Clash_OFF/` и `11_mode_Clash_ON/`)

### 3.1 Интерфейсы и адреса
- `11_interfaces_runtime.log`
  - `ip -br link`
  - `ip -br addr`
  - `ip -d link`
  - `ubus call network.interface dump`

### 3.2 Маршрутизация и policy routing
- `12_routing_runtime.log`
  - `ip route show table main`
  - `ip route show table all`
  - `ip rule show`
  - `ip -6 route show table all`
  - `ip -6 rule show`

### 3.3 Firewall4 + nftables
- `13_fw4_nft_runtime.log`
  - `fw4 print`
  - `nft list ruleset`
  - `nft list tables`
  - `nft -a list ruleset`  # c handle/counter

### 3.4 iptables compatibility/legacy audit
- `14_iptables_compat_audit.log`
  - `iptables -V 2>&1`
  - `ip6tables -V 2>&1`
  - `iptables-save 2>&1`
  - `ip6tables-save 2>&1`
  - `ls -l /usr/sbin/iptables /usr/sbin/ip6tables 2>/dev/null`

### 3.5 DNS и резолвинг
- `15_dns_runtime.log`
  - `cat /tmp/resolv.conf 2>/dev/null`
  - `cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null`
  - `uci export dhcp`
  - `logread | tail -n 300 | grep -Ei 'dns|resolve|dnsmasq|servfail|timeout'`
  - `nslookup openwrt.org 127.0.0.1 2>&1 || true`

### 3.6 Clash/Mihomo/Tailscale runtime
- `16_clash_tailscale_runtime.log`
  - `ps w | grep -Ei 'mihomo|clash|tailscale|tun|tproxy'`
  - `ss -lntup`
  - `tailscale status 2>&1 || true`
  - `tailscale ip -4 2>&1 || true`
  - `tailscale netcheck 2>&1 || true`

### 3.7 Sysctl (сетевые ключи)
- `17_sysctl_network_runtime.log`
  - `sysctl net.ipv4.ip_forward`
  - `sysctl net.ipv6.conf.all.forwarding`
  - `sysctl net.ipv4.conf.all.rp_filter`
  - `sysctl net.ipv4.conf.default.rp_filter`
  - `sysctl net.netfilter.nf_conntrack_max 2>/dev/null`

### 3.8 Диагностические логи ядра/системы
- `18_logs_filtered.log`
  - `logread | tail -n 800`
  - `dmesg | tail -n 300`
  - `logread | grep -Ei 'nft|fw4|tproxy|tailscale|dns|drop|reject|conntrack' | tail -n 500`

### 3.9 Мини-проверка связности из роутера
- `19_router_connectivity.log`
  - `ping -c 3 1.1.1.1`
  - `ping -c 3 8.8.8.8`
  - `nslookup openwrt.org 1.1.1.1 2>&1 || true`

---

## 4) `meta/` файлы

- `90_manifest.log`
  - session_id, mode, hostname, timestamp, версия скрипта, exit codes секций.
- `91_errors.log`
  - stderr команд, которых не удалось выполнить.
- `92_recommendations.log`
  - отсутствующие утилиты/модули и рекомендации по доустановке.
- `93_collection_matrix.csv`
  - матрица `file, command, status, duration_ms`.

---

## 5) Требования к формату каждого файла

Каждый файл должен иметь повторяемые блоки:

```text
===== BEGIN COMMAND =====
CMD: <команда>
TIME: <ISO8601>
RC: <код возврата>
----- STDOUT -----
...
----- STDERR -----
...
===== END COMMAND =====
```

Это упростит автоматический парсинг LLM и `diff` между ON/OFF.

---

## 6) Что добавлено с учётом `ssclash` (без анализа багов)

Даже без детального разбора скриптов, в сбор включены ключевые зоны, которые обычно затрагивают `clash-rules`:
- nft таблицы/цепочки/priority/mark;
- policy routing (`ip rule`, `table all`);
- DNS hijack и dnsmasq-поведение;
- sysctl (`forwarding`, `rp_filter`);
- процессы/порты `clash`/`mihomo`/`tailscale`;
- presence-check модулей `tproxy`/`socket`.

Важно: этот список **дополняет**, а не ограничивает полную диагностику.

---

## 7) Что будет на Этапе 4

Этап 4 формализует поведение при ошибках:
- мало места в `/tmp`;
- отсутствуют утилиты;
- нет доступа к отдельным командам;
- частично повреждённые/пустые конфиги.

---

## 8) Привязка к `ssclash` через «следы изменений» (без дебага логики)

Чтобы учитывать реальные действия `clash-rules`, в `owrt-diag.sh` добавляется дополнительный отчёт:

- `meta/94_ssclash_touchpoints.log`
  - вход: 1..N файлов `clash-rules*.sh` (если переданы локально через `--ssclash-file`);
  - извлечение только «что трогается», а не «почему так сделано».

Что извлекаем из скриптов (pattern-based):
- команды `uci set|add|del|commit` + какие секции/опции;
- команды `nft` (table/chain/rule/set/flush/delete/add);
- команды `ip rule`, `ip route`, `ip -6 rule/route`;
- вызовы `iptables/ip6tables` и тип таблиц/цепочек;
- изменения `sysctl`;
- управление сервисами (`/etc/init.d/*`, `service`, `procd`, `ubus call service`).

Практический смысл:
1. Полная диагностика остаётся неизменной (основной набор файлов из разделов 2–4).
2. `94_ssclash_touchpoints.log` только подсвечивает «куда смотреть в первую очередь».
3. Если скрипт недоступен, диагностика всё равно полностью валидна.

### 8.1 Наблюдаемые touchpoints из предоставленных `clash-rules` (3.6.0/3.7.0)

По структуре скриптов добавляем обязательные проверки в диагностику:
- **fwmark значения**: `0x0001`, `0x0002`, `0x0003`, `0xff00/0xff00`;
- **policy routing таблицы**: `table 100` (local `lo`) и `table 101` (`clash-tun` в mixed/tun);
- **интерфейс**: `clash-tun` (наличие, route replace в table 101);
- **iptables mangle/filter цепочки**: `CLASH_PROCESS`, `CLASH_LOCAL`, QUIC-блок (`udp/443` REJECT);
- **TPROXY порт**: `7894`, плюс исключения диапазона `7890:7894`;
- **ipset для fake-ip whitelist**: `clash_fakeip_whitelist`;
- **файлы состояния**: `/opt/clash/settings`, `/opt/clash/config.yaml`, `/opt/clash/lst/fakeip-whitelist-ipcidr.txt`, `/tmp/clash/clash_subscription_ips.cache`.

### 8.2 Дополнение к командам Stage 3 (обязательные)

Добавить в режимные файлы:
- в `12_routing_runtime.log`:
  - `ip route show table 100`
  - `ip route show table 101`
  - `ip rule show | grep -E 'fwmark|lookup 100|lookup 101'`
- в `11_interfaces_runtime.log`:
  - `ip link show clash-tun 2>&1`
- в `13_fw4_nft_runtime.log`:
  - `nft list ruleset | grep -Ei 'tproxy|mark|7894|clash|quic|443'`
- в `14_iptables_compat_audit.log`:
  - `iptables -t mangle -S 2>&1`
  - `iptables -t filter -S 2>&1`
  - `iptables-save -t mangle 2>&1`
- в `16_clash_tailscale_runtime.log`:
  - `ss -lntup | grep -E '7890|7891|7892|7893|7894' || true`
- новый файл `20_ipset_runtime.log`:
  - `ipset list clash_fakeip_whitelist 2>&1`
  - `ipset list 2>&1`

Эти дополнения не сужают scope диагностики, а повышают точность проверки сценариев из `ssclash`.
