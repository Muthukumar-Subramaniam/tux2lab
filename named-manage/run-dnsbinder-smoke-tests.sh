#!/usr/bin/env bash
#-----------------------------------------------------------------------#
# dnsbinder comprehensive smoke test suite                              #
# Run after any change to dnsbinder.sh to verify nothing is broken.     #
# Requires: running DNS (--setup already done), sudo/root access.       #
# Leaves zones in clean state on success.                               #
#-----------------------------------------------------------------------#

set -uo pipefail

DNSBINDER="$(dirname "$0")/dnsbinder.sh"
FW_ZONE="/tux2lab-data/named/dnsbinder-managed-zone-files"
DOMAIN=""
PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

assert() {
    local desc="$1"
    local result="$2"
    local expected="$3"
    ((TOTAL++))
    if [[ "$result" == "$expected" ]]; then
        ((PASS++))
        printf "  ${GREEN}✓${NC} %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}✗${NC} %s\n" "$desc"
        printf "    Expected: %s\n" "$expected"
        printf "    Got:      %s\n" "$result"
    fi
}

assert_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    ((TOTAL++))
    if echo "$output" | grep -qE "$pattern"; then
        ((PASS++))
        printf "  ${GREEN}✓${NC} %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}✗${NC} %s\n" "$desc"
        printf "    Pattern not found: %s\n" "$pattern"
        printf "    Output: %s\n" "$(echo "$output" | head -3)"
    fi
}

assert_not_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    ((TOTAL++))
    if ! echo "$output" | grep -qE "$pattern"; then
        ((PASS++))
        printf "  ${GREEN}✓${NC} %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}✗${NC} %s\n" "$desc"
        printf "    Pattern should NOT be present: %s\n" "$pattern"
    fi
}

assert_exit_code() {
    local desc="$1"
    local actual="$2"
    local expected="$3"
    ((TOTAL++))
    if [[ "$actual" -eq "$expected" ]]; then
        ((PASS++))
        printf "  ${GREEN}✓${NC} %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}✗${NC} %s\n" "$desc"
        printf "    Expected exit code: %s, Got: %s\n" "$expected" "$actual"
    fi
}

section() {
    printf "\n${CYAN}━━━ %s ━━━${NC}\n" "$1"
}

cleanup_record() {
    sudo "$DNSBINDER" -d "$1" -y &>/dev/null || true
}

# --- Pre-flight checks ---
if [[ "${UID}" -ne 0 ]]; then
    echo "Must run as root (sudo)."
    exit 1
fi

if [[ "${1:-}" != "--wipe-zone-files" ]]; then
    echo "WARNING: This test suite WIPES all DNS zone files and recreates them from scratch."
    echo "Usage: $0 --wipe-zone-files"
    echo ""
    echo "Only run this on a lab where wiping DNS is acceptable."
    exit 1
fi

# Read domain from lab_environment.json for --setup test
SETUP_DOMAIN=$(jq -r '.lab.domain' /tux2lab-data/lab-config/lab_environment.json 2>/dev/null || true)
if [[ -z "$SETUP_DOMAIN" || "$SETUP_DOMAIN" == "null" ]]; then
    echo "Cannot determine domain from lab_environment.json."
    exit 1
fi

printf "${YELLOW}dnsbinder smoke test suite${NC}\n"
printf "Domain: ${SETUP_DOMAIN}\n\n"

# ═══════════════════════════════════════════════════════════════════════
section "0. SETUP (--setup)"
# ═══════════════════════════════════════════════════════════════════════

# Wipe existing config for a clean --setup test
rm -rf /tux2lab-data/named/dnsbinder-managed-zone-files/
rm -f /tux2lab-data/named/named.conf /tux2lab-data/named/named.conf_bkp_by_dnsbinder

out=$(sudo "$DNSBINDER" --setup "$SETUP_DOMAIN" 2>&1)
assert_contains "--setup completes successfully" "$out" "configured successfully"
assert_contains "--setup shows server info" "$out" "tux2lab-engine"

# Verify named.conf created
assert "--setup creates named.conf" "$(test -f /tux2lab-data/named/named.conf && echo yes)" "yes"

