#!/bin/bash

# ==============================================================================
# Script Name: fullFail2Ban.sh
# Description: Enterprise-grade Fail2Ban setup for FreeSWITCH
# ==============================================================================

if [ "$EUID" -ne 0 ]; then echo "ERROR: Run as root!"; exit 1; fi

echo "--> Installing Fail2Ban and Nftables..."
apt update -y && apt install fail2ban nftables -y

# ১. ফিল্টার তৈরি (সবগুলো প্যাটার্ন কভার করবে)
cat > /etc/fail2ban/filter.d/freeswitch.conf << 'EOF'
[Definition]
failregex = ^.*Can't find user.*from <HOST>.*
            ^.*SIP auth failure.*from <HOST>.*
            ^.*invalid password.*from <HOST>.*
            ^.*SIP registration failure.*from <HOST>.*
            ^.*failed to authorize.*from <HOST>.*
            ^.*authentication failed for <HOST>.*
            ^.*receiving invite from <HOST>.*
            ^.*SIP scan detected from <HOST>.*
            ^.*AUTH FAILURE.*<HOST>.*
            ^.*wrong password.*from <HOST>.*
            ^.*XML-RPC authentication failed for <HOST>.*
            ^.*Event Socket authentication failed from <HOST>.*
ignoreregex =
EOF

# ২. jail.local তৈরি (সবগুলো জেলসহ)
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# এখানে আপনার Trusted IP বা অফিস IP দিন
ignoreip = 127.0.0.1/8
bantime = 1h
findtime = 10m
maxretry = 3
banaction = nftables[type=allports]

# SIP Auth ও Register অ্যাটাক প্রতিরোধের জন্য
[freeswitch-auth]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 3
bantime = 24h

# INVITE ও স্ক্যানিং প্রতিরোধের জন্য
[freeswitch-scan]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 2
findtime = 60
bantime = 1w

# API ও Socket অ্যাটাক প্রতিরোধের জন্য
[freeswitch-api]
enabled = true
filter = freeswitch
logpath = /var/log/freeswitch/freeswitch.log
maxretry = 3
bantime = 12h

# বারবার অপরাধীদের জন্য দীর্ঘমেয়াদী জেল
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 1month
findtime = 86400
maxretry = 5
EOF

# ৩. লগ ফাইল ও সার্ভিস ম্যানেজমেন্ট
touch /var/log/freeswitch/freeswitch.log
chmod 644 /var/log/freeswitch/freeswitch.log

echo "--> Restarting Fail2Ban..."
systemctl restart fail2ban
systemctl enable fail2ban

echo "==============================================================="
echo " SETUP COMPLETE!"
echo " Monitor status with: fail2ban-client status"
echo "==============================================================="
EOF
