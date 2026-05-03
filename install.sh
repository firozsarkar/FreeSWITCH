#!/bin/bash
# ================================================
# Full FreeSWITCH + Welcome Page Installer
# Debian 11 / Debian 12
# ================================================

set -e  # Exit on any error

echo "🚀 FreeSWITCH + Web Welcome Page Installer চলছে..."

# =======================
# 1. Update System
# =======================
apt update && apt upgrade -y
apt install -y curl git lsb-release gnupg2 apache2

# =======================
# 2. SignalWire Token Check
# =======================
if [ -z "$TOKEN" ]; then
    echo "❌ Error: TOKEN পাওয়া যায়নি!"
    echo "এভাবে রান করুন:"
    echo "TOKEN=your_signalwire_token ./install.sh"
    exit 1
fi

echo "✅ SignalWire Token গৃহীত হয়েছে।"

# =======================
# 3. Install FreeSWITCH
# =======================
echo "📦 FreeSWITCH ইনস্টল করা হচ্ছে..."

curl -sSL https://freeswitch.org/fsget | bash -s $TOKEN release install

# Enable & Start Service
systemctl enable freeswitch
systemctl start freeswitch

echo "✅ FreeSWITCH ইনস্টল ও চালু হয়েছে।"

# =======================
# 4. Create Welcome Page
# =======================
echo "🌐 Web Welcome Page তৈরি করা হচ্ছে..."

mkdir -p /var/www/html

cat > /var/www/html/index.php << 'EOF'
<?php
$ip = $_SERVER['SERVER_ADDR'] ?? 'Unknown';
?>
<!DOCTYPE html>
<html lang="bn">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome - FreeSWITCH Server</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            text-align: center;
            padding: 80px 20px;
            margin: 0;
        }
        .container {
            max-width: 700px;
            margin: auto;
            background: rgba(0,0,0,0.2);
            padding: 50px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
        }
        h1 { font-size: 3.5em; margin-bottom: 10px; }
        p { font-size: 1.4em; margin: 15px 0; }
        .success { color: #90EE90; font-size: 1.8em; margin: 25px 0; }
        .info { margin-top: 40px; font-size: 1.2em; opacity: 0.9; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome</h1>
        <p class="success">✅ FreeSWITCH সার্ভার সফলভাবে ইনস্টল হয়েছে!</p>
        <p>আপনার সার্ভার এখন প্রস্তুত।</p>
        
        <div class="info">
            <strong>Server IP:</strong> <?= $ip ?><br><br>
            <strong>Time:</strong> <?= date('Y-m-d H:i:s') ?><br><br>
            <strong>Status:</strong> Running
        </div>
    </div>
</body>
</html>
EOF

# Set proper permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# Restart Apache
systemctl restart apache2

echo "✅ Welcome Page তৈরি হয়েছে!"

# =======================
# Final Message
# =======================
echo ""
echo "========================================"
echo "🎉 ইনস্টলেশন সম্পূর্ণ হয়েছে!"
echo "========================================"
echo ""
echo "🌐 ব্রাউজারে খুলুন: http://$(curl -s ifconfig.me || echo 'YOUR_SERVER_IP')"
echo "🔧 FreeSWITCH CLI: fs_cli -rRS"
echo ""
echo "✅ সবকিছু অটোমেটিক হয়ে গেছে।"
