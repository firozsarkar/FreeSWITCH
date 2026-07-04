#!/bin/bash
# =====================================================================
# fix-acl.sh
# apply-inbound-acl রিমুভ করে (যেটা বৈধ extension/gateway ব্লক করছিল)
# শুধু auth-calls=true রাখা হবে — যা IP নির্বিশেষে সঠিক user/pass লাগবে
# =====================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "❌ root/sudo দিয়ে চালান।"
    exit 1
fi

INTERNAL_PROFILE="/etc/freeswitch/sip_profiles/internal.xml"
BACKUP_DIR="/root/freeswitch-security-backup-$(date +%F_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ ! -f "$INTERNAL_PROFILE" ]; then
    echo "❌ $INTERNAL_PROFILE পাওয়া যায়নি।"
    exit 1
fi

cp "$INTERNAL_PROFILE" "$BACKUP_DIR/"
echo "💾 ব্যাকআপ রাখা হলো: $BACKUP_DIR/$(basename "$INTERNAL_PROFILE")"

# apply-inbound-acl লাইনটা সম্পূর্ণ রিমুভ করা হচ্ছে
sed -i '/apply-inbound-acl/d' "$INTERNAL_PROFILE"
echo "✅ apply-inbound-acl প্যারামিটার সরানো হলো।"

# auth-calls=true আছে কিনা নিশ্চিত করা (এটাই মূল সুরক্ষা, এটা রাখা হচ্ছে)
if grep -q 'name="auth-calls"' "$INTERNAL_PROFILE"; then
    sed -i 's#<param name="auth-calls"[^/]*/>#<param name="auth-calls" value="true"/>#' "$INTERNAL_PROFILE"
else
    sed -i '/<settings>/a\    <param name="auth-calls" value="true"/>' "$INTERNAL_PROFILE"
fi
echo "✅ auth-calls=true নিশ্চিত করা হলো (এটাই আসল সুরক্ষা, IP-নির্বিশেষে কাজ করবে)।"

# একই কারণে গেটওয়ে/ট্রাঙ্কের জন্য external প্রোফাইলেও ACL থাকলে চেক
EXTERNAL_PROFILE="/etc/freeswitch/sip_profiles/external.xml"
if [ -f "$EXTERNAL_PROFILE" ] && grep -q 'apply-inbound-acl' "$EXTERNAL_PROFILE"; then
    cp "$EXTERNAL_PROFILE" "$BACKUP_DIR/"
    echo "⚠️  external.xml এও apply-inbound-acl পাওয়া গেছে — এটাও রিমুভ করা হচ্ছে।"
    sed -i '/apply-inbound-acl/d' "$EXTERNAL_PROFILE"
fi

echo ""
echo "🔄 FreeSWITCH sofia profiles রিলোড করা হচ্ছে..."
fs_cli -x "reloadacl" || true
fs_cli -x "sofia profile internal restart" || true
if [ -f "$EXTERNAL_PROFILE" ]; then
    fs_cli -x "sofia profile external restart" || true
fi

echo ""
echo "=========================================================="
echo "✅ ফিক্স সম্পন্ন হয়েছে।"
echo "=========================================================="
echo "এখন থেকে:"
echo "  - যেকোনো IP থেকে extension/gateway রেজিস্টার করতে পারবে"
echo "  - কিন্তু সঠিক username/password ছাড়া কল/রেজিস্ট্রেশন গ্রহণ হবে না"
echo "  - fail2ban এখনও ভুল পাসওয়ার্ড দিয়ে বারবার চেষ্টাকারী IP ব্লক করবে"
echo ""
echo "টেস্ট করুন:"
echo "  sudo fs_cli -x 'sofia status profile internal'"
echo "  আপনার সফটফোন/গেটওয়ে থেকে রেজিস্টার করে দেখুন"