# Verify zone files created
DOMAIN=$(awk '/zones-are-managed-by-dnsbinder/ {print $2}' /tux2lab-data/named/named.conf 2>/dev/null || true)
FW_ZONE_FILE="${FW_ZONE}/${DOMAIN}-forward.db"
IPV6_ZONE_FILE="${FW_ZONE}/${DOMAIN}-ipv6-reverse.db"

assert "--setup creates forward zone" "$(test -f "$FW_ZONE_FILE" && echo yes)" "yes"
assert "--setup creates IPv6 reverse zone" "$(test -f "$IPV6_ZONE_FILE" && echo yes)" "yes"

# Verify server A record
assert "--setup adds server A record" "$(grep -c '^tux2lab-engine .*IN A ' "$FW_ZONE_FILE")" "1"

# Verify server AAAA record
assert "--setup adds server AAAA record" "$(grep -c '^tux2lab-engine .*IN AAAA' "$FW_ZONE_FILE")" "1"

# Verify gateway CNAME
assert "--setup adds gateway CNAME" "$(grep -c '^gateway .*IN CNAME' "$FW_ZONE_FILE")" "1"

# Verify IPv6 PTR for server
assert "--setup adds server IPv6 PTR" "$(grep -c 'IN PTR tux2lab-engine' "$IPV6_ZONE_FILE")" "1"

# Verify IPv4 reverse zone exists
ptr_zone=$(find "$FW_ZONE" -name "10.28.28.*-reverse.db" 2>/dev/null | head -1)
assert "--setup creates IPv4 reverse zone" "$(test -n "$ptr_zone" && echo yes)" "yes"

# Verify server PTR in IPv4 reverse
assert "--setup adds server IPv4 PTR" "$(grep -c 'IN PTR tux2lab-engine' "$ptr_zone")" "1"

# Verify named is running and can resolve
out=$(sudo "$DNSBINDER" -q tux2lab-engine 2>&1)
assert_contains "--setup: DNS resolves server" "$out" "A     :"

printf "\n"

# Clean up any leftover smoke-* records from a previous failed run
remaining=$(grep "^smoke-" "$FW_ZONE_FILE" 2>/dev/null | awk '{print $1}' | sort -u || true)
if [[ -n "$remaining" ]]; then
    echo "$remaining" > /tmp/smoke-pre-cleanup.txt
    sudo "$DNSBINDER" -dfy /tmp/smoke-pre-cleanup.txt --inline &>/dev/null || true
    rm -f /tmp/smoke-pre-cleanup.txt
fi

# ═══════════════════════════════════════════════════════════════════════
section "1. CREATE DUAL-STACK (-c)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" -c smoke-dual -y 2>&1)
assert_contains "-c creates A record" "$out" "Created host record"
assert "A record in zone" "$(grep -c '^smoke-dual .*IN A ' "$FW_ZONE_FILE")" "1"
assert "AAAA record in zone" "$(grep -c '^smoke-dual .*IN AAAA' "$FW_ZONE_FILE")" "1"

# IPv6 offset check (first host after server = offset 2 = ::2)
ipv6=$(awk '/^smoke-dual .*IN AAAA/ {print $NF}' "$FW_ZONE_FILE")
assert "IPv6 offset correct (::2)" "$ipv6" "fd28:2808:2020:3000::2"

# IPv6 PTR exists
assert "IPv6 PTR record exists" "$(grep -c 'smoke-dual' "$IPV6_ZONE_FILE")" "1"

# Duplicate error
out=$(sudo "$DNSBINDER" -c smoke-dual -y 2>&1)
assert_contains "-c duplicate detected" "$out" "already exists"

# ═══════════════════════════════════════════════════════════════════════
section "2. CREATE IPv4-ONLY (-c4)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" -c4 smoke-v4only -y 2>&1)
assert_contains "-c4 creates record" "$out" "Created IPv4-only"
assert "A record exists" "$(grep -c '^smoke-v4only .*IN A ' "$FW_ZONE_FILE")" "1"
assert "No AAAA record" "$(grep -c '^smoke-v4only .*IN AAAA' "$FW_ZONE_FILE")" "0"
assert "No IPv6 PTR" "$(grep -c 'smoke-v4only' "$IPV6_ZONE_FILE")" "0"

