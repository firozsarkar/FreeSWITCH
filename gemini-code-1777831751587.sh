#!/bin/bash
# FreeSWITCH Installation Script for Debian 12

if [ "$EUID" -ne 0 ]; then
  echo "[-] অনুগ্রহ করে রুট (root) ইউজার হিসেবে স্ক্রিপ্টটি চালান (sudo bash install.sh)."
  exit 1
fi

set -e

echo "[+] FreeSWITCH ইনস্টলেশন প্রক্রিয়া শুরু হচ্ছে..."

# ১. সিস্টেম আপডেট করুন এবং curl ইনস্টল করুন
echo "[+] সিস্টেম আপডেট এবং curl ইনস্টল করা হচ্ছে..."
apt-get update -y && apt-get install -y curl

# ২. SignalWire Token
TOKEN="pat_3F3fQQ2Ce9u4E7k2CXTpit2t"

# ৩. FreeSWITCH ডাউনলোড এবং ইনস্টল করুন
echo "[+] SignalWire থেকে FreeSWITCH ডাউনলোড এবং ইনস্টল করা হচ্ছে..."
curl -sSL https://freeswitch.org/fsget | bash -s $TOKEN release install

# ৪. সার্ভিস স্টার্ট এবং এনাবল করুন
echo "[+] FreeSWITCH সার্ভিস চালু এবং এনাবল করা হচ্ছে..."
systemctl daemon-reload
systemctl enable freeswitch
systemctl start freeswitch

echo "=================================================="
echo " [✓] FreeSWITCH সফলভাবে ইনস্টল হয়েছে!"
echo "=================================================="
echo " -> FreeSWITCH কনসোলে ঢুকতে টাইপ করুন: fs_cli"
echo "=================================================="