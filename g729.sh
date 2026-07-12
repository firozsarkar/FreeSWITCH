# ১. প্রয়োজনীয় প্যাকেজ ইন্সটল করুন
apt-get install unzip

# ২. ইন্সটলার ডাউনলোড ও রান করুন
wget http://files.freeswitch.org/g729/fs-latest-installer-v1.6
chmod +x fs-latest-installer-v1.6
./fs-latest-installer-v1.6 /usr /usr/lib/freeswitch/mod

# ৩. লাইসেন্স ভ্যালিডেট ও ডাউনলোড করুন
/usr/bin/freeswitch-license-validator   # এখানে আপনার লাইসেন্স কোড দিতে হবে

# ৪. ডাউনলোড করা লাইসেন্স ফাইল কপি করুন
unzip licences.zip
cp <HEX-KEY>.conf /etc/freeswitch/   # <HEX-KEY> আপনার ফাইলের নাম দিয়ে রিপ্লেস করুন

# ৫. FreeSWITCH রিস্টার্ট ও মডিউল লোড করুন
systemctl stop freeswitch
freeswitch-licence-server
systemctl start freeswitch
fs_cli -x "load mod_com_g729"

# ৬. লাইসেন্স চেক করুন
fs_cli -x "g729_info"
# সফল হলে দেখাবে: Success checking G.729A/0 ও লাইসেন্স কাউন্ট [citation:1][citation:10]
