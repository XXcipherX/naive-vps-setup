#!/bin/bash

set -e
trap 'rm -f ./test_pbk' EXIT
trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer expects a Debian/Ubuntu-like system with apt-get."
  exit 1
fi

REQUIRED_TEMPLATES=(compose caddy)
for f in "${REQUIRED_TEMPLATES[@]}"; do
  if [ ! -f "$SCRIPT_DIR/templates_for_script/$f" ]; then
    echo "Missing required template: $f"
    exit 1
  fi
done

random_token() {
  local length="$1"
  tr -dc A-Za-z0-9 </dev/urandom | head -c "$length"
  echo
}

random_probe_domain() {
  local label
  label=$(tr -dc a-z0-9 </dev/urandom | head -c 24)
  echo "$label.com"
}

is_urlsafe_value() {
  [[ "$1" =~ ^[A-Za-z0-9._~-]+$ ]]
}

apt-get update
apt-get install -y ca-certificates curl wget gpg idn sudo dnsutils gettext-base openssl openssh-client lsb-release

read -ep "Enter your domain: " input_domain
while [[ -z "$input_domain" ]]; do
  read -ep "Domain cannot be empty. Enter your domain: " input_domain
done

export NAIVE_DOMAIN
NAIVE_DOMAIN=$(echo "$input_domain" | tr -d '[:space:]' | idn | tr '[:upper:]' '[:lower:]')
export TEST_DOMAIN_A
TEST_DOMAIN_A=$(dig +short A "$NAIVE_DOMAIN" | head -n1)
export TEST_DOMAIN_AAAA
TEST_DOMAIN_AAAA=$(dig +short AAAA "$NAIVE_DOMAIN" | head -n1)

if [[ -z "$TEST_DOMAIN_A" && -z "$TEST_DOMAIN_AAAA" ]]; then
  read -ep "Are you sure? That domain has no A/AAAA DNS record. If DNS is not ready, Caddy cannot issue a certificate yet. Continue? [y/N] " prompt_response
  if [[ "$prompt_response" =~ ^[Yy] ]]; then
    echo "Ok"
  else
    echo "Come back later"
    exit 1
  fi
fi

