# tblocker for Remnawave nodes (KafkaVPN)

Installs [xray-torrent-blocker](https://github.com/kutovoys/xray-torrent-blocker) on a Remnawave node with one command and connects it to the Solobot webhook.

## Install

Run on every node (as root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) --webhook BOT_DOMAIN
```

`BOT_DOMAIN` is the bot's domain without `https://`. The script itself turns it into `https://BOT_DOMAIN/tblocker/webhook`.

On a node behind a cascade, add the entry nodes to the exceptions so the whole entry server does not get blocked:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) \
  --webhook BOT_DOMAIN --bypass twcascade1.kafka7004.ru,twcascade2.kafka7004.ru
```

## What the script does

1. Adds the `/var/log/remnanode` volume to `/opt/remnanode/docker-compose.yml`. It makes a backup first and runs `docker compose config` afterwards.
2. Recreates the node container.
3. Sets up logrotate (50M × 5, copytruncate).
4. Removes the old apt package `tblocker`, if it is installed.
5. Downloads the latest tblocker release from GitHub and checks its SHA256.
6. Writes `/opt/tblocker/config.yaml` and the systemd service.
7. Runs a self-test on an isolated copy with the webhook turned off. It blocks the test IP 203.0.113.200, makes sure the rule appeared in iptables, and removes it.
8. Starts the service, makes sure it stays up, and checks whether Xray is writing the log.

Running it again is safe. The old config is backed up, and the webhook, block duration, hostname and bypass list carry over.

## Done by hand

- **The Remnawave panel.** Open Profiles → Xray config and add `log`, the `TORRENT` blackhole outbound and the bittorrent rule in `routing`. The inbounds need `sniffing.enabled: true`. The script prints the exact JSON at the end.
- **The tBlocker module in Solobot.** Put each node's hostname in `SERVER_COUNTRIES`. The script prints it in its final summary.

## Options

| Option | Description |
|---|---|
| `--webhook URL\|DOMAIN` | bot webhook |
| `--no-webhook` | no webhooks |
| `--duration MIN` | block duration, default 30 |
| `--bypass LIST` | IPs/domains that are never blocked |
| `--hostname NAME` | server name in the webhook (default: `hostname`) |
| `--firewall iptables\|nft` | default iptables |
| `--version vX.Y.Z` | pin a tblocker version |
| `--skip-node` | do not touch docker-compose (for Xray outside docker) |
| `--no-restart` | do not restart the node container |
| `-y` | ask no questions |
| `--uninstall` | remove tblocker completely |

## Useful commands

```bash
journalctl -u tblocker -f                  # live log
iptables -t raw -S TBLOCKER_BLOCKED        # who is blocked right now
cat /opt/tblocker/blocked_ips.json         # blocks with users and expiry times
```
