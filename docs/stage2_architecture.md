# Этап 2 — Архитектура `owrt-diag.sh` и список утилит

## Цель этапа
Спроектировать отказоустойчивую архитектуру read-only диагностического скрипта для OpenWRT 24.10/25.12 (Firewall4 + nftables), с режимами сравнения `Clash_ON` и `Clash_OFF`.

## 1) Набор утилит (минимум/рекомендуемые)

### Базовые (должны быть в системе)
- `sh`/`ash`, `busybox` core утилиты (`cat`, `sed`, `awk`, `grep`, `cut`, `sort`, `uniq`, `date`, `df`, `du`, `free`, `ps`, `dmesg`).
- Сетевые: `ip`, `ip6tables-nft` (проверка совместимости), `iptables-nft` (проверка совместимости), `nft`, `ss`, `ping`, `traceroute` (если есть).
- OpenWRT: `ubus`, `uci`, `logread`, `fw4`.

### Диагностические (желательно)
- `tcpdump` (только presence-check + опциональный короткий capture в read-only режиме).
- `nslookup`/`drill`/`dig` (что доступно).
- `tailscale` CLI (если установлен).
- `mihomo`/`clash` binary presence-check.

### Пакетные менеджеры (детект)
- OpenWRT 24.10: `opkg`
- OpenWRT 25.12: `apk`

Скрипт **не устанавливает** пакеты, только:
1. определяет пакетный менеджер;
2. фиксирует наличие/отсутствие нужных утилит;
3. пишет рекомендации в `90_recommendations.log`.

## 2) Логика меню / режимы запуска

Поддерживаются 2 модели запуска:

1. **Неинтерактивный режим (предпочтительный)**
   - `owrt-diag.sh --mode Clash_ON`
   - `owrt-diag.sh --mode Clash_OFF`
   - `owrt-diag.sh --out /tmp/owrt-diagnostic`

2. **Интерактивный режим (fallback)**
   - Текстовое меню выбора режима и каталога вывода.

## 3) Структура функций скрипта

### Блок A — каркас
- `main()` — orchestrator, порядок вызова.
- `parse_args()` — разбор `--mode`, `--out`, `--no-anon` (опционально для локального приватного анализа).
- `init_paths()` — подготовка директорий вывода.
- `preflight_checks()` — проверка памяти /tmp, прав, наличия команд.

### Блок B — совместимость и окружение
- `detect_openwrt_release()` — парсинг `/etc/openwrt_release`, `/etc/os-release`.
- `detect_pkg_manager()` — `opkg|apk|unknown`.
- `collect_package_inventory()` — список ключевых пакетов и бинарников.
- `audit_iptables_legacy_conflicts()` — аудит legacy/compat следов (`iptables-save`, modules, alternatives).

### Блок C — сбор сетевой диагностики (read-only)
- `collect_system_snapshot()` — uptime, load, память, версия ядра.
- `collect_network_config()` — интерфейсы, адреса, маршруты, policy rules.
- `collect_nft_fw4_state()` — `nft list ruleset`, `fw4 print`, includes, sets, counters.
- `collect_dns_state()` — dnsmasq/resolv, hijack rules, loop indicators.
- `collect_tailscale_state()` — status, routes, exit-node indicators.
- `collect_clash_state()` — процесс, listening sockets, tproxy mark/port признаки.
- `collect_logs()` — `logread`, `dmesg` фильтры по ключевым паттернам.

### Блок D — анонимизация и запись
- `mask_sensitive_data()` — маскировка IP/MAC/UUID/секретов.
- `write_block_header()` — стандартизированный заголовок команд.
- `run_and_capture()` — безопасный wrapper выполнения команд с тайм-аутом и кодом возврата.
- `finalize_manifest()` — индекс файлов, хеши, метаданные запуска.

### Блок E — устойчивость
- `handle_low_tmp_space()` — graceful деградация (сокращённый сбор).
- `handle_missing_command()` — запись WARN + пропуск секции.
- `handle_permission_errors()` — фиксировать stderr и продолжать следующий шаг.

## 4) Формат каталога вывода

```text
/tmp/owrt-diagnostic/
  └─ <timestamp>_<mode>/
      ├─ raw/
      ├─ anon/
      ├─ meta/
      ├─ errors/
      └─ manifest.txt
```

- `raw/` — исходные данные команд.
- `anon/` — анонимизированные копии для передачи внешнему анализатору.
- `meta/` — версии, список утилит, параметры запуска.
- `errors/` — stderr и ошибки недоступных команд.

