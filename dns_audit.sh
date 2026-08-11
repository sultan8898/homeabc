#!/bin/bash
# =============================================================================
# Cloudways DNS audit — list domains (local nginx and/or API v2) and query DNS
#
# Cloudways API v2 does NOT return full zone files. It can list application
# domains (cname / aliases). For actual records we query public DNS via dig.
# If DNS is on Cloudways "DNS Made Easy" add-on, use their API for zone export.
#
# Usage (on a Cloudways server — recommended):
#   ./dns_audit.sh
#   ./dns_audit.sh --csv > dns_report.csv
#
# Usage (account-wide via API — any machine with curl + jq):
#   export CW_EMAIL='you@example.com'
#   export CW_API_KEY='your-api-key'
#   ./dns_audit.sh --api
#
#   # One-liner (credentials as flags — works with pipe to bash):
#   curl -fsSL .../dns_audit.sh | bash -s -- --api \
#     --email 'you@example.com' --api-key 'your-api-key'
#
# Options:
#   --api          Fetch domains from Cloudways API v2 (all servers in account)
#   --email        Cloudways account email (or set CW_EMAIL)
#   --api-key      Cloudways API key (or set CW_API_KEY)
#   --local-only   Only parse /home/master/applications (default on server)
#   --csv          Tab-separated output (domain, host, type, value, note)
#   --server-ip    Override expected A-record IP (default: api.ipify.org)
# =============================================================================

set -euo pipefail

API_BASE="https://api.cloudways.com/api/v2"
USE_API=0
CSV=0
LOCAL=1
SERVER_IP=""
BASE_DIR="/home/master/applications"

# Common hostnames to probe (add more in EXTRA_HOSTS env, space-separated)
COMMON_HOSTS="www mail smtp pop pop3 imap webmail ftp cpanel autodiscover autoconfig _dmarc"
EXTRA_HOSTS="${EXTRA_HOSTS:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) USE_API=1; shift ;;
        --email) CW_EMAIL="$2"; shift 2 ;;
        --api-key) CW_API_KEY="$2"; shift 2 ;;
        --local-only) LOCAL=1; USE_API=0; shift ;;
        --csv) CSV=1; shift ;;
        --server-ip) SERVER_IP="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v dig >/dev/null 2>&1 || { echo "dig is required (install dnsutils)." >&2; exit 1; }

# Only compare A records to this machine's IP in local (single-server) mode.
# Account-wide --api spans many servers; pass --server-ip to enable checks.
if [[ -z "$SERVER_IP" && "$USE_API" -eq 0 ]]; then
    SERVER_IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
fi

declare -A SEEN_DOMAINS
declare -a DOMAIN_LIST

add_domain() {
    local d
    d=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    d="${d%.}"        # trim trailing dot
    [[ -z "$d" ]] && return 0
    [[ "$d" == *cloudwaysapps.com ]] && return 0
    [[ "$d" == _* ]] && return 0
    if [[ -z "${SEEN_DOMAINS[$d]:-}" ]]; then
        SEEN_DOMAINS[$d]=1
        DOMAIN_LIST+=("$d")
    fi
}

# --- Local: domains from nginx configs on this server ---
collect_local_domains() {
    [[ -d "$BASE_DIR" ]] || return 0
    for conf in "$BASE_DIR"/*/conf/server.nginx; do
        [[ -f "$conf" ]] || continue
        local app
        app=$(basename "$(dirname "$(dirname "$conf")")")
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            add_domain "$line"
        done < <(
            sed -e 's/server_name //' -e '/^$/d' -e 's/;//g' -e 's/#.*//' "$conf" \
                | tr ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
        )
        if [[ "$CSV" -eq 0 ]]; then
            echo "# App: $app" >&2
        fi
    done
}

# --- Cloudways API v2: domains from all servers/apps ---
api_token() {
    [[ -n "${CW_EMAIL:-}" && -n "${CW_API_KEY:-}" ]] || {
        echo "Set CW_EMAIL and CW_API_KEY (export) or pass --email and --api-key." >&2
        echo "Note: VAR=value before curl does NOT reach 'bash' in a pipe — use export or flags." >&2
        exit 1
    }
    command -v jq >/dev/null 2>&1 || { echo "jq is required for --api mode." >&2; exit 1; }
    curl -fsS --max-time 30 -X POST "${API_BASE}/oauth/access_token" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${CW_EMAIL}\",\"api_key\":\"${CW_API_KEY}\"}" \
        | jq -r '.access_token // empty'
}

