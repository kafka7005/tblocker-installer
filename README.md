# tblocker для нод Remnawave (KafkaVPN)

Ставит [xray-torrent-blocker](https://github.com/kutovoys/xray-torrent-blocker) на ноду Remnawave одной командой и подключает его к вебхуку Solobot.

## Установка

Запускать на каждой ноде (от root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) --webhook ДОМЕН_БОТА
```

`ДОМЕН_БОТА` — домен твоего бота без `https://`. Скрипт сам превращает его в `https://ДОМЕН_БОТА/tblocker/webhook`.

## Что делает скрипт

1. Добавляет volume `/var/log/remnanode` в `/opt/remnanode/docker-compose.yml`. Перед этим делает бэкап, после проверяет файл через `docker compose config`.
2. Пересоздаёт контейнер ноды, если папка ещё не подключена.
3. Настраивает logrotate (50M × 5, copytruncate).
4. Удаляет старый apt-пакет `tblocker`, если он стоит.
5. Скачивает последний релиз tblocker с GitHub и проверяет SHA256.
6. Пишет `/opt/tblocker/config.yaml` и systemd-сервис.
7. Делает самотест на изолированной копии с выключенным вебхуком: блокирует тестовый IP 203.0.113.200, проверяет, что правило появилось в iptables, и убирает его.
8. Запускает сервис, проверяет, что он не падает, и смотрит, пишет ли Xray лог.

Повторный запуск безопасен. Старый конфиг сохраняется в бэкап, вебхук, срок блокировки, hostname и bypass-список переносятся.

## Что делается руками

- **Панель Remnawave.** В Профили → конфиг Xray добавь `log`, outbound `TORRENT` с протоколом blackhole и правило для bittorrent в `routing`. У инбаундов должно быть `sniffing.enabled: true`. Точный JSON скрипт выводит в конце.
- **Модуль tBlocker в Solobot.** Впиши hostname каждой ноды в `SERVER_COUNTRIES`. Скрипт печатает его в итоговой сводке.

## Параметры

| Параметр | Описание |
|---|---|
| `--webhook URL\|ДОМЕН` | вебхук бота |
| `--no-webhook` | без вебхуков |
| `--duration МИН` | срок блокировки, по умолчанию 30 |
| `--bypass СПИСОК` | IP/домены, которые никогда не блокируются |
| `--hostname ИМЯ` | имя сервера в вебхуке (по умолчанию `hostname`) |
| `--firewall iptables\|nft` | по умолчанию iptables |
| `--version vX.Y.Z` | зафиксировать версию tblocker |
| `--skip-node` | не трогать docker-compose (для Xray вне docker) |
| `--no-restart` | не перезапускать контейнер ноды |
| `-y` | ничего не спрашивать |
| `--uninstall` | полностью удалить tblocker |

## Полезные команды

```bash
journalctl -u tblocker -f                  # лог в реальном времени
iptables -t raw -S TBLOCKER_BLOCKED        # кто заблокирован сейчас
cat /opt/tblocker/blocked_ips.json         # блокировки с пользователями и сроками
```

## Удаление

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) --uninstall
```
