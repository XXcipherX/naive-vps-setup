# NaiveProxy Context

Source review date: 2026-05-08

Sources studied:

- https://github.com/XXcipherX/xray-vps-setup
- https://github.com/SonyCore/Naive-deploy
- https://github.com/klzgrad/naiveproxy
- https://hub.docker.com/r/pocat/naiveproxy
- https://github.com/caddyserver/forwardproxy

## Current Architecture

- `vps-setup.sh` is an interactive root installer for Debian/Ubuntu-like VPSes.
- The script asks for a domain, optional ACME email, Naive basic auth
  credentials, and optional first-run SSH/firewall hardening.
- It renders templates into `/opt/naive-vps-setup` and starts one Docker
  Compose service: `pocat/naiveproxy`.
- The container runs Caddy v2 with the Naive fork of `forwardproxy`, using host
  networking so ports `80/tcp`, `443/tcp`, and `443/udp` are available.
- Caddy terminates TLS, returns 404 for regular web requests, and exposes
  authenticated forward proxy over HTTP/1.1, HTTP/2, and HTTP/3.

## Notes From Official Docs

- NaiveProxy uses Chromium's network stack and recommends keeping clients
  current so their network signature tracks Chrome.
- Server-side setup is usually Caddy plus the Naive fork of the forwardproxy
  module.
- The Caddyfile site address must begin with `:443` for forward proxy requests
  to work for arbitrary origins.
- `basic_auth` is required for a private proxy. `probe_resistance` only makes
  sense with authentication.
- `hide_ip` and `hide_via` reduce obvious proxy headers.
- The `pocat/naiveproxy` image ships Caddy v2 with `forwardproxy (naive)` and
  documents `protocols h1 h2 h3`, so the installer opens `443/udp` when the
  optional firewall setup is enabled.

## Differences From Old Naive-deploy

- Uses Docker Compose and templates, matching the shape of `xray-vps-setup`.
- Uses Caddyfile instead of generated JSON because the Docker image recommends
  Caddyfile for server-side setup.
- Adds DNS checks, optional ACME email, optional SSH/firewall hardening, and
  repeatable runtime files under `/opt/naive-vps-setup`.
- Returns 404 to regular non-proxy web requests instead of serving a visible
  placeholder page.
- Keeps generated credentials URL-safe so the printed client URLs do not need
  extra escaping. Some clients, including Shadowrocket, may still require
  manual node creation instead of one-tap importing the raw URL.

## Operational Risks

- `pocat/naiveproxy:latest` intentionally tracks current Chrome/Naive releases,
  but this also means behavior can change between installs. Pin
  `NAIVE_IMAGE=pocat/naiveproxy:<tag>` before running the script if
  reproducibility matters more than freshness.
- Docker is installed via `get.docker.com`, which is convenient but not pinned.
- The optional SSH/firewall hardening is designed for a fresh VPS. It rewrites
  SSH drop-in config and flushes existing iptables/ip6tables rules.