# Duplicate
out=$(sudo "$DNSBINDER" -c4 smoke-v4only -y 2>&1)
assert_contains "-c4 duplicate detected" "$out" "already exists"

# ═══════════════════════════════════════════════════════════════════════
section "3. CREATE IPv6-ONLY (-c6)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" -c6 smoke-v6only -y 2>&1)
assert_contains "-c6 creates record" "$out" "Created IPv6-only"
assert "No A record" "$(grep -c '^smoke-v6only .*IN A ' "$FW_ZONE_FILE")" "0"
assert "AAAA record exists" "$(grep -c '^smoke-v6only .*IN AAAA' "$FW_ZONE_FILE")" "1"

# Offset >= 1023 (0x3ff)
ipv6=$(awk '/^smoke-v6only .*IN AAAA/ {print $NF}' "$FW_ZONE_FILE")
assert "IPv6 offset >= 0x3ff" "$ipv6" "fd28:2808:2020:3000::3ff"

# IPv6 PTR exists
assert "IPv6 PTR record exists" "$(grep -c 'smoke-v6only' "$IPV6_ZONE_FILE")" "1"

# Duplicate
out=$(sudo "$DNSBINDER" -c6 smoke-v6only -y 2>&1)
assert_contains "-c6 duplicate detected" "$out" "already exists"

# ═══════════════════════════════════════════════════════════════════════
section "4. CREATE WITH SPECIFIC IP (-ci)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" -ci smoke-ci 10.28.29.50 -y 2>&1)
assert_contains "-ci creates record" "$out" "Created host record"
ip=$(awk '/^smoke-ci .*IN A / {print $NF}' "$FW_ZONE_FILE")
assert "Specific IP assigned" "$ip" "10.28.29.50"

# Offset = (29-28)*256+50 = 306 = 0x132
ipv6=$(awk '/^smoke-ci .*IN AAAA/ {print $NF}' "$FW_ZONE_FILE")
assert "IPv6 offset matches IPv4 (0x132)" "$ipv6" "fd28:2808:2020:3000::132"

# Out-of-range IP
out=$(sudo "$DNSBINDER" -ci smoke-oor 192.168.1.1 -y 2>&1); rc=$?
assert_contains "-ci rejects out-of-range IP" "$out" "doesn't reside within"
assert_exit_code "-ci out-of-range exits non-zero" "$rc" "7"

# Invalid IP format
out=$(sudo "$DNSBINDER" -ci smoke-badip 999.1.2.3 -y 2>&1); rc=$?
assert_contains "-ci rejects invalid IP format" "$out" "Invalid input"

# Duplicate host with -ci
out=$(sudo "$DNSBINDER" -ci smoke-ci 10.28.29.51 -y 2>&1)
assert_contains "-ci duplicate detected" "$out" "already exists"

# ═══════════════════════════════════════════════════════════════════════
section "5. CREATE CNAME (-cc)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" -cc smoke-alias smoke-dual -y 2>&1)
assert_contains "-cc creates CNAME" "$out" "Created CNAME"
assert "CNAME in zone" "$(grep -c '^smoke-alias .*IN CNAME' "$FW_ZONE_FILE")" "1"

# Duplicate
out=$(sudo "$DNSBINDER" -cc smoke-alias smoke-dual -y 2>&1)
assert_contains "-cc duplicate detected" "$out" "already exists"

# Nonexistent target
out=$(sudo "$DNSBINDER" -cc smoke-bad nonexistent-host -y 2>&1)
assert_contains "-cc rejects nonexistent target" "$out" "doesn't exist"

# ═══════════════════════════════════════════════════════════════════════
section "6. TTL OPERATIONS (--ttl, --update-ttl)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" -c smoke-ttl --ttl 120 -y 2>&1)
assert_contains "--ttl creates with custom TTL" "$out" "TTL : 120 seconds"
assert "TTL in zone A record" "$(awk '/^smoke-ttl .*IN A / {print $2}' "$FW_ZONE_FILE")" "120"
assert "TTL in zone AAAA record" "$(awk '/^smoke-ttl .*IN AAAA/ {print $2}' "$FW_ZONE_FILE")" "120"

