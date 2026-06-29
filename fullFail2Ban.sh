#!/bin/bash

if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

echo "Installing and Configuring Fail2Ban for FreeSWITCH..."

apt update -y
apt install fail2ban nftables -y

# ১. ফিল্টার তৈরি করা (সবগুলো অ্যাটাক কভার করবে)
cat > /etc/fail2ban/filter.d/freeswitch.conf << 'EOF'
[Definition]
# আধুনিক FreeSWITCH লগ ফরম্যাট অনুযায়ী রেজেক্স
failregex = ^.*SIP auth failure.*(from|ip)=<HOST>.*
            ^.*AUTH FAILURE.*<HOST>.*
            ^.*SIP registration failure.*from <HOST>.*
            ^.*Can't find user.*from <HOST>.*
            ^.*SIP scan detected from <HOST>.*
            ^.*Invalid password for user.*from <HOST>.*
            ^.*failed to authorize.*from <HOST>.*
            ^.*XML-RPC authentication failed for <HOST>.*
            ^.*Event Socket authentication failed from <HOST>.*
ignoreregex =
EOF

# ২. jail.local ফাইল তৈরি করা
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
banaction = nftables[type=allports]

[freeswitch-auth]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 3
findtime = 600
bantime = 24h

[freeswitch-register]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 5
findtime = 300
bantime = 48h

[freeswitch-scan]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 2
findtime = 60
bantime = 1w

[freeswitch-api]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 3
findtime = 300
bantime = 24h
EOF

# ৩. পারমিশন ও রিস্টার্ট
touch /var/log/freeswitch/freeswitch.log
systemctl restart fail2ban
systemctl enable fail2ban

echo "Fail2Ban configuration complete!"
echo "Check status with: fail2ban-client status"
