#!/bin/bash

echo "=========================================="
echo " FreeSWITCH Fail2Ban FULL AUTO FIX"
echo "=========================================="

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

echo "[1/10] Updating packages..."
apt update -y

echo "[2/10] Installing Fail2Ban..."
apt install fail2ban iptables -y

echo "[3/10] Removing old configs..."
rm -f /etc/fail2ban/jail.local
rm -f /etc/fail2ban/filter.d/freeswitch.conf

echo "[4/10] Creating FreeSWITCH filter..."

cat > /etc/fail2ban/filter.d/freeswitch.conf << 'EOF'
[Definition]

failregex = .*SIP auth failure.*ip=<HOST>.*
            .*AUTH FAILURE.*<HOST>.*
            .*invalid password.*<HOST>.*
            .*wrong password.*<HOST>.*
            .*Rejected by acl.*<HOST>.*
            .*Can't find user.*from <HOST>.*
            .*registration failure.*<HOST>.*

ignoreregex =
EOF

echo "[5/10] Checking FreeSWITCH log..."

mkdir -p /var/log/freeswitch

touch /var/log/freeswitch/freeswitch.log

chmod 644 /var/log/freeswitch/freeswitch.log

echo "[6/10] Creating jail.local..."

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = auto
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[sshd]
enabled = false

[freeswitch]
enabled = true
filter = freeswitch
port = 5060,5061
protocol = all
logpath = /var/log/freeswitch/freeswitch.log
backend = auto
maxretry = 5
findtime = 600
bantime = 3600

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 604800
findtime = 86400
maxretry = 3
EOF

echo "[7/10] Testing Fail2Ban config..."

fail2ban-client -d > /tmp/fail2ban-test.txt 2>&1

if grep -q "ERROR" /tmp/fail2ban-test.txt; then
    echo "Fail2Ban config error found!"
    cat /tmp/fail2ban-test.txt
    exit 1
fi

echo "[8/10] Restarting Fail2Ban..."

systemctl daemon-reload
systemctl enable fail2ban
systemctl restart fail2ban

sleep 5

echo "[9/10] Service Status..."
systemctl --no-pager status fail2ban

echo ""
echo "[10/10] Active Jails..."
fail2ban-client status

echo ""
echo "=========================================="
echo " FreeSWITCH Jail Details"
echo "=========================================="

fail2ban-client status freeswitch

echo ""
echo "=========================================="
echo " INSTALL COMPLETED SUCCESSFULLY"
echo "=========================================="

echo ""
echo "Useful Commands:"
echo "--------------------------------"
echo "fail2ban-client status"
echo "fail2ban-client status freeswitch"
echo "tail -f /var/log/fail2ban.log"
echo "watch -n 2 fail2ban-client status freeswitch"
echo "--------------------------------"
