#!/bin/bash
set -e

echo "========================================="
echo "  Debian 11 - Nginx & PHP 8.2 Installer"
echo "========================================="

# ১. সিস্টেম আপডেট
echo "[*] প্যাকেজ লিস্ট আপডেট করা হচ্ছে..."
sudo apt update

# ২. সরাসরি PHP 8.2 এবং প্রয়োজনীয় এক্সটেনশন ইনস্টল 
# (যেহেতু রিপোজিটরি অলরেডি সিস্টেমে আছে)
echo "[*] PHP 8.2 এবং প্রয়োজনীয় এক্সটেনশন ইনস্টল করা হচ্ছে..."
sudo apt install -y php8.2-fpm php8.2-cli php8.2-common php8.2-mysql php8.2-curl php8.2-xml php8.2-mbstring php8.2-zip php8.2-gd php8.2-sqlite3 php8.2-bcmath php8.2-soap

# ৩. Nginx ওয়েব সার্ভার ইনস্টল
echo "[*] Nginx ওয়েব সার্ভার ইনস্টল করা হচ্ছে..."
sudo apt install -y nginx

# ৪. ওয়েব ডিরেক্টরি পারমিশন ঠিক করা
echo "[*] ওয়েব ডিরেক্টরি সেটআপ করা হচ্ছে..."
sudo mkdir -p /var/www/html
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html

# ৫. index.php ড্যাশবোর্ড ফাইল তৈরি
echo "[*] index.php ফাইল তৈরি করা হচ্ছে..."
sudo tee /var/www/html/index.php > /dev/null << 'EOF'
<?php
header("Content-Type: text/html; charset=UTF-8");
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Gateway Engine</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f6f9; color: #333; margin: 0; padding: 40px; text-align: center; }
        .container { max-width: 600px; background: white; margin: 0 auto; padding: 30px; border-radius: 8px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        h1 { color: #2c3e50; font-size: 24px; margin-bottom: 10px; }
        p { color: #7f8c8d; font-size: 16px; }
        .status { display: inline-block; margin: 20px auto; padding: 8px 15px; background-color: #2ecc71; color: white; border-radius: 20px; font-weight: bold; font-size: 14px; }
        .info { text-align: left; background: #f8f9fa; padding: 15px; border-radius: 5px; font-family: monospace; font-size: 13px; border-left: 4px solid #3498db; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Node Dashboard</h1>
        <p>Nginx and PHP 8.2 are running successfully on this endpoint.</p>
        <div class="status">System Online</div>
        <div class="info">
            <strong>Server IP:</strong> <?php echo $_SERVER['SERVER_ADDR'] ?? $_SERVER['LOCAL_ADDR'] ?? '127.0.0.1'; ?><br>
            <strong>PHP Version:</strong> <?php echo phpversion(); ?><br>
            <strong>Request Time:</strong> <?php echo date('Y-m-d H:i:s'); ?>
        </div>
    </div>
</body>
</html>
EOF

# 6. Nginx ডিফল্ট সাইট কনফিগারেশন আপডেট (PHP 8.2 FPM সকেট সহ)
echo "[*] Nginx ডিফল্ট কনফিগারেশন তৈরি করা হচ্ছে..."
sudo tee /etc/nginx/sites-available/default > /dev/null << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.php index.html index.htm;

    server_name _;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# ৭. সার্ভিস রিস্টার্ট ও বুট এনাবেল
echo "[*] সার্ভিসগুলো রিস্টার্ট করা হচ্ছে..."
sudo systemctl restart php8.2-fpm
sudo systemctl restart nginx
sudo systemctl enable php8.2-fpm
sudo systemctl enable nginx

echo "========================================="
echo "   ইনস্টলেশন সফলভাবে সম্পন্ন হয়েছে!"
echo "========================================="
