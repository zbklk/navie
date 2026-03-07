#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash install_naive_cf.sh <DOMAIN> <EMAIL> <USERNAME> <PASSWORD>
#
# Example:
#   bash install_naive_cf.sh deth.icyzb.top icy.zhangbing@outlook.com ajiu 502097

DOMAIN="${1:-}"
EMAIL="${2:-}"
USERNAME="${3:-}"
PASSWORD="${4:-}"

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo "Usage: bash install_naive_cf.sh <DOMAIN> <EMAIL> <USERNAME> <PASSWORD>"
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

echo "==> [1/9] Checking system..."
if ! command -v apt >/dev/null 2>&1; then
  echo "This script currently supports Debian/Ubuntu with apt."
  exit 1
fi

echo "==> [2/9] Installing dependencies..."
apt update
apt install -y \
  curl \
  wget \
  git \
  golang \
  xz-utils \
  build-essential \
  ca-certificates \
  ufw

echo "==> [3/9] Preparing build directories..."
mkdir -p /root/tmp /root/naive
export TMPDIR=/root/tmp
export GOCACHE=/root/.cache/go-build
export PATH=$PATH:/root/go/bin

echo "==> [4/9] Installing xcaddy..."
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

echo "==> [5/9] Building Caddy with forward_proxy(naive)..."
cd /root/naive
/root/go/bin/xcaddy build \
  --output /usr/local/bin/caddy-naive \
  --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive

chmod +x /usr/local/bin/caddy-naive

echo "==> [6/9] Creating fake website..."
mkdir -p /var/www/site
cat >/var/www/site/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Welcome</title>
</head>
<body>
  <h1>Welcome to ${DOMAIN}</h1>
  <p>This is a normal website.</p>
</body>
</html>
EOF

echo "==> [7/9] Writing Caddyfile..."
mkdir -p /etc/caddy
cat >/etc/caddy/Caddyfile <<EOF
{
	order forward_proxy before file_server
}

:443, ${DOMAIN} {
	tls ${EMAIL}

	forward_proxy {
		basic_auth ${USERNAME} ${PASSWORD}
		hide_ip
		hide_via
		probe_resistance
	}

	file_server {
		root /var/www/site
	}
}
EOF

/usr/local/bin/caddy-naive fmt --overwrite /etc/caddy/Caddyfile

echo "==> [8/9] Writing systemd service..."
cat >/etc/systemd/system/caddy-naive.service <<'EOF'
[Unit]
Description=Caddy (Naive forward_proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=/usr/local/bin/caddy-naive run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy-naive reload --config /etc/caddy/Caddyfile
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "==> [9/9] Enabling service and opening firewall..."
systemctl daemon-reload
systemctl disable --now caddy 2>/dev/null || true
systemctl enable --now caddy-naive

ufw allow 80/tcp || true
ufw allow 443/tcp || true

echo
echo "=========================================="
echo "Naive server installed."
echo "Domain   : ${DOMAIN}"
echo "Username : ${USERNAME}"
echo "Password : ${PASSWORD}"
echo
echo "IMPORTANT:"
echo "1) In Cloudflare, set ${DOMAIN} to DNS only (gray cloud)."
echo "2) Wait for DNS refresh if you changed it recently."
echo
echo "Check service:"
echo "  systemctl status caddy-naive --no-pager -l"
echo
echo "Check module:"
echo "  /usr/local/bin/caddy-naive list-modules | grep forward_proxy"
echo
echo "Test proxy:"
echo "  curl --proxy https://${USERNAME}:${PASSWORD}@${DOMAIN}:443 --proxy-http2 --proxy-insecure https://example.com"
echo "=========================================="