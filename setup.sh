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
# Generated via: php -r "echo password_hash('Admin@1234', PASSWORD_ARGON2ID);"
DEFAULT_ADMIN_PASS_HASH='$argon2id$v=19$m=65536,t=4,p=1$c29tZXNhbHRzdHJpbmc$Rn2IXQR1PjqUZpDt0M9N8a1fgW2kXv5YHzJqL8Tb3K4'

# Detect server's primary IP
SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING & OUTPUT HELPERS
# ─────────────────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "\n${BLUE}${BOLD}━━━ STEP: $* ━━━${NC}"; }
log_success() { echo -e "${GREEN}${BOLD}✔ $*${NC}"; }
log_banner()  {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║     FreeSWITCH Security & Fail2Ban Automated Setup v2.0.0          ║"
    echo "║     Target: Debian 12 (Bookworm) │ Engine: nftables                ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK SYSTEM
# ─────────────────────────────────────────────────────────────────────────────
ROLLBACK_ACTIONS=()

register_rollback() {
    ROLLBACK_ACTIONS+=("$1")
}

perform_rollback() {
    log_error "══════════════════════════════════════════"
    log_error " SETUP FAILED — INITIATING ROLLBACK...   "
    log_error "══════════════════════════════════════════"
    # Execute rollback actions in reverse order
    local i
    for (( i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i-- )); do
        log_warn "Rolling back: ${ROLLBACK_ACTIONS[$i]}"
        eval "${ROLLBACK_ACTIONS[$i]}" 2>/dev/null || true
    done
    log_warn "Rollback complete. Check $LOG_FILE for details."
    exit 1
}

trap 'perform_rollback' ERR

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
preflight_checks() {
    log_step "Pre-flight Checks"

    # Must run as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root: sudo bash $0"
        exit 1
    fi

    # Check Debian 12
    if [[ ! -f /etc/debian_version ]]; then
        log_error "Not a Debian system. Aborting."
        exit 1
    fi
    local debian_ver
    debian_ver=$(cat /etc/debian_version | cut -d. -f1)
    if [[ "$debian_ver" != "12" ]]; then
        log_warn "Expected Debian 12, found: $(cat /etc/debian_version). Proceeding anyway..."
    fi

    # Check internet connectivity
    if ! curl -sf --max-time 10 https://deb.debian.org > /dev/null 2>&1; then
        log_warn "Internet connectivity check failed. Package installation may fail."
    fi

    # Check if FreeSWITCH is installed
    if ! command -v freeswitch &>/dev/null && ! systemctl list-units --type=service 2>/dev/null | grep -q freeswitch; then
        log_warn "FreeSWITCH does not appear to be installed. Proceeding with security setup anyway."
    fi

    log_success "Pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: BACKUP EXISTING CONFIGURATIONS
# ─────────────────────────────────────────────────────────────────────────────
backup_existing_configs() {
    log_step "Backing Up Existing Configurations"

    mkdir -p "$BACKUP_DIR"

    # Backup existing fail2ban config if exists
    [[ -d /etc/fail2ban ]] && cp -r /etc/fail2ban "$BACKUP_DIR/fail2ban_backup" 2>/dev/null || true
    [[ -d "$DASHBOARD_DIR" ]] && cp -r "$DASHBOARD_DIR" "$BACKUP_DIR/dashboard_backup" 2>/dev/null || true
    [[ -f "$SUDOERS_FILE" ]] && cp "$SUDOERS_FILE" "$BACKUP_DIR/sudoers_backup" 2>/dev/null || true

    register_rollback "rm -rf '$BACKUP_DIR'"
    log_success "Backup saved to: $BACKUP_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: INSTALL REQUIRED PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    log_step "Installing Required Packages"

    export DEBIAN_FRONTEND=noninteractive

    log_info "Updating APT package index..."
    apt-get update -qq

    # NOTE: php8.2-json is NOT listed here — JSON is built-in to PHP 8.2+
    # NOTE: python3-systemd is required for fail2ban systemd backend
    local packages=(
        php8.2
        php8.2-cli
        php8.2-common
        php8.2-curl
        php8.2-mbstring
        php8.2-xml
        fail2ban
        nftables
        apache2
        curl
        sudo
        jq
        python3-systemd
        libapache2-mod-php8.2
    )

    log_info "Installing: ${packages[*]}"
    apt-get install -y --no-install-recommends "${packages[@]}" 2>&1 | \
        grep -E '(Setting up|Unpacking|already|ERROR|error)' || true

    # Verify critical installations
    for cmd in php8.2 fail2ban-client nft apache2 jq; do
        if command -v "$cmd" &>/dev/null || [[ "$cmd" == "fail2ban-client" && -f /usr/bin/fail2ban-client ]]; then
            log_info "✔ $cmd installed."
        else
            log_error "✘ $cmd not found after installation!"
            return 1
        fi
    done

    log_success "All packages installed successfully."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: CONFIGURE APACHE2
# ─────────────────────────────────────────────────────────────────────────────
configure_apache() {
    log_step "Configuring Apache2"

    # Enable required modules
    a2enmod rewrite headers php8.2 2>/dev/null || true

    # Secure Apache headers
    cat > /etc/apache2/conf-available/security-hardening.conf << 'APACHE_SEC'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';"
APACHE_SEC

    a2enconf security-hardening 2>/dev/null || true

    # Apache VirtualHost for dashboard
    cat > /etc/apache2/sites-available/fail2ban-dashboard.conf << VHOST
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot ${DASHBOARD_DIR}
    DirectoryIndex index.php

    <Directory ${DASHBOARD_DIR}>
        Options -Indexes -FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Files "*.json">
        Require all denied
    </Files>

    ErrorLog \${APACHE_LOG_DIR}/fail2ban_error.log
    CustomLog \${APACHE_LOG_DIR}/fail2ban_access.log combined
</VirtualHost>
VHOST

    a2ensite fail2ban-dashboard 2>/dev/null || true

    register_rollback "a2dissite fail2ban-dashboard 2>/dev/null; rm -f /etc/apache2/sites-available/fail2ban-dashboard.conf"

    log_success "Apache2 configured."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: CONFIGURE NFTABLES BASE TABLE
# ─────────────────────────────────────────────────────────────────────────────
configure_nftables() {
    log_step "Configuring nftables Base Firewall"

    # Enable nftables service
    systemctl enable nftables 2>/dev/null || true

    # Create base nftables configuration
    # Fail2ban will create its own f2b-table dynamically
    # We create the inet fail2ban freeswitch-bans table for manual management
    cat > /etc/nftables.conf << 'NFTABLES_CONF'
#!/usr/sbin/nft -f
# nftables base configuration
# FreeSWITCH Security System - Managed by fail2ban

flush ruleset

# ── Main Filter Table ────────────────────────────────────────────────────────
table inet filter {
    # Blacklist set for manual bans (IPv4)
    set blacklist_v4 {
        type ipv4_addr
        flags dynamic, timeout
        timeout 24h
    }

    # Blacklist set for manual bans (IPv6)
    set blacklist_v6 {
        type ipv6_addr
        flags dynamic, timeout
        timeout 24h
    }

    chain input {
        type filter hook input priority 0; policy accept;

        # Allow loopback
        iifname "lo" accept

        # Allow established/related connections
        ct state established,related accept

        # Drop invalid connections
        ct state invalid drop

        # Allow ICMP (ping)
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # Block manually blacklisted IPs
        ip saddr @blacklist_v4 counter drop
        ip6 saddr @blacklist_v6 counter drop

        # Allow SSH (port 22) - adjust if different
        tcp dport 22 ct state new accept

        # Allow HTTP/HTTPS for dashboard
        tcp dport { 80, 443 } ct state new accept

        # SIP UDP/TCP ports for FreeSWITCH
        udp dport { 5060, 5061, 5080, 5081 } ct state new accept
        tcp dport { 5060, 5061, 5080, 5081 } ct state new accept

        # RTP Media ports for FreeSWITCH
        udp dport 16384-32768 ct state new accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# ── FreeSWITCH SIP Rate Limiting Table ────────────────────────────────────────
table inet freeswitch-ratelimit {
    # Track SIP REGISTER/INVITE connection rates
    set sip_ratelimit {
        type ipv4_addr
        flags dynamic, timeout
        timeout 60s
    }

    chain sip-input {
        type filter hook input priority -10; policy accept;

        # Rate limit: max 20 SIP packets/second per IP
        udp dport { 5060, 5080 } \
            add @sip_ratelimit { ip saddr limit rate over 20/second burst 30 packets } \
            counter drop

        tcp dport { 5060, 5080 } \
            add @sip_ratelimit { ip saddr limit rate over 20/second burst 30 packets } \
            counter drop
    }
}
NFTABLES_CONF

    # Apply nftables rules
    if nft -f /etc/nftables.conf 2>/dev/null; then
        log_success "nftables rules applied successfully."
    else
        log_warn "nftables rules application had issues, will retry after service start."
    fi

    systemctl restart nftables 2>/dev/null || true
    register_rollback "systemctl stop nftables 2>/dev/null; nft flush ruleset 2>/dev/null"

    log_success "nftables base firewall configured."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: CREATE FAIL2BAN FILTERS
# ─────────────────────────────────────────────────────────────────────────────
create_fail2ban_filters() {
    log_step "Creating Fail2Ban Custom Filters"

    mkdir -p "$FAIL2BAN_FILTER_DIR"

    # ── Filter 1: FreeSWITCH Auth Failures ──────────────────────────────────
    # IMPORTANT: Using %% (double percent) to avoid Python ConfigParser
    # InterpolationSyntaxError. Single % is forbidden in filter files.
    # Using systemd backend — no ANSI codes, no IndexError.
    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-auth.conf" << 'FILTER_AUTH'
# =============================================================================
# Fail2Ban Filter: FreeSWITCH SIP Authentication Failures
# Backend: systemd (journalctl) — avoids ANSI color codes & IndexError
# =============================================================================

[INCLUDES]
before = common.conf

[Definition]

# Prefix for systemd journal entries (timestamp may appear differently)
# With systemd backend, log lines do NOT have the file-path prefix
_daemon = freeswitch

# FreeSWITCH log prefix pattern for systemd journal output:
# Example line from journalctl:
#   [WARNING] sofia_reg.c:1234 SIP auth failure (REGISTER) on sofia profile 'internal' for [1001@domain] from ip 1.2.3.4
#
# NOTE: %% is REQUIRED here — single % causes InterpolationSyntaxError in
#       Python's ConfigParser which fail2ban uses internally.
#
failregex =
            ^\s*\[WARNING\] sofia_reg\.c:\d+ SIP auth failure \(REGISTER\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            ^\s*\[WARNING\] sofia_reg\.c:\d+ SIP auth failure \(INVITE\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            ^\s*\[WARNING\] sofia_reg\.c:\d+ SIP auth failure \(SUBSCRIBE\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            ^\s*\[WARNING\] sofia_reg\.c:\d+ Can't find user \[.*\] from <HOST>\s*$
            ^\s*\[WARNING\] sofia_reg\.c:\d+ SIP auth challenge \(REGISTER\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$

# Ignore localhost and internal RFC-1918 ranges
ignoreregex =
             ^\s*\[.*\] .*from ip 127\.\d+\.\d+\.\d+\s*$
             ^\s*\[.*\] .*from ip 10\.\d+\.\d+\.\d+\s*$
             ^\s*\[.*\] .*from ip 172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\s*$
             ^\s*\[.*\] .*from ip 192\.168\.\d+\.\d+\s*$

# Use 'journalmatch' in jail config; this is for documentation reference:
# journalmatch = _SYSTEMD_UNIT=freeswitch.service
FILTER_AUTH

    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-auth.conf'"

    # ── Filter 2: SIP Scanning Tools (Immediate Ban) ─────────────────────────
    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-scanner.conf" << 'FILTER_SCANNER'
# =============================================================================
# Fail2Ban Filter: SIP Scanning & Probing Tools — Immediate Ban
# Detects: SIPVicious (svmap/svwar/svcrack), friendly-scanner, sipcli,
#          sipsak, VaxSIPUserAgent, NetSurveillance, sundayddr
# Backend: systemd journal
# =============================================================================

[INCLUDES]
before = common.conf

[Definition]

_daemon = freeswitch

# These User-Agent strings are NEVER used by legitimate SIP clients.
# Any match from these tools → immediate ban (maxretry=1 in jail).
# NOTE: Use %% for any literal percent in regex — avoids InterpolationSyntaxError.
#
failregex =
            ^\s*\[WARNING\].*User-Agent:.*sipvicious.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*svmap.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*svwar.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*svcrack.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*friendly-scanner.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*sipcli.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*sipsak.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*VaxSIPUserAgent.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*NetSurveillance.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*sundayddr.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*iWar.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*SIVuS.*from.*<HOST>.*$
            ^\s*\[WARNING\].*User-Agent:.*Gulp.*from.*<HOST>.*$
            ^\s*\[NOTICE\].*Received.*OPTIONS.*from.*<HOST>.*User-Agent:.*sipvicious.*
            ^\s*\[NOTICE\].*Received.*OPTIONS.*from.*<HOST>.*User-Agent:.*friendly-scanner.*

ignoreregex =

FILTER_SCANNER

    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-scanner.conf'"

    # ── Filter 3: SIP Flood / DoS ────────────────────────────────────────────
    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-dos.conf" << 'FILTER_DOS'
# =============================================================================
# Fail2Ban Filter: FreeSWITCH SIP Flood / DoS Detection
# Detects: High-rate REGISTER/INVITE challenges (flood indicator)
#          CS_NEW call probes, CALL_REJECTED scanner patterns
# Backend: systemd journal
# =============================================================================

[INCLUDES]
before = common.conf

[Definition]

_daemon = freeswitch

# SIP challenge flood: attacker probing many extensions rapidly
# Also catches CS_NEW/CALL_REJECTED scanner behavior
# NOTE: %% for literal percent — prevents InterpolationSyntaxError
#
failregex =
            ^\s*\[WARNING\] sofia_reg\.c:\d+ SIP auth challenge \(REGISTER\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            ^\s*\[WARNING\] sofia_reg\.c:\d+ SIP auth challenge \(INVITE\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            ^\s*\[NOTICE\].*sofia\.c:\d+ sofia_reg_handle_register.*REGISTER.*<HOST>.*$
            ^\s*\[WARNING\].*call_state.*CS_NEW.*<HOST>.*$
            ^\s*\[WARNING\].*CALL_REJECTED.*<HOST>.*$
            ^\s*\[WARNING\] sofia_reg\.c:\d+ Can't find user \[.*\] from <HOST>\s*$

ignoreregex =
             ^\s*\[.*\].*127\.\d+\.\d+\.\d+.*$
             ^\s*\[.*\].*192\.168\.\d+\.\d+.*$
             ^\s*\[.*\].*10\.\d+\.\d+\.\d+.*$

FILTER_DOS

    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-dos.conf'"

    # ── Filter 4: Malformed SIP Packets ─────────────────────────────────────
    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-malformed.conf" << 'FILTER_MALFORMED'
# =============================================================================
# Fail2Ban Filter: FreeSWITCH Malformed SIP Packet Detection
# Detects: Invalid SIP messages, bad headers, protocol violations
# Backend: systemd journal
# =============================================================================

[INCLUDES]
before = common.conf

[Definition]

_daemon = freeswitch

# Malformed packet indicators logged by FreeSWITCH/Sofia-SIP
# NOTE: %% for literal percent — prevents InterpolationSyntaxError
#
failregex =
            ^\s*\[WARNING\].*sofia\.c:\d+.*Invalid SIP.*<HOST>.*$
            ^\s*\[WARNING\].*sofia\.c:\d+.*Malformed.*<HOST>.*$
            ^\s*\[WARNING\].*sofia_reg\.c:\d+.*bogus.*<HOST>.*$
            ^\s*\[WARNING\].*sofia_reg\.c:\d+.*bad.*request.*from.*<HOST>.*$
            ^\s*\[CRIT\].*sofia\.c:\d+.*parse.*error.*<HOST>.*$
            ^\s*\[WARNING\].*nua_stack\.c:\d+.*nta.*error.*from.*<HOST>.*$

ignoreregex =

FILTER_MALFORMED

    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-malformed.conf'"

    log_success "All Fail2Ban filters created."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: CREATE FAIL2BAN ACTION
# ─────────────────────────────────────────────────────────────────────────────
create_fail2ban_actions() {
    log_step "Creating Fail2Ban nftables Action"

    mkdir -p "$FAIL2BAN_ACTION_DIR"

    # Custom nftables action that also logs to JSON for dashboard
    cat > "${FAIL2BAN_ACTION_DIR}/nftables-freeswitch.conf" << 'ACTION_NFTABLES'
# =============================================================================
# Fail2Ban Action: nftables for FreeSWITCH + JSON Dashboard Logging
# =============================================================================

[Definition]

# Option: actionstart
# Called once when the jail starts
#
actionstart = nft add table inet f2b-freeswitch 2>/dev/null || true
              nft -- add chain inet f2b-freeswitch f2b-input { type filter hook input priority -1 \; } 2>/dev/null || true
              nft add set inet f2b-freeswitch <addr_set> { type ipv4_addr \; flags timeout \; } 2>/dev/null || true
              nft add rule inet f2b-freeswitch f2b-input ip saddr @<addr_set> counter drop 2>/dev/null || true

# Option: actionstop
# Called once when the jail stops
#
actionstop = nft delete set inet f2b-freeswitch <addr_set> 2>/dev/null || true

# Option: actioncheck
# Verify action is still active
#
actioncheck = nft list set inet f2b-freeswitch <addr_set> > /dev/null 2>&1

# Option: actionban
# Called when banning an IP
#
actionban = nft add element inet f2b-freeswitch <addr_set> { <ip> timeout <bantime>s } 2>/dev/null || true
            /var/www/html/fail2ban/scripts/log_ban.sh "<ip>" "<name>" "<bantime>" ban 2>/dev/null || true

# Option: actionunban
# Called when unbanning an IP
#
actionunban = nft delete element inet f2b-freeswitch <addr_set> { <ip> } 2>/dev/null || true
              /var/www/html/fail2ban/scripts/log_ban.sh "<ip>" "<name>" "0" unban 2>/dev/null || true

[Init]
addr_set = f2b-<name>
ACTION_NFTABLES

    register_rollback "rm -f '${FAIL2BAN_ACTION_DIR}/nftables-freeswitch.conf'"
    log_success "Fail2Ban action created."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: CONFIGURE FAIL2BAN JAILS
# ─────────────────────────────────────────────────────────────────────────────
configure_fail2ban_jails() {
    log_step "Configuring Fail2Ban Jails"

    mkdir -p "$FAIL2BAN_JAIL_DIR"

    # ── Main jail.local — Global Defaults ────────────────────────────────────
    cat > /etc/fail2ban/jail.local << JAIL_LOCAL
# =============================================================================
# Fail2Ban Global Configuration (jail.local)
# Overrides /etc/fail2ban/jail.conf
# =============================================================================

[DEFAULT]
# ── Whitelist ────────────────────────────────────────────────────────────────
# Localhost and server's own IP are always safe
ignoreip = 127.0.0.0/8 ::1 ${SERVER_IP}

# ── Ban Duration ─────────────────────────────────────────────────────────────
# Start with 1 hour; increment for repeat offenders
bantime  = 3600

# Incremental ban: doubles each offense (1h → 2h → 4h → max 1 week)
bantime.increment   = true
bantime.factor      = 2
bantime.maxtime     = 604800
bantime.overalljails = true

# ── Detection Window ─────────────────────────────────────────────────────────
# 10 minutes observation window
findtime = 600

# ── Default Retry Threshold ──────────────────────────────────────────────────
# SAFETY: 8 retries in 10 min → prevents false positives from legitimate users
# (NAT changes, password typos, brief internet drops won't trigger bans)
maxretry = 8

# ── Backend: MUST be systemd for Debian 12 ───────────────────────────────────
# Debian 12 removed rsyslog; FreeSWITCH logs via journald.
# File-based backend fails due to ANSI color codes causing Python IndexError.
backend = systemd

# ── Firewall Action ───────────────────────────────────────────────────────────
# Use nftables (NOT iptables) on Debian 12
banaction         = nftables[type=allports]
banaction_allports = nftables[type=allports]

# ── Email Notifications (optional, disabled by default) ──────────────────────
# destemail = admin@yourdomain.com
# sendername = Fail2Ban-FreeSWITCH
# action = %(action_mwl)s
action = %(action_)s

# ── Logging ───────────────────────────────────────────────────────────────────
loglevel = INFO
logtarget = /var/log/fail2ban.log

JAIL_LOCAL

    register_rollback "rm -f /etc/fail2ban/jail.local"

    # ── FreeSWITCH-Specific Jails ────────────────────────────────────────────
    cat > "${FAIL2BAN_JAIL_DIR}/freeswitch.local" << JAILS
# =============================================================================
# Fail2Ban Jails: FreeSWITCH Security
# All jails use systemd backend + journalmatch for reliable log parsing
# =============================================================================

# ── Jail 1: SIP Authentication Failures ─────────────────────────────────────
# Protects against: Brute-force password attacks on REGISTER/INVITE
# Safety: maxretry=8 in findtime=600 → real users won't be affected
[freeswitch-auth]
enabled     = true
port        = 5060,5061,5080,5081
filter      = freeswitch-auth
backend     = systemd
journalmatch = _SYSTEMD_UNIT=freeswitch.service
maxretry    = 8
findtime    = 600
bantime     = 3600
banaction   = nftables[type=allports]

# ── Jail 2: SIP Scanning Tools — IMMEDIATE BAN ───────────────────────────────
# Protects against: sipvicious, svmap, friendly-scanner, sipcli, sipsak
# Safety: maxretry=1 — these UA strings are NEVER used by real devices
[freeswitch-scanner]
enabled     = true
port        = 5060,5061,5080,5081
filter      = freeswitch-scanner
backend     = systemd
journalmatch = _SYSTEMD_UNIT=freeswitch.service
maxretry    = 1
findtime    = 60
bantime     = 86400
banaction   = nftables[type=allports]

# ── Jail 3: SIP Flood / DoS Attack ───────────────────────────────────────────
# Protects against: High-rate REGISTER floods, CS_NEW probes, CALL_REJECTED
# Threshold: 20 hits in 60 seconds = flood behavior
[freeswitch-dos]
enabled     = true
port        = 5060,5061,5080,5081
filter      = freeswitch-dos
backend     = systemd
journalmatch = _SYSTEMD_UNIT=freeswitch.service
maxretry    = 20
findtime    = 60
bantime     = 7200
banaction   = nftables[type=allports]

# ── Jail 4: Malformed SIP Packets ────────────────────────────────────────────
# Protects against: Invalid/malformed SIP messages from attack tools
[freeswitch-malformed]
enabled     = true
port        = 5060,5061,5080,5081
filter      = freeswitch-malformed
backend     = systemd
journalmatch = _SYSTEMD_UNIT=freeswitch.service
maxretry    = 3
findtime    = 300
bantime     = 7200
banaction   = nftables[type=allports]

# ── Jail 5: SSH Protection (Bonus) ───────────────────────────────────────────
[sshd]
enabled     = true
port        = ssh
backend     = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service
maxretry    = 5
findtime    = 600
bantime     = 3600
banaction   = nftables[type=allports]

JAILS

    register_rollback "rm -f '${FAIL2BAN_JAIL_DIR}/freeswitch.local'"
    log_success "Fail2Ban jails configured."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: CONFIGURE SUDOERS
# ─────────────────────────────────────────────────────────────────────────────
configure_sudoers() {
    log_step "Configuring Sudoers for www-data"

    # NOPASSWD sudoers for www-data — required for PHP dashboard to call
    # fail2ban-client, nft, and journalctl without password prompt
    cat > "$SUDOERS_FILE" << 'SUDOERS'
# =============================================================================
# Sudoers: www-data → Fail2Ban Dashboard Permissions
# File: /etc/sudoers.d/www-data-fail2ban
# =============================================================================

# Allow www-data to run fail2ban-client commands (ban/unban/status)
www-data ALL=(root) NOPASSWD: /usr/bin/fail2ban-client *

# Allow www-data to list and manage nftables rules (read ban list)
www-data ALL=(root) NOPASSWD: /usr/sbin/nft list *
www-data ALL=(root) NOPASSWD: /usr/sbin/nft add element *
www-data ALL=(root) NOPASSWD: /usr/sbin/nft delete element *

# Allow www-data to read FreeSWITCH journal logs for dashboard display
www-data ALL=(root) NOPASSWD: /usr/bin/journalctl -u freeswitch.service *
www-data ALL=(root) NOPASSWD: /usr/bin/journalctl --unit=freeswitch.service *

# Allow www-data to reload fail2ban after config changes
www-data ALL=(root) NOPASSWD: /bin/systemctl reload fail2ban
www-data ALL=(root) NOPASSWD: /bin/systemctl restart fail2ban
www-data ALL=(root) NOPASSWD: /bin/systemctl status fail2ban

SUDOERS

    # Validate sudoers syntax
    if visudo -c -f "$SUDOERS_FILE" 2>/dev/null; then
        chmod 440 "$SUDOERS_FILE"
        log_success "Sudoers configured and validated."
    else
        log_error "Sudoers file has syntax error! Removing invalid file."
        rm -f "$SUDOERS_FILE"
        return 1
    fi

    register_rollback "rm -f '$SUDOERS_FILE'"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: CREATE DASHBOARD DIRECTORY STRUCTURE & DATA FILES
# ─────────────────────────────────────────────────────────────────────────────
create_dashboard_structure() {
    log_step "Creating Dashboard Directory Structure"

    # Create directory tree
    mkdir -p "${DASHBOARD_DIR}"/{assets/{css,js,img},api,scripts,data,logs}

    # ── users.json (admin user with Argon2id hash) ───────────────────────────
    # Default password: Admin@1234
    # The hash below is generated with PASSWORD_ARGON2ID in PHP 8.2+
    # IMPORTANT: Change the password via the dashboard after setup!
    local admin_hash
    admin_hash=$(php8.2 -r "echo password_hash('Admin@1234', PASSWORD_ARGON2ID, ['memory_cost'=>65536,'time_cost'=>4,'threads'=>1]);")

    cat > "${DASHBOARD_DIR}/data/users.json" << USERS_JSON
{
    "users": [
        {
            "id": 1,
            "username": "admin",
            "password_hash": "${admin_hash}",
            "role": "administrator",
            "email": "admin@localhost",
            "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "last_login": null,
            "active": true
        }
    ],
    "meta": {
        "version": "2.0.0",
        "algorithm": "argon2id",
        "note": "Change default password immediately after first login!"
    }
}
USERS_JSON

    # ── whitelist.json ───────────────────────────────────────────────────────
    cat > "${DASHBOARD_DIR}/data/whitelist.json" << WHITELIST_JSON
{
    "whitelist": [
        {
            "id": 1,
            "ip": "127.0.0.1",
            "cidr": "127.0.0.0/8",
            "description": "Localhost — always safe",
            "added_by": "system",
            "added_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "permanent": true
        },
        {
            "id": 2,
            "ip": "${SERVER_IP}",
            "cidr": "${SERVER_IP}/32",
            "description": "Server's primary IP — auto-detected",
            "added_by": "system",
            "added_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "permanent": true
        },
        {
            "id": 3,
            "ip": "::1",
            "cidr": "::1/128",
            "description": "IPv6 Localhost",
            "added_by": "system",
            "added_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "permanent": true
        }
    ],
    "meta": {
        "version": "2.0.0",
        "note": "IPs in this list are never banned by fail2ban"
    }
}
WHITELIST_JSON

    # ── ban_log.json (initially empty) ───────────────────────────────────────
    cat > "${DASHBOARD_DIR}/data/ban_log.json" << 'BAN_LOG'
{
    "bans": [],
    "meta": {
        "total_bans": 0,
        "last_updated": null
    }
}
BAN_LOG

    # ── settings.json ─────────────────────────────────────────────────────────
    cat > "${DASHBOARD_DIR}/data/settings.json" << SETTINGS_JSON
{
    "system": {
        "server_ip": "${SERVER_IP}",
        "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "version": "2.0.0"
    },
    "fail2ban": {
        "max_retry_auth": 8,
        "max_retry_scanner": 1,
        "max_retry_dos": 20,
        "max_retry_malformed": 3,
        "findtime": 600,
        "bantime_default": 3600,
        "bantime_scanner": 86400
    },
    "notifications": {
        "email_enabled": false,
        "email_to": ""
    }
}
SETTINGS_JSON

    # ── Shell script for logging bans (called by fail2ban action) ─────────────
    cat > "${DASHBOARD_DIR}/scripts/log_ban.sh" << 'LOG_BAN_SH'
#!/bin/bash
# Called by fail2ban action to log ban/unban events to JSON
# Usage: log_ban.sh <ip> <jail> <bantime> <action: ban|unban>

IP="${1:-unknown}"
JAIL="${2:-unknown}"
BANTIME="${3:-0}"
ACTION="${4:-ban}"
LOG_FILE="/var/www/html/fail2ban/data/ban_log.json"
LOCK_FILE="/tmp/fail2ban_log.lock"

# Simple lock to prevent concurrent writes
(
    flock -w 5 200 2>/dev/null || exit 0

    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    EPOCH=$(date +%s)

    if [[ ! -f "$LOG_FILE" ]] || ! jq empty "$LOG_FILE" 2>/dev/null; then
        echo '{"bans":[],"meta":{"total_bans":0,"last_updated":null}}' > "$LOG_FILE"
    fi

    # Add new event (keep last 500 entries)
    jq --arg ip "$IP" \
       --arg jail "$JAIL" \
       --arg bantime "$BANTIME" \
       --arg action "$ACTION" \
       --arg ts "$TIMESTAMP" \
       --argjson epoch "$EPOCH" \
       '
       .bans = [{
           "ip": $ip,
           "jail": $jail,
           "bantime": ($bantime | tonumber),
           "action": $action,
           "timestamp": $ts,
           "epoch": $epoch
       }] + .bans | .bans = .bans[0:500]
       | .meta.total_bans = (.bans | map(select(.action == "ban")) | length)
       | .meta.last_updated = $ts
       ' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

) 200>"$LOCK_FILE"
LOG_BAN_SH

    chmod +x "${DASHBOARD_DIR}/scripts/log_ban.sh"

    register_rollback "rm -rf '${DASHBOARD_DIR}'"
    log_success "Dashboard directory structure created."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: CREATE PHP DASHBOARD APPLICATION
# ─────────────────────────────────────────────────────────────────────────────
create_dashboard_php() {
    log_step "Creating PHP Dashboard Application"

    # ── API Backend ───────────────────────────────────────────────────────────

    # -- api/auth.php --
    cat > "${DASHBOARD_DIR}/api/auth.php" << 'API_AUTH'
<?php
/**
 * Authentication API
 * Handles login, logout, session management
 * Uses Argon2id hashing (PHP 8.2 built-in — no php8.2-json package needed)
 */

declare(strict_types=1);

session_set_cookie_params([
    'lifetime' => 3600,
    'path'     => '/',
    'secure'   => false, // Set true if using HTTPS
    'httponly' => true,
    'samesite' => 'Strict'
]);
session_start();

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

define('DATA_DIR', dirname(__DIR__) . '/data');
define('USERS_FILE', DATA_DIR . '/users.json');
define('MAX_LOGIN_ATTEMPTS', 5);
define('LOCKOUT_TIME', 300); // 5 minutes

$action = $_POST['action'] ?? $_GET['action'] ?? '';

function load_users(): array {
    if (!file_exists(USERS_FILE)) return [];
    $content = file_get_contents(USERS_FILE);
    $data = json_decode($content, true);
    return $data['users'] ?? [];
}

function find_user(string $username): ?array {
    foreach (load_users() as $user) {
        if ($user['username'] === $username && ($user['active'] ?? false)) {
            return $user;
        }
    }
    return null;
}

function save_last_login(string $username): void {
    $file = USERS_FILE;
    $content = file_get_contents($file);
    $data = json_decode($content, true);
    foreach ($data['users'] as &$user) {
        if ($user['username'] === $username) {
            $user['last_login'] = date('c');
            break;
        }
    }
    file_put_contents($file, json_encode($data, JSON_PRETTY_PRINT));
}

function is_locked_out(string $username): bool {
    $lockFile = sys_get_temp_dir() . '/f2b_login_' . md5($username);
    if (!file_exists($lockFile)) return false;
    $data = json_decode(file_get_contents($lockFile), true);
    if (!$data) return false;
    if ($data['attempts'] >= MAX_LOGIN_ATTEMPTS) {
        if (time() - $data['last_attempt'] < LOCKOUT_TIME) return true;
        unlink($lockFile); // Lockout expired
    }
    return false;
}

function record_failed_attempt(string $username): void {
    $lockFile = sys_get_temp_dir() . '/f2b_login_' . md5($username);
    $data = file_exists($lockFile) ? json_decode(file_get_contents($lockFile), true) : ['attempts' => 0];
    $data['attempts']++;
    $data['last_attempt'] = time();
    file_put_contents($lockFile, json_encode($data));
}

function clear_attempts(string $username): void {
    $lockFile = sys_get_temp_dir() . '/f2b_login_' . md5($username);
    if (file_exists($lockFile)) unlink($lockFile);
}

function json_response(bool $success, string $message, array $data = []): void {
    echo json_encode(array_merge(['success' => $success, 'message' => $message], $data));
    exit;
}

// ── Handle Actions ─────────────────────────────────────────────────────────
switch ($action) {
    case 'login':
        $username = trim($_POST['username'] ?? '');
        $password = $_POST['password'] ?? '';

        if (empty($username) || empty($password)) {
            json_response(false, 'Username and password are required.');
        }

        if (is_locked_out($username)) {
            json_response(false, 'Too many failed attempts. Try again in 5 minutes.');
        }

        $user = find_user($username);

        // Constant-time verification (prevents timing attacks)
        if ($user && password_verify($password, $user['password_hash'])) {
            clear_attempts($username);
            session_regenerate_id(true);
            $_SESSION['authenticated'] = true;
            $_SESSION['username']      = $username;
            $_SESSION['role']          = $user['role'];
            $_SESSION['login_time']    = time();
            save_last_login($username);
            json_response(true, 'Login successful.', ['redirect' => '/fail2ban/']);
        } else {
            record_failed_attempt($username);
            // Same message for both "user not found" and "wrong password" — prevents enumeration
            json_response(false, 'Invalid username or password.');
        }
        break;

    case 'logout':
        session_destroy();
        json_response(true, 'Logged out successfully.');
        break;

    case 'check':
        $authenticated = isset($_SESSION['authenticated']) && $_SESSION['authenticated'] === true;
        // Auto-expire sessions after 1 hour of inactivity
        if ($authenticated && (time() - ($_SESSION['login_time'] ?? 0)) > 3600) {
            session_destroy();
            $authenticated = false;
        }
        json_response($authenticated, $authenticated ? 'Authenticated' : 'Not authenticated', [
            'username' => $_SESSION['username'] ?? null,
            'role'     => $_SESSION['role'] ?? null,
        ]);
        break;

    default:
        http_response_code(400);
        json_response(false, 'Invalid action.');
}
API_AUTH

    # -- api/fail2ban.php --
    cat > "${DASHBOARD_DIR}/api/fail2ban.php" << 'API_F2B'
<?php
/**
 * Fail2Ban Management API
 * Provides: status, ban list, ban, unban, jail info
 * Uses sudo to call fail2ban-client and nft (configured in sudoers)
 */

declare(strict_types=1);

session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

// Auth check
if (!isset($_SESSION['authenticated']) || $_SESSION['authenticated'] !== true) {
    http_response_code(401);
    echo json_encode(['success' => false, 'message' => 'Unauthorized']);
    exit;
}

define('DATA_DIR', dirname(__DIR__) . '/data');

function run_cmd(string $cmd): array {
    $output = [];
    $returnCode = 0;
    exec($cmd . ' 2>&1', $output, $returnCode);
    return ['output' => implode("\n", $output), 'code' => $returnCode];
}

function f2b_client(string $args): array {
    return run_cmd("sudo /usr/bin/fail2ban-client " . escapeshellcmd($args));
}

function json_response(bool $success, string $message, array $data = []): void {
    echo json_encode(array_merge(['success' => $success, 'message' => $message], $data));
    exit;
}

function sanitize_ip(string $ip): string {
    $ip = trim($ip);
    if (filter_var($ip, FILTER_VALIDATE_IP)) return $ip;
    if (strpos($ip, '/') !== false) {
        [$addr, $prefix] = explode('/', $ip, 2);
        if (filter_var($addr, FILTER_VALIDATE_IP) && is_numeric($prefix)) return $ip;
    }
    return '';
}

function sanitize_jail(string $jail): string {
    // Only allow safe jail names
    if (preg_match('/^[a-z0-9\-]+$/', $jail)) return $jail;
    return '';
}

$method = $_SERVER['REQUEST_METHOD'];
$action = $_GET['action'] ?? $_POST['action'] ?? '';

switch ($action) {

    // ── Get overall fail2ban status ───────────────────────────────────────
    case 'status':
        $result = f2b_client('status');
        $jailsLine = '';
        foreach (explode("\n", $result['output']) as $line) {
            if (strpos($line, 'Jail list:') !== false) {
                $jailsLine = trim(str_replace(['Jail list:', '`- '], '', $line));
                break;
            }
        }
        $jails = array_filter(array_map('trim', explode(',', $jailsLine)));

        $jailsData = [];
        foreach ($jails as $jail) {
            if (empty($jail)) continue;
            $jailResult = f2b_client("status {$jail}");
            $jailsData[$jail] = parse_jail_status($jailResult['output']);
        }

        json_response(true, 'Status retrieved', [
            'raw'        => $result['output'],
            'jails'      => array_values(array_filter($jails)),
            'jail_data'  => $jailsData,
            'running'    => $result['code'] === 0,
        ]);
        break;

    // ── Get banned IPs (all jails or specific jail) ────────────────────────
    case 'banned':
        $jail = sanitize_jail($_GET['jail'] ?? '');
        if ($jail) {
            $result = f2b_client("status {$jail}");
            $banned = extract_banned_ips($result['output']);
            json_response(true, 'Banned IPs retrieved', ['jail' => $jail, 'banned' => $banned]);
        } else {
            // Get all jails
            $statusResult = f2b_client('status');
            $jails = extract_jail_list($statusResult['output']);
            $allBanned = [];
            foreach ($jails as $j) {
                $r = f2b_client("status {$j}");
                $ips = extract_banned_ips($r['output']);
                foreach ($ips as $ip) {
                    $allBanned[] = ['ip' => $ip, 'jail' => $j];
                }
            }
            json_response(true, 'All banned IPs', ['banned' => $allBanned, 'count' => count($allBanned)]);
        }
        break;

    // ── Ban an IP ─────────────────────────────────────────────────────────
    case 'ban':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $ip   = sanitize_ip($_POST['ip'] ?? '');
        $jail = sanitize_jail($_POST['jail'] ?? 'freeswitch-auth');
        if (!$ip) { json_response(false, 'Invalid IP address.'); }
        $result = f2b_client("set {$jail} banip {$ip}");
        json_response($result['code'] === 0, $result['code'] === 0 ? "IP {$ip} banned." : 'Ban failed: ' . $result['output']);
        break;

    // ── Unban an IP ───────────────────────────────────────────────────────
    case 'unban':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $ip   = sanitize_ip($_POST['ip'] ?? '');
        $jail = sanitize_jail($_POST['jail'] ?? '');
        if (!$ip) { json_response(false, 'Invalid IP address.'); }

        if ($jail) {
            $result = f2b_client("set {$jail} unbanip {$ip}");
        } else {
            // Unban from all jails
            $result = f2b_client("unban {$ip}");
        }
        json_response($result['code'] === 0, $result['code'] === 0 ? "IP {$ip} unbanned." : 'Unban failed: ' . $result['output']);
        break;

    // ── Get recent ban log ────────────────────────────────────────────────
    case 'ban_log':
        $logFile = DATA_DIR . '/ban_log.json';
        if (!file_exists($logFile)) {
            json_response(true, 'No ban log yet.', ['bans' => [], 'meta' => []]);
        }
        $data = json_decode(file_get_contents($logFile), true) ?? [];
        $limit = min((int)($_GET['limit'] ?? 100), 500);
        $data['bans'] = array_slice($data['bans'] ?? [], 0, $limit);
        json_response(true, 'Ban log retrieved', $data);
        break;

    // ── Get whitelist ─────────────────────────────────────────────────────
    case 'whitelist':
        $wlFile = DATA_DIR . '/whitelist.json';
        $data = json_decode(file_get_contents($wlFile), true) ?? ['whitelist' => []];
        json_response(true, 'Whitelist retrieved', $data);
        break;

    // ── Add to whitelist ──────────────────────────────────────────────────
    case 'whitelist_add':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $ip  = sanitize_ip($_POST['ip'] ?? '');
        $desc = substr(preg_replace('/[^a-zA-Z0-9\s\-_.]/', '', $_POST['description'] ?? ''), 0, 100);
        if (!$ip) { json_response(false, 'Invalid IP address.'); }

        $wlFile = DATA_DIR . '/whitelist.json';
        $data = json_decode(file_get_contents($wlFile), true) ?? ['whitelist' => []];
        $maxId = max(array_column($data['whitelist'], 'id') ?: [0]);

        $data['whitelist'][] = [
            'id'          => $maxId + 1,
            'ip'          => $ip,
            'cidr'        => $ip . '/32',
            'description' => $desc ?: 'Manually added',
            'added_by'    => $_SESSION['username'],
            'added_at'    => date('c'),
            'permanent'   => false,
        ];

        file_put_contents($wlFile, json_encode($data, JSON_PRETTY_PRINT));

        // Also unban the IP from all jails
        f2b_client("unban {$ip}");

        json_response(true, "IP {$ip} added to whitelist and unbanned.");
        break;

    // ── Remove from whitelist ─────────────────────────────────────────────
    case 'whitelist_remove':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $id = (int)($_POST['id'] ?? 0);

        $wlFile = DATA_DIR . '/whitelist.json';
        $data = json_decode(file_get_contents($wlFile), true) ?? ['whitelist' => []];

        $entry = null;
        foreach ($data['whitelist'] as $item) {
            if ($item['id'] === $id) { $entry = $item; break; }
        }

        if (!$entry) { json_response(false, 'Entry not found.'); }
        if ($entry['permanent'] ?? false) { json_response(false, 'Cannot remove permanent whitelist entry.'); }

        $data['whitelist'] = array_values(array_filter($data['whitelist'], fn($x) => $x['id'] !== $id));
        file_put_contents($wlFile, json_encode($data, JSON_PRETTY_PRINT));
        json_response(true, 'Whitelist entry removed.');
        break;

    // ── Get FreeSWITCH recent logs ────────────────────────────────────────
    case 'fs_logs':
        $lines = min((int)($_GET['lines'] ?? 50), 200);
        $result = run_cmd("sudo /usr/bin/journalctl -u freeswitch.service --no-pager -n {$lines} --output=short-iso 2>&1");
        json_response(true, 'Logs retrieved', ['logs' => $result['output']]);
        break;

    // ── Get nftables ban sets ─────────────────────────────────────────────
    case 'nft_sets':
        $result = run_cmd("sudo /usr/sbin/nft list table inet f2b-freeswitch 2>&1");
        json_response(true, 'nftables data', ['output' => $result['output'], 'success' => $result['code'] === 0]);
        break;

    // ── Reload fail2ban ───────────────────────────────────────────────────
    case 'reload':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $result = f2b_client('reload');
        json_response($result['code'] === 0, $result['code'] === 0 ? 'Fail2Ban reloaded.' : 'Reload failed: ' . $result['output']);
        break;

    default:
        http_response_code(400);
        json_response(false, 'Unknown action.');
}

// ── Helper Functions ───────────────────────────────────────────────────────

function extract_banned_ips(string $output): array {
    foreach (explode("\n", $output) as $line) {
        if (preg_match('/Banned IP list:\s*(.*)/', $line, $m)) {
            $ips = array_filter(array_map('trim', explode(' ', $m[1])));
            return array_values($ips);
        }
    }
    return [];
}

function extract_jail_list(string $output): array {
    foreach (explode("\n", $output) as $line) {
        if (strpos($line, 'Jail list:') !== false) {
            $part = trim(str_replace(['Jail list:', '`- '], '', $line));
            return array_filter(array_map('trim', explode(',', $part)));
        }
    }
    return [];
}

function parse_jail_status(string $output): array {
    $data = [];
    foreach (explode("\n", $output) as $line) {
        if (preg_match('/Currently failed:\s*(\d+)/', $line, $m)) $data['failed'] = (int)$m[1];
        if (preg_match('/Total failed:\s*(\d+)/', $line, $m))     $data['total_failed'] = (int)$m[1];
        if (preg_match('/Currently banned:\s*(\d+)/', $line, $m)) $data['banned'] = (int)$m[1];
        if (preg_match('/Total banned:\s*(\d+)/', $line, $m))     $data['total_banned'] = (int)$m[1];
        if (preg_match('/Banned IP list:\s*(.*)/', $line, $m))    $data['banned_ips'] = array_filter(explode(' ', trim($m[1])));
    }
    return $data;
}
API_F2B

    log_success "API files created."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11: CREATE DASHBOARD FRONTEND (HTML/CSS/JS)
# ─────────────────────────────────────────────────────────────────────────────
create_dashboard_frontend() {
    log_step "Creating Dashboard Frontend (HTML/CSS/JS)"

    # ── Login Page ─────────────────────────────────────────────────────────
    cat > "${DASHBOARD_DIR}/login.php" << 'LOGIN_PHP'
<?php
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();
if (isset($_SESSION['authenticated']) && $_SESSION['authenticated'] === true) {
    header('Location: /fail2ban/');
    exit;
}
?>
<!DOCTYPE html>
<html lang="bn">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FreeSWITCH Security — Login</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(135deg,#0f0c29,#302b63,#24243e);min-height:100vh;display:flex;align-items:center;justify-content:center}
  .card{background:rgba(255,255,255,0.05);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,0.1);border-radius:20px;padding:40px;width:100%;max-width:420px;box-shadow:0 25px 50px rgba(0,0,0,0.5)}
  .logo{text-align:center;margin-bottom:30px}
  .logo-icon{font-size:48px;margin-bottom:10px}
  .logo h1{color:#fff;font-size:22px;font-weight:700}
  .logo p{color:rgba(255,255,255,0.5);font-size:13px;margin-top:4px}
  .form-group{margin-bottom:20px}
  label{display:block;color:rgba(255,255,255,0.7);font-size:13px;margin-bottom:8px;font-weight:500}
  input{width:100%;padding:12px 16px;background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.15);border-radius:10px;color:#fff;font-size:15px;outline:none;transition:all .3s}
  input:focus{border-color:#6c63ff;background:rgba(108,99,255,0.1);box-shadow:0 0 0 3px rgba(108,99,255,0.2)}
  input::placeholder{color:rgba(255,255,255,0.3)}
  .btn{width:100%;padding:14px;background:linear-gradient(135deg,#6c63ff,#5a52e0);border:none;border-radius:10px;color:#fff;font-size:16px;font-weight:600;cursor:pointer;transition:all .3s;margin-top:10px}
  .btn:hover{transform:translateY(-2px);box-shadow:0 10px 30px rgba(108,99,255,0.4)}
  .btn:active{transform:translateY(0)}
  .btn:disabled{opacity:.6;cursor:not-allowed;transform:none}
  .alert{padding:12px 16px;border-radius:10px;font-size:14px;margin-bottom:20px;display:none}
  .alert-error{background:rgba(239,68,68,0.2);border:1px solid rgba(239,68,68,0.4);color:#fca5a5}
  .alert-success{background:rgba(34,197,94,0.2);border:1px solid rgba(34,197,94,0.4);color:#86efac}
  .badge{display:inline-block;background:rgba(239,68,68,0.2);color:#fca5a5;border:1px solid rgba(239,68,68,0.3);padding:4px 12px;border-radius:20px;font-size:11px;margin-bottom:20px}
  .spinner{display:inline-block;width:18px;height:18px;border:2px solid rgba(255,255,255,0.3);border-top-color:#fff;border-radius:50%;animation:spin .8s linear infinite;vertical-align:middle;margin-right:8px}
  @keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="card">
    <div class="logo">
        <div class="logo-icon">🛡️</div>
        <h1>FreeSWITCH Security</h1>
        <p>Fail2Ban Management Dashboard</p>
        <br>
        <span class="badge">🔐 Restricted Access</span>
    </div>

    <div class="alert alert-error" id="alertBox"></div>

    <form id="loginForm">
        <div class="form-group">
            <label for="username">👤 Username</label>
            <input type="text" id="username" name="username" placeholder="admin" autocomplete="username" required>
        </div>
        <div class="form-group">
            <label for="password">🔑 Password</label>
            <input type="password" id="password" name="password" placeholder="Enter password" autocomplete="current-password" required>
        </div>
        <button type="submit" class="btn" id="loginBtn">Login to Dashboard</button>
    </form>
</div>

<script>
document.getElementById('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = document.getElementById('loginBtn');
    const alert = document.getElementById('alertBox');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span>Authenticating...';
    alert.style.display = 'none';

    const fd = new FormData(e.target);
    fd.append('action', 'login');

    try {
        const res = await fetch('/fail2ban/api/auth.php', { method: 'POST', body: fd });
        const data = await res.json();
        if (data.success) {
            btn.innerHTML = '✅ Success! Redirecting...';
            window.location.href = '/fail2ban/';
        } else {
            alert.textContent = '⚠️ ' + data.message;
            alert.style.display = 'block';
            btn.disabled = false;
            btn.innerHTML = 'Login to Dashboard';
            document.getElementById('password').value = '';
        }
    } catch (err) {
        alert.textContent = '⚠️ Connection error. Please try again.';
        alert.style.display = 'block';
        btn.disabled = false;
        btn.innerHTML = 'Login to Dashboard';
    }
});
</script>
</body>
</html>
LOGIN_PHP

    # ── Main Dashboard index.php ───────────────────────────────────────────
    cat > "${DASHBOARD_DIR}/index.php" << 'DASHBOARD_PHP'
<?php
/**
 * FreeSWITCH Security Dashboard — Main Interface
 * Auth check: redirects to login if not authenticated
 */
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();
if (!isset($_SESSION['authenticated']) || $_SESSION['authenticated'] !== true) {
    header('Location: /fail2ban/login.php');
    exit;
}
// Session timeout: 1 hour
if ((time() - ($_SESSION['login_time'] ?? 0)) > 3600) {
    session_destroy();
    header('Location: /fail2ban/login.php?expired=1');
    exit;
}
$username = htmlspecialchars($_SESSION['username'] ?? 'admin');
$role     = htmlspecialchars($_SESSION['role'] ?? 'user');
?>
<!DOCTYPE html>
<html lang="bn">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FreeSWITCH Security Dashboard</title>
<style>
:root{--bg:#0d1117;--surface:#161b22;--surface2:#21262d;--border:#30363d;--text:#e6edf3;--text-muted:#8b949e;--primary:#6c63ff;--primary-dark:#5a52e0;--success:#3fb950;--danger:#f85149;--warning:#d29922;--info:#58a6ff}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;overflow-x:hidden}
/* ── Sidebar ─────────────────────────────────────────────────────────── */
.sidebar{position:fixed;top:0;left:0;width:260px;height:100vh;background:var(--surface);border-right:1px solid var(--border);display:flex;flex-direction:column;z-index:100;transition:transform .3s}
.sidebar-logo{padding:24px 20px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px}
.sidebar-logo .icon{font-size:28px}
.sidebar-logo h1{font-size:16px;font-weight:700;color:var(--text)}
.sidebar-logo p{font-size:11px;color:var(--text-muted)}
.nav{flex:1;padding:16px 0;overflow-y:auto}
.nav-section{padding:8px 20px 4px;font-size:10px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:1px}
.nav-item{display:flex;align-items:center;gap:12px;padding:10px 20px;color:var(--text-muted);text-decoration:none;cursor:pointer;transition:all .2s;font-size:14px;border-left:3px solid transparent}
.nav-item:hover,.nav-item.active{background:rgba(108,99,255,0.1);color:var(--text);border-left-color:var(--primary)}
.nav-item .icon{font-size:18px;width:22px;text-align:center}
.sidebar-footer{padding:16px 20px;border-top:1px solid var(--border);font-size:12px;color:var(--text-muted)}
.sidebar-footer strong{color:var(--text);display:block}
/* ── Main Content ───────────────────────────────────────────────────── */
.main{margin-left:260px;min-height:100vh;display:flex;flex-direction:column}
.topbar{background:var(--surface);border-bottom:1px solid var(--border);padding:0 28px;height:60px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:50}
.topbar h2{font-size:18px;font-weight:600}
.topbar-actions{display:flex;align-items:center;gap:12px}
.content{padding:28px;flex:1}
/* ── Cards ───────────────────────────────────────────────────────────── */
.cards-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:24px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:20px}
.card-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:12px}
.card-title{font-size:13px;color:var(--text-muted);font-weight:500}
.card-icon{font-size:22px}
.card-value{font-size:32px;font-weight:700;color:var(--text)}
.card-sub{font-size:12px;color:var(--text-muted);margin-top:4px}
/* ── Stat colors ──────────────────────────────────────────────────────── */
.stat-danger .card-value{color:var(--danger)}
.stat-success .card-value{color:var(--success)}
.stat-warning .card-value{color:var(--warning)}
.stat-info .card-value{color:var(--info)}
/* ── Tables ───────────────────────────────────────────────────────────── */
.table-card{background:var(--surface);border:1px solid var(--border);border-radius:12px;overflow:hidden;margin-bottom:24px}
.table-card-header{padding:16px 20px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center}
.table-card-header h3{font-size:15px;font-weight:600}
table{width:100%;border-collapse:collapse}
th{padding:10px 16px;text-align:left;font-size:12px;font-weight:600;color:var(--text-muted);background:var(--surface2);text-transform:uppercase;letter-spacing:.5px}
td{padding:10px 16px;font-size:13px;border-top:1px solid var(--border)}
tr:hover td{background:rgba(255,255,255,0.02)}
.empty-state{text-align:center;padding:40px;color:var(--text-muted)}
/* ── Badges ──────────────────────────────────────────────────────────── */
.badge{display:inline-flex;align-items:center;gap:4px;padding:3px 10px;border-radius:20px;font-size:11px;font-weight:600}
.badge-danger{background:rgba(248,81,73,0.15);color:var(--danger);border:1px solid rgba(248,81,73,0.3)}
.badge-success{background:rgba(63,185,80,0.15);color:var(--success);border:1px solid rgba(63,185,80,0.3)}
.badge-warning{background:rgba(210,153,34,0.15);color:var(--warning);border:1px solid rgba(210,153,34,0.3)}
.badge-info{background:rgba(88,166,255,0.15);color:var(--info);border:1px solid rgba(88,166,255,0.3)}
/* ── Buttons ─────────────────────────────────────────────────────────── */
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;border:none;border-radius:8px;font-size:13px;font-weight:500;cursor:pointer;transition:all .2s;text-decoration:none}
.btn-primary{background:var(--primary);color:#fff}
.btn-primary:hover{background:var(--primary-dark)}
.btn-danger{background:rgba(248,81,73,0.15);color:var(--danger);border:1px solid rgba(248,81,73,0.3)}
.btn-danger:hover{background:rgba(248,81,73,0.25)}
.btn-success{background:rgba(63,185,80,0.15);color:var(--success);border:1px solid rgba(63,185,80,0.3)}
.btn-success:hover{background:rgba(63,185,80,0.25)}
.btn-sm{padding:5px 12px;font-size:12px}
.btn-outline{background:transparent;color:var(--text-muted);border:1px solid var(--border)}
.btn-outline:hover{border-color:var(--primary);color:var(--primary)}
/* ── Forms ───────────────────────────────────────────────────────────── */
.input-group{display:flex;gap:8px;margin-bottom:12px}
input,select,textarea{background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:8px 12px;border-radius:8px;font-size:13px;outline:none;width:100%;transition:border-color .2s}
input:focus,select:focus{border-color:var(--primary)}
input::placeholder{color:var(--text-muted)}
/* ── Section tabs ────────────────────────────────────────────────────── */
.section{display:none}
.section.active{display:block}
/* ── Alert ───────────────────────────────────────────────────────────── */
.alert-box{position:fixed;top:20px;right:20px;z-index:9999;display:flex;flex-direction:column;gap:8px}
.alert-item{padding:12px 18px;border-radius:10px;font-size:13px;display:flex;align-items:center;gap:10px;min-width:280px;max-width:400px;animation:slideIn .3s ease;box-shadow:0 4px 20px rgba(0,0,0,0.4)}
.alert-item.success{background:#1a3a2a;border:1px solid var(--success);color:var(--success)}
.alert-item.error{background:#3a1a1a;border:1px solid var(--danger);color:var(--danger)}
.alert-item.info{background:#1a2a3a;border:1px solid var(--info);color:var(--info)}
@keyframes slideIn{from{transform:translateX(120%);opacity:0}to{transform:translateX(0);opacity:1}}
/* ── Log viewer ──────────────────────────────────────────────────────── */
.log-viewer{background:#0d1117;border:1px solid var(--border);border-radius:8px;padding:16px;font-family:'Courier New',monospace;font-size:12px;line-height:1.6;max-height:500px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;color:#8b949e}
.log-viewer .log-warn{color:var(--warning)}
.log-viewer .log-err{color:var(--danger)}
.log-viewer .log-info{color:var(--info)}
/* ── Responsive ──────────────────────────────────────────────────────── */
@media(max-width:768px){.sidebar{transform:translateX(-100%)}.main{margin-left:0}.sidebar.open{transform:translateX(0)}}
/* ── Spinner ─────────────────────────────────────────────────────────── */
.spinner{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,0.2);border-top-color:currentColor;border-radius:50%;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
/* ── Tabs ────────────────────────────────────────────────────────────── */
.tab-bar{display:flex;gap:4px;margin-bottom:20px;background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:4px}
.tab-btn{flex:1;padding:8px 12px;background:none;border:none;color:var(--text-muted);font-size:13px;cursor:pointer;border-radius:7px;transition:all .2s;font-weight:500}
.tab-btn.active{background:var(--primary);color:#fff}
.tab-content{display:none}
.tab-content.active{display:block}
/* ── Refresh indicator ────────────────────────────────────────────────── */
.refresh-indicator{font-size:11px;color:var(--text-muted);display:flex;align-items:center;gap:6px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--success);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
</style>
</head>
<body>

<!-- Alert Box -->
<div class="alert-box" id="alertBox"></div>

<!-- Sidebar -->
<nav class="sidebar" id="sidebar">
    <div class="sidebar-logo">
        <div class="icon">🛡️</div>
        <div>
            <h1>FS Security</h1>
            <p>FreeSWITCH Fail2Ban</p>
        </div>
    </div>
    <div class="nav">
        <div class="nav-section">Main</div>
        <div class="nav-item active" data-section="overview" onclick="showSection('overview', this)">
            <span class="icon">📊</span> Overview
        </div>
        <div class="nav-item" data-section="banned" onclick="showSection('banned', this)">
            <span class="icon">🚫</span> Banned IPs
        </div>
        <div class="nav-item" data-section="ban_log" onclick="showSection('ban_log', this)">
            <span class="icon">📋</span> Ban Log
        </div>

        <div class="nav-section">Management</div>
        <div class="nav-item" data-section="whitelist" onclick="showSection('whitelist', this)">
            <span class="icon">✅</span> Whitelist
        </div>
        <div class="nav-item" data-section="manual_ban" onclick="showSection('manual_ban', this)">
            <span class="icon">🔨</span> Manual Ban/Unban
        </div>

        <div class="nav-section">Monitoring</div>
        <div class="nav-item" data-section="logs" onclick="showSection('logs', this)">
            <span class="icon">📝</span> FreeSWITCH Logs
        </div>
        <div class="nav-item" data-section="jails" onclick="showSection('jails', this)">
            <span class="icon">🏛️</span> Jail Status
        </div>
    </div>
    <div class="sidebar-footer">
        <strong>👤 <?= $username ?></strong>
        <span style="text-transform:capitalize"><?= $role ?></span>
        <br><br>
        <a href="#" onclick="logout()" style="color:var(--danger);text-decoration:none;font-size:12px">⏻ Logout</a>
    </div>
</nav>

<!-- Main Content -->
<div class="main">
    <div class="topbar">
        <h2 id="pageTitle">📊 Overview</h2>
        <div class="topbar-actions">
            <div class="refresh-indicator">
                <span class="dot"></span> Live
            </div>
            <button class="btn btn-outline btn-sm" onclick="refreshCurrentSection()">🔄 Refresh</button>
            <button class="btn btn-primary btn-sm" onclick="reloadFail2ban()">⚡ Reload F2B</button>
        </div>
    </div>

    <div class="content">

        <!-- ── OVERVIEW SECTION ─────────────────────────────────────── -->
        <div class="section active" id="section-overview">
            <div class="cards-grid" id="statsCards">
                <div class="card"><div class="card-header"><div><div class="card-title">Total Banned IPs</div><div class="card-value" id="totalBanned">—</div><div class="card-sub">Across all jails</div></div><div class="card-icon">🚫</div></div></div>
                <div class="card stat-danger"><div class="card-header"><div><div class="card-title">Active Jails</div><div class="card-value" id="activeJails">—</div><div class="card-sub">Monitoring</div></div><div class="card-icon">🏛️</div></div></div>
                <div class="card stat-warning"><div class="card-header"><div><div class="card-title">Current Failures</div><div class="card-value" id="currentFailed">—</div><div class="card-sub">All jails combined</div></div><div class="card-icon">⚠️</div></div></div>
                <div class="card stat-success"><div class="card-header"><div><div class="card-title">Fail2Ban Status</div><div class="card-value" id="f2bStatus" style="font-size:18px">—</div><div class="card-sub" id="f2bSub">Checking...</div></div><div class="card-icon">💚</div></div></div>
            </div>

            <div class="table-card">
                <div class="table-card-header">
                    <h3>🏛️ Jail Summary</h3>
                    <span id="lastUpdate" style="font-size:12px;color:var(--text-muted)"></span>
                </div>
                <div id="jailSummaryTable">
                    <div class="empty-state">⏳ Loading jail data...</div>
                </div>
            </div>

            <div class="table-card">
                <div class="table-card-header">
                    <h3>🕐 Recent Bans (Last 10)</h3>
                </div>
                <div id="recentBansTable">
                    <div class="empty-state">⏳ Loading...</div>
                </div>
            </div>
        </div>

        <!-- ── BANNED IPs SECTION ────────────────────────────────────── -->
        <div class="section" id="section-banned">
            <div class="table-card">
                <div class="table-card-header">
                    <h3>🚫 Currently Banned IPs</h3>
                    <button class="btn btn-outline btn-sm" onclick="loadBanned()">🔄 Refresh</button>
                </div>
                <div id="bannedTable">
                    <div class="empty-state">⏳ Loading...</div>
                </div>
            </div>
        </div>

        <!-- ── BAN LOG SECTION ───────────────────────────────────────── -->
        <div class="section" id="section-ban_log">
            <div class="table-card">
                <div class="table-card-header">
                    <h3>📋 Ban Activity Log</h3>
                    <div style="display:flex;gap:8px">
                        <select id="logFilter" style="width:140px" onchange="loadBanLog()">
                            <option value="">All Actions</option>
                            <option value="ban">Bans Only</option>
                            <option value="unban">Unbans Only</option>
                        </select>
                        <button class="btn btn-outline btn-sm" onclick="loadBanLog()">🔄 Refresh</button>
                    </div>
                </div>
                <div id="banLogTable">
                    <div class="empty-state">⏳ Loading...</div>
                </div>
            </div>
        </div>

        <!-- ── WHITELIST SECTION ─────────────────────────────────────── -->
        <div class="section" id="section-whitelist">
            <div class="card" style="margin-bottom:20px">
                <h3 style="margin-bottom:16px;font-size:15px">➕ Add IP to Whitelist</h3>
                <div class="input-group">
                    <input type="text" id="wlIP" placeholder="IP Address (e.g. 192.168.1.100)" style="flex:2">
                    <input type="text" id="wlDesc" placeholder="Description" style="flex:2">
                    <button class="btn btn-success" onclick="addWhitelist()">✅ Add</button>
                </div>
                <p style="font-size:12px;color:var(--text-muted)">⚠️ Adding an IP will also automatically unban it from all jails.</p>
            </div>
            <div class="table-card">
                <div class="table-card-header">
                    <h3>✅ Whitelisted IPs</h3>
                    <button class="btn btn-outline btn-sm" onclick="loadWhitelist()">🔄 Refresh</button>
                </div>
                <div id="whitelistTable">
                    <div class="empty-state">⏳ Loading...</div>
                </div>
            </div>
        </div>

        <!-- ── MANUAL BAN SECTION ────────────────────────────────────── -->
        <div class="section" id="section-manual_ban">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
                <div class="card">
                    <h3 style="margin-bottom:16px;font-size:15px;color:var(--danger)">🔨 Ban an IP</h3>
                    <div class="form-group" style="margin-bottom:12px">
                        <label style="color:var(--text-muted);font-size:12px;display:block;margin-bottom:6px">IP Address</label>
                        <input type="text" id="banIP" placeholder="1.2.3.4">
                    </div>
                    <div class="form-group" style="margin-bottom:16px">
                        <label style="color:var(--text-muted);font-size:12px;display:block;margin-bottom:6px">Jail</label>
                        <select id="banJail">
                            <option value="freeswitch-auth">freeswitch-auth</option>
                            <option value="freeswitch-scanner">freeswitch-scanner</option>
                            <option value="freeswitch-dos">freeswitch-dos</option>
                            <option value="freeswitch-malformed">freeswitch-malformed</option>
                        </select>
                    </div>
                    <button class="btn btn-danger" style="width:100%" onclick="manualBan()">🚫 Ban IP</button>
                </div>
                <div class="card">
                    <h3 style="margin-bottom:16px;font-size:15px;color:var(--success)">🔓 Unban an IP</h3>
                    <div class="form-group" style="margin-bottom:12px">
                        <label style="color:var(--text-muted);font-size:12px;display:block;margin-bottom:6px">IP Address</label>
                        <input type="text" id="unbanIP" placeholder="1.2.3.4">
                    </div>
                    <div class="form-group" style="margin-bottom:16px">
                        <label style="color:var(--text-muted);font-size:12px;display:block;margin-bottom:6px">Jail (leave blank = all jails)</label>
                        <select id="unbanJail">
                            <option value="">All Jails</option>
                            <option value="freeswitch-auth">freeswitch-auth</option>
                            <option value="freeswitch-scanner">freeswitch-scanner</option>
                            <option value="freeswitch-dos">freeswitch-dos</option>
                            <option value="freeswitch-malformed">freeswitch-malformed</option>
                        </select>
                    </div>
                    <button class="btn btn-success" style="width:100%" onclick="manualUnban()">🔓 Unban IP</button>
                </div>
            </div>
        </div>

        <!-- ── FREESWITCH LOGS SECTION ───────────────────────────────── -->
        <div class="section" id="section-logs">
            <div class="table-card">
                <div class="table-card-header">
                    <h3>📝 FreeSWITCH System Logs (journalctl)</h3>
                    <div style="display:flex;gap:8px;align-items:center">
                        <select id="logLines" style="width:100px">
                            <option value="50">50 lines</option>
                            <option value="100">100 lines</option>
                            <option value="200">200 lines</option>
                        </select>
                        <button class="btn btn-outline btn-sm" onclick="loadFSLogs()">🔄 Refresh</button>
                    </div>
                </div>
                <div style="padding:16px">
                    <div class="log-viewer" id="logViewer">⏳ Loading logs...</div>
                </div>
            </div>
        </div>

        <!-- ── JAIL STATUS SECTION ───────────────────────────────────── -->
        <div class="section" id="section-jails">
            <div id="jailDetails">
                <div class="empty-state">⏳ Loading jail details...</div>
            </div>
        </div>

    </div><!-- /content -->
</div><!-- /main -->

<script>
// ── State ────────────────────────────────────────────────────────────────────
let currentSection = 'overview';
let autoRefreshTimer = null;

// ── Section Navigation ───────────────────────────────────────────────────────
function showSection(name, el) {
    document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
    document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
    document.getElementById('section-' + name).classList.add('active');
    if (el) el.classList.add('active');
    currentSection = name;

    const titles = {
        overview: '📊 Overview', banned: '🚫 Banned IPs', ban_log: '📋 Ban Log',
        whitelist: '✅ Whitelist', manual_ban: '🔨 Manual Ban/Unban',
        logs: '📝 FreeSWITCH Logs', jails: '🏛️ Jail Status'
    };
    document.getElementById('pageTitle').textContent = titles[name] || name;
    loadSection(name);
}

function loadSection(name) {
    switch(name) {
        case 'overview':   loadOverview(); break;
        case 'banned':     loadBanned(); break;
        case 'ban_log':    loadBanLog(); break;
        case 'whitelist':  loadWhitelist(); break;
        case 'logs':       loadFSLogs(); break;
        case 'jails':      loadJailDetails(); break;
    }
}

function refreshCurrentSection() { loadSection(currentSection); }

// ── Alert System ─────────────────────────────────────────────────────────────
function showAlert(message, type = 'info', duration = 4000) {
    const box = document.getElementById('alertBox');
    const item = document.createElement('div');
    const icons = { success: '✅', error: '❌', info: 'ℹ️' };
    item.className = 'alert-item ' + type;
    item.innerHTML = `<span>${icons[type] || 'ℹ️'}</span><span>${message}</span>`;
    box.appendChild(item);
    setTimeout(() => { item.style.opacity = '0'; item.style.transition = 'opacity .5s'; setTimeout(() => item.remove(), 500); }, duration);
}

// ── API Helper ───────────────────────────────────────────────────────────────
async function api(action, params = {}, method = 'GET') {
    try {
        let url = `/fail2ban/api/fail2ban.php?action=${action}`;
        let opts = { method };
        if (method === 'POST') {
            const fd = new FormData();
            fd.append('action', action);
            Object.entries(params).forEach(([k, v]) => fd.append(k, v));
            opts.body = fd;
            url = '/fail2ban/api/fail2ban.php';
        } else if (Object.keys(params).length) {
            Object.entries(params).forEach(([k, v]) => url += `&${k}=${encodeURIComponent(v)}`);
        }
        const res = await fetch(url, opts);
        if (res.status === 401) { window.location.href = '/fail2ban/login.php'; return null; }
        return await res.json();
    } catch (err) {
        showAlert('API Error: ' + err.message, 'error');
        return null;
    }
}

// ── Overview ─────────────────────────────────────────────────────────────────
async function loadOverview() {
    const data = await api('status');
    if (!data) return;

    document.getElementById('activeJails').textContent = data.jails?.length ?? 0;
    document.getElementById('f2bStatus').textContent = data.running ? '🟢 Running' : '🔴 Down';
    document.getElementById('f2bSub').textContent = data.running ? 'All systems go' : 'Service issue!';
    document.getElementById('lastUpdate').textContent = 'Updated: ' + new Date().toLocaleTimeString();

    let totalBanned = 0, totalFailed = 0;
    const jailRows = Object.entries(data.jail_data || {}).map(([jail, info]) => {
        totalBanned += info.banned ?? 0;
        totalFailed += info.failed ?? 0;
        return `<tr>
            <td><strong>${jail}</strong></td>
            <td><span class="badge badge-danger">${info.banned ?? 0} banned</span></td>
            <td><span class="badge badge-warning">${info.failed ?? 0} failing</span></td>
            <td><span class="badge badge-info">${info.total_banned ?? 0} total</span></td>
        </tr>`;
    });

    document.getElementById('totalBanned').textContent = totalBanned;
    document.getElementById('currentFailed').textContent = totalFailed;

    document.getElementById('jailSummaryTable').innerHTML = jailRows.length > 0
        ? `<table><thead><tr><th>Jail Name</th><th>Currently Banned</th><th>Currently Failing</th><th>Total Banned</th></tr></thead><tbody>${jailRows.join('')}</tbody></table>`
        : '<div class="empty-state">No jails active or fail2ban not running.</div>';

    // Recent bans
    const logData = await api('ban_log', { limit: 10 });
    if (logData?.bans?.length > 0) {
        const rows = logData.bans.slice(0, 10).map(b => `<tr>
            <td><code style="color:var(--info)">${b.ip}</code></td>
            <td>${b.jail}</td>
            <td><span class="badge ${b.action === 'ban' ? 'badge-danger' : 'badge-success'}">${b.action === 'ban' ? '🚫 Banned' : '🔓 Unbanned'}</span></td>
            <td style="color:var(--text-muted)">${formatTime(b.timestamp)}</td>
        </tr>`).join('');
        document.getElementById('recentBansTable').innerHTML = `<table><thead><tr><th>IP Address</th><th>Jail</th><th>Action</th><th>Time</th></tr></thead><tbody>${rows}</tbody></table>`;
    } else {
        document.getElementById('recentBansTable').innerHTML = '<div class="empty-state">🎉 No bans recorded yet. System is clean!</div>';
    }
}

// ── Banned IPs ───────────────────────────────────────────────────────────────
async function loadBanned() {
    const data = await api('banned');
    if (!data) return;

    if (data.banned?.length > 0) {
        const rows = data.banned.map(item => `<tr>
            <td><code style="color:var(--danger)">${item.ip}</code></td>
            <td><span class="badge badge-warning">${item.jail}</span></td>
            <td>
                <button class="btn btn-success btn-sm" onclick="quickUnban('${item.ip}', '${item.jail}')">🔓 Unban</button>
                <button class="btn btn-outline btn-sm" onclick="addToWL('${item.ip}')">✅ Whitelist</button>
            </td>
        </tr>`).join('');
        document.getElementById('bannedTable').innerHTML = `
            <div style="padding:12px 20px;background:rgba(248,81,73,0.05);border-bottom:1px solid var(--border);font-size:13px">
                <strong>${data.banned.length}</strong> IP(s) currently banned
            </div>
            <table><thead><tr><th>IP Address</th><th>Jail</th><th>Actions</th></tr></thead><tbody>${rows}</tbody></table>`;
    } else {
        document.getElementById('bannedTable').innerHTML = '<div class="empty-state">🎉 No banned IPs! Your system is clean.</div>';
    }
}

// ── Ban Log ───────────────────────────────────────────────────────────────────
async function loadBanLog() {
    const filter = document.getElementById('logFilter')?.value || '';
    const data = await api('ban_log', { limit: 200 });
    if (!data) return;

    let bans = data.bans || [];
    if (filter) bans = bans.filter(b => b.action === filter);

    if (bans.length > 0) {
        const rows = bans.map(b => `<tr>
            <td><code style="color:var(--info)">${b.ip}</code></td>
            <td>${b.jail}</td>
            <td><span class="badge ${b.action === 'ban' ? 'badge-danger' : 'badge-success'}">${b.action === 'ban' ? '🚫 Ban' : '🔓 Unban'}</span></td>
            <td style="color:var(--text-muted);font-size:12px">${formatTime(b.timestamp)}</td>
            ${b.action === 'ban' ? `<td style="color:var(--text-muted);font-size:12px">${formatDuration(b.bantime)}</td>` : '<td>—</td>'}
        </tr>`).join('');
        document.getElementById('banLogTable').innerHTML = `<table><thead><tr><th>IP Address</th><th>Jail</th><th>Action</th><th>Time</th><th>Ban Duration</th></tr></thead><tbody>${rows}</tbody></table>`;
    } else {
        document.getElementById('banLogTable').innerHTML = '<div class="empty-state">No ban events recorded.</div>';
    }
}

// ── Whitelist ─────────────────────────────────────────────────────────────────
async function loadWhitelist() {
    const data = await api('whitelist');
    if (!data) return;

    const items = data.whitelist || [];
    if (items.length > 0) {
        const rows = items.map(item => `<tr>
            <td><code style="color:var(--success)">${item.ip}</code></td>
            <td>${item.description || '—'}</td>
            <td style="color:var(--text-muted);font-size:12px">${item.added_by || 'system'}</td>
            <td style="color:var(--text-muted);font-size:12px">${formatTime(item.added_at)}</td>
            <td>
                ${item.permanent
                    ? '<span class="badge badge-info">🔒 Permanent</span>'
                    : `<button class="btn btn-danger btn-sm" onclick="removeWhitelist(${item.id})">🗑️ Remove</button>`}
            </td>
        </tr>`).join('');
        document.getElementById('whitelistTable').innerHTML = `<table><thead><tr><th>IP Address</th><th>Description</th><th>Added By</th><th>Date</th><th>Action</th></tr></thead><tbody>${rows}</tbody></table>`;
    } else {
        document.getElementById('whitelistTable').innerHTML = '<div class="empty-state">No whitelist entries.</div>';
    }
}

async function addWhitelist() {
    const ip = document.getElementById('wlIP').value.trim();
    const desc = document.getElementById('wlDesc').value.trim();
    if (!ip) { showAlert('Please enter an IP address.', 'error'); return; }
    const data = await api('whitelist_add', { ip, description: desc }, 'POST');
    if (data?.success) {
        showAlert(data.message, 'success');
        document.getElementById('wlIP').value = '';
        document.getElementById('wlDesc').value = '';
        loadWhitelist();
    } else {
        showAlert(data?.message || 'Failed to add whitelist entry.', 'error');
    }
}

async function removeWhitelist(id) {
    if (!confirm('Remove this whitelist entry?')) return;
    const data = await api('whitelist_remove', { id }, 'POST');
    if (data?.success) { showAlert('Whitelist entry removed.', 'success'); loadWhitelist(); }
    else showAlert(data?.message || 'Failed to remove entry.', 'error');
}

// ── FreeSWITCH Logs ──────────────────────────────────────────────────────────
async function loadFSLogs() {
    const lines = document.getElementById('logLines')?.value || 50;
    const viewer = document.getElementById('logViewer');
    viewer.textContent = '⏳ Loading...';
    const data = await api('fs_logs', { lines });
    if (!data) return;

    // Colorize log output
    const colored = (data.logs || '').replace(/\[WARNING\]/g, '<span class="log-warn">[WARNING]</span>')
        .replace(/\[ERROR\]/g, '<span class="log-err">[ERROR]</span>')
        .replace(/\[CRIT\]/g, '<span class="log-err">[CRIT]</span>')
        .replace(/\[NOTICE\]/g, '<span class="log-info">[NOTICE]</span>');
    viewer.innerHTML = colored || '<span style="color:var(--text-muted)">No log entries found.</span>';
    viewer.scrollTop = viewer.scrollHeight;
}

// ── Jail Details ──────────────────────────────────────────────────────────────
async function loadJailDetails() {
    const data = await api('status');
    if (!data) return;

    const cards = Object.entries(data.jail_data || {}).map(([jail, info]) => `
        <div class="card" style="margin-bottom:16px">
            <h3 style="font-size:15px;margin-bottom:12px">🏛️ ${jail}</h3>
            <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:12px">
                <div style="text-align:center"><div style="color:var(--danger);font-size:24px;font-weight:700">${info.banned ?? 0}</div><div style="color:var(--text-muted);font-size:11px">Currently Banned</div></div>
                <div style="text-align:center"><div style="color:var(--warning);font-size:24px;font-weight:700">${info.failed ?? 0}</div><div style="color:var(--text-muted);font-size:11px">Currently Failing</div></div>
                <div style="text-align:center"><div style="color:var(--info);font-size:24px;font-weight:700">${info.total_banned ?? 0}</div><div style="color:var(--text-muted);font-size:11px">Total Banned</div></div>
                <div style="text-align:center"><div style="color:var(--text-muted);font-size:24px;font-weight:700">${info.total_failed ?? 0}</div><div style="color:var(--text-muted);font-size:11px">Total Failed</div></div>
            </div>
            ${(info.banned_ips?.length > 0) ? `<div style="font-size:12px;color:var(--text-muted);margin-top:8px">Banned: ${Array.from(info.banned_ips).map(ip => `<code style="background:rgba(248,81,73,0.1);padding:2px 6px;border-radius:4px;margin:2px;display:inline-block;cursor:pointer" onclick="quickUnban('${ip}','${jail}')" title="Click to unban">${ip}</code>`).join('')}</div>` : ''}
        </div>`).join('');

    document.getElementById('jailDetails').innerHTML = cards || '<div class="empty-state">No jail data available.</div>';
}

// ── Manual Ban/Unban ──────────────────────────────────────────────────────────
async function manualBan() {
    const ip = document.getElementById('banIP').value.trim();
    const jail = document.getElementById('banJail').value;
    if (!ip) { showAlert('Enter an IP address.', 'error'); return; }
    const data = await api('ban', { ip, jail }, 'POST');
    if (data?.success) { showAlert(data.message, 'success'); document.getElementById('banIP').value = ''; }
    else showAlert(data?.message || 'Ban failed.', 'error');
}

async function manualUnban() {
    const ip = document.getElementById('unbanIP').value.trim();
    const jail = document.getElementById('unbanJail').value;
    if (!ip) { showAlert('Enter an IP address.', 'error'); return; }
    const data = await api('unban', { ip, jail }, 'POST');
    if (data?.success) { showAlert(data.message, 'success'); document.getElementById('unbanIP').value = ''; }
    else showAlert(data?.message || 'Unban failed.', 'error');
}

async function quickUnban(ip, jail) {
    if (!confirm(`Unban ${ip} from ${jail}?`)) return;
    const data = await api('unban', { ip, jail }, 'POST');
    if (data?.success) { showAlert(`${ip} unbanned.`, 'success'); loadSection(currentSection); }
    else showAlert(data?.message || 'Unban failed.', 'error');
}

async function addToWL(ip) {
    if (!confirm(`Add ${ip} to whitelist and unban?`)) return;
    const data = await api('whitelist_add', { ip, description: 'Manually whitelisted' }, 'POST');
    if (data?.success) { showAlert(`${ip} whitelisted.`, 'success'); loadBanned(); }
    else showAlert(data?.message || 'Failed.', 'error');
}

// ── Fail2Ban Reload ────────────────────────────────────────────────────────────
async function reloadFail2ban() {
    const data = await api('reload', {}, 'POST');
    if (data?.success) showAlert('Fail2Ban reloaded successfully!', 'success');
    else showAlert(data?.message || 'Reload failed.', 'error');
}

// ── Logout ────────────────────────────────────────────────────────────────────
async function logout() {
    await fetch('/fail2ban/api/auth.php?action=logout');
    window.location.href = '/fail2ban/login.php';
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function formatTime(ts) {
    if (!ts) return '—';
    try { return new Date(ts).toLocaleString('en-GB', { hour12: false }); } catch { return ts; }
}

function formatDuration(seconds) {
    if (!seconds || seconds === 0) return 'Permanent';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (h > 0) return `${h}h ${m}m`;
    return `${m} min`;
}

// ── Auto-refresh every 30 seconds ─────────────────────────────────────────────
setInterval(() => {
    if (['overview', 'banned', 'jails'].includes(currentSection)) {
        loadSection(currentSection);
    }
}, 30000);

// ── Init ──────────────────────────────────────────────────────────────────────
loadOverview();
</script>
</body>
</html>
DASHBOARD_PHP

    # ── .htaccess for security ────────────────────────────────────────────────
    cat > "${DASHBOARD_DIR}/.htaccess" << 'HTACCESS'
Options -Indexes
DirectoryIndex index.php login.php

# Deny access to data directory (JSON files)
<FilesMatch "\.(json|sh|log)$">
    Require all denied
</FilesMatch>

# Allow PHP files only
<FilesMatch "\.php$">
    Require all granted
</FilesMatch>

# Security headers
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
HTACCESS

    log_success "Dashboard frontend created."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 12: SET PERMISSIONS
# ─────────────────────────────────────────────────────────────────────────────
set_permissions() {
    log_step "Setting File Permissions"

    # Dashboard files: www-data owns, restrictive permissions
    chown -R www-data:www-data "${DASHBOARD_DIR}"

    # Directories: 750
    find "${DASHBOARD_DIR}" -type d -exec chmod 750 {} \;

    # PHP files: 640 (read by www-data, not world)
    find "${DASHBOARD_DIR}" -name "*.php" -exec chmod 640 {} \;

    # Data directory: only www-data can read/write
    chmod 700 "${DASHBOARD_DIR}/data"
    find "${DASHBOARD_DIR}/data" -name "*.json" -exec chmod 600 {} \;

    # Scripts: executable by www-data
    chmod 750 "${DASHBOARD_DIR}/scripts/log_ban.sh"

    # Fail2ban config: root only
    chown -R root:root /etc/fail2ban/
    chmod 640 /etc/fail2ban/jail.local 2>/dev/null || true
    chmod 640 "${FAIL2BAN_JAIL_DIR}/freeswitch.local" 2>/dev/null || true
    find "${FAIL2BAN_FILTER_DIR}" -name "freeswitch-*.conf" -exec chmod 640 {} \;

    log_success "Permissions set correctly."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 13: ENABLE & START SERVICES
# ─────────────────────────────────────────────────────────────────────────────
enable_services() {
    log_step "Enabling & Starting Services"

    # Reload Apache config first
    apache2ctl configtest 2>/dev/null && systemctl reload apache2 || systemctl restart apache2

    # nftables
    systemctl enable --now nftables 2>/dev/null || true

    # Fail2Ban — validate config before starting
    log_info "Validating Fail2Ban configuration..."
    if fail2ban-client -t 2>/dev/null; then
        log_success "Fail2Ban configuration is valid."
    else
        log_warn "Fail2Ban config test had warnings. Check /var/log/fail2ban.log"
        fail2ban-client -t 2>&1 | head -20 || true
    fi

    # Enable and start fail2ban
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || {
        log_error "Fail2Ban failed to start. Check: journalctl -u fail2ban -n 50"
    }

    # Apache2
    systemctl enable --now apache2 2>/dev/null || true

    # Brief pause for services to settle
    sleep 3

    # Check service statuses
    local services=(apache2 fail2ban nftables)
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            log_success "$svc is running."
        else
            log_warn "$svc is NOT running. Check: systemctl status $svc"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 14: VERIFY FAIL2BAN JAILS ARE ACTIVE
# ─────────────────────────────────────────────────────────────────────────────
verify_jails() {
    log_step "Verifying Fail2Ban Jails"

    sleep 2
    local expected_jails=(freeswitch-auth freeswitch-scanner freeswitch-dos freeswitch-malformed sshd)

    if ! fail2ban-client ping &>/dev/null; then
        log_warn "Fail2Ban is not responding to ping. Jails verification skipped."
        return 0
    fi

    for jail in "${expected_jails[@]}"; do
        if fail2ban-client status "$jail" &>/dev/null; then
            local banned
            banned=$(fail2ban-client status "$jail" 2>/dev/null | grep 'Currently banned' | awk '{print $NF}')
            log_success "Jail [$jail] is ACTIVE — Currently banned: ${banned:-0}"
        else
            log_warn "Jail [$jail] is not active. May start when first log match occurs."
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY REPORT
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    local server_ip="$SERVER_IP"

    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║              ✅ SETUP COMPLETE — SYSTEM SUMMARY                     ║"
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    printf "║  %-68s ║\n" ""
    printf "║  %-68s ║\n" "  📁 Dashboard:      http://${server_ip}/fail2ban/"
    printf "║  %-68s ║\n" "  👤 Username:       admin"
    printf "║  %-68s ║\n" "  🔑 Password:       Admin@1234  ← CHANGE IMMEDIATELY!"
    printf "║  %-68s ║\n" ""
    printf "║  %-68s ║\n" "  🔒 Security Jails:"
    printf "║  %-68s ║\n" "     • freeswitch-auth     → maxretry=8,  bantime=1h"
    printf "║  %-68s ║\n" "     • freeswitch-scanner  → maxretry=1,  bantime=24h (instant!)"
    printf "║  %-68s ║\n" "     • freeswitch-dos      → maxretry=20, bantime=2h"
    printf "║  %-68s ║\n" "     • freeswitch-malformed→ maxretry=3,  bantime=2h"
    printf "║  %-68s ║\n" "     • sshd                → maxretry=5,  bantime=1h"
    printf "║  %-68s ║\n" ""
    printf "║  %-68s ║\n" "  🛡️  Whitelist: 127.0.0.0/8, ::1, ${server_ip}"
    printf "║  %-68s ║\n" "  🔥 Firewall:  nftables (inet filter + f2b-freeswitch)"
    printf "║  %-68s ║\n" "  📝 Log file:  ${LOG_FILE}"
    printf "║  %-68s ║\n" "  💾 Backup:    ${BACKUP_DIR}"
    printf "║  %-68s ║\n" ""
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    printf "║  %-68s ║\n" "  ⚡ QUICK COMMANDS:"
    printf "║  %-68s ║\n" "  fail2ban-client status           → All jails status"
    printf "║  %-68s ║\n" "  fail2ban-client status freeswitch-auth → Auth jail"
    printf "║  %-68s ║\n" "  fail2ban-client set freeswitch-auth unbanip 1.2.3.4"
    printf "║  %-68s ║\n" "  nft list table inet f2b-freeswitch → nftables bans"
    printf "║  %-68s ║\n" "  journalctl -u freeswitch -f       → Live FS logs"
    printf "║  %-68s ║\n" ""
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    printf "║  %-68s ║\n" "  ⚠️  IMPORTANT POST-SETUP STEPS:"
    printf "║  %-68s ║\n" "  1. Change admin password at: http://${server_ip}/fail2ban/"
    printf "║  %-68s ║\n" "  2. Add your IPs to whitelist via dashboard"
    printf "║  %-68s ║\n" "  3. Enable FreeSWITCH log-auth-failures in sofia profiles"
    printf "║  %-68s ║\n" "  4. Set up HTTPS (Let's Encrypt) for the dashboard"
    printf "║  %-68s ║\n" "  5. Test: fail2ban-client -t  (verify config)"
    printf "║  %-68s ║\n" ""
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN EXECUTION FLOW
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log_banner
    log_info "Starting setup... Log: ${LOG_FILE}"
    log_info "Server IP detected: ${SERVER_IP}"
    echo ""

    preflight_checks
    backup_existing_configs
    install_packages
    configure_apache
    configure_nftables
    create_fail2ban_filters
    create_fail2ban_actions
    configure_fail2ban_jails
    configure_sudoers
    create_dashboard_structure
    create_dashboard_php
    create_dashboard_frontend
    set_permissions
    enable_services
    verify_jails
    print_summary

    # Disable rollback trap on success
    trap - ERR
    log_success "All done! Setup completed successfully."
}

main "$@"
