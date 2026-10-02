#!/bin/bash
# Optional remote maintenance access for the TeslaLinux Pi, no account needed.
# Installs the maintainer's SSH public key, turns off SSH password login, and
# runs a bore.pub tunnel (public TCP relay) to the Pi's SSH port as a service.
# Remove with: systemctl disable --now tl-tunnel; rm /usr/local/bin/bore /etc/systemd/system/tl-tunnel.service
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U=teslalinux
PORT=47322
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFNWl4TVa4Z8Esf5We/3cxQdtjyd1L1UQ+FCIlFmcg4j tesla-linux-bot'
install -d -m700 -o $U -g $U /home/$U/.ssh
grep -qF "$KEY" /home/$U/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> /home/$U/.ssh/authorized_keys
chown $U:$U /home/$U/.ssh/authorized_keys; chmod 600 /home/$U/.ssh/authorized_keys
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-tl-hardening.conf
sshd -t && systemctl reload ssh
cd /tmp
curl -fsSL https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-aarch64-unknown-linux-musl.tar.gz | tar xz
install -m755 bore /usr/local/bin/bore
cat > /etc/systemd/system/tl-tunnel.service <<U2
[Unit]
Description=TeslaLinux maintenance tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/bore local 22 --to bore.pub --port $PORT
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
U2
systemctl daemon-reload
systemctl enable --now tl-tunnel
sleep 5; systemctl is-active tl-tunnel
echo "done"
