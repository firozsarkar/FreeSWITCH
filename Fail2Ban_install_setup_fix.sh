#!/bin/bash

echo "------------------------------------------"
echo "Fail2Ban Auto-Fixer started..."
echo "------------------------------------------"

# ১. পুরনো বা আটকে থাকা সকেট এবং পিআইডি ফাইল পরিষ্কার করা
echo "[1/4] Cleaning up old socket and pid files..."
sudo rm -f /var/run/fail2ban/fail2ban.sock
sudo rm -f /var/run/fail2ban/fail2ban.pid

# ২. কনফিগারেশনে কোনো সিনট্যাক্স এরর আছে কিনা চেক করা
echo "[2/4] Testing configuration syntax..."
if sudo fail2ban-server -t > /dev/null 2>&1; then
    echo "✔ Configuration is OK."
else
    echo "✘ Configuration error detected! Please check your jail.local file."
    sudo fail2ban-server -t
    exit 1
fi

# ৩. সার্ভিস রিস্টার্ট দেওয়া
echo "[3/4] Restarting Fail2Ban service..."
sudo systemctl restart fail2ban

# ৪. সার্ভিস স্ট্যাটাস এবং সকেট ফাইল চেক করা
sleep 2
if [ -S /var/run/fail2ban/fail2ban.sock ]; then
    echo "✔ Fail2Ban is running successfully."
    echo "------------------------------------------"
    sudo fail2ban-client status
else
    echo "✘ Fail2Ban failed to create socket. Check /var/log/fail2ban.log"
    sudo journalctl -u fail2ban --no-pager -n 10
fi

echo "------------------------------------------"