# Update TTL
out=$(sudo "$DNSBINDER" --update-ttl smoke-ttl 600 2>&1)
assert_contains "--update-ttl succeeds" "$out" "TTL updated to 600"
assert "A TTL updated" "$(awk '/^smoke-ttl .*IN A / {print $2}' "$FW_ZONE_FILE")" "600"
assert "AAAA TTL updated" "$(awk '/^smoke-ttl .*IN AAAA/ {print $2}' "$FW_ZONE_FILE")" "600"

# Error: nonexistent host
out=$(sudo "$DNSBINDER" --update-ttl nonexistent 600 2>&1); rc=$?
assert_contains "--update-ttl rejects nonexistent" "$out" "No record found"

# Error: invalid TTL
out=$(sudo "$DNSBINDER" --update-ttl smoke-ttl abc 2>&1); rc=$?
assert_contains "--update-ttl rejects non-numeric" "$out" "must be a positive integer"

cleanup_record smoke-ttl

# ═══════════════════════════════════════════════════════════════════════
section "7. RENAME (-r)"
# ═══════════════════════════════════════════════════════════════════════

# Create with TTL to test TTL preservation
sudo "$DNSBINDER" -c smoke-rename --ttl 200 -y &>/dev/null
out=$(sudo "$DNSBINDER" -r smoke-rename smoke-renamed -y 2>&1)
assert_contains "-r renames successfully" "$out" "Renamed host"
assert "Old name gone" "$(grep -c '^smoke-rename ' "$FW_ZONE_FILE")" "0"
assert "New name exists (A)" "$(grep -c '^smoke-renamed .*IN A ' "$FW_ZONE_FILE")" "1"
assert "New name exists (AAAA)" "$(grep -c '^smoke-renamed .*IN AAAA' "$FW_ZONE_FILE")" "1"

# TTL preserved
assert "TTL preserved on A" "$(awk '/^smoke-renamed .*IN A / {print $2}' "$FW_ZONE_FILE")" "200"
assert "TTL preserved on AAAA" "$(awk '/^smoke-renamed .*IN AAAA/ {print $2}' "$FW_ZONE_FILE")" "200"

# IPv6 PTR updated
assert "IPv6 PTR points to new name" "$(grep -c 'smoke-renamed' "$IPV6_ZONE_FILE")" "1"
assert "IPv6 PTR old name gone" "$(grep -c 'smoke-rename\.' "$IPV6_ZONE_FILE")" "0"

# Error: nonexistent source
out=$(sudo "$DNSBINDER" -r nonexistent newname -y 2>&1)
assert_contains "-r rejects nonexistent source" "$out" "doesn't exist"

# Error: conflicting target
out=$(sudo "$DNSBINDER" -r smoke-renamed smoke-v4only -y 2>&1)
assert_contains "-r rejects existing target" "$out" "Conflict"

cleanup_record smoke-renamed

# ═══════════════════════════════════════════════════════════════════════
section "8. DELETE AUTO-DETECT (-d)"
# ═══════════════════════════════════════════════════════════════════════

# Delete CNAME
out=$(sudo "$DNSBINDER" -d smoke-alias -y 2>&1)
assert_contains "-d deletes CNAME" "$out" "deleted cname"
assert "CNAME removed" "$(grep -c '^smoke-alias ' "$FW_ZONE_FILE")" "0"

# Delete IPv6-only
out=$(sudo "$DNSBINDER" -d smoke-v6only -y 2>&1)
assert_contains "-d deletes IPv6-only" "$out" "Deleted IPv6-only"
assert "AAAA removed" "$(grep -c '^smoke-v6only ' "$FW_ZONE_FILE")" "0"
assert "IPv6 PTR removed" "$(grep -c 'smoke-v6only' "$IPV6_ZONE_FILE")" "0"

# Delete IPv4-only
out=$(sudo "$DNSBINDER" -d smoke-v4only -y 2>&1)
assert_contains "-d deletes IPv4-only" "$out" "deleted host record"
assert "A removed" "$(grep -c '^smoke-v4only ' "$FW_ZONE_FILE")" "0"

# Delete dual-stack
out=$(sudo "$DNSBINDER" -d smoke-dual -y 2>&1)
assert_contains "-d deletes dual-stack" "$out" "deleted host record"
assert "A removed" "$(grep -c '^smoke-dual ' "$FW_ZONE_FILE")" "0"
assert "IPv6 PTR removed" "$(grep -c 'smoke-dual' "$IPV6_ZONE_FILE")" "0"

