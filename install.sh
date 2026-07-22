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
apt install -y curl git lsb-release gnupg2 apache2 software-properties-common ufw ca-certificates apt-transport-https net-tools

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
# ৩. PHP 8.2 ইনস্টলেশন
# ==========================================
echo "📦 PHP 8.2 ইনস্টল করা হচ্ছে..."
SUITE=$(lsb_release -sc)

# SURY PHP Repository যোগ করা হচ্ছে
curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $SUITE main" > /etc/apt/sources.list.d/php.list

apt update
apt install -y php8.2 php8.2-cli libapache2-mod-php8.2 php8.2-common php8.2-curl php8.2-xml php8.2-mbstring

# ==========================================
# ৪. Apache কনফিগারেশন ঠিক করা
# ==========================================
echo "🔧 Apache কনফিগার করা হচ্ছে..."

# Apache-তে PHP 8.2 এনাবল করা
a2enmod php8.2
a2enmod rewrite

# Apache কনফিগারেশন ফাইল তৈরি করা
cat > /etc/apache2/sites-available/000-default.conf << 'EOF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Directory Index কনফিগারেশন
cat > /etc/apache2/mods-available/dir.conf << 'EOF'
<IfModule mod_dir.c>
    DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm
</IfModule>
EOF

# Apache রিস্টার্ট
systemctl restart apache2

# Apache স্ট্যাটাস চেক
if systemctl is-active --quiet apache2; then
    echo "✅ Apache সফলভাবে চলছে"
else
    echo "❌ Apache চলছে না, সমস্যা সমাধান করা হচ্ছে..."
    systemctl status apache2
    exit 1
fi

# ==========================================
# ৫. FreeSWITCH ইনস্টলেশন
# ==========================================
echo "📦 FreeSWITCH ইনস্টল করা হচ্ছে..."

curl -sSL https://freeswitch.org/fsget | bash -s "$TOKEN" release install

# Enable & Start Service
systemctl enable freeswitch
systemctl start freeswitch

echo "✅ FreeSWITCH ইনস্টল ও চালু হয়েছে।"

# ==========================================
# ৬. Fail2Ban ফুল অটোমেটিক কনফিগারেশন
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

# SSH ব্রুট-ফোর্স প্রতিরোধের জন্য জেলও চালু রাখা
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
echo "✅ Fail2Ban সিকিউরিটি সেটআপ সম্পন্ন হয়েছে।"

# ==========================================
# ৭. UFW ফায়ারওয়াল কনফিগারেশন
# ==========================================
echo "🔥 UFW ফায়ারওয়াল কনফিগার করা হচ্ছে..."

ufw default deny incoming
ufw default allow outgoing

ufw allow OpenSSH
ufw allow 80/tcp    # HTTP (Web Welcome Page)
ufw allow 443/tcp   # HTTPS
ufw allow 5060/udp  # SIP signaling
ufw allow 5060/tcp
ufw allow 5061/udp
ufw allow 5061/tcp
ufw allow 5080/udp
ufw allow 5080/tcp
ufw allow 5081/udp
ufw allow 5081/tcp
ufw allow 16384:32768/udp  # RTP মিডিয়া পোর্ট রেঞ্জ

ufw --force enable
echo "✅ UFW ফায়ারওয়াল চালু হয়েছে।"

# ==========================================
# ৮. Glassmorphism UI সহ Welcome Page তৈরি
# ==========================================
echo "🌐 Web Welcome Page তৈরি করা হচ্ছে..."

# HTML ফাইল ডিলিট করে PHP ফাইল তৈরি
rm -f /var/www/html/index.html
rm -f /var/www/html/index.php

# ওয়েব রুট ডিরেক্টরি তৈরি
mkdir -p /var/www/html

cat > /var/www/html/index.php << 'EOF'
<?php
// PHP Error Reporting Off
error_reporting(0);

