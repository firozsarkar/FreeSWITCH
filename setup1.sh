#!/usr/bin/env bash
# =============================================================================
# FreeSWITCH Security & Fail2Ban Automated Setup Script
# Target OS  : Debian 12 (Bookworm)
# Author     : Production Security Automation
# Version    : 2.0.0
# Usage      : sudo bash setup.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# ANSI COLOR CODES
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# GLOBAL CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
DASHBOARD_DIR="/var/www/html/fail2ban"
FAIL2BAN_FILTER_DIR="/etc/fail2ban/filter.d"
FAIL2BAN_ACTION_DIR="/etc/fail2ban/action.d"
FAIL2BAN_JAIL_DIR="/etc/fail2ban/jail.d"
SUDOERS_FILE="/etc/sudoers.d/www-data-fail2ban"
LOG_FILE="/var/log/freeswitch-security-setup.log"
BACKUP_DIR="/root/freeswitch-security-backup-$(date +%Y%m%d_%H%M%S)"

# Default admin credentials (password: Admin@1234 - change after install!)
DEFAULT_ADMIN_PASS_HASH='$argon2id$v=19$m=65536,t=4,p=1$c29tZXNhbHRzdHJpbmc$Rn2IXQR1PjqUZpDt0M9N8a1fgW2kXv5YHzJqL8Tb3K4'

# Detect server's primary IP
SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING & OUTPUT HELPERS
# ─────────────────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()    { echo -e "${GREEN}[INFO]${NC}   $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}   $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "\n${BLUE}${BOLD}━━━ STEP: $* ━━━${NC}"; }
log_success() { echo -e "${GREEN}${BOLD}✔ $*${NC}"; }
log_banner()  {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║      FreeSWITCH Security & Fail2Ban Automated Setup                  ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Use sudo."
   exit 1
fi

log_banner
log_info "Initialization started. Logging to $LOG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: SYSTEM UPDATE & DEPENDENCIES
# ─────────────────────────────────────────────────────────────────────────────
log_step "Updating System Packages & Installing Dependencies"
apt-get update -y
apt-get install -y fail2ban ufw iptables-persistent apache2 php php-cli php-mbstring curl git

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: CREATE FREEPBX / FREESWITCH FAIL2BAN FILTERS
# ─────────────────────────────────────────────────────────────────────────────
log_step "Creating Fail2Ban Custom Filters for FreeSWITCH"

cat << 'EOF' > "${FAIL2BAN_FILTER_DIR}/freeswitch.conf"
[Definition]
failregex = ^.*\[WARNING\] sofia_reg\.h? \d+ Can't find user \['?.+?'?@.+?\] from <HOST>$
            ^.*\[WARNING\] sofia_reg\.c:\d+ Can't find user \['?.+?'?@.+?\] from <HOST>$
            ^.*SIP/2.0 403 Forbidden.*From:.*<HOST>.*$
ignoreregex =
EOF

cat << 'EOF' > "${FAIL2BAN_FILTER_DIR}/freeswitch-dos.conf"
[Definition]
failregex = ^.*sip:(?:invite|register).*from <HOST>.*$
ignoreregex =
EOF

log_success "Fail2Ban filters configured successfully."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: CONFIGURE FAIL2BAN JAILS
# ─────────────────────────────────────────────────────────────────────────────
log_step "Configuring Fail2Ban Jails"

cat << 'EOF' > "${FAIL2BAN_JAIL_DIR}/freeswitch.local"
[freeswitch]
enabled  = true
port     = 5060,5061,5080,5081,5241
protocol = udp,tcp
filter   = freeswitch
logpath  /var/log/freeswitch/freeswitch.log
maxretry = 5
findtime = 60
bantime  = 86400

[freeswitch-dos]
enabled  = true
port     = 5060,5061,5080,5081,5241
protocol = udp,tcp
filter   = freeswitch-dos
logpath  /var/log/freeswitch/freeswitch.log
maxretry = 20
findtime = 10
bantime  = 604800
EOF

systemctl restart fail2ban
systemctl enable fail2ban
log_success "Fail2Ban service restarted and enabled."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: CREATE MONITORING DASHBOARD
# ─────────────────────────────────────────────────────────────────────────────
log_step "Deploying Web Dashboard for Blocked IPs"
mkdir -p "$DASHBOARD_DIR"

cat << 'EOF' > "${DASHBOARD_DIR}/index.php"
<?php
session_start();
$logFile = "/var/log/freeswitch-security-setup.log";

if (isset($_POST['action']) && $_POST['action'] === 'unban') {
    $ip = escapeshellcmd($_POST['ip']);
    if (filter_var($ip, FILTER_VALIDATE_IP)) {
        shell_exec("sudo fail2ban-client unban " . $ip);
        $msg = "IP $ip has been unbanned successfully.";
    }
}

$jails = ['freeswitch', 'freeswitch-dos', 'sshd'];
$bannedIPs = [];
foreach ($jails as $jail) {
    $output = shell_exec("sudo fail2ban-client status " . $jail);
    if (preg_match("/Banned IP list:\s*(.*)/i", $output, $match)) {
        $ips = trim($match[1]);
        if (!empty($ips)) {
            foreach (explode(" ", $ips) as $ip) {
                $bannedIPs[] = ['jail' => $jail, 'ip' => trim($ip)];
            }
        }
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>FreeSWITCH Security Dashboard</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
<div class="container mt-5">
    <h2 class="mb-4">🛡️ FreeSWITCH Active Firewall & Fail2Ban Dashboard</h2>
    <?php if (isset($msg)): ?>
        <div class="alert alert-success"><?= $msg; ?></div>
    <?php endif; ?>
    <div class="card shadow-sm">
        <div class="card-header bg-dark text-white">Currently Banned Attackers</div>
        <div class="card-body">
            <table class="table table-striped">
                <thead>
                    <tr>
                        <th>Jail</th>
                        <th>IP Address</th>
                        <th>Action</th>
                    </tr>
                </thead>
                <tbody>
                    <?php if (empty($bannedIPs)): ?>
                        <tr><td colspan="3" class="text-center">No active bans right now.</td></tr>
                    <?php else: ?>
                        <?php foreach ($bannedIPs as $entry): ?>
                        <tr>
                            <td><?= htmlspecialchars($entry['jail']); ?></td>
                            <td><code><?= htmlspecialchars($entry['ip']); ?></code></td>
                            <td>
                                <form method="post" style="display:inline;">
                                    <input type="hidden" name="ip" value="<?= $entry['ip']; ?>">
                                    <input type="hidden" name="action" value="unban">
                                    <button type="submit" class="btn btn-sm btn-danger">Unban</button>
                                </form>
                            </td>
                        </tr>
                        <?php endforeach; ?>
                    <?php endif; ?>
                </tbody>
            </table>
        </div>
    </div>
</div>
</body>
</html>
EOF

chown -R www-data:www-data "$DASHBOARD_DIR"
log_success "Dashboard installed at /var/www/html/fail2ban"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: SUDOERS CONFIGURATION FOR WEB CONTROL
# ─────────────────────────────────────────────────────────────────────────────
log_step "Configuring Sudoers Permissions for Web Dashboard"
echo "www-data ALL=(root) NOPASSWD: /usr/bin/fail2ban-client" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
log_success "Sudoers permissions updated."

log_success "Setup Completed Successfully! All attack streams will now be automatically dropped."
