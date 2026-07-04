#!/bin/bash
# =================================================================
# Full FreeSWITCH + PHP 8.2 + Fail2Ban + UFW + Glassmorphism Welcome Page
# Supported OS: Debian 11 / Debian 12
# Author: Firoz Sarkar
# =================================================================

set -e  # কোনো কমান্ড ফেইল করলে স্ক্রিপ্ট থেমে যাবে

echo "🚀 FreeSWITCH + Web Welcome Page (with PHP 8.2, Fail2Ban & UFW) Installer চলছে..."

# ==========================================
# ০. Root চেক
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ এই স্ক্রিপ্ট root/sudo দিয়ে চালাতে হবে।"
    exit 1
fi

# ==========================================
# ১. সিস্টেম আপডেট এবং ডিপেন্ডেন্সি ইনস্টল
# ==========================================
echo "🔄 সিস্টেম আপডেট করা হচ্ছে..."
apt update && apt upgrade -y
apt install -y curl git lsb-release gnupg2 apache2 software-properties-common ufw ca-certificates apt-transport-https

# ==========================================
# ২. SignalWire Token চেক
# ==========================================
if [ -z "$TOKEN" ]; then
    echo "❌ Error: TOKEN পাওয়া যায়নি!"
    echo "এভাবে রান করুন:"
    echo "TOKEN=your_signalwire_token ./install.sh"
    exit 1
fi

echo "✅ SignalWire Token গৃহীত হয়েছে।"

# ==========================================
# ৩. PHP 8.2 ইনস্টলেশন (Debian-এর জন্য Repository সহ)
# ==========================================
echo "📦 PHP 8.2 ইনস্টল করা হচ্ছে..."
SUITE=$(lsb_release -sc)

# SURY PHP Repository যোগ করা হচ্ছে
curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $SUITE main" > /etc/apt/sources.list.d/php.list

apt update
apt install -y php8.2 php8.2-cli libapache2-mod-php8.2 php8.2-common php8.2-curl php8.2-xml php8.2-mbstring

# Apache-তে PHP 8.2 এনাবল করা
a2enmod php8.2
a2enmod rewrite
systemctl restart apache2
echo "✅ PHP 8.2 ইনস্টলেশন সম্পন্ন হয়েছে।"

# ==========================================
# ৪. FreeSWITCH ইনস্টলেশন
# ==========================================
echo "📦 FreeSWITCH ইনস্টল করা হচ্ছে..."

curl -sSL https://freeswitch.org/fsget | bash -s "$TOKEN" release install

# Enable & Start Service
systemctl enable freeswitch
systemctl start freeswitch

echo "✅ FreeSWITCH ইনস্টল ও চালু হয়েছে।"

# ==========================================
# ৫. Fail2Ban ফুল অটোমেটিক কনফিগারেশন
# ==========================================
echo "🛡️ Fail2Ban ইনস্টল ও সিকিউরিটি কনফিগার করা হচ্ছে..."
apt install -y fail2ban

# FreeSWITCH লগ থেকে auth failure ধরার filter
cat > /etc/fail2ban/filter.d/freeswitch.conf << 'EOF'
[Definition]
failregex = \[WARNING\].*SIP auth (failure|challenge).*from ip <HOST>
            .*[Cc]an't find user.*from <HOST>
            .*[Cc]hallenging.*from <HOST>
ignoreregex =
EOF

# FreeSWITCH এর জন্য Fail2Ban Jail তৈরি
cat > /etc/fail2ban/jail.d/freeswitch.local << 'EOF'
[freeswitch]
enabled  = true
port     = 5060,5061,5080,5081
filter   = freeswitch
logpath  = /var/log/freeswitch/freeswitch.log
maxretry = 5
findtime = 600
bantime  = -1
backend  = polling
action   = iptables-allports[name=freeswitch, protocol=all]
EOF

# SSH ব্রুট-ফোর্স প্রতিরোধের জন্য জেলও চালু রাখা (fail2ban এ ডিফল্ট আছে, নিশ্চিত করে দিলাম)
cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled  = true
maxretry = 5
findtime = 600
bantime  = 3600
EOF

# Fail2Ban রিস্টার্ট এবং অটো-স্টার্ট
systemctl enable fail2ban
systemctl restart fail2ban
echo "✅ Fail2Ban সিকিউরিটি সেটআপ সম্পন্ন হয়েছে (FreeSWITCH ও SSH পোর্ট সুরক্ষিত)।"

# ==========================================
# ৬. UFW ফায়ারওয়াল কনফিগারেশন
# ==========================================
echo "🔥 UFW ফায়ারওয়াল কনফিগার করা হচ্ছে..."

ufw default deny incoming
ufw default allow outgoing

ufw allow OpenSSH
ufw allow 80/tcp    # HTTP (Web Welcome Page)
ufw allow 443/tcp   # HTTPS (ভবিষ্যতে SSL এর জন্য)
ufw allow 5060/udp  # SIP signaling
ufw allow 5060/tcp
ufw allow 5061/udp
ufw allow 5061/tcp
ufw allow 5080/udp
ufw allow 5080/tcp
ufw allow 5081/udp
ufw allow 5081/tcp
ufw allow 16384:32768/udp  # RTP মিডিয়া পোর্ট রেঞ্জ (freeswitch.xml এর ডিফল্ট রেঞ্জ)