# Delete specific-IP
out=$(sudo "$DNSBINDER" -d smoke-ci -y 2>&1)
assert_contains "-d deletes specific-IP host" "$out" "deleted host record"

# Error: nonexistent
out=$(sudo "$DNSBINDER" -d nonexistent -y 2>&1)
assert_contains "-d rejects nonexistent" "$out" "doesn't exist"

# ═══════════════════════════════════════════════════════════════════════
section "9. BULK CREATE (-cfy, -c4fy, -c6fy, -cify)"
# ═══════════════════════════════════════════════════════════════════════

cat > /tmp/smoke-bulk-dual.txt << 'EOF'
smoke-bd1
smoke-bd2
smoke-bd3
EOF
out=$(sudo "$DNSBINDER" -cfy /tmp/smoke-bulk-dual.txt --inline 2>&1)
assert_contains "-cfy creates records" "$out" "Successful : 3"
assert "All 3 A records" "$(grep -c '^smoke-bd[123] .*IN A ' "$FW_ZONE_FILE")" "3"
assert "All 3 AAAA records" "$(grep -c '^smoke-bd[123] .*IN AAAA' "$FW_ZONE_FILE")" "3"

# Bulk with duplicates
cat > /tmp/smoke-bulk-dup.txt << 'EOF'
smoke-bd1
smoke-bd4
bad!host
EOF
out=$(sudo "$DNSBINDER" -cfy /tmp/smoke-bulk-dup.txt --inline 2>&1)
assert_contains "-cfy detects duplicates" "$out" "Already Exists"
assert_contains "-cfy detects invalid host" "$out" "Invalid Host"
assert_contains "-cfy creates valid ones" "$out" "Successful : 1"

# IPv4-only bulk
cat > /tmp/smoke-bulk-v4.txt << 'EOF'
smoke-bv4a
smoke-bv4b
EOF
out=$(sudo "$DNSBINDER" -c4fy /tmp/smoke-bulk-v4.txt --inline 2>&1)
assert_contains "-c4fy creates records" "$out" "Successful : 2"
assert "No AAAA for bulk v4" "$(grep -c '^smoke-bv4[ab] .*IN AAAA' "$FW_ZONE_FILE")" "0"

# IPv6-only bulk
cat > /tmp/smoke-bulk-v6.txt << 'EOF'
smoke-bv6a
smoke-bv6b
EOF
out=$(sudo "$DNSBINDER" -c6fy /tmp/smoke-bulk-v6.txt --inline 2>&1)
assert_contains "-c6fy creates records" "$out" "Successful : 2"
assert "No A for bulk v6" "$(grep -c '^smoke-bv6[ab] .*IN A ' "$FW_ZONE_FILE")" "0"
assert "AAAA for bulk v6" "$(grep -c '^smoke-bv6[ab] .*IN AAAA' "$FW_ZONE_FILE")" "2"

# Bulk with IP
cat > /tmp/smoke-bulk-ci.txt << 'EOF'
smoke-bci1 10.28.30.20
smoke-bci2 10.28.30.21
smoke-bci3 192.168.1.1
EOF
out=$(sudo "$DNSBINDER" -cify /tmp/smoke-bulk-ci.txt --inline 2>&1)
assert_contains "-cify creates valid records" "$out" "Successful : 2"
assert_contains "-cify rejects invalid IP" "$out" "Invalid-IPv4"
assert "No inline error noise" "$(echo "$out" | grep -c '\[ERROR\]')" "0"

# ═══════════════════════════════════════════════════════════════════════
section "10. BULK DELETE (-dfy) MIXED TYPES"
# ═══════════════════════════════════════════════════════════════════════

# Add a CNAME for the mix
sudo "$DNSBINDER" -cc smoke-balias smoke-bd1 -y &>/dev/null

