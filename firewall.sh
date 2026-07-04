#!/bin/bash
#
# FreeSWITCH Firewall Auto-Setup Script (Debian/Ubuntu)
# ------------------------------------------------------
# এই স্ক্রিপ্ট iptables দিয়ে ফায়ারওয়াল সেটআপ করে, fail2ban ইনস্টল করে,
# এবং FreeSWITCH SIP/RTP পোর্ট সিকিউর করে।
#
# চালানোর নিয়ম:
#   sudo bash firewall.sh
#
# চালানোর আগে নিচের ভ্যারিয়েবলগুলো নিজের মতো করে বদলে নিন।

set -e

# ================== কনফিগারেশন (দরকার হলে বদলান) ==================

SSH_PORT=22                     # আপনার SSH পোর্ট
SIP_UDP_PORTS="5060:5091"       # SIP signaling (UDP)
SIP_TCP_PORTS="5060:5091"       # SIP signaling (TCP, দরকার হলে)
RTP_PORT_RANGE="16384:32768"    # RTP মিডিয়া পোর্ট রেঞ্জ (freeswitch.xml এ যা সেট করা আছে তা মেলান)
ALLOWED_SIP_IPS=()              # উদাহরণ: ("203.0.113.10" "198.51.100.20") — খালি রাখলে সবার জন্য SIP খোলা থাকবে
ENABLE_FAIL2BAN=true            # true/false

# ====================================================================

if [ "$EUID" -ne 0 ]; then
  echo "এই স্ক্রিপ্ট root/sudo দিয়ে চালাতে হবে।"
  exit 1
fi

echo ">>> প্যাকেজ ইনডেক্স আপডেট করা হচ্ছে..."
apt update -y

echo ">>> iptables ও প্রয়োজনীয় প্যাকেজ ইনস্টল করা হচ্ছে..."
apt install -y iptables iptables-persistent netfilter-persistent

if [ "$ENABLE_FAIL2BAN" = true ]; then
  echo ">>> fail2ban ইনস্টল করা হচ্ছে..."
  apt install -y fail2ban
fi

echo ">>> বিদ্যমান iptables rules ব্যাকআপ নেওয়া হচ্ছে..."
mkdir -p /etc/iptables/backup
iptables-save > /etc/iptables/backup/iptables-backup-$(date +%F_%H%M%S).rules

echo ">>> Firewall rules রিসেট করা হচ্ছে..."
iptables -F
iptables -X
iptables -Z

echo ">>> ডিফল্ট পলিসি সেট করা হচ্ছে (drop by default)..."
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

echo ">>> Loopback interface allow করা হচ্ছে..."
iptables -A INPUT -i lo -j ACCEPT

echo ">>> Established/related কানেকশন allow করা হচ্ছে..."
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo ">>> Invalid প্যাকেট ড্রপ করা হচ্ছে..."
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

echo ">>> SSH ($SSH_PORT/tcp) allow করা হচ্ছে (brute force রেট-লিমিট সহ)..."
iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --set --name SSH
iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 6 --name SSH -j DROP
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT

echo ">>> ICMP (ping) সীমিত হারে allow করা হচ্ছে..."
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT

if [ ${#ALLOWED_SIP_IPS[@]} -eq 0 ]; then
  echo ">>> SIP পোর্ট সবার জন্য খোলা হচ্ছে (ALLOWED_SIP_IPS খালি আছে)..."
  iptables -A INPUT -p udp --dport "$SIP_UDP_PORTS" -j ACCEPT
  iptables -A INPUT -p tcp --dport "$SIP_TCP_PORTS" -j ACCEPT
else
  echo ">>> শুধুমাত্র নির্দিষ্ট IP থেকে SIP allow করা হচ্ছে..."
  for ip in "${ALLOWED_SIP_IPS[@]}"; do
    iptables -A INPUT -p udp -s "$ip" --dport "$SIP_UDP_PORTS" -j ACCEPT
    iptables -A INPUT -p tcp -s "$ip" --dport "$SIP_TCP_PORTS" -j ACCEPT
  done
fi

echo ">>> RTP মিডিয়া পোর্ট রেঞ্জ allow করা হচ্ছে..."
iptables -A INPUT -p udp --dport "$RTP_PORT_RANGE" -j ACCEPT

echo ">>> বাকি সব ইনকামিং ট্রাফিক ড্রপ ও লগ করা হচ্ছে..."
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables-dropped: " --log-level 4
iptables -A INPUT -j DROP

echo ">>> Rules সেভ করা হচ্ছে (রিবুটের পরও থাকবে)..."
netfilter-persistent save

if [ "$ENABLE_FAIL2BAN" = true ]; then
  echo ">>> fail2ban এর জন্য FreeSWITCH filter তৈরি করা হচ্ছে..."
  cat > /etc/fail2ban/filter.d/freeswitch.conf <<'EOF'
[Definition]
failregex = \[WARNING\].*SIP auth (failure|challenge).*from ip <HOST>
            .*[Cc]an't find user.*from <HOST>
            .*[Cc]hallenging.*from <HOST>
ignoreregex =
EOF

  echo ">>> fail2ban jail কনফিগার করা হচ্ছে..."
  cat > /etc/fail2ban/jail.d/freeswitch.local <<EOF
[freeswitch]
enabled  = true
port     = ${SIP_UDP_PORTS%%:*}:${SIP_UDP_PORTS##*:}
protocol = udp
filter   = freeswitch
logpath  = /var/log/freeswitch/freeswitch.log
maxretry = 5
findtime = 600
bantime  = 3600
action   = iptables-allports[name=freeswitch, protocol=all]
EOF

  echo ">>> fail2ban রিস্টার্ট করা হচ্ছে..."
  systemctl enable fail2ban
  systemctl restart fail2ban
  sleep 2
  fail2ban-client status freeswitch || echo "সতর্কতা: freeswitch jail স্ট্যাটাস চেক করা যায়নি, লগ পাথ ঠিক আছে কিনা দেখুন।"
fi

echo ""
echo "======================================================"
echo " সেটআপ সম্পন্ন হয়েছে।"
echo " বর্তমান iptables rules দেখতে: sudo iptables -L -n -v"
echo " fail2ban স্ট্যাটাস দেখতে:     sudo fail2ban-client status freeswitch"
echo "======================================================"