ufw --force enable
echo "✅ UFW ফায়ারওয়াল চালু হয়েছে।"

# ==========================================
# ৭. Glassmorphism UI সহ Welcome Page তৈরি
# ==========================================
echo "🌐 Web Welcome Page তৈরি করা হচ্ছে..."

mkdir -p /var/www/html
rm -f /var/www/html/index.html # Default Apache page রিমুভ

cat > /var/www/html/index.php << 'EOF'
<?php
$ip = $_SERVER['SERVER_ADDR'] ?? 'Unknown';
$fs_status = shell_exec("systemctl is-active freeswitch") ? trim(shell_exec("systemctl is-active freeswitch")) : 'unknown';
$f2b_status = shell_exec("systemctl is-active fail2ban") ? trim(shell_exec("systemctl is-active fail2ban")) : 'unknown';
?>
<!DOCTYPE html>
<html lang="bn">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome - FreeSWITCH Core Platform</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: radial-gradient(circle at center, #1e1e2f 0%, #0f0f1a 100%);
            color: #ffffff;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            overflow: hidden;
        }
        /* Glassmorphic Container */
        .container {
            max-width: 650px;
            width: 90%;
            background: rgba(255, 255, 255, 0.03);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.1);
            padding: 40px;
            border-radius: 24px;
            box-shadow: 0 20px 50px rgba(0, 0, 0, 0.4);
            text-align: center;
        }
        h1 {
            font-size: 2.8em;
            margin-bottom: 5px;
            background: linear-gradient(45deg, #00f2fe, #4facfe);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .subtitle {
            color: #8a8a9e;
            font-size: 1.1em;
            margin-top: 0;
            margin-bottom: 30px;
            letter-spacing: 1px;
        }
        .success-badge {
            background: rgba(0, 230, 118, 0.15);
            color: #00e676;
            padding: 10px 20px;
            border-radius: 50px;
            display: inline-block;
            font-size: 1.1em;
            font-weight: 600;
            margin-bottom: 30px;
            border: 1px solid rgba(0, 230, 118, 0.3);
        }
        /* Grid Info */
        .info-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
            text-align: left;
            margin-top: 20px;
        }
        .info-card {
            background: rgba(255, 255, 255, 0.02);
            border: 1px solid rgba(255, 255, 255, 0.05);
            padding: 15px;
            border-radius: 12px;
        }
        .info-card span {
            display: block;
            font-size: 0.85em;
            color: #8a8a9e;
            text-transform: uppercase;
            margin-bottom: 5px;
        }
        .info-card strong {
            font-size: 1.1em;
            color: #ffffff;
        }
        .status-active {
            color: #00e676 !important;
        }
        .footer-text {
            margin-top: 35px;
            font-size: 0.85em;
            color: #5a5a75;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>FreeSWITCH Server</h1>
        <div class="subtitle">AUTOMATED VOIP PLATFORM</div>

        <div class="success-badge">✓ সার্ভার সফলভাবে ইনস্টল ও কনফিগার হয়েছে</div>

        <div class="info-grid">
            <div class="info-card">
                <span>Server IP</span>
                <strong><?= htmlspecialchars($ip) ?></strong>
            </div>
            <div class="info-card">
                <span>System Time</span>
                <strong><?= date('Y-m-d H:i:s') ?></strong>
            </div>
            <div class="info-card">
                <span>FreeSWITCH Status</span>
                <strong class="<?= $fs_status === 'active' ? 'status-active' : '' ?>"><?= ucfirst($fs_status) ?></strong>
            </div>
            <div class="info-card">
                <span>Fail2Ban Security</span>
                <strong class="<?= $f2b_status === 'active' ? 'status-active' : '' ?>"><?= ucfirst($f2b_status) ?></strong>
            </div>
        </div>

        <div class="footer-text"> Powered by PHP 8.2 & Apache2 Architecture </div>
    </div>
</body>
</html>
EOF

# সঠিক পারমিশন সেট করা
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# Apache রিস্টার্ট
systemctl restart apache2

echo "✅ Welcome Page এবং PHP ইন্টিগ্রেশন সম্পন্ন হয়েছে!"

# ==========================================
# ফাইনাল সামারি মেসেজ
# ==========================================
echo ""
echo "=========================================================="
echo "🎉 অভিনন্দন! অল-ইন-ওয়ান ইনস্টলেশন সম্পূর্ণ হয়েছে।"
echo "=========================================================="
echo ""
echo "🌐 লাইভ ওয়েব ড্যাশবোর্ড দেখুন: http://$(curl -s ifconfig.me || echo 'YOUR_SERVER_IP')"
echo "🔒 Security: UFW ও Fail2Ban সক্রিয় আছে, SIP পোর্ট (5060/5061/5080/5081) মনিটর করছে।"
echo "🔧 FreeSWITCH CLI অ্যাক্সেস করতে লিখুন: fs_cli -rRS"
echo "📋 UFW স্ট্যাটাস দেখতে: ufw status verbose"
echo "📋 Fail2Ban স্ট্যাটাস দেখতে: fail2ban-client status freeswitch"
echo ""
echo "🔥 সবকিছু অটোমেট ও অপ্টিমাইজড করা হয়েছে।"
