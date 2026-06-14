#!/bin/bash

# ==============================================================================
# Script Name: Fail2Ban.sh
# Description: Full automated installation and optimization of Fail2Ban 
#              specifically tuned for Debian 11/12, FreeSWITCH, and nftables.
# ==============================================================================

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root or with sudo privileges."
    exit 1
fi

echo "================================================================="
echo " Starting Fail2Ban Automated Installation & Configuration"
echo " Target System: Debian 11 / Debian 12 (Optimized with nftables)"
echo "================================================================="

# ------------------------------------------------------------------------------
# Step 1: System Package Update and Prerequisites Installation
# ------------------------------------------------------------------------------
echo "--> [1/10] Updating package repositories..."
apt update -y

echo "--> [2/10] Installing Fail2Ban, nftables, and systemd dependencies..."
# Installing python3-systemd for Debian native logs and nftables for bulletproof blocking
apt install fail2ban nftables python3-systemd -y

# ------------------------------------------------------------------------------
# Step 2: Cleanup Dead Sockets, Lock Files, and Legacy Configurations
# ------------------------------------------------------------------------------
echo "--> [3/10] Clearing older socket paths and old configurations..."
systemctl stop fail2ban >/dev/null 2>&1
rm -f /var/run/fail2ban/fail2ban.sock
rm -f /var/run/fail2ban/fail2ban.pid
rm -f /etc/fail2ban/jail.local
rm -f /etc/fail2ban/filter.d/freeswitch.conf

# ------------------------------------------------------------------------------
# Step 3: Create Custom FreeSWITCH Filter
# ------------------------------------------------------------------------------
echo "--> [4/10] Creating FreeSWITCH filter definition..."

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

# ------------------------------------------------------------------------------
# Step 4: Ensure FreeSWITCH Log Directory Exists
# ------------------------------------------------------------------------------
echo "--> [5/10] Verifying FreeSWITCH logging ecosystem..."
mkdir -p /var/log/freeswitch
touch /var/log/freeswitch/freeswitch.log
chmod 644 /var/log/freeswitch/freeswitch.log

# ------------------------------------------------------------------------------
# Step 5: Generate Tailored jail.local with nftables & Lifetime Ban
# ------------------------------------------------------------------------------
echo "--> [6/10] Deploying unified jail.local..."

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# Forced native systemd backend for system log scanning on Debian 11/12
backend = systemd
# Fixed Ghost Hits by routing bans directly through modern Debian nftables architecture
banaction = nftables[type=allports]
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd

[freeswitch]
enabled = true
filter = freeswitch
port = 5060,5061
protocol = all
logpath = /var/log/freeswitch/freeswitch.log
backend = auto
maxretry = 2
findtime = 3600
# Permanent/Lifetime block for aggressive attackers
bantime = -1  

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
backend = auto
maxretry = 2
findtime = 86400
# Permanent/Lifetime block for repeated offenders
bantime = -1
EOF

# ------------------------------------------------------------------------------
# Step 6: Configuration Integrity Verification
# ------------------------------------------------------------------------------
echo "--> [7/10] Testing Fail2Ban configuration for syntax validation..."

if fail2ban-server -t > /dev/null 2>&1; then
    echo "✔ Configuration syntax validation passed successfully."
else
    echo "✘ Configuration syntax error discovered! Inspecting configuration..."
    fail2ban-server -t
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 7: Service Initialization and Execution
# ------------------------------------------------------------------------------
echo "--> [8/10] Initializing Fail2Ban engine daemon..."

systemctl daemon-reload
systemctl enable fail2ban
systemctl restart fail2ban

# Allow time for the socket initialization process to complete
sleep 3

# ------------------------------------------------------------------------------
# Step 8: Operational Status Check
# ------------------------------------------------------------------------------
echo "--> [9/10] Analyzing service runtime environment..."

if [ -S /var/run/fail2ban/fail2ban.sock ]; then
    echo "✔ Socket connection initialized successfully."
    echo ""
    systemctl --no-pager status fail2ban
else
    echo "✘ Fail2Ban failed to initialize its socket channel. Reviewing system logs:"
    journalctl -u fail2ban --no-pager -n 20
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 9: Jail Verification Matrix
# ------------------------------------------------------------------------------
echo ""
echo "--> [10/10] Querying active Jail Matrix..."
echo "----------------------------------------------------------------="
fail2ban-client status
echo "----------------------------------------------------------------="

echo ""
echo "================================================================="
echo " FreeSWITCH Specific Jail Details"
echo "================================================================="
fail2ban-client status freeswitch

echo ""
echo "================================================================="
echo " DEPLOYMENT AND CONFIGURATION COMPLETE"
echo "================================================================="
echo "Useful Commands Matrix:"
echo " - View General Status:       fail2ban-client status"
echo " - View FreeSWITCH Status:  fail2ban-client status freeswitch"
echo " - Live Log Monitoring:      tail -f /var/log/fail2ban.log"
echo " - Realtime Prison Watch:    watch -n 2 fail2ban-client status freeswitch"
echo "================================================================="