collect_api_domains() {
    local token
    token=$(api_token)
    [[ -n "$token" ]] || { echo "Failed to obtain API token." >&2; exit 1; }

    local json
    json=$(curl -fsS --max-time 60 -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" "${API_BASE}/server")

    # Primary cname + alias domains on each app
    while IFS= read -r d; do
        add_domain "$d"
    done < <(echo "$json" | jq -r '
        .servers[]?.apps[]? |
        (.cname // empty),
        (.app_fqdn // empty),
        (.aliases[]? // empty)
    ' 2>/dev/null | grep -v cloudwaysapps.com || true)

    if [[ "$CSV" -eq 0 ]]; then
        echo "# API: $(echo "$json" | jq -r '.servers | length') server(s), ${#DOMAIN_LIST[@]} unique domain(s)" >&2
    fi
}

csv_row() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

print_header() {
    if [[ "$CSV" -eq 1 ]]; then
        csv_row "apex_domain" "host" "type" "value" "note"
    else
        echo "================================================================"
        echo "DNS AUDIT — $(date '+%Y-%m-%d %H:%M:%S')"
        [[ -n "$SERVER_IP" ]] && echo "Expected server A record IP: $SERVER_IP"
        echo "================================================================"
    fi
}

# Query one name for one RR type; print rows
dig_query() {
    local apex="$1" host="$2" rrtype="$3"
    local qname="$host"
    [[ "$host" == "@" ]] && qname="$apex" || qname="${host}.${apex}"

    local out
    out=$(dig +short "$rrtype" "$qname" 2>/dev/null | sed '/^$/d')
    [[ -z "$out" ]] && return 0

    while IFS= read -r val; do
        local note=""
        if [[ "$rrtype" == "A" && -n "$SERVER_IP" && "$val" != "$SERVER_IP" ]]; then
            note="A does not match server IP ($SERVER_IP)"
        fi
        if [[ "$CSV" -eq 1 ]]; then
            csv_row "$apex" "$host" "$rrtype" "$val" "$note"
        else
            if [[ -n "$note" ]]; then
                printf "  %-6s %-40s %s  [%s]\n" "$rrtype" "$qname" "$val" "$note"
            else
                printf "  %-6s %-40s %s\n" "$rrtype" "$qname" "$val"
            fi
        fi
    done <<< "$out"
}

# SRV: dig returns "priority weight port target"
dig_srv() {
    local apex="$1" service="$2"   # e.g. _imap._tcp
    local qname="${service}.${apex}"
    local out
    out=$(dig +short SRV "$qname" 2>/dev/null | sed '/^$/d')
    [[ -z "$out" ]] && return 0
    while IFS= read -r val; do
        if [[ "$CSV" -eq 1 ]]; then
            csv_row "$apex" "$service" "SRV" "$val" ""
        else
            printf "  %-6s %-40s %s\n" "SRV" "$qname" "$val"
        fi
    done <<< "$out"
}

audit_domain() {
    local apex="$1"
    if [[ "$CSV" -eq 0 ]]; then
        echo ""
        echo "--- $apex ---"
        echo "  Nameservers:"
    fi

    dig_query "$apex" "@" NS
    dig_query "$apex" "@" SOA
    dig_query "$apex" "@" A
    dig_query "$apex" "@" AAAA
    dig_query "$apex" "@" MX
    dig_query "$apex" "@" TXT
    dig_query "$apex" "@" CNAME

    # Common subdomains
    for h in $COMMON_HOSTS $EXTRA_HOSTS; do
        if [[ "$h" == _dmarc ]]; then
            dig_query "$apex" "_dmarc" TXT
            continue
        fi
        dig_query "$apex" "$h" A
        dig_query "$apex" "$h" AAAA
        dig_query "$apex" "$h" CNAME
    done

    # Common SRV mail discovery
    for srv in _imap._tcp _pop3._tcp _smtp._tcp _submission._tcp _autodiscover._tcp; do
        dig_srv "$apex" "$srv"
    done

    # Pointing check (local single-server mode only)
    if [[ -n "$SERVER_IP" && "$CSV" -eq 0 ]]; then
        local root_ip www_ip
        root_ip=$(dig +short A "$apex" 2>/dev/null | head -n1)
        www_ip=$(dig +short A "www.${apex}" 2>/dev/null | head -n1)
        if [[ -z "$root_ip" ]]; then
            echo "  CHECK: $apex has no A record"
        elif [[ "$root_ip" != "$SERVER_IP" ]]; then
            echo "  CHECK: $apex A=$root_ip (expected $SERVER_IP)"
        fi
        if [[ -z "$www_ip" ]]; then
            echo "  CHECK: www.$apex has no A record"
        elif [[ "$www_ip" != "$SERVER_IP" ]]; then
            echo "  CHECK: www.$apex A=$www_ip (expected $SERVER_IP)"
        fi
    fi
}

# --- Main ---
if [[ "$USE_API" -eq 1 ]]; then
    collect_api_domains
elif [[ "$LOCAL" -eq 1 && -d "$BASE_DIR" ]]; then
    collect_local_domains
else
    echo "No domains found. Run on a Cloudways server or use --api with CW_EMAIL/CW_API_KEY." >&2
    exit 1
fi

if [[ ${#DOMAIN_LIST[@]} -eq 0 ]]; then
    echo "No domains collected." >&2
    exit 1
fi

print_header
total=${#DOMAIN_LIST[@]}
n=0
for d in "${DOMAIN_LIST[@]}"; do
    n=$((n + 1))
    if [[ "$CSV" -eq 0 ]]; then
        echo "# [$n/$total] $d" >&2
    fi
    audit_domain "$d"
done

if [[ "$CSV" -eq 0 ]]; then
    echo ""
    echo "Done. ${#DOMAIN_LIST[@]} domain(s) audited."
    echo "Note: This lists public DNS answers, not a full zone export."
    echo "For ALL records in a Cloudways DNS Made Easy zone, use DNS Made Easy API."
fi
