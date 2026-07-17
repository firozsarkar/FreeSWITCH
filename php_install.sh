#!/bin/bash

# ভুল হলে স্ক্রিপ্ট স্টপ করার জন্য
set -e

echo "========================================="
echo "  Nginx, PHP 8.2 & Dependencies Installer"
echo "========================================="

# ১. সিস্টেম আপডেট
echo "[*] সিস্টেম আপডেট করা হচ্ছে..."
sudo apt update && sudo apt upgrade -y

# ২. প্রয়োজনীয় সাধারণ ডিপেন্ডেন্সি ইনস্টল
echo "[*] প্রয়োজনীয় টুলস ইনস্টল করা হচ্ছে..."
sudo apt install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common unzip git

# ৩. PHP 8.2 এর জন্য SURY Repository যোগ করা
echo "[*] PHP 8.2 রিপোজিটরি সেটআপ করা হচ্ছে..."
sudo lsb_release -sc | grep -q 'bookworm\|bullseye\|focal\|jammy' || {
    echo "[!] OS সংস্করণ সামঞ্জস্যপূর্ণ নয় বা চেক করা যাচ্ছে না। সাধারণ প্রসেস চলছে..."
}
sudo add-apt-repository ppa:ondrej/php -y || {
    # Debian এর জন্য যদি PPA কাজ না করে
    sudo wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/php.list
}
sudo apt update

# ৪. PHP 8.2 এবং কমন এক্সটেনশন ইনস্টল
echo "[*] PHP 8.2 এবং প্রয়োজনীয় এক্সটেনশন ইনস্টল করা হচ্ছে..."
sudo apt install -y php8.2-fpm php8.2-cli php8.2-common php8.2-mysql php8.2-curl php8.2-xml php8.2-mbstring php8.2-zip php8.2-gd php8.2-sqlite3 php8.2-bcmath php8.2-soap

# ৫. Nginx ইনস্টল
echo "[*] Nginx ওয়েব সার্ভার ইনস্টল করা হচ্ছে..."
sudo apt install -y nginx

# ৬. ওয়েব ডিরেক্টরি এবং index.php তৈরি
echo "[*] ওয়েব ডিরেক্টরি পারমিশন এবং index.php তৈরি করা হচ্ছে..."
sudo mkdir -p /var/www/html
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html

# একটি সিম্পল index.php ফাইল তৈরি (ফ্রিইচউইচ সার্ভার ইনফো দেখার জন্য)
sudo tee /var/www/html/index.php > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
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
        .status { inline-size: fit-content; margin: 20px auto; padding: 8px 15px; background-color: #2ecc71; color: white; border-radius: 20px; font-weight: bold; font-size: 14px; }
        .info { text-align: left; background: #f8f9fa; padding: 15px; border-radius: 5px; font-family: monospace; font-size: 13px; border-left: 4px solid #3498db; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Node Dashboard</h1>
        <p>Nginx and PHP 8.2 are running successfully on this endpoint.</p>
        <div class="status">System Online</div>
        <div class="info">
            <strong>Server IP:</strong> <?php echo $_SERVER['SERVER_ADDR']; ?><br>
            <strong>PHP Version:</strong> <?php echo phpversion(); ?><br>
            <strong>Request Time:</strong> <?php echo date('Y-m-d H:i:s'); ?>
        </div>
    </div>
</body>
</html>
EOF

# ৭. FreeSWITCH IP তে রান করার জন্য Nginx ডিফল্ট কনফিগারেশন পরিবর্তন
echo "[*] Nginx ডিফল্ট সাইট কনফিগার করা হচ্ছে..."
sudo tee /etc/nginx/sites-available/default > /dev/null << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    
    # index.php কে প্রথমে প্রায়োরিটি দেওয়া হয়েছে
    index index.php index.html index.htm;

    server_name _;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # PHP-FPM এর মাধ্যমে PHP ফাইল প্রসেস করার কনফিগারেশন
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    # .htaccess বা হিডেন ফাইল ব্লক করার জন্য
    location ~ /\.ht {
        deny all;
    }
}
EOF

# ৮. সার্ভিস রিস্টার্ট এবং এনাবেল করা
echo "[*] সার্ভিসগুলো রিস্টার্ট করা হচ্ছে..."
sudo systemctl restart php8.2-fpm
sudo systemctl restart nginx
sudo systemctl enable php8.2-fpm
sudo systemctl enable nginx

echo "========================================="
echo "   ইনস্টলেশন সফলভাবে সম্পন্ন হয়েছে!"
echo "   এখন ব্রাউজারে আপনার সার্ভারের IP লিখুন।"
echo "========================================="
