#!/bin/bash

echo "===================================="
echo " Fail2Ban Auto Install Script"
echo "===================================="

# Update system
echo "[1/6] Updating system..."
apt update -y && apt upgrade -y

# Install Fail2Ban
echo "[2/6] Installing Fail2Ban..."
apt install fail2ban -y

# Backup default config
echo "[3/6] Backing up config..."
if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# Create custom jail.local
echo "[4/6] Creating jail.local config..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = false
port = ssh
logpath = %(sshd_log)s
backend = systemd

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 1w
findtime = 1d
maxretry = 3
EOF

# Enable and start service
echo "[5/6] Enabling service..."
systemctl enable fail2ban
systemctl restart fail2ban

# Status check
echo "[6/6] Checking status..."
systemctl status fail2ban --no-pager

echo "===================================="
echo " Fail2Ban Installed & Configured!"
echo "===================================="
