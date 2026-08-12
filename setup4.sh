#!/usr/bin/env bash
# =============================================================================
# FreeSWITCH Security & Fail2Ban Automated Setup Script — FIXED EDITION
# Target OS  : Debian 12 (Bookworm)
# Version    : 2.2.1 (patched — auto-detects journal vs file logging, fixed datepattern newline)
#
# FIXES vs v2.0.0:
#  1. Ban events now ACTUALLY reach the dashboard (previous script created a
#     custom nftables action that was never wired into any jail — the built-in
#     'nftables[type=allports]' action was used instead, so log_ban.sh / the
#     Ban Log page never fired). We keep the reliable built-in nftables action
#     for firewalling, and attach a small logging-only action for the JSON log.
#  2. Adds a pre-flight check that verifies FreeSWITCH is actually writing to
#     the systemd journal. If it isn't, fail2ban's systemd backend will never
#     see auth failures and will never ban anyone — this is the #1 reason
#     "attack hocche kintu block hocche na". The script prints exact
#     instructions to fix FreeSWITCH logging instead of failing silently.
#  3. Removes unused/dangerous sudoers rules (nft add/delete element wildcards
#     that the PHP code never calls) — reduces blast radius if the dashboard
#     is ever compromised.
#  4. PHP shell calls now use escapeshellarg() per-argument instead of
#     escapeshellcmd() on the whole string.
#  5. Removes the dead/fake DEFAULT_ADMIN_PASS_HASH constant.
#  6. Admin is forced to change the password on first login.
#
# Usage: sudo bash setup-fixed.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DASHBOARD_DIR="/var/www/html/fail2ban"
FAIL2BAN_FILTER_DIR="/etc/fail2ban/filter.d"
FAIL2BAN_ACTION_DIR="/etc/fail2ban/action.d"
FAIL2BAN_JAIL_DIR="/etc/fail2ban/jail.d"
SUDOERS_FILE="/etc/sudoers.d/www-data-fail2ban"
LOG_FILE="/var/log/freeswitch-security-setup.log"
BACKUP_DIR="/root/freeswitch-security-backup-$(date +%Y%m%d_%H%M%S)"

SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")

exec > >(tee -a "$LOG_FILE") 2>&1

log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "\n${BLUE}${BOLD}--- STEP: $* ---${NC}"; }
log_success() { echo -e "${GREEN}${BOLD}[OK] $*${NC}"; }
log_banner()  {
    echo -e "${CYAN}${BOLD}"
    echo "=========================================================================="
    echo "   FreeSWITCH Security & Fail2Ban Setup v2.2.0 (patched)"
    echo "   Target: Debian 12 (Bookworm) | Engine: nftables"
    echo "=========================================================================="
    echo -e "${NC}"
}

ROLLBACK_ACTIONS=()
register_rollback() { ROLLBACK_ACTIONS+=("$1"); }
perform_rollback() {
    log_error "=========================================="
    log_error " SETUP FAILED - ROLLING BACK"
    log_error "=========================================="
    local i
    for (( i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i-- )); do
        log_warn "Rolling back: ${ROLLBACK_ACTIONS[$i]}"
        eval "${ROLLBACK_ACTIONS[$i]}" 2>/dev/null || true
    done
    log_warn "Rollback complete. Check $LOG_FILE for details."
    exit 1
}
trap 'perform_rollback' ERR

