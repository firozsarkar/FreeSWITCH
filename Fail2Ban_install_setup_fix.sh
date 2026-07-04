#!/bin/bash
# =====================================================================
# secure.sh
# বিদ্যমান FreeSWITCH ইনস্টলেশন সুরক্ষিত করার স্ক্রিপ্ট
# (re-install করে না, শুধু হার্ডেনিং প্রয়োগ করে)
# Supported OS: Debian 11 / Debian 12
# =====================================================================
#
# রান করার নিয়ম:
#   chmod +x secure.sh
#   sudo ./secure.sh
#
# =====================================================================

set -e

echo "🛡️  FreeSWITCH সার্ভার সিকিউরিটি হার্ডেনিং শুরু হচ্ছে..."

# ==========================================
# ০. Root চেক
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ এই স্ক্রিপ্ট root/sudo দিয়ে চালাতে হবে।"
    exit 1
fi

# ==========================================
# ১. FreeSWITCH ইনস্টল আছে কিনা যাচাই
# ==========================================
if ! command -v fs_cli >/dev/null 2>&1; then
    echo "❌ fs_cli পাওয়া যায়নি। FreeSWITCH ইনস্টল আছে কিনা নিশ্চিত করুন।"
    exit 1
fi

if ! systemctl is-active --quiet freeswitch; then
    echo "⚠️  সতর্কতা: FreeSWITCH সার্ভিস এখন চালু নেই। চালিয়ে নিন: systemctl start freeswitch"
fi

FS_CONF_DIR="/etc/freeswitch"
if [ ! -d "$FS_CONF_DIR" ]; then
    echo "❌ $FS_CONF_DIR পাওয়া যায়নি। কনফিগ পাথ ভিন্ন হলে স্ক্রিপ্টে বদলে নিন।"
    exit 1
fi

echo "✅ FreeSWITCH ইনস্টলেশন শনাক্ত হয়েছে।"

# ==========================================
# ২. প্রয়োজনীয় প্যাকেজ ইনস্টল
# ==========================================
echo "📦 fail2ban ও ufw ইনস্টল করা হচ্ছে (না থাকলে)..."
apt update -y
apt install -y fail2ban ufw

# ==========================================
# ৩. ACL হার্ডেনিং (internal প্রোফাইল বাইরের থেকে বন্ধ করা)
# ==========================================
echo "🔐 ACL কনফিগার করা হচ্ছে..."

ACL_FILE="$FS_CONF_DIR/autoload_configs/acl.conf.xml"
INTERNAL_PROFILE="$FS_CONF_DIR/sip_profiles/internal.xml"
BACKUP_DIR="/root/freeswitch-security-backup-$(date +%F_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -f "$ACL_FILE" ]; then
    cp "$ACL_FILE" "$BACKUP_DIR/"
    if grep -q 'name="domains"' "$ACL_FILE"; then
        sed -i 's#<list name="domains"[^>]*>#<list name="domains" default="deny">#' "$ACL_FILE"
        echo "✅ 'domains' ACL এখন default deny করা হয়েছে।"
    else
        echo "⚠️  'domains' ACL লিস্ট পাওয়া যায়নি — ম্যানুয়ালি চেক করুন: $ACL_FILE"
    fi
else
    echo "⚠️  $ACL_FILE পাওয়া যায়নি, এই ধাপ স্কিপ করা হলো।"
fi

if [ -f "$INTERNAL_PROFILE" ]; then
    cp "$INTERNAL_PROFILE" "$BACKUP_DIR/"

    if ! grep -q 'apply-inbound-acl' "$INTERNAL_PROFILE"; then
        sed -i '/<settings>/a\    <param name="apply-inbound-acl" value="domains"/>' "$INTERNAL_PROFILE"
        echo "✅ apply-inbound-acl যোগ করা হলো।"
    else
        echo "ℹ️  apply-inbound-acl আগে থেকেই আছে, বাদ দেওয়া হলো।"
    fi

    if grep -q 'name="auth-calls"' "$INTERNAL_PROFILE"; then
        sed -i 's#<param name="auth-calls"[^/]*/>#<param name="auth-calls" value="true"/>#' "$INTERNAL_PROFILE"
    else
        sed -i '/<settings>/a\    <param name="auth-calls" value="true"/>' "$INTERNAL_PROFILE"
    fi
    echo "✅ auth-calls=true নিশ্চিত করা হয়েছে।"
else
    echo "⚠️  $INTERNAL_PROFILE পাওয়া যায়নি, এই ধাপ স্কিপ করা হলো।"
fi

# ==========================================
# ৪. Fail2Ban কনফিগারেশন
# ==========================================
echo "🛡️  Fail2Ban কনফিগার করা হচ্ছে..."

FS_LOG="/var/log/freeswitch/freeswitch.log"
if [ ! -f "$FS_LOG" ]; then
    echo "⚠️  $FS_LOG পাওয়া যায়নি — আপনার লগ পাথ ভিন্ন হলে jail.d/freeswitch.local এ ঠিক করে দিন।"
