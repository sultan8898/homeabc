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
#   --server-ip    Override expected A-record IP (local mode only)
#   --securitytrails | --st   Use SecurityTrails API for apex DNS records
#   --st-api-key   SecurityTrails API key (or ST_API_KEY env)
#   --st-subdomains  Also list known subdomains (1 extra API call per domain)
#   --source       dig | securitytrails | both  (default: dig)
#   --domain       Audit one domain only (skip Cloudways/local discovery)
#   --limit N      Only audit first N domains (API quota safety)
# =============================================================================

set -euo pipefail

API_BASE="https://api.cloudways.com/api/v2"
ST_API_BASE="https://api.securitytrails.com/v1"
USE_API=0
CSV=0
LOCAL=1
SERVER_IP=""
BASE_DIR="/home/master/applications"
DNS_SOURCE="dig"
ST_SUBDOMAINS=0
ST_SLEEP="${ST_SLEEP:-0.6}"
DOMAIN_LIMIT=0
SINGLE_DOMAIN=""

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
        --securitytrails|--st) DNS_SOURCE="securitytrails"; shift ;;
        --st-api-key) ST_API_KEY="$2"; shift 2 ;;
        --st-subdomains) ST_SUBDOMAINS=1; shift ;;
        --source) DNS_SOURCE="$2"; shift 2 ;;
        --domain) SINGLE_DOMAIN="$2"; shift 2 ;;
        --limit) DOMAIN_LIMIT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v dig >/dev/null 2>&1 || { echo "dig is required (install dnsutils)." >&2; exit 1; }

case "$DNS_SOURCE" in
    dig|securitytrails|both) ;;
    *) echo "Invalid --source: $DNS_SOURCE (use dig, securitytrails, or both)" >&2; exit 1 ;;
esac

if [[ "$DNS_SOURCE" != "dig" ]]; then
    command -v jq >/dev/null 2>&1 || { echo "jq is required for SecurityTrails mode." >&2; exit 1; }
    [[ -n "${ST_API_KEY:-}" ]] || {
        echo "Set ST_API_KEY or pass --st-api-key for SecurityTrails mode." >&2
        exit 1
    }
fi

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
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

emit_row() {
    local apex="$1" host="$2" rrtype="$3" val="$4" note="${5:-}" source="${6:-dig}"
    if [[ "$CSV" -eq 1 ]]; then
        csv_row "$apex" "$host" "$rrtype" "$val" "$note" "$source"
    else
        if [[ -n "$note" ]]; then
            printf "  %-6s %-40s %s  [%s] (%s)\n" "$rrtype" "$host" "$val" "$note" "$source"
        else
            printf "  %-6s %-40s %s (%s)\n" "$rrtype" "$host" "$val" "$source"
        fi
    fi
}

print_header() {
    if [[ "$CSV" -eq 1 ]]; then
        csv_row "apex_domain" "host" "type" "value" "note" "source"
    else
        echo "================================================================"
        echo "DNS AUDIT — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "DNS source: $DNS_SOURCE"
        [[ -n "$SERVER_IP" ]] && echo "Expected server A record IP: $SERVER_IP"
        echo "================================================================"
    fi
}

st_api_get() {
    local path="$1"
    curl -fsS --max-time 45 \
        -H "APIKEY: ${ST_API_KEY}" \
        -H "Accept: application/json" \
        "${ST_API_BASE}${path}"
}

