#!/bin/bash

set -e

echo "==== Updating system ===="
apt update -y && apt upgrade -y

echo "==== Installing Fail2Ban ===="
apt install fail2ban -y

echo "==== Backup old configs ===="
mkdir -p /root/fail2ban_backup
cp -r /etc/fail2ban/* /root/fail2ban_backup/ 2>/dev/null || true

echo "==== Cleaning old broken configs ===="
rm -f /etc/fail2ban/jail.local
rm -f /etc/fail2ban/filter.d/freeswitch.conf

echo "==== Creating FreeSWITCH filter ===="
cat > /etc/fail2ban/filter.d/freeswitch.conf <<EOF
[Definition]
failregex = ^.*Can't find user .* from <HOST>.*$
            ^.*SIP auth failure.*ip <HOST>.*$
            ^.*AUTH FAILURE.*<HOST>.*$
ignoreregex =
EOF

echo "==== Creating jail config ===="
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
allowipv6 = auto
bantime = 86400
findtime = 600
maxretry = 3

[sshd]
enabled = true

[freeswitch]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
backend = auto
port = 5060,5061
EOF

echo "==== Fixing systemd socket issues ===="
systemctl daemon-reexec

echo "==== Restarting Fail2Ban ===="
systemctl restart fail2ban
systemctl enable fail2ban

echo "==== Checking status ===="
systemctl status fail2ban --no-pager

echo "==== Fail2Ban installation completed ===="
echo "Check jails with: fail2ban-client status"