cat > /tmp/smoke-bulk-del.txt << 'EOF'
smoke-bd1
smoke-bv4a
smoke-bv6a
smoke-balias
smoke-bci1
nonexistent-xyz
smoke-bd2
EOF
out=$(sudo "$DNSBINDER" -dfy /tmp/smoke-bulk-del.txt --inline 2>&1)
assert_contains "-dfy deletes successfully" "$out" "Successful : 6"
assert_contains "-dfy detects nonexistent" "$out" "Doesn't-Exist"
assert_contains "-dfy shows CNAME label" "$out" "Deleting CNAME"
assert_contains "-dfy shows IPv6-only label" "$out" "Deleting IPv6-only"
assert "CNAME removed from zone" "$(grep -c '^smoke-balias ' "$FW_ZONE_FILE")" "0"
assert "IPv6-only removed from zone" "$(grep -c '^smoke-bv6a ' "$FW_ZONE_FILE")" "0"

# ═══════════════════════════════════════════════════════════════════════
section "11. QUERY (-q)"
# ═══════════════════════════════════════════════════════════════════════

# Create test records for query
sudo "$DNSBINDER" -c smoke-qhost --ttl 180 -y &>/dev/null
sudo "$DNSBINDER" -cc smoke-qalias smoke-qhost -y &>/dev/null

# Forward query
out=$(sudo "$DNSBINDER" -q smoke-qhost 2>&1)
assert_contains "-q shows A record" "$out" "A     :"
assert_contains "-q shows AAAA record" "$out" "AAAA  :"
assert_contains "-q shows TTL" "$out" "TTL   : 180 seconds"
assert_contains "-q shows CNAME alias" "$out" "CNAME : smoke-qalias"

# Query CNAME
out=$(sudo "$DNSBINDER" -q smoke-qalias 2>&1)
assert_contains "-q resolves CNAME" "$out" "CNAME of :"
assert_contains "-q CNAME shows TTL" "$out" "TTL   :"

# Query with FQDN
out=$(sudo "$DNSBINDER" -q "smoke-qhost.${DOMAIN}" 2>&1)
assert_contains "-q accepts FQDN" "$out" "A     :"

# IPv4 reverse query
ip=$(awk '/^smoke-qhost .*IN A / {print $NF}' "$FW_ZONE_FILE")
out=$(sudo "$DNSBINDER" -q "$ip" 2>&1)
assert_contains "-q IPv4 reverse shows PTR" "$out" "PTR   :"
assert_contains "-q IPv4 reverse shows TTL" "$out" "TTL   : 180 seconds"

# IPv6 reverse query
ipv6=$(awk '/^smoke-qhost .*IN AAAA/ {print $NF}' "$FW_ZONE_FILE")
out=$(sudo "$DNSBINDER" -q "$ipv6" 2>&1)
assert_contains "-q IPv6 reverse shows PTR" "$out" "PTR   :"
assert_contains "-q IPv6 reverse shows TTL" "$out" "TTL   : 180 seconds"

# Error: nonexistent
out=$(sudo "$DNSBINDER" -q nonexistent-xyz 2>&1)
assert_contains "-q error for nonexistent" "$out" "No records found"

cleanup_record smoke-qalias
cleanup_record smoke-qhost

# ═══════════════════════════════════════════════════════════════════════
section "12. RECONFIGURE (--reconfigure)"
# ═══════════════════════════════════════════════════════════════════════

out=$(sudo "$DNSBINDER" --reconfigure 2>&1)
assert_contains "--reconfigure succeeds" "$out" "named.conf regenerated"
# DNS still works after reconfigure
out=$(sudo "$DNSBINDER" -q tux2lab-engine 2>&1)
assert_contains "DNS works after reconfigure" "$out" "A     :"

# ═══════════════════════════════════════════════════════════════════════
section "13. ERROR HANDLING"
# ═══════════════════════════════════════════════════════════════════════

# Invalid option
out=$(sudo "$DNSBINDER" --bogus 2>&1); rc=$?
assert_contains "Invalid option rejected" "$out" "Invalid Option"

# Too many arguments
out=$(sudo "$DNSBINDER" -c a b c 2>&1); rc=$?
assert_contains "Too many args rejected" "$out" "takes only 1 argument"

# -dc rejected (removed flag)
out=$(sudo "$DNSBINDER" -dc test 2>&1); rc=$?
assert_contains "-dc flag rejected" "$out" "Invalid Option"

# Invalid hostname
out=$(sudo "$DNSBINDER" -c 'bad!host' -y 2>&1)
assert_contains "Invalid hostname rejected" "$out" "letters, numbers, and hyphens"