// Server Information
$ip = $_SERVER['SERVER_ADDR'] ?? 'Unknown';
$hostname = gethostname();

// Service Status Check
$fs_status = 'unknown';
$f2b_status = 'unknown';

// Check FreeSWITCH
$fs_check = shell_exec("systemctl is-active freeswitch 2>/dev/null");
if ($fs_check) {
    $fs_status = trim($fs_check);
}

// Check Fail2Ban
$f2b_check = shell_exec("systemctl is-active fail2ban 2>/dev/null");
if ($f2b_check) {
    $f2b_status = trim($f2b_check);
}

// Get server load
$load = sys_getloadavg();
$load_display = isset($load[0]) ? number_format($load[0], 2) : 'N/A';
?>
<!DOCTYPE html>
<html lang="bn">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome - FreeSWITCH Core Platform</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: radial-gradient(circle at 30% 30%, #1a1a2e, #0f0f1a 80%);
            color: #ffffff;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }
        .container {
            max-width: 700px;
            width: 100%;
            background: rgba(255, 255, 255, 0.05);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid rgba(255, 255, 255, 0.1);
            padding: 45px 40px;
            border-radius: 30px;
            box-shadow: 0 30px 70px rgba(0, 0, 0, 0.6);
            text-align: center;
            transition: all 0.3s ease;
        }
        .container:hover {
            transform: translateY(-5px);
            box-shadow: 0 40px 80px rgba(0, 0, 0, 0.8);
        }
        .logo-icon {
            font-size: 4em;
            margin-bottom: 10px;
            display: block;
        }
        h1 {
            font-size: 2.8em;
            margin-bottom: 5px;
            background: linear-gradient(135deg, #00f2fe, #4facfe, #43e97b);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        .subtitle {
            color: #a0a0b8;
            font-size: 1.1em;
            margin-top: 0;
            margin-bottom: 25px;
            letter-spacing: 3px;
            font-weight: 300;
        }
        .success-badge {
            background: rgba(0, 230, 118, 0.12);
            color: #00e676;
            padding: 12px 25px;
            border-radius: 50px;
            display: inline-block;
            font-size: 1em;
            font-weight: 600;
            margin-bottom: 30px;
            border: 1px solid rgba(0, 230, 118, 0.2);
            backdrop-filter: blur(10px);
        }
        .info-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
            text-align: left;
            margin-top: 20px;
        }
        .info-card {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.06);
            padding: 18px 20px;
            border-radius: 16px;
            transition: all 0.3s ease;
        }
        .info-card:hover {
            background: rgba(255, 255, 255, 0.06);
            border-color: rgba(255, 255, 255, 0.1);
        }
        .info-card span {
            display: block;
            font-size: 0.75em;
            color: #8a8a9e;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 6px;
            font-weight: 600;
        }
        .info-card strong {
            font-size: 1.1em;
            color: #ffffff;
            font-weight: 500;
        }
        .status-active {
            color: #00e676 !important;
        }
        .status-inactive {
            color: #ff6b6b !important;
        }
        .status-unknown {
            color: #ffd93d !important;
        }
        .footer-text {
            margin-top: 35px;
            font-size: 0.8em;
            color: #5a5a75;
            border-top: 1px solid rgba(255, 255, 255, 0.05);
            padding-top: 25px;
        }
        .footer-text span {
            color: #4facfe;
        }
        @media (max-width: 600px) {
            .container {
                padding: 30px 20px;
            }
            h1 {
                font-size: 2em;
            }
            .info-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <span class="logo-icon">📞</span>
        <h1>FreeSWITCH Server</h1>
        <div class="subtitle">✦ AUTOMATED VOIP PLATFORM ✦</div>

        <div class="success-badge">
            ✓ সার্ভার সফলভাবে ইনস্টল ও কনফিগার হয়েছে
        </div>

        <div class="info-grid">
            <div class="info-card">
                <span>🌐 Server IP</span>
                <strong><?= htmlspecialchars($ip) ?></strong>
            </div>
            <div class="info-card">
                <span>🖥️ Hostname</span>
                <strong><?= htmlspecialchars($hostname) ?></strong>
            </div>
            <div class="info-card">
                <span>⏰ System Time</span>
                <strong><?= date('d-m-Y H:i:s') ?></strong>
            </div>
            <div class="info-card">
                <span>📊 Server Load</span>
                <strong><?= $load_display ?></strong>
            </div>
            <div class="info-card">
                <span>📞 FreeSWITCH</span>
                <strong class="<?= $fs_status === 'active' ? 'status-active' : ($fs_status === 'inactive' ? 'status-inactive' : 'status-unknown') ?>">
                    <?= $fs_status === 'active' ? '✅ Active' : ($fs_status === 'inactive' ? '❌ Inactive' : '⚠️ Unknown') ?>
                </strong>
            </div>
            <div class="info-card">
                <span>🛡️ Fail2Ban</span>
                <strong class="<?= $f2b_status === 'active' ? 'status-active' : ($f2b_status === 'inactive' ? 'status-inactive' : 'status-unknown') ?>">
                    <?= $f2b_status === 'active' ? '✅ Active' : ($f2b_status === 'inactive' ? '❌ Inactive' : '⚠️ Unknown') ?>
                </strong>
            </div>
        </div>

        <div class="footer-text">
            ⚡ Powered by <span>PHP 8.2</span> & <span>Apache2</span> Architecture
        </div>
    </div>
</body>
</html>
EOF

# সঠিক পারমিশন সেট করা
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# টেস্ট PHP ফাইল তৈরি (PHP কাজ করছে কিনা চেক করতে)
echo "<?php phpinfo(); ?>" > /var/www/html/info.php
chown www-data:www-data /var/www/html/info.php

# Apache রিস্টার্ট
systemctl restart apache2

echo "✅ Welcome Page এবং PHP ইন্টিগ্রেশন সম্পন্ন হয়েছে!"

# ==========================================
# ৯. ওয়েব সার্ভার টেস্ট
# ==========================================
echo "🧪 ওয়েব সার্ভার টেস্ট করা হচ্ছে..."

# লোকাল হোস্টে টেস্ট
if curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q "200"; then
    echo "✅ ওয়েব সার্ভার সঠিকভাবে কাজ করছে!"
else
    echo "⚠️ ওয়েব সার্ভার টেস্টে সমস্যা, কিন্তু Apache চলছে কিনা চেক করুন:"
    systemctl status apache2
fi

# ==========================================
# ১০. IP ঠিকানা বের করা
# ==========================================
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "YOUR_SERVER_IP")

# ==========================================
# ফাইনাল সামারি মেসেজ
# ==========================================
echo ""
echo "=========================================================="
echo "🎉 অভিনন্দন! অল-ইন-ওয়ান ইনস্টলেশন সম্পূর্ণ হয়েছে।"
echo "=========================================================="
echo ""
echo "🌐 লাইভ ওয়েব ড্যাশবোর্ড দেখুন:"
echo "   🔗 http://$SERVER_IP"
echo "   🔗 http://$SERVER_IP/info.php (PHP Information)"
echo ""
echo "🔒 Security: UFW ও Fail2Ban সক্রিয় আছে"
echo "   📋 UFW স্ট্যাটাস: ufw status verbose"
echo "   📋 Fail2Ban: fail2ban-client status freeswitch"
echo ""
echo "🔧 FreeSWITCH CLI: fs_cli -rRS"
echo ""
echo "📝 Apache Log: tail -f /var/log/apache2/error.log"
echo "📝 FreeSWITCH Log: tail -f /var/log/freeswitch/freeswitch.log"
echo ""
echo "🔥 সবকিছু অটোমেট ও অপ্টিমাইজড করা হয়েছে।"
echo "=========================================================="