fi

cat > /etc/fail2ban/filter.d/freeswitch.conf << 'EOF'
[Definition]
failregex = \[WARNING\].*SIP auth (failure|challenge).*from ip <HOST>
            .*[Cc]an't find user.*from <HOST>
            .*[Cc]hallenging.*from <HOST>
            .*receiving invite from <HOST>:\d+.*
ignoreregex =
EOF

cat > /etc/fail2ban/jail.d/freeswitch.local << EOF
[freeswitch]
enabled  = true
port     = 5060,5061,5080,5081
filter   = freeswitch
logpath  = $FS_LOG
maxretry = 5
findtime = 600
bantime  = -1
backend  = polling
action   = iptables-allports[name=freeswitch, protocol=all]
EOF

cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled  = true
maxretry = 5
findtime = 600
bantime  = 3600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "✅ Fail2Ban চালু হয়েছে।"

# ==========================================
# ৫. UFW ফায়ারওয়াল
# ==========================================
echo "🔥 UFW ফায়ারওয়াল কনফিগার করা হচ্ছে..."

ufw default deny incoming
ufw default allow outgoing

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 5060/udp
ufw allow 5060/tcp
ufw allow 5061/udp
ufw allow 5061/tcp
ufw allow 5080/udp
ufw allow 5080/tcp
ufw allow 5081/udp
ufw allow 5081/tcp
ufw allow 16384:32768/udp   # RTP রেঞ্জ — আপনার sofia/switch কনফিগের সাথে মিলিয়ে নিন

ufw --force enable
echo "✅ UFW চালু হয়েছে।"

# ==========================================
# ৬. এখনই যে IP গুলো স্ক্যান করছে সেগুলো ব্লক করার অপশন
# ==========================================
echo ""
echo "🔍 বিগত কিছুক্ষণে সন্দেহজনক IP খোঁজা হচ্ছে (লগ থেকে)..."
if [ -f "$FS_LOG" ]; then
    SUSPECTS=$(grep -Eo "receiving invite from [0-9.]+" "$FS_LOG" 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn | head -10 || true)
    if [ -n "$SUSPECTS" ]; then
        echo "সাম্প্রতিক INVITE-পাঠানো IP (বেশি সংখ্যক মানেই সন্দেহজনক):"
        echo "$SUSPECTS"
        echo ""
        echo "কোনো IP সরাসরি ব্লক করতে চাইলে:"
        echo "  sudo iptables -I INPUT -s <IP> -j DROP && sudo netfilter-persistent save"
    else
        echo "লগে সাম্প্রতিক সন্দেহজনক INVITE পাওয়া যায়নি।"
    fi
fi

# ==========================================
# ৭. FreeSWITCH রিলোড
# ==========================================
echo ""
echo "🔄 FreeSWITCH ACL ও sofia profile রিলোড করা হচ্ছে..."
fs_cli -x "reloadacl" || echo "⚠️  reloadacl কমান্ড ব্যর্থ হয়েছে, ম্যানুয়ালি চেক করুন।"
fs_cli -x "sofia profile internal restart" || echo "⚠️  sofia profile restart ব্যর্থ হয়েছে, ম্যানুয়ালি চেক করুন।"
echo "✅ রিলোড সম্পন্ন।"

# ==========================================
# ফাইনাল সামারি
# ==========================================
echo ""
echo "=========================================================="
echo "🎉 সিকিউরিটি হার্ডেনিং সম্পন্ন হয়েছে!"
echo "=========================================================="
echo ""
echo "🔐 ACL: internal প্রোফাইলে auth-calls ও domains ACL সক্রিয়"
echo "🔒 Fail2Ban: SIP scan/auth-failure প্যাটার্ন মনিটর করছে"
echo "🔥 UFW: শুধু SSH, HTTP/HTTPS, SIP, RTP পোর্ট খোলা"
echo ""
echo "📋 চেক করুন:"
echo "   sudo ufw status verbose"
echo "   sudo fail2ban-client status freeswitch"
echo "   sudo fs_cli -x 'sofia status profile internal'"
echo ""
echo "💾 পরিবর্তনের আগের ফাইল ব্যাকআপ আছে এখানে: $BACKUP_DIR"
echo ""
echo "⚠️  গুরুত্বপূর্ণ: auth-calls=true চালু হওয়ার ফলে যদি আপনার কোনো"
echo "    ট্রাঙ্ক/প্রোভাইডার unauthenticated (IP-based) ভাবে রেজিস্টার করে,"
echo "    সেটা আর কানেক্ট নাও হতে পারে। প্রয়োজনে সেই ট্রাঙ্কের IP আলাদাভাবে"
echo "    ACL হোয়াইটলিস্টে যোগ করুন acl.conf.xml এ।"