st_audit_domain() {
    local apex="$1"
    local json err

    if ! json=$(st_api_get "/domain/${apex}" 2>&1); then
        echo "# SecurityTrails error for $apex: $json" >&2
        return 0
    fi

    if echo "$json" | jq -e '.message' >/dev/null 2>&1; then
        echo "# SecurityTrails: $(echo "$json" | jq -r '.message') ($apex)" >&2
        return 0
    fi

    local qname="$apex"
    while IFS= read -r val; do
        [[ -n "$val" ]] && emit_row "$apex" "$qname" "A" "$val" "" "securitytrails"
    done < <(echo "$json" | jq -r '.current_dns.a.values[]?.ip // empty')

    while IFS= read -r val; do
        [[ -n "$val" ]] && emit_row "$apex" "$qname" "AAAA" "$val" "" "securitytrails"
    done < <(echo "$json" | jq -r '.current_dns.aaaa.values[]?.ip // empty')

    while IFS= read -r val; do
        [[ -n "$val" ]] && emit_row "$apex" "$qname" "MX" "$val" "" "securitytrails"
    done < <(echo "$json" | jq -r '.current_dns.mx.values[]? | "\(.priority) \(.host)"')

    while IFS= read -r val; do
        [[ -n "$val" ]] && emit_row "$apex" "$qname" "NS" "$val" "" "securitytrails"
    done < <(echo "$json" | jq -r '.current_dns.ns.values[]?.nameserver // empty')

    while IFS= read -r val; do
        [[ -n "$val" ]] && emit_row "$apex" "$qname" "SOA" "$val" "" "securitytrails"
    done < <(echo "$json" | jq -r '.current_dns.soa.values[]? | "ttl=\(.ttl) rname=\(.email)"')

    while IFS= read -r val; do
        [[ -n "$val" ]] && emit_row "$apex" "$qname" "TXT" "$val" "" "securitytrails"
    done < <(echo "$json" | jq -r '.current_dns.txt.values[]?.value // empty')

    if [[ "$ST_SUBDOMAINS" -eq 1 ]]; then
        sleep "$ST_SLEEP"
        local subs
        if subs=$(st_api_get "/domain/${apex}/subdomains" 2>/dev/null); then
            while IFS= read -r sub; do
                [[ -n "$sub" ]] && emit_row "$apex" "${sub}.${apex}" "SUBDOMAIN" "(known)" "" "securitytrails"
            done < <(echo "$subs" | jq -r '.subdomains[]? // empty')
        fi
    fi

    sleep "$ST_SLEEP"
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
            csv_row "$apex" "$host" "$rrtype" "$val" "$note" "dig"
        else
            if [[ -n "$note" ]]; then
                printf "  %-6s %-40s %s  [%s] (dig)\n" "$rrtype" "$qname" "$val" "$note"
            else
                printf "  %-6s %-40s %s (dig)\n" "$rrtype" "$qname" "$val"
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
            csv_row "$apex" "$service" "SRV" "$val" "" "dig"
        else
            printf "  %-6s %-40s %s (dig)\n" "SRV" "$qname" "$val"
        fi
    done <<< "$out"
}

audit_domain() {
    local apex="$1"
    if [[ "$CSV" -eq 0 ]]; then
        echo ""
        echo "--- $apex ---"
    fi

    if [[ "$DNS_SOURCE" == "securitytrails" || "$DNS_SOURCE" == "both" ]]; then
        [[ "$CSV" -eq 0 ]] && echo "  SecurityTrails (apex):"
        st_audit_domain "$apex"
    fi

    if [[ "$DNS_SOURCE" == "dig" || "$DNS_SOURCE" == "both" ]]; then
        if [[ "$CSV" -eq 0 ]]; then
            echo "  dig:"
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
    fi
}

# --- Main ---
if [[ -n "$SINGLE_DOMAIN" ]]; then
    add_domain "$SINGLE_DOMAIN"
elif [[ "$USE_API" -eq 1 ]]; then
    collect_api_domains
elif [[ "$LOCAL" -eq 1 && -d "$BASE_DIR" ]]; then
    collect_local_domains
else
    echo "No domains found. Use --domain, --api, or run on a Cloudways server." >&2
    exit 1
fi

if [[ ${#DOMAIN_LIST[@]} -eq 0 ]]; then
    echo "No domains collected." >&2
    exit 1
fi

print_header
total=${#DOMAIN_LIST[@]}
[[ "$DOMAIN_LIMIT" -gt 0 && "$DOMAIN_LIMIT" -lt "$total" ]] && total="$DOMAIN_LIMIT"
n=0
for d in "${DOMAIN_LIST[@]}"; do
    n=$((n + 1))
    [[ "$DOMAIN_LIMIT" -gt 0 && "$n" -gt "$DOMAIN_LIMIT" ]] && break
    if [[ "$CSV" -eq 0 ]]; then
        echo "# [$n/$total] $d" >&2
    fi
    audit_domain "$d"
done

if [[ "$CSV" -eq 0 ]]; then
    echo ""
    echo "Done. $n domain(s) audited."
    echo "Note: SecurityTrails returns apex DNS + optional subdomain names (not full zone)."
    echo "dig probes common hostnames; neither is a complete zone export."
fi