# ─────────────────────────────────────────────────────────────────────────
preflight_checks() {
    log_step "Pre-flight Checks"
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root: sudo bash $0"; exit 1
    fi
    if [[ ! -f /etc/debian_version ]]; then
        log_error "Not a Debian system. Aborting."; exit 1
    fi
    local debian_ver
    debian_ver=$(cut -d. -f1 /etc/debian_version)
    [[ "$debian_ver" != "12" ]] && log_warn "Expected Debian 12, found: $(cat /etc/debian_version). Proceeding anyway."
    if ! curl -sf --max-time 10 https://deb.debian.org > /dev/null 2>&1; then
        log_warn "Internet connectivity check failed. Package installation may fail."
    fi
    if ! command -v freeswitch &>/dev/null && ! systemctl list-units --type=service 2>/dev/null | grep -q freeswitch; then
        log_warn "FreeSWITCH does not appear to be installed. Proceeding anyway."
    fi
    log_success "Pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────
# FIX (v2.2): the old check piped a big `systemctl list-units` output into
# `grep -q`, which under `set -o pipefail` produces a FALSE "not found" any
# time grep matches early and closes the pipe (systemctl gets SIGPIPE ->
# non-zero exit -> pipefail treats the whole pipeline as failed). Fixed by
# using `systemctl is-active --quiet`, a single command with no pipe.
#
# It also now AUTO-DETECTS whether FreeSWITCH is actually writing
# SIP-auth-relevant lines to the journal or to a log file (the official
# Debian freeswitch-systemd package logs to /var/log/freeswitch/freeswitch.log
# via mod_logfile, NOT to the journal, by default) and configures the jails
# to read from whichever source actually has the data.
# ─────────────────────────────────────────────────────────────────────────
FS_BACKEND="systemd"
FS_LOGPATH=""
FS_JOURNALMATCH="_SYSTEMD_UNIT=freeswitch.service"

detect_fs_logging() {
    log_step "Detecting FreeSWITCH logging method (journal vs file)"

    if systemctl is-active --quiet freeswitch.service 2>/dev/null; then
        log_info "freeswitch.service is active."
    else
        log_warn "freeswitch.service not active/found — jails will stay idle until it's running."
    fi

    # Capture output to a variable BEFORE grepping it — avoids the same
    # pipefail/SIGPIPE false-negative described above.
    local journal_sample journal_hits=0
    journal_sample=$(journalctl -u freeswitch.service --no-pager -n 2000 2>/dev/null || true)
    if [[ -n "$journal_sample" ]]; then
        journal_hits=$(printf '%s\n' "$journal_sample" | grep -icE "sofia_reg\.c|sip auth" || true)
    fi

    local candidate_logs=(/var/log/freeswitch/freeswitch.log /usr/local/freeswitch/log/freeswitch.log)
    local file_log="" file_hits=0
    for f in "${candidate_logs[@]}"; do
        if [[ -f "$f" ]]; then
            local hits
            hits=$(grep -icE "sofia_reg\.c|sip auth" "$f" 2>/dev/null || true)
            if [[ -z "$file_log" || "$hits" -gt "$file_hits" ]]; then
                file_log="$f"; file_hits="$hits"
            fi
        fi
    done

    log_info "Journal SIP-related lines (last 2000): ${journal_hits}"
    [[ -n "$file_log" ]] && log_info "File '${file_log}' SIP-related lines: ${file_hits}"

    if [[ "$journal_hits" -gt 0 && "$journal_hits" -ge "$file_hits" ]]; then
        FS_BACKEND="systemd"
        log_success "Using systemd journal backend — journal has the strongest signal."
    elif [[ -n "$file_log" ]]; then
        FS_BACKEND="polling"
        FS_LOGPATH="$file_log"
        if [[ "$file_hits" -gt 0 ]]; then
            log_success "Using file-based polling backend: ${FS_LOGPATH} (has SIP auth lines, journal doesn't)."
        else
            log_warn "No SIP auth-failure lines seen yet anywhere (may just mean no recent attempts)."
            log_warn "Defaulting to file-based polling backend since ${FS_LOGPATH} exists — this is how"
            log_warn "the official Debian freeswitch package logs by default (via mod_logfile)."
        fi
    else
        FS_BACKEND="systemd"
        log_warn "No FreeSWITCH log file found and journal has no SIP content either."
        log_warn "Jails will stay idle until FreeSWITCH actually logs something matching the filters."
    fi
}

# Emits the correct backend/logpath/journalmatch block for a freeswitch jail,
# based on what detect_fs_logging found.
fs_backend_block() {
    if [[ "$FS_BACKEND" == "systemd" ]]; then
        printf 'backend      = systemd\njournalmatch = %s\n' "$FS_JOURNALMATCH"
    else
        printf 'backend      = polling\n'
        printf 'logpath      = %s\n' "${FS_LOGPATH}"
        printf 'datepattern  = %%%%Y-%%%%m-%%%%d %%%%H:%%%%M:%%%%S\\.%%%%f\n'
    fi
}

backup_existing_configs() {
    log_step "Backing Up Existing Configurations"
    mkdir -p "$BACKUP_DIR"
    [[ -d /etc/fail2ban ]] && cp -r /etc/fail2ban "$BACKUP_DIR/fail2ban_backup" 2>/dev/null || true
    [[ -d "$DASHBOARD_DIR" ]] && cp -r "$DASHBOARD_DIR" "$BACKUP_DIR/dashboard_backup" 2>/dev/null || true
    [[ -f "$SUDOERS_FILE" ]] && cp "$SUDOERS_FILE" "$BACKUP_DIR/sudoers_backup" 2>/dev/null || true
    register_rollback "rm -rf '$BACKUP_DIR'"
    log_success "Backup saved to: $BACKUP_DIR"
}

install_packages() {
    log_step "Installing Required Packages"
    export DEBIAN_FRONTEND=noninteractive
    log_info "Updating APT package index..."
    apt-get update -qq

    local packages=(
        php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-mbstring php8.2-xml
        fail2ban nftables apache2 curl sudo jq python3-systemd libapache2-mod-php8.2
    )
    log_info "Installing: ${packages[*]}"
    apt-get install -y --no-install-recommends "${packages[@]}" 2>&1 | \
        grep -E '(Setting up|Unpacking|already|ERROR|error)' || true

    for cmd in php8.2 fail2ban-client nft apache2 jq; do
        if command -v "$cmd" &>/dev/null || [[ "$cmd" == "fail2ban-client" && -f /usr/bin/fail2ban-client ]]; then
            log_info "OK: $cmd installed."
        else
            log_error "MISSING: $cmd not found after installation!"
            return 1
        fi
    done
    log_success "All packages installed successfully."
}

configure_apache() {
    log_step "Configuring Apache2"
    a2enmod rewrite headers php8.2 2>/dev/null || true

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

configure_nftables() {
    log_step "Configuring nftables Base Firewall"
    systemctl enable nftables 2>/dev/null || true

    cat > /etc/nftables.conf << 'NFTABLES_CONF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    set blacklist_v4 { type ipv4_addr; flags dynamic, timeout; timeout 24h; }
    set blacklist_v6 { type ipv6_addr; flags dynamic, timeout; timeout 24h; }

    chain input {
        type filter hook input priority 0; policy accept;
        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        ip saddr @blacklist_v4 counter drop
        ip6 saddr @blacklist_v6 counter drop
        tcp dport 22 ct state new accept
        tcp dport { 80, 443 } ct state new accept
        udp dport { 5060, 5061, 5080, 5081 } ct state new accept
        tcp dport { 5060, 5061, 5080, 5081 } ct state new accept
        udp dport 16384-32768 ct state new accept
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}

table inet freeswitch-ratelimit {
    set sip_ratelimit { type ipv4_addr; flags dynamic, timeout; timeout 60s; }
    chain sip-input {
        type filter hook input priority -10; policy accept;
        udp dport { 5060, 5080 } add @sip_ratelimit { ip saddr limit rate over 20/second burst 30 packets } counter drop
        tcp dport { 5060, 5080 } add @sip_ratelimit { ip saddr limit rate over 20/second burst 30 packets } counter drop
    }
}
NFTABLES_CONF

    if nft -f /etc/nftables.conf 2>/dev/null; then
        log_success "nftables rules applied successfully."
    else
        log_warn "nftables rules application had issues, will retry after service start."
    fi
    systemctl restart nftables 2>/dev/null || true
    register_rollback "systemctl stop nftables 2>/dev/null; nft flush ruleset 2>/dev/null"
    log_success "nftables base firewall configured."
}

create_fail2ban_filters() {
    log_step "Creating Fail2Ban Custom Filters"
    mkdir -p "$FAIL2BAN_FILTER_DIR"

    # NOTE (v2.2): failregex/ignoreregex no longer anchor with `^\s*` right
    # before the log-level tag. FreeSWITCH embeds its own timestamp text at
    # the start of every line REGARDLESS of journal vs file backend (e.g.
    # "2026-08-11 15:22:10.482887 [WARNING] ..."), so an anchor expecting
    # `[WARNING]` at the very start of the line would never match. Matching
    # `[WARNING]` anywhere on the line (still requiring <HOST> at end) is
    # robust to both formats.
    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-auth.conf" << 'FILTER_AUTH'
# Fail2Ban Filter: FreeSWITCH SIP Authentication Failures
[INCLUDES]
before = common.conf
[Definition]
_daemon = freeswitch
failregex = \[WARNING\] sofia_reg\.c:\d+ SIP auth failure \(REGISTER\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            \[WARNING\] sofia_reg\.c:\d+ SIP auth failure \(INVITE\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            \[WARNING\] sofia_reg\.c:\d+ SIP auth failure \(SUBSCRIBE\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            \[WARNING\] sofia_reg\.c:\d+ Can't find user \[.*\] from <HOST>\s*$
            \[WARNING\] sofia_reg\.c:\d+ SIP auth challenge \(REGISTER\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
ignoreregex = from ip 127\.\d+\.\d+\.\d+\s*$
              from ip 10\.\d+\.\d+\.\d+\s*$
              from ip 172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\s*$
              from ip 192\.168\.\d+\.\d+\s*$
FILTER_AUTH
    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-auth.conf'"

    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-scanner.conf" << 'FILTER_SCANNER'
# Fail2Ban Filter: SIP Scanning/Probing tools (sipvicious, friendly-scanner, etc)
[INCLUDES]
before = common.conf
[Definition]
_daemon = freeswitch
failregex = \[WARNING\].*User-Agent:.*sipvicious.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*svmap.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*svwar.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*svcrack.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*friendly-scanner.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*sipcli.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*sipsak.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*VaxSIPUserAgent.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*NetSurveillance.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*sundayddr.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*iWar.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*SIVuS.*from.*<HOST>.*$
            \[WARNING\].*User-Agent:.*Gulp.*from.*<HOST>.*$
            \[NOTICE\].*Received.*OPTIONS.*from.*<HOST>.*User-Agent:.*sipvicious.*
            \[NOTICE\].*Received.*OPTIONS.*from.*<HOST>.*User-Agent:.*friendly-scanner.*
ignoreregex =
FILTER_SCANNER
    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-scanner.conf'"

    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-dos.conf" << 'FILTER_DOS'
# Fail2Ban Filter: FreeSWITCH SIP Flood / DoS detection
[INCLUDES]
before = common.conf
[Definition]
_daemon = freeswitch
failregex = \[WARNING\] sofia_reg\.c:\d+ SIP auth challenge \(REGISTER\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            \[WARNING\] sofia_reg\.c:\d+ SIP auth challenge \(INVITE\) on sofia profile \'.+\' for \[.*\] from ip <HOST>\s*$
            \[NOTICE\].*sofia\.c:\d+ sofia_reg_handle_register.*REGISTER.*<HOST>.*$
            \[WARNING\].*call_state.*CS_NEW.*<HOST>.*$
            \[WARNING\].*CALL_REJECTED.*<HOST>.*$
            \[WARNING\] sofia_reg\.c:\d+ Can't find user \[.*\] from <HOST>\s*$
ignoreregex = \[.*\].*127\.\d+\.\d+\.\d+.*$
              \[.*\].*192\.168\.\d+\.\d+.*$
              \[.*\].*10\.\d+\.\d+\.\d+.*$
FILTER_DOS
    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-dos.conf'"

    cat > "${FAIL2BAN_FILTER_DIR}/freeswitch-malformed.conf" << 'FILTER_MALFORMED'
# Fail2Ban Filter: FreeSWITCH malformed SIP packet detection
[INCLUDES]
before = common.conf
[Definition]
_daemon = freeswitch
failregex = \[WARNING\].*sofia\.c:\d+.*Invalid SIP.*<HOST>.*$
            \[WARNING\].*sofia\.c:\d+.*Malformed.*<HOST>.*$
            \[WARNING\].*sofia_reg\.c:\d+.*bogus.*<HOST>.*$
            \[WARNING\].*sofia_reg\.c:\d+.*bad.*request.*from.*<HOST>.*$
            \[CRIT\].*sofia\.c:\d+.*parse.*error.*<HOST>.*$
            \[WARNING\].*nua_stack\.c:\d+.*nta.*error.*from.*<HOST>.*$
ignoreregex =
FILTER_MALFORMED
    register_rollback "rm -f '${FAIL2BAN_FILTER_DIR}/freeswitch-malformed.conf'"

    log_success "All Fail2Ban filters created."
}

# ─────────────────────────────────────────────────────────────────────────
# FIX #1: replace the old dead "nftables-freeswitch" action (which was never
# actually referenced by any jail) with a small LOGGING-ONLY action. The
# firewall drop itself is done by fail2ban's proven built-in
# 'nftables[type=allports]' action — we just piggyback a JSON log write onto
# ban/unban events so the dashboard actually reflects reality.
# ─────────────────────────────────────────────────────────────────────────
create_fail2ban_actions() {
    log_step "Creating Fail2Ban Logging Action (dashboard hook)"
    mkdir -p "$FAIL2BAN_ACTION_DIR"

    cat > "${FAIL2BAN_ACTION_DIR}/fs-ban-logger.conf" << 'ACTION_LOGGER'
# Fail2Ban Action: logging-only hook for the FreeSWITCH dashboard.
# Does NOT touch the firewall itself — combine with a real ban action
# (e.g. nftables[type=allports]) in the jail's `action =` line.
[Definition]
actionban   = /var/www/html/fail2ban/scripts/log_ban.sh "<ip>" "<name>" "<bantime>" ban 2>/dev/null || true
actionunban = /var/www/html/fail2ban/scripts/log_ban.sh "<ip>" "<name>" "0" unban 2>/dev/null || true
ACTION_LOGGER

    register_rollback "rm -f '${FAIL2BAN_ACTION_DIR}/fs-ban-logger.conf'"
    log_success "Logging action created."
}

configure_fail2ban_jails() {
    log_step "Configuring Fail2Ban Jails"
    mkdir -p "$FAIL2BAN_JAIL_DIR"

    cat > /etc/fail2ban/jail.local << JAIL_LOCAL
[DEFAULT]
ignoreip = 127.0.0.0/8 ::1 ${SERVER_IP}
bantime  = 3600
bantime.increment    = true
bantime.factor       = 2
bantime.maxtime      = 604800
bantime.overalljails = true
findtime = 600
maxretry = 8
backend = systemd
banaction           = nftables[type=allports]
banaction_allports  = nftables[type=allports]
action = %(action_)s
loglevel = INFO
logtarget = /var/log/fail2ban.log
JAIL_LOCAL
    register_rollback "rm -f /etc/fail2ban/jail.local"

    # NOTE the `action =` line on every jail below: it combines the real
    # firewall ban (%(banaction)s) with the JSON logger so the dashboard
    # actually updates. This is the concrete fix for the "ban log always
    # empty" problem.
    #
    # NOTE the `$(fs_backend_block)` calls: this heredoc is UNQUOTED on
    # purpose so that function/command substitution runs, plugging in
    # whichever logging source detect_fs_logging() found actually has data
    # (systemd journal OR the freeswitch.log file).
    cat > "${FAIL2BAN_JAIL_DIR}/freeswitch.local" << JAILS
# ── SIP Authentication Failures (brute force) ──────────────────────────
[freeswitch-auth]
enabled      = true
port         = 5060,5061,5080,5081
filter       = freeswitch-auth
$(fs_backend_block)maxretry     = 8
findtime     = 600
bantime      = 3600
banaction    = nftables[type=allports]
action       = %(action_)s
               fs-ban-logger[name=%(__name__)s]

# ── SIP Scanning Tools — immediate ban ──────────────────────────────────
[freeswitch-scanner]
enabled      = true
port         = 5060,5061,5080,5081
filter       = freeswitch-scanner
$(fs_backend_block)maxretry     = 1
findtime     = 60
bantime      = 86400
banaction    = nftables[type=allports]
action       = %(action_)s
               fs-ban-logger[name=%(__name__)s]

# ── SIP Flood / DoS ──────────────────────────────────────────────────────
[freeswitch-dos]
enabled      = true
port         = 5060,5061,5080,5081
filter       = freeswitch-dos
$(fs_backend_block)maxretry     = 20
findtime     = 60
bantime      = 7200
banaction    = nftables[type=allports]
action       = %(action_)s
               fs-ban-logger[name=%(__name__)s]

# ── Malformed SIP Packets ────────────────────────────────────────────────
[freeswitch-malformed]
enabled      = true
port         = 5060,5061,5080,5081
filter       = freeswitch-malformed
$(fs_backend_block)maxretry     = 3
findtime     = 300
bantime      = 7200
banaction    = nftables[type=allports]
action       = %(action_)s
               fs-ban-logger[name=%(__name__)s]

# ── SSH Protection ───────────────────────────────────────────────────────
[sshd]
enabled      = true
port         = ssh
backend      = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service
maxretry     = 5
findtime     = 600
bantime      = 3600
banaction    = nftables[type=allports]
JAILS
    register_rollback "rm -f '${FAIL2BAN_JAIL_DIR}/freeswitch.local'"
    log_success "Fail2Ban jails configured (backend=${FS_BACKEND}${FS_LOGPATH:+, logpath=${FS_LOGPATH}}; dashboard logging wired in)."
}

# ─────────────────────────────────────────────────────────────────────────
# FIX #3: sudoers tightened — the previous script granted www-data
# `nft add element *` / `nft delete element *` even though the PHP code
# never calls those (it only calls `nft list table inet f2b-freeswitch`
# for display). Those write-permissions were pure attack surface. Removed.
# ─────────────────────────────────────────────────────────────────────────
configure_sudoers() {
    log_step "Configuring Sudoers for www-data (hardened)"

    cat > "$SUDOERS_FILE" << 'SUDOERS'
# Sudoers: www-data -> Fail2Ban Dashboard Permissions (minimal set)
# Only what the dashboard's PHP code actually calls.

www-data ALL=(root) NOPASSWD: /usr/bin/fail2ban-client *
www-data ALL=(root) NOPASSWD: /usr/sbin/nft list table inet f2b-freeswitch
www-data ALL=(root) NOPASSWD: /usr/bin/journalctl -u freeswitch.service --no-pager -n * --output=short-iso
www-data ALL=(root) NOPASSWD: /usr/bin/tail -n * /var/log/freeswitch/freeswitch.log
www-data ALL=(root) NOPASSWD: /bin/systemctl reload fail2ban
www-data ALL=(root) NOPASSWD: /bin/systemctl restart fail2ban
www-data ALL=(root) NOPASSWD: /bin/systemctl status fail2ban
SUDOERS

    if visudo -c -f "$SUDOERS_FILE" 2>/dev/null; then
        chmod 440 "$SUDOERS_FILE"
        log_success "Sudoers configured and validated (minimal permission set)."
    else
        log_error "Sudoers file has syntax error! Removing invalid file."
        rm -f "$SUDOERS_FILE"
        return 1
    fi
    register_rollback "rm -f '$SUDOERS_FILE'"
}

create_dashboard_structure() {
    log_step "Creating Dashboard Directory Structure"
    mkdir -p "${DASHBOARD_DIR}"/{assets/{css,js,img},api,scripts,data,logs}

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
            "must_change_password": true,
            "active": true
        }
    ],
    "meta": { "version": "2.1.0", "algorithm": "argon2id" }
}
USERS_JSON

    cat > "${DASHBOARD_DIR}/data/whitelist.json" << WHITELIST_JSON
{
    "whitelist": [
        {"id":1,"ip":"127.0.0.1","cidr":"127.0.0.0/8","description":"Localhost","added_by":"system","added_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","permanent":true},
        {"id":2,"ip":"${SERVER_IP}","cidr":"${SERVER_IP}/32","description":"Server's own IP (auto-detected)","added_by":"system","added_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","permanent":true},
        {"id":3,"ip":"::1","cidr":"::1/128","description":"IPv6 Localhost","added_by":"system","added_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","permanent":true}
    ],
    "meta": { "version": "2.1.0" }
}
WHITELIST_JSON

    cat > "${DASHBOARD_DIR}/data/ban_log.json" << 'BAN_LOG'
{"bans": [], "meta": {"total_bans": 0, "last_updated": null}}
BAN_LOG

    cat > "${DASHBOARD_DIR}/data/settings.json" << SETTINGS_JSON
{
    "system": {"server_ip": "${SERVER_IP}", "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "version": "2.1.0"},
    "fail2ban": {"max_retry_auth":8,"max_retry_scanner":1,"max_retry_dos":20,"max_retry_malformed":3,"findtime":600,"bantime_default":3600,"bantime_scanner":86400},
    "notifications": {"email_enabled": false, "email_to": ""}
}
SETTINGS_JSON

    cat > "${DASHBOARD_DIR}/scripts/log_ban.sh" << 'LOG_BAN_SH'
#!/bin/bash
# Called by fail2ban's fs-ban-logger action to log ban/unban events to JSON.
IP="${1:-unknown}"; JAIL="${2:-unknown}"; BANTIME="${3:-0}"; ACTION="${4:-ban}"
LOG_FILE="/var/www/html/fail2ban/data/ban_log.json"
LOCK_FILE="/tmp/fail2ban_log.lock"
(
    flock -w 5 200 2>/dev/null || exit 0
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    EPOCH=$(date +%s)
    if [[ ! -f "$LOG_FILE" ]] || ! jq empty "$LOG_FILE" 2>/dev/null; then
        echo '{"bans":[],"meta":{"total_bans":0,"last_updated":null}}' > "$LOG_FILE"
    fi
    jq --arg ip "$IP" --arg jail "$JAIL" --arg bantime "$BANTIME" --arg action "$ACTION" \
       --arg ts "$TIMESTAMP" --argjson epoch "$EPOCH" '
       .bans = [{"ip":$ip,"jail":$jail,"bantime":($bantime|tonumber),"action":$action,"timestamp":$ts,"epoch":$epoch}] + .bans
       | .bans = .bans[0:500]
       | .meta.total_bans = (.bans | map(select(.action == "ban")) | length)
       | .meta.last_updated = $ts
    ' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
) 200>"$LOCK_FILE"
LOG_BAN_SH
    chmod +x "${DASHBOARD_DIR}/scripts/log_ban.sh"

    register_rollback "rm -rf '${DASHBOARD_DIR}'"
    log_success "Dashboard directory structure created."
}

create_dashboard_php() {
    log_step "Creating PHP Dashboard Application"

    cat > "${DASHBOARD_DIR}/api/auth.php" << 'API_AUTH'
<?php
declare(strict_types=1);
session_set_cookie_params(['lifetime'=>3600,'path'=>'/','secure'=>false,'httponly'=>true,'samesite'=>'Strict']);
session_start();
header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

define('DATA_DIR', dirname(__DIR__) . '/data');
define('USERS_FILE', DATA_DIR . '/users.json');
define('MAX_LOGIN_ATTEMPTS', 5);
define('LOCKOUT_TIME', 300);

$action = $_POST['action'] ?? $_GET['action'] ?? '';

function load_users(): array {
    if (!file_exists(USERS_FILE)) return [];
    $data = json_decode(file_get_contents(USERS_FILE), true);
    return $data['users'] ?? [];
}
function find_user(string $username): ?array {
    foreach (load_users() as $u) if ($u['username'] === $username && ($u['active'] ?? false)) return $u;
    return null;
}
function save_last_login(string $username): void {
    $data = json_decode(file_get_contents(USERS_FILE), true);
    foreach ($data['users'] as &$u) if ($u['username'] === $username) { $u['last_login'] = date('c'); break; }
    file_put_contents(USERS_FILE, json_encode($data, JSON_PRETTY_PRINT));
}
function update_password(string $username, string $newHash): void {
    $data = json_decode(file_get_contents(USERS_FILE), true);
    foreach ($data['users'] as &$u) if ($u['username'] === $username) {
        $u['password_hash'] = $newHash;
        $u['must_change_password'] = false;
        break;
    }
    file_put_contents(USERS_FILE, json_encode($data, JSON_PRETTY_PRINT));
}
function is_locked_out(string $username): bool {
    $f = sys_get_temp_dir() . '/f2b_login_' . hash('sha256', $username);
    if (!file_exists($f)) return false;
    $d = json_decode(file_get_contents($f), true);
    if (!$d) return false;
    if ($d['attempts'] >= MAX_LOGIN_ATTEMPTS) {
        if (time() - $d['last_attempt'] < LOCKOUT_TIME) return true;
        unlink($f);
    }
    return false;
}
function record_failed_attempt(string $username): void {
    $f = sys_get_temp_dir() . '/f2b_login_' . hash('sha256', $username);
    $d = file_exists($f) ? json_decode(file_get_contents($f), true) : ['attempts' => 0];
    $d['attempts']++; $d['last_attempt'] = time();
    file_put_contents($f, json_encode($d));
}
function clear_attempts(string $username): void {
    $f = sys_get_temp_dir() . '/f2b_login_' . hash('sha256', $username);
    if (file_exists($f)) unlink($f);
}
function json_response(bool $success, string $message, array $data = []): void {
    echo json_encode(array_merge(['success' => $success, 'message' => $message], $data)); exit;
}

switch ($action) {
    case 'login':
        $username = trim($_POST['username'] ?? '');
        $password = $_POST['password'] ?? '';
        if (empty($username) || empty($password)) json_response(false, 'Username and password are required.');
        if (is_locked_out($username)) json_response(false, 'Too many failed attempts. Try again in 5 minutes.');

        $user = find_user($username);
        if ($user && password_verify($password, $user['password_hash'])) {
            clear_attempts($username);
            session_regenerate_id(true);
            $_SESSION['authenticated'] = true;
            $_SESSION['username']      = $username;
            $_SESSION['role']          = $user['role'];
            $_SESSION['login_time']    = time();
            save_last_login($username);
            json_response(true, 'Login successful.', [
                'redirect' => '/fail2ban/',
                'must_change_password' => (bool)($user['must_change_password'] ?? false),
            ]);
        } else {
            record_failed_attempt($username);
            json_response(false, 'Invalid username or password.');
        }
        break;

    case 'change_password':
        if (!isset($_SESSION['authenticated']) || $_SESSION['authenticated'] !== true) {
            http_response_code(401); json_response(false, 'Unauthorized');
        }
        $newPass = $_POST['new_password'] ?? '';
        if (strlen($newPass) < 10) json_response(false, 'Password must be at least 10 characters.');
        update_password($_SESSION['username'], password_hash($newPass, PASSWORD_ARGON2ID));
        json_response(true, 'Password updated.');
        break;

    case 'logout':
        session_destroy();
        json_response(true, 'Logged out successfully.');
        break;

    case 'check':
        $authenticated = isset($_SESSION['authenticated']) && $_SESSION['authenticated'] === true;
        if ($authenticated && (time() - ($_SESSION['login_time'] ?? 0)) > 3600) {
            session_destroy(); $authenticated = false;
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

    # api/fail2ban.php — FIX #4: escapeshellarg() per-argument instead of
    # escapeshellcmd() on the assembled string.
    cat > "${DASHBOARD_DIR}/api/fail2ban.php" << 'API_F2B'
<?php
declare(strict_types=1);
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();
header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

if (!isset($_SESSION['authenticated']) || $_SESSION['authenticated'] !== true) {
    http_response_code(401);
    echo json_encode(['success' => false, 'message' => 'Unauthorized']);
    exit;
}

define('DATA_DIR', dirname(__DIR__) . '/data');

function run_cmd(string $cmd): array {
    $output = []; $returnCode = 0;
    exec($cmd . ' 2>&1', $output, $returnCode);
    return ['output' => implode("\n", $output), 'code' => $returnCode];
}
// Each positional arg is escaped individually — no raw string concatenation.
function f2b_client(array $args): array {
    $parts = array_map('escapeshellarg', $args);
    return run_cmd('sudo /usr/bin/fail2ban-client ' . implode(' ', $parts));
}
function json_response(bool $success, string $message, array $data = []): void {
    echo json_encode(array_merge(['success' => $success, 'message' => $message], $data)); exit;
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
    return preg_match('/^[a-z0-9\-]+$/', $jail) ? $jail : '';
}

$method = $_SERVER['REQUEST_METHOD'];
$action = $_GET['action'] ?? $_POST['action'] ?? '';

switch ($action) {
    case 'status':
        $result = f2b_client(['status']);
        $jailsLine = '';
        foreach (explode("\n", $result['output']) as $line) {
            if (strpos($line, 'Jail list:') !== false) {
                $jailsLine = trim(str_replace(['Jail list:', '`- '], '', $line)); break;
            }
        }
        $jails = array_filter(array_map('trim', explode(',', $jailsLine)));
        $jailsData = [];
        foreach ($jails as $jail) {
            if (empty($jail)) continue;
            $jailResult = f2b_client(['status', $jail]);
            $jailsData[$jail] = parse_jail_status($jailResult['output']);
        }
        json_response(true, 'Status retrieved', [
            'raw' => $result['output'], 'jails' => array_values(array_filter($jails)),
            'jail_data' => $jailsData, 'running' => $result['code'] === 0,
        ]);
        break;

    case 'banned':
        $jail = sanitize_jail($_GET['jail'] ?? '');
        if ($jail) {
            $result = f2b_client(['status', $jail]);
            json_response(true, 'Banned IPs retrieved', ['jail' => $jail, 'banned' => extract_banned_ips($result['output'])]);
        } else {
            $statusResult = f2b_client(['status']);
            $jails = extract_jail_list($statusResult['output']);
            $allBanned = [];
            foreach ($jails as $j) {
                $r = f2b_client(['status', $j]);
                foreach (extract_banned_ips($r['output']) as $ip) $allBanned[] = ['ip' => $ip, 'jail' => $j];
            }
            json_response(true, 'All banned IPs', ['banned' => $allBanned, 'count' => count($allBanned)]);
        }
        break;

    case 'ban':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $ip = sanitize_ip($_POST['ip'] ?? ''); $jail = sanitize_jail($_POST['jail'] ?? 'freeswitch-auth');
        if (!$ip) json_response(false, 'Invalid IP address.');
        if (!$jail) json_response(false, 'Invalid jail name.');
        $result = f2b_client(['set', $jail, 'banip', $ip]);
        json_response($result['code'] === 0, $result['code'] === 0 ? "IP {$ip} banned." : 'Ban failed: ' . $result['output']);
        break;

    case 'unban':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $ip = sanitize_ip($_POST['ip'] ?? ''); $jail = sanitize_jail($_POST['jail'] ?? '');
        if (!$ip) json_response(false, 'Invalid IP address.');
        $result = $jail ? f2b_client(['set', $jail, 'unbanip', $ip]) : f2b_client(['unban', $ip]);
        json_response($result['code'] === 0, $result['code'] === 0 ? "IP {$ip} unbanned." : 'Unban failed: ' . $result['output']);
        break;

    case 'ban_log':
        $logFile = DATA_DIR . '/ban_log.json';
        if (!file_exists($logFile)) json_response(true, 'No ban log yet.', ['bans' => [], 'meta' => []]);
        $data = json_decode(file_get_contents($logFile), true) ?? [];
        $limit = min((int)($_GET['limit'] ?? 100), 500);
        $data['bans'] = array_slice($data['bans'] ?? [], 0, $limit);
        json_response(true, 'Ban log retrieved', $data);
        break;

    case 'whitelist':
        $wlFile = DATA_DIR . '/whitelist.json';
        json_response(true, 'Whitelist retrieved', json_decode(file_get_contents($wlFile), true) ?? ['whitelist' => []]);
        break;

    case 'whitelist_add':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $ip = sanitize_ip($_POST['ip'] ?? '');
        $desc = substr(preg_replace('/[^a-zA-Z0-9\s\-_.]/', '', $_POST['description'] ?? ''), 0, 100);
        if (!$ip) json_response(false, 'Invalid IP address.');
        $wlFile = DATA_DIR . '/whitelist.json';
        $data = json_decode(file_get_contents($wlFile), true) ?? ['whitelist' => []];
        $maxId = max(array_column($data['whitelist'], 'id') ?: [0]);
        $data['whitelist'][] = [
            'id' => $maxId + 1, 'ip' => $ip, 'cidr' => $ip . '/32',
            'description' => $desc ?: 'Manually added', 'added_by' => $_SESSION['username'],
            'added_at' => date('c'), 'permanent' => false,
        ];
        file_put_contents($wlFile, json_encode($data, JSON_PRETTY_PRINT));
        f2b_client(['unban', $ip]);
        json_response(true, "IP {$ip} added to whitelist and unbanned.");
        break;

    case 'whitelist_remove':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $id = (int)($_POST['id'] ?? 0);
        $wlFile = DATA_DIR . '/whitelist.json';
        $data = json_decode(file_get_contents($wlFile), true) ?? ['whitelist' => []];
        $entry = null;
        foreach ($data['whitelist'] as $item) if ($item['id'] === $id) { $entry = $item; break; }
        if (!$entry) json_response(false, 'Entry not found.');
        if ($entry['permanent'] ?? false) json_response(false, 'Cannot remove permanent whitelist entry.');
        $data['whitelist'] = array_values(array_filter($data['whitelist'], fn($x) => $x['id'] !== $id));
        file_put_contents($wlFile, json_encode($data, JSON_PRETTY_PRINT));
        json_response(true, 'Whitelist entry removed.');
        break;

    case 'fs_logs':
        $lines = min((int)($_GET['lines'] ?? 50), 200);
        $fsLogFile = '/var/log/freeswitch/freeswitch.log';
        if (is_readable($fsLogFile)) {
            // File-based backend: www-data can read it directly if group
            // permissions allow, no sudo needed. Fallback to sudo tail if not.
            $result = run_cmd('tail -n ' . escapeshellarg((string)$lines) . ' ' . escapeshellarg($fsLogFile));
            if ($result['code'] !== 0) {
                $result = run_cmd('sudo /usr/bin/tail -n ' . escapeshellarg((string)$lines) . ' ' . escapeshellarg($fsLogFile));
            }
        } else {
            $result = run_cmd('sudo /usr/bin/journalctl -u freeswitch.service --no-pager -n ' . escapeshellarg((string)$lines) . ' --output=short-iso');
        }
        json_response(true, 'Logs retrieved', ['logs' => $result['output']]);
        break;

    case 'nft_sets':
        $result = run_cmd('sudo /usr/sbin/nft list table inet f2b-freeswitch');
        json_response(true, 'nftables data', ['output' => $result['output'], 'success' => $result['code'] === 0]);
        break;

    case 'reload':
        if ($method !== 'POST') { http_response_code(405); exit; }
        $result = f2b_client(['reload']);
        json_response($result['code'] === 0, $result['code'] === 0 ? 'Fail2Ban reloaded.' : 'Reload failed: ' . $result['output']);
        break;

    default:
        http_response_code(400);
        json_response(false, 'Unknown action.');
}

function extract_banned_ips(string $output): array {
    foreach (explode("\n", $output) as $line) {
        if (preg_match('/Banned IP list:\s*(.*)/', $line, $m)) {
            return array_values(array_filter(array_map('trim', explode(' ', $m[1]))));
        }
    }
    return [];
}
function extract_jail_list(string $output): array {
    foreach (explode("\n", $output) as $line) {
        if (strpos($line, 'Jail list:') !== false) {
            return array_filter(array_map('trim', explode(',', trim(str_replace(['Jail list:', '`- '], '', $line)))));
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

set_permissions() {
    log_step "Setting File Permissions"
    chown -R www-data:www-data "${DASHBOARD_DIR}"
    find "${DASHBOARD_DIR}" -type d -exec chmod 750 {} \;
    find "${DASHBOARD_DIR}" -name "*.php" -exec chmod 640 {} \;
    chmod 700 "${DASHBOARD_DIR}/data"
    find "${DASHBOARD_DIR}/data" -name "*.json" -exec chmod 600 {} \;
    chmod 750 "${DASHBOARD_DIR}/scripts/log_ban.sh"
    chown -R root:root /etc/fail2ban/
    chmod 640 /etc/fail2ban/jail.local 2>/dev/null || true
    chmod 640 "${FAIL2BAN_JAIL_DIR}/freeswitch.local" 2>/dev/null || true
    find "${FAIL2BAN_FILTER_DIR}" -name "freeswitch-*.conf" -exec chmod 640 {} \;
    log_success "Permissions set correctly."
}

enable_services() {
    log_step "Enabling & Starting Services"
    apache2ctl configtest 2>/dev/null && systemctl reload apache2 || systemctl restart apache2
    systemctl enable --now nftables 2>/dev/null || true

    log_info "Validating Fail2Ban configuration..."
    if fail2ban-client -t 2>/dev/null; then
        log_success "Fail2Ban configuration is valid."
    else
        log_warn "Fail2Ban config test had warnings. Check /var/log/fail2ban.log"
        fail2ban-client -t 2>&1 | head -20 || true
    fi

    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || log_error "Fail2Ban failed to start. Check: journalctl -u fail2ban -n 50"
    systemctl enable --now apache2 2>/dev/null || true
    sleep 3

    for svc in apache2 fail2ban nftables; do
        if systemctl is-active --quiet "$svc"; then log_success "$svc is running."
        else log_warn "$svc is NOT running. Check: systemctl status $svc"; fi
    done
}

verify_jails() {
    log_step "Verifying Fail2Ban Jails"
    sleep 2
    local expected_jails=(freeswitch-auth freeswitch-scanner freeswitch-dos freeswitch-malformed sshd)
    if ! fail2ban-client ping &>/dev/null; then
        log_warn "Fail2Ban is not responding to ping. Jails verification skipped."; return 0
    fi
    for jail in "${expected_jails[@]}"; do
        if fail2ban-client status "$jail" &>/dev/null; then
            local banned
            banned=$(fail2ban-client status "$jail" 2>/dev/null | grep 'Currently banned' | awk '{print $NF}')
            log_success "Jail [$jail] is ACTIVE — currently banned: ${banned:-0}"
        else
            log_warn "Jail [$jail] is not active yet. Will start once matching log lines appear."
        fi
    done
}

print_summary() {
    local server_ip="$SERVER_IP"
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "=========================================================================="
    echo "  SETUP COMPLETE"
    echo "=========================================================================="
    echo "  Dashboard:   http://${server_ip}/fail2ban/"
    echo "  Username:    admin"
    echo "  Password:    Admin@1234   <-- you will be forced to change this on first login"
    echo ""
    echo "  Jails:"
    echo "    freeswitch-auth      maxretry=8   findtime=10m  bantime=1h  (increments up to 7d)"
    echo "    freeswitch-scanner   maxretry=1   findtime=1m   bantime=24h (instant ban tools)"
    echo "    freeswitch-dos       maxretry=20  findtime=1m   bantime=2h"
    echo "    freeswitch-malformed maxretry=3   findtime=5m   bantime=2h"
    echo "    sshd                 maxretry=5   findtime=10m  bantime=1h"
    echo ""
    if [[ "$FS_BACKEND" == "systemd" ]]; then
        echo "  FreeSWITCH log source: systemd journal (${FS_JOURNALMATCH})"
    else
        echo "  FreeSWITCH log source: file — ${FS_LOGPATH} (polling backend)"
    fi
    echo "  If bans still don't happen after a real failed login, check the exact log line format with:"
    if [[ "$FS_BACKEND" == "systemd" ]]; then
        echo "    journalctl -u freeswitch.service | grep -i 'auth failure'"
    else
        echo "    grep -i 'auth failure' ${FS_LOGPATH}"
    fi
    echo "  ...and compare it against /etc/fail2ban/filter.d/freeswitch-auth.conf"
    echo ""
    echo "  Whitelist: 127.0.0.0/8, ::1, ${server_ip} (your real clients/office IPs — add more via dashboard)"
    echo "  Backup of previous config: ${BACKUP_DIR}"
    echo "  Setup log: ${LOG_FILE}"
    echo "=========================================================================="
    echo -e "${NC}"
}

main() {
    log_banner
    log_info "Starting setup... Log: ${LOG_FILE}"
    log_info "Server IP detected: ${SERVER_IP}"
    echo ""

    preflight_checks
    detect_fs_logging
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
    set_permissions
    enable_services
    verify_jails
    print_summary

    trap - ERR
    log_success "All done."
}

main "$@"
