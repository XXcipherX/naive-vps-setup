# naive-vps-setup

Interactive VPS bootstrap script for NaiveProxy over Caddy forwardproxy.

```bash
git clone https://github.com/XXcipherX/naive-vps-setup.git
cd naive-vps-setup
bash vps-setup.sh
```

## Requirements

- Debian/Ubuntu VPS with `root` access.
- A domain pointing directly to the VPS. Do not proxy it through a CDN.
- Open inbound ports: `80/tcp`, `443/tcp`, and `443/udp` if you want HTTP/3/QUIC.

The script installs Docker if needed, renders the Caddy/NaiveProxy config into
`/opt/naive-vps-setup`, starts `pocat/naiveproxy` with Docker Compose, and prints
the client link/config at the end.

The optional server security step is intended for a fresh VPS only. It creates a
new sudo user, disables root/password SSH login, changes the SSH port if you ask
it to, and rewrites iptables/ip6tables rules.

Set `NAIVE_IMAGE` before running the script if you want to pin the Docker image:

```bash
NAIVE_IMAGE=pocat/naiveproxy:latest bash vps-setup.sh
```

## iOS / Shadowrocket

If one-tap import does not recognize the printed URL, add the node manually:

- Type: `HTTPS` (or `Naive`/`NaiveProxy` if your app version shows it)
- Server: your domain
- Port: `443`
- User: printed Naive username
- Password: printed Naive password

Do not add the raw `https://user:password@domain:443` URL as a subscription.

## Runtime Files

- `/opt/naive-vps-setup/docker-compose.yml`
- `/opt/naive-vps-setup/caddy/Caddyfile`
- `/opt/naive-vps-setup/caddy/data`
- `/opt/naive-vps-setup/caddy/config`

Useful commands on the VPS:

```bash
docker compose -f /opt/naive-vps-setup/docker-compose.yml ps
docker compose -f /opt/naive-vps-setup/docker-compose.yml logs -f
docker compose -f /opt/naive-vps-setup/docker-compose.yml restart
```