# Nonexistent file for bulk ops
out=$(sudo "$DNSBINDER" -cfy /tmp/no-such-file.txt --inline 2>&1)
assert_contains "-cfy rejects nonexistent file" "$out" "doesn't exist"

out=$(sudo "$DNSBINDER" -dfy /tmp/no-such-file.txt --inline 2>&1)
assert_contains "-dfy rejects nonexistent file" "$out" "doesn't exist"

# Empty file for bulk ops
> /tmp/smoke-empty.txt
out=$(sudo "$DNSBINDER" -cfy /tmp/smoke-empty.txt --inline 2>&1)
assert_contains "-cfy rejects empty file" "$out" "empty"

# --ttl with non-numeric value
out=$(sudo "$DNSBINDER" -c smoke-badttl --ttl abc -y 2>&1)
assert_contains "--ttl non-numeric rejected" "$out" "TTL must be a positive integer"

# Comma-separated create and delete
out=$(sudo "$DNSBINDER" -c smoke-comma1,smoke-comma2 -y 2>&1)
assert "Comma-separated creates both" "$(grep -c '^smoke-comma[12] .*IN A ' "$FW_ZONE_FILE")" "2"
out=$(sudo "$DNSBINDER" -d smoke-comma1,smoke-comma2 -y 2>&1)
assert "Comma-separated deletes both" "$(grep -c '^smoke-comma[12] ' "$FW_ZONE_FILE" || true)" "0"

# ═══════════════════════════════════════════════════════════════════════
section "14. SERIAL NUMBER CONSISTENCY"
# ═══════════════════════════════════════════════════════════════════════

# Get current serials
fw_serial_before=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "$FW_ZONE_FILE")
ipv6_serial_before=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "$IPV6_ZONE_FILE")

# Create dual-stack (should bump forward + ipv6)
sudo "$DNSBINDER" -c smoke-serial -y &>/dev/null

fw_serial_after=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "$FW_ZONE_FILE")
ipv6_serial_after=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "$IPV6_ZONE_FILE")

assert "Forward serial incremented" "$([[ $fw_serial_after -gt $fw_serial_before ]] && echo yes)" "yes"
assert "IPv6 serial incremented" "$([[ $ipv6_serial_after -gt $ipv6_serial_before ]] && echo yes)" "yes"

cleanup_record smoke-serial

# ═══════════════════════════════════════════════════════════════════════
section "15. ZONE FILE INTEGRITY"
# ═══════════════════════════════════════════════════════════════════════

# Clean up all remaining smoke-* records
remaining=$(grep "^smoke-" "$FW_ZONE_FILE" | awk '{print $1}' | sort -u)
if [[ -n "$remaining" ]]; then
    echo "$remaining" > /tmp/smoke-final-cleanup.txt
    sudo "$DNSBINDER" -dfy /tmp/smoke-final-cleanup.txt --inline &>/dev/null
fi

# Verify zone is clean
smoke_count=$(grep -c "^smoke-" "$FW_ZONE_FILE" || true)
assert "No smoke-* records left in forward zone" "$smoke_count" "0"

smoke_ipv6_count=$(grep -c "smoke-" "$IPV6_ZONE_FILE" || true)
assert "No smoke-* records left in IPv6 reverse zone" "$smoke_ipv6_count" "0"

# Verify named is running and healthy
rndc_status=$(sudo podman exec tux2lab-engine rndc status 2>&1 | grep -c "server is up and running" || echo 0)
assert "named is running" "$rndc_status" "1"

# Verify no python in dnsbinder
python_count=$(grep -c "python3" "$DNSBINDER" || true)
assert "Zero python3 calls" "$python_count" "0"

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════

echo ""
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if [[ $FAIL -eq 0 ]]; then
    printf "${GREEN}ALL %d TESTS PASSED${NC}\n" "$TOTAL"
else
    printf "${RED}%d FAILED${NC} / ${GREEN}%d passed${NC} / %d total\n" "$FAIL" "$PASS" "$TOTAL"
fi
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# Clean up temp files
rm -f /tmp/smoke-bulk-*.txt /tmp/smoke-final-cleanup.txt

exit $FAIL