read -ep "Enter ACME email for certificates (optional): " input_email
while [[ -n "$input_email" && ! "$input_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; do
  read -ep "Invalid email format. Enter ACME email (optional): " input_email
done

read -ep "Enter Naive auth username [naive]: " input_user
input_user=${input_user:-naive}
while ! is_urlsafe_value "$input_user"; do
  read -ep "Use only A-Z, a-z, 0-9, dot, underscore, tilde, or dash. Enter username [naive]: " input_user
  input_user=${input_user:-naive}
done

read -rsp "Enter Naive auth password (blank=random): " input_password
echo
if [[ -n "$input_password" ]]; then
  while ! is_urlsafe_value "$input_password"; do
    read -rsp "Use only A-Z, a-z, 0-9, dot, underscore, tilde, or dash. Enter password (blank=random): " input_password
    echo
    if [[ -z "$input_password" ]]; then
      break
    fi
  done
fi

read -ep "Do you want to configure server security? Do this on first run only. [y/N]: " configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  read -ep "Enter SSH port (default 22, can't use ports 80, 443): " input_ssh_port
  input_ssh_port=${input_ssh_port:-22}

  while ! [[ "$input_ssh_port" =~ ^[0-9]+$ ]] || [[ "$input_ssh_port" -lt 1 || "$input_ssh_port" -gt 65535 || "$input_ssh_port" -eq 80 || "$input_ssh_port" -eq 443 ]]; do
    read -ep "Invalid port or reserved (80, 443). Enter again: " input_ssh_port
    input_ssh_port=${input_ssh_port:-22}
  done

  read -ep "Enter SSH public key: " input_ssh_pbk
  echo "$input_ssh_pbk" > ./test_pbk
  while ! ssh-keygen -l -f ./test_pbk >/dev/null 2>&1; do
    echo "Can't verify the public key. Make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by the key body."
    read -ep "Enter SSH public key: " input_ssh_pbk
    echo "$input_ssh_pbk" > ./test_pbk
  done
  rm -f ./test_pbk
fi

docker_install() {
  curl -fsSL https://get.docker.com | bash
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  docker_install
fi

systemctl enable --now docker.service >/dev/null 2>&1 || true

export SSH_USER
SSH_USER=$(random_token 8)
export SSH_PORT=${input_ssh_port:-22}
export NAIVE_USER="$input_user"
export NAIVE_PASSWORD=${input_password:-$(random_token 32)}
export NAIVE_PROBE_DOMAIN
NAIVE_PROBE_DOMAIN=$(random_probe_domain)
export NAIVE_TLS_DIRECTIVE=""
if [[ -n "$input_email" ]]; then
  export NAIVE_TLS_DIRECTIVE="tls $input_email"
fi
export NAIVE_IMAGE=${NAIVE_IMAGE:-pocat/naiveproxy:latest}

naive_setup() {
  mkdir -p /opt/naive-vps-setup
  pushd /opt/naive-vps-setup >/dev/null
    envsubst < "$SCRIPT_DIR/templates_for_script/compose" > ./docker-compose.yml

    mkdir -p caddy/data caddy/config caddy/logs
    envsubst < "$SCRIPT_DIR/templates_for_script/caddy" > ./caddy/Caddyfile
  popd >/dev/null
}

naive_setup

ensure_container_name_available() {
  local compose_project

  if docker ps -a --format '{{.Names}}' | grep -qx naiveproxy; then
    compose_project=$(docker inspect naiveproxy --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
    if [[ "$compose_project" != "naive-vps-setup" ]]; then
      echo "A Docker container named naiveproxy already exists and is not managed by this Compose project."
      echo "Stop/remove or rename it before running this installer again."
      exit 1
    fi
  fi
}

sshd_edit() {
  local conf="/etc/ssh/sshd_config"

  sed -i 's|^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/\*.conf|#&|' "$conf"
  sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$conf"

  rm -f /etc/ssh/sshd_config.d/*.conf

  cat > /etc/ssh/sshd_config.d/00-hardened.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF

  sshd -t || { echo "sshd config test failed"; exit 1; }

  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service
}

add_user() {
  useradd -m "$SSH_USER" -s /bin/bash
  mkdir "/home/$SSH_USER/.ssh"
  echo "$input_ssh_pbk" > "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 700 "/home/$SSH_USER/.ssh/"
  chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"

  echo "$SSH_USER ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$SSH_USER"
  chmod 440 "/etc/sudoers.d/$SSH_USER"

  echo "sudo -i" > "/home/$SSH_USER/.bash_profile"

  chown "$SSH_USER:$SSH_USER" -R "/home/$SSH_USER"
  usermod -aG docker "$SSH_USER"
  passwd -l "$SSH_USER" >/dev/null 2>&1
}

edit_iptables() {
  debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF

  apt-get -y install iptables-persistent netfilter-persistent

  iptables -F INPUT
  iptables -F FORWARD
  iptables -F OUTPUT

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -p icmp -j ACCEPT

  iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 10 --name SSH -j DROP
  iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --set --name SSH
  iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -j ACCEPT

  iptables -A INPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
  iptables -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
  iptables -A INPUT -p udp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

  ip6tables -F INPUT
  ip6tables -F FORWARD
  ip6tables -F OUTPUT

  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT

  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

  ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 10 --name SSHv6 -j DROP
  ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --set --name SSHv6
  ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -j ACCEPT

  ip6tables -A INPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
  ip6tables -A INPUT -p udp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

  netfilter-persistent save
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  add_user
  sshd_edit
  edit_iptables
fi

end_script() {
  ensure_container_name_available
  docker compose -f /opt/naive-vps-setup/docker-compose.yml config >/dev/null
  docker run --rm --entrypoint /usr/bin/caddy \
    -v /opt/naive-vps-setup/caddy/Caddyfile:/etc/naiveproxy/Caddyfile:ro \
    "$NAIVE_IMAGE" validate --config /etc/naiveproxy/Caddyfile --adapter caddyfile
  docker compose -f /opt/naive-vps-setup/docker-compose.yml pull
  docker compose -f /opt/naive-vps-setup/docker-compose.yml up -d

  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "New user for SSH: $SSH_USER. SSH auth: key only. New port for SSH: $SSH_PORT."
  fi

  echo ""
  echo "NaiveProxy client URLs:"
  echo "[https] https://$NAIVE_USER:$NAIVE_PASSWORD@$NAIVE_DOMAIN:443"
  echo "[quic]  quic://$NAIVE_USER:$NAIVE_PASSWORD@$NAIVE_DOMAIN:443"
  echo ""
  echo "Client config:"
  cat <<EOF
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://$NAIVE_USER:$NAIVE_PASSWORD@$NAIVE_DOMAIN:443"
}
EOF
  echo ""
  echo "Shadowrocket manual setup:"
  echo "Type: HTTPS (or Naive/NaiveProxy if your app version shows it)"
  echo "Server: $NAIVE_DOMAIN"
  echo "Port: 443"
  echo "User: $NAIVE_USER"
  echo "Password: $NAIVE_PASSWORD"
  echo ""
  echo "Probe resistance domain: $NAIVE_PROBE_DOMAIN"
  echo "Runtime directory: /opt/naive-vps-setup"
  echo "Done."
}

end_script
