# openwrt-routing-diagnostic

Read-only-first diagnostic toolkit for OpenWRT routing issues (Mihomo/Clash TPROXY + Tailscale).

## Shell compatibility

Script is written for `/bin/sh` (BusyBox `ash` compatible), not bash-specific syntax.

## Default tuning in script header

All default runtime/anonymization knobs are grouped at the top of `owrt-diag.sh` under `# Default settings (editable)`:
- output path / ssclash path defaults
- timeout and service wait values
- log tail sizes for normal/degraded mode
- anonymization policy switches and prefixes

## Script

`owrt-diag.sh` collects system/network snapshots and writes artifacts to:

```text
/tmp/owrt-diagnostic/<session_id>/
  ├─ raw/
  │   ├─ 00_static/
  │   ├─ 10_mode_Clash_OFF/
  │   ├─ 10_mode_Clash_OFF_untrusted/   # if auto state transition failed
  │   ├─ 11_mode_Clash_ON/
  │   ├─ 11_mode_Clash_ON_untrusted/    # if auto state transition failed
  │   └─ 12_mode_Clash_ON_post/         # only in --auto when initial state is ON
  ├─ anon/
  └─ meta/
```

## Полная карта файлов репозитория

### Основные скрипты

- `owrt-diag.sh`  
  Главный диагностический скрипт: сбор данных, режимы `--clash/--auto`, маскирование, мета-файлы, опциональное архивирование.

- `clash-checker.sh`  
  Отдельный прототип decision-логики определения состояния Clash (service/initd/process/ports).

- `clash-status.sh`  
  Вспомогательный probe-скрипт для проверки статус-парсинга и эвристик состояния Clash.

- `test_script.sh`  
  Лёгкий локальный playground для проверки `sanitize_hostname`, `parse_status_line` и live-проб.

### Документация

- `README.md` — быстрый старт, структура вывода, FAQ/How-to.
- `docs/stage1_theoretical_analysis.md` — теоретический анализ проблемы.
- `docs/stage2_architecture.md` — архитектура и поток выполнения.
- `docs/stage3_data_inventory.md` — инвентаризация собираемых данных.
- `docs/stage4_error_handling.md` — стратегия ошибок/деградации.
- `docs/how_to_share_files.md` — как безопасно делиться результатами.
- `docs/merge_conflicts_quick_guide.md` — краткий гайд по merge conflicts.
- `docs/merge_playbook_pr_conflicts.md` — расширенный playbook по конфликтам.

### Что появляется в output-сессии

- `raw/` — исходные (немаскированные) данные.
- `anon/` — маскированные данные (если не указан `--no-anon`).
- `meta/` — служебные файлы запуска:
  - `90_manifest.txt`
  - `91_errors.txt`
  - `92_recommendations.txt`
  - `93_collection_matrix.txt`
  - `94_ssclash_touchpoints.txt`
  - `95_runtime_events.txt`
  - `96_summary.txt`
  - `97_run_<timestamp>.txt`
  - `.anon_ipv4_map.tsv` (внутренняя таблица соответствий публичных IPv4)

## Usage

```bash
# one-liner on router: download latest, make executable, run
wget -O /tmp/owrt-diag.sh https://raw.githubusercontent.com/yuliantrip/openwrt-routing-diagnostic/main/owrt-diag.sh \
  && chmod +x /tmp/owrt-diag.sh \
  && /tmp/owrt-diag.sh

# default run (no params): detect service clash status and run one snapshot
./owrt-diag.sh

# manual mode
./owrt-diag.sh --clash on
./owrt-diag.sh --clash off --out /tmp/owrt-diagnostic

# auto workflow with stop/start checks and state restore
./owrt-diag.sh --auto

# optional ssclash sources
./owrt-diag.sh --ssclash-dir /opt/clash/bin
./owrt-diag.sh --ssclash-file /opt/clash/bin/clash-rules

# raw only
./owrt-diag.sh --no-anon

# archive options
./owrt-diag.sh --tar full
./owrt-diag.sh --tar raw
./owrt-diag.sh --tar anon
./owrt-diag.sh --tar no
```

## Default parameters

Running `./owrt-diag.sh` without extra options uses:
- auto-detected clash state via `service clash status`
- output directory: `/tmp/owrt-diagnostic`
- ssclash directory: `/opt/clash/bin`
- anonymization: enabled

Service wait/timeout defaults are configurable in script header:
- `SERVICE_CMD_TIMEOUT_SEC=60`
- `SERVICE_WAIT_MAX_SEC=60`
- `SERVICE_WAIT_LOG_INTERVAL_SEC=1`

## File naming

- Session folder: `<timestamp>_<hostname>` (hostname auto-detected from `hostname` / `/proc/sys/kernel/hostname` / `uname -n` fallback).
- Export files are `.txt`.
- Runtime files in mode folders include mode suffix:
  - `..._<hostname>_ClashON.txt`
  - `..._<hostname>_ClashOFF.txt`

## About WARN lines in output

Some WARN entries are normal and expected depending on router setup:
- `ip link show clash-tun` fails when TUN interface is not present in current mode.
- `ip route show table 101` fails if table 101 is not configured in this profile.
- `iptables*` commands can fail (`rc=127`) on nftables-only systems without iptables-compat packages.
- `ipset list clash_fakeip_whitelist` can fail when the set is absent (script still continues).

## Anonymization policy (anon/)

- Loopback IPv4 (`127.x.x.x`) is preserved.
- Private LAN by default is rewritten using `ANON_PRIVATE_PREFIX="192.168.55"` (prefix length adaptive).
- Tailscale (`100.64.0.0/10`) by default is rewritten using `ANON_TAILSCALE_PREFIX="100.55"` (adaptive).
- Public IPv4 are deterministically remapped into `ANON_PUBLIC_PREFIX` space (default `198.18`, adaptive by prefix length).
- IPv6 subnet is masked while keeping host tail, format `[IPV6_MASKED]::<tail>`.
- MAC addresses are partially masked: `XX:XX:XX:XX:<last2octets>`.
- `option username`, `option password`, token/secret-like values are masked.

## FAQ / How-to

### 1) Как запустить быстро и безопасно?

```bash
chmod +x owrt-diag.sh
./owrt-diag.sh
```

По умолчанию скрипт read-only по сбору данных (кроме `--auto`, где выполняются `service clash stop/start` для сравнения состояний).

### 2) Как получить сравнение OFF/ON автоматически?

```bash
./owrt-diag.sh --auto
```

Скрипт соберёт минимум `Clash_OFF` и `Clash_ON` (и `Clash_ON_post`, если стартовое состояние было ON), затем попробует восстановить исходное состояние сервиса.

### 3) Что делать, если нужен только raw без маскировки?

```bash
./owrt-diag.sh --no-anon
```

### 4) Как управлять архивом результата?

- Явно:
  - `--tar full` (вся сессия),
  - `--tar raw` (`raw+meta`),
  - `--tar anon` (`anon+meta`),
  - `--tar no` (не создавать архив).
- Если `--tar` не задан, скрипт спросит в конце (в интерактивном TTY).

### 5) Скрипт можно запускать из любой папки?

Да. Текущая версия не должна зависеть от `cwd` для определения состояния `clash`.

### 6) Какие WARN можно считать «нормальными»?

- отсутствие `clash-tun`,
- отсутствие `table 101`,
- отсутствие `iptables`-compat на nft-only роутерах,
- отсутствие отдельных ipset-сетов.

Это не блокирует сбор и обычно отражает особенности конкретной конфигурации роутера.