## 5) Гарантия READ-ONLY

Скрипт **не должен**:
- менять `uci` конфиги;
- выполнять `service restart` / `fw4 reload` / `nft flush`;
- добавлять `ip rule`/`ip route`;
- устанавливать/удалять пакеты.

Скрипт **должен** только собирать состояние и сохранять результаты.

## 6) План перехода к Этапу 3

На следующем этапе будет составлен **точный перечень файлов и команд** + строгая схема именования артефактов (`01_*.log`, `02_*.nft` и т.д.) для машинного сравнения режимов `Clash_ON` vs `Clash_OFF`.

## 7) Уточнение по структуре данных: что собирать один раз, а что в каждом режиме

Чтобы не дублировать тяжёлые данные между `Clash_ON` и `Clash_OFF`, предлагается двухуровневый формат:

```text
/tmp/owrt-diagnostic/
  └─ <session_id>/
      ├─ 00_static/                 # снимается 1 раз за сессию
      ├─ 10_mode_Clash_OFF/         # снимается при OFF
      ├─ 11_mode_Clash_ON/          # снимается при ON
      └─ meta/
```

### 7.1 `00_static/` (один раз)
Данные, которые обычно не меняются между двумя прогонами:
- базовая система: версии, ядро, board, release;
- инвентарь пакетов и модулей;
- постоянные UCI-конфиги (`network`, `firewall`, `dhcp`, `system`, `tailscale`, `mihomo`/`openclash` если есть);
- список автозапускаемых сервисов и init-скриптов.

### 7.2 `10_mode_*` (для каждого режима отдельно)
Данные, чувствительные к состоянию Clash:
- runtime маршрутизация: `ip route`, `ip rule`, `ip -6 route`, `ip -6 rule`;
- активные nft counters/ruleset snapshot;
- слушающие сокеты, процессы, актуальные PID;
- runtime DNS-состояние (`resolv.conf`, dnsmasq runtime, запросы/ошибки);
- tail логов за ограниченный интервал.

## 8) Баланс размеров и количества файлов (предложение)

Вместо «один огромный файл» или «сотни мелких» — 10–16 тематических файлов на режим + 4–6 static-файлов.

### 8.1 Группы файлов
1. **System & Baseline**
   - `00_static/01_system_baseline.log`
2. **Packages & Kernel modules**
   - `00_static/02_packages_modules.log`
3. **Persistent config (UCI + service configs)**
   - `00_static/03_persistent_config.log`
4. **Routing runtime**
   - `10_mode_*/11_routing_runtime.log`
5. **Firewall/nft/iptables compatibility**
   - `10_mode_*/12_firewall_nft_runtime.log`
   - `10_mode_*/13_iptables_compat_audit.log`
6. **Interfaces & link state**
   - `10_mode_*/14_interfaces_runtime.log`
7. **DNS runtime**
   - `10_mode_*/15_dns_runtime.log`
8. **Clash + Tailscale runtime**
   - `10_mode_*/16_clash_tailscale_runtime.log`
9. **Kernel/system logs (filtered)**
   - `10_mode_*/17_logs_filtered.log`
10. **Errors/warnings manifest**
   - `meta/90_manifest.log`, `meta/91_errors.log`, `meta/92_recommendations.log`

### 8.2 Почему так лучше
- Меньше дублей: база системы сохраняется 1 раз.
- Сравнение ON/OFF становится тривиальным (сравниваются одноимённые файлы `10_mode_Clash_OFF` vs `11_mode_Clash_ON`).
- Файлы остаются читаемыми человеком и удобными для LLM-парсинга.

## 9) Что именно мы «получаем» из этого формата

- **Причинно-следственный срез**: что изменилось именно при включении Clash.
- **Отделение статики от динамики**: исключаем шум от неизменяемых параметров.
- **Снижение объёма**: меньше размер архива, проще передача.
- **Быстрый triage**: можно начать с `11/12/15/16/17` и затем углубляться.

## 10) Интеграция будущего анализа `clash-rules (ssclash)`

Поддерживаю ваш план: загрузите 2 версии (проблемную и рабочую), и мы:
1. выделим, какие именно параметры/таблицы/цепочки/марки/роуты скрипт трогает;
2. добавим эти точки в диагностический сбор;
3. не будем дебажить сам `ssclash` на этом шаге, только расширим покрытие диагностики.

Рекомендуемый формат загрузки:
- лучше **прямо сюда** (файлами в репозиторий/чат), чтобы сразу сравнить diff локально;
- GitHub тоже можно, но это добавит лишний цикл синхронизации.
