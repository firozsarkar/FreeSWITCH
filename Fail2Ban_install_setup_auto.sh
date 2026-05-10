#!/bin/bash

echo "=========================================="
echo "  FreeSWITCH Fail2Ban Auto Setup"
echo "=========================================="

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "[1/8] Updating system..."
apt update -y

echo "[2/8] Installing Fail2Ban..."
apt install fail2ban -y

echo "[3/8] Creating FreeSWITCH filter..."

cat > /etc/fail2ban/filter.d/freeswitch.conf << 'EOF'
[Definition]

failregex = .*sofia_reg.c:\d+ Can't find user \[.*\] from <HOST>.*
            .*SIP auth failure.*ip=<HOST>.*
            .*AUTH FAILURE.*<HOST>.*
            .*invalid password.*<HOST>.*
            .*registration failure.*<HOST>.*
            .*wrong password.*<HOST>.*
            .*Rejected by acl.*<HOST>.*

ignoreregex =
EOF

echo "[4/8] Creating jail.local..."

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = auto
ignoreip = 127.0.0.1/8

[sshd]
enabled = false

[freeswitch]
enabled  = true
port     = 5060,5061
protocol = udp
filter   = freeswitch
logpath  = /var/log/freeswitch/freeswitch.log
maxretry = 5
findtime = 10m
bantime  = 1h
action   = iptables-allports[name=freeswitch]

[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

echo "[5/8] Restarting Fail2Ban..."
systemctl enable fail2ban
systemctl restart fail2ban

echo "[6/8] Checking service..."
systemctl --no-pager status fail2ban

echo "[7/8] Jail status..."
fail2ban-client status

echo "[8/8] FreeSWITCH jail status..."
fail2ban-client status freeswitch

echo "=========================================="
echo "  Fail2Ban Setup Completed!"
echo "=========================================="

echo ""
echo "Useful Commands:"
echo "------------------------------"
echo "Check all jails:"
echo "fail2ban-client status"
echo ""
echo "Check FreeSWITCH jail:"
echo "fail2ban-client status freeswitch"
echo ""
echo "Live logs:"
echo "tail -f /var/log/fail2ban.log"
echo ""
echo "Watch banned IPs:"
echo "watch -n 2 fail2ban-client status freeswitch"
echo "=========================================="
