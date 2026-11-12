#!/usr/bin/env bash
# =============================================================================
# check-apache-http2-cve.sh
#
# Defensive diagnostic for CVE-2026-119618 (Apache mod_http2 RCE).
# Affects Apache HTTP Server 2.4.55–2.4.70 when HTTP/2 is enabled
# (Protocols h2 / h2c, or standalone mod_h2 2.0.8–2.0.42).
# Fixed in Apache 2.4.71.
#
# Safe to run as a normal user; some checks are richer with root/sudo.
# Does NOT exploit anything — config / package inspection only.
#
# Usage:
#   bash check-apache-http2-cve.sh
#   sudo bash check-apache-http2-cve.sh
# =============================================================================

set -euo pipefail

RED=$'\033[31m'
GRN=$'\033[32m'
YLW=$'\033[33m'
CYN=$'\033[36m'
BLD=$'\033[1m'
RST=$'\033[0m'

HAVE_SUDO=0
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  HAVE_SUDO=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  HAVE_SUDO=1
fi

run() {
  # Prefer direct root; else try passwordless sudo; else run as self.
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif [[ "$HAVE_SUDO" -eq 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

section() {
  echo
  echo "${BLD}${CYN}==> $*${RST}"
}

ok()   { echo "  ${GRN}[OK]${RST}   $*"; }
warn() { echo "  ${YLW}[WARN]${RST} $*"; }
bad()  { echo "  ${RED}[RISK]${RST} $*"; }
info() { echo "  ${CYN}[INFO]${RST} $*"; }
skip() { echo "  ${YLW}[SKIP]${RST} $*"; }

# -----------------------------------------------------------------------------
# Result flags (0 = false / not present, 1 = true)
# -----------------------------------------------------------------------------
APACHE_INSTALLED=0
APACHE_RUNNING=0
APACHE_VERSION=""
APACHE_IN_RANGE=0          # 2.4.55–2.4.70
APACHE_FIXED=0             # >= 2.4.71
HTTP2_MODULE_AVAILABLE=0
HTTP2_MODULE_ENABLED=0
HTTP2_MODULE_LOADED=0
PROTOCOLS_H2_ENABLED=0
NGINX_HTTP2=0
VERDICT="UNKNOWN"

version_ge() {
  # Return 0 if $1 >= $2 (dotted numeric versions)
  printf '%s\n%s\n' "$2" "$1" | sort -C -V
}

version_lt() {
  ! version_ge "$1" "$2"
}

parse_apache_version() {
  # Extract X.Y.Z from "Server version: Apache/2.4.69 (Debian)" etc.
  local raw="$1"
  echo "$raw" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# =============================================================================
section "0. Host context"
# =============================================================================
info "Host:     $(hostname -f 2>/dev/null || hostname)"
info "Kernel:   $(uname -sr)"
info "User:     $(id -un) (uid=$(id -u))"
info "Date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if [[ "$HAVE_SUDO" -eq 1 ]]; then
  ok "Elevated/sudo available — full config reads enabled"
else
  warn "No passwordless sudo — some checks may be limited"
fi

# =============================================================================
section "1. Is Apache HTTP Server installed?"
# =============================================================================
APACHE_BIN=""
for cand in /usr/sbin/apache2 /usr/sbin/httpd /usr/local/sbin/httpd; do
  if [[ -x "$cand" ]]; then
    APACHE_BIN="$cand"
    break
  fi
done

if [[ -z "$APACHE_BIN" ]] && command -v apache2 >/dev/null 2>&1; then
  APACHE_BIN="$(command -v apache2)"
elif [[ -z "$APACHE_BIN" ]] && command -v httpd >/dev/null 2>&1; then
  APACHE_BIN="$(command -v httpd)"
fi

PKG_LINE=""
if command -v dpkg >/dev/null 2>&1; then
  PKG_LINE="$(dpkg -l apache2 2>/dev/null | awk '/^ii/{print}' || true)"
elif command -v rpm >/dev/null 2>&1; then
  PKG_LINE="$(rpm -q httpd 2>/dev/null || true)"
fi

if [[ -n "$APACHE_BIN" ]] || [[ -n "$PKG_LINE" ]]; then
  APACHE_INSTALLED=1
  ok "Apache binary/package found"
  [[ -n "$APACHE_BIN" ]] && info "Binary:  $APACHE_BIN"
  [[ -n "$PKG_LINE" ]] && info "Package: $PKG_LINE"
else
  skip "Apache not installed — host is not in scope for this CVE"
  VERDICT="NOT_APPLICABLE"
fi

# =============================================================================
section "2. Is Apache running?"
# =============================================================================
if [[ "$APACHE_INSTALLED" -eq 1 ]]; then
  if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1; then
    APACHE_RUNNING=1
    ok "Apache process is running"
    ps -eo user,pid,cmd 2>/dev/null | grep -E '[a]pache2|[h]ttpd' | head -8 | sed 's/^/         /'
  else
    warn "Apache installed but no running process found"
  fi

  if command -v ss >/dev/null 2>&1; then
    info "Listening sockets (80/443/8080/8081):"
    ss -lntp 2>/dev/null | grep -E ':80 |:443 |:8080|:8081' | sed 's/^/         /' || info "(none matched)"
  fi
else
  skip "Skipped — Apache not installed"
fi

# =============================================================================
section "3. Apache version vs CVE-2026-119618 range (2.4.55–2.4.70)"
# =============================================================================
if [[ "$APACHE_INSTALLED" -eq 1 ]]; then
  VER_RAW=""
  if [[ -n "$APACHE_BIN" ]]; then
    VER_RAW="$("$APACHE_BIN" -v 2>&1 || true)"
  fi
  if [[ -z "$VER_RAW" ]] && command -v apache2ctl >/dev/null 2>&1; then
    VER_RAW="$(apache2ctl -v 2>&1 || true)"
  elif [[ -z "$VER_RAW" ]] && [[ -x /usr/sbin/apache2ctl ]]; then
    VER_RAW="$(/usr/sbin/apache2ctl -v 2>&1 || true)"
  fi

  APACHE_VERSION="$(parse_apache_version "$VER_RAW")"
  if [[ -n "$APACHE_VERSION" ]]; then
    info "Reported: $VER_RAW" | head -1
    info "Parsed version: $APACHE_VERSION"

    if version_ge "$APACHE_VERSION" "2.4.71"; then
      APACHE_FIXED=1
      ok "Version >= 2.4.71 — patched for CVE-2026-119618"
    elif version_ge "$APACHE_VERSION" "2.4.55" && version_lt "$APACHE_VERSION" "2.4.71"; then
      APACHE_IN_RANGE=1
      bad "Version $APACHE_VERSION is in affected range 2.4.55–2.4.70"
      info "Exploitability still requires HTTP/2 enabled on Apache (next steps)"
    else
      ok "Version $APACHE_VERSION is outside the affected range"
    fi
  else
    warn "Could not parse Apache version"
    echo "$VER_RAW" | sed 's/^/         /'
  fi
else
  skip "Skipped — Apache not installed"
fi

# =============================================================================
section "4. Is mod_http2 available / enabled / loaded?"
# =============================================================================
APACHE_ROOT=""
for d in /etc/apache2 /etc/httpd /usr/local/apache2/conf; do
  if [[ -d "$d" ]]; then
    APACHE_ROOT="$d"
    break
  fi
done

if [[ "$APACHE_INSTALLED" -eq 1 ]]; then
  # --- available ---
  if [[ -n "$APACHE_ROOT" ]]; then
    info "Config root: $APACHE_ROOT"
    if ls "$APACHE_ROOT"/mods-available/http2.load >/dev/null 2>&1 \
      || ls "$APACHE_ROOT"/modules/mod_http2.so >/dev/null 2>&1 \
      || ls /usr/lib/apache2/modules/mod_http2.so >/dev/null 2>&1 \
      || ls /usr/lib64/httpd/modules/mod_http2.so >/dev/null 2>&1; then
      HTTP2_MODULE_AVAILABLE=1
      warn "mod_http2 module files are present on disk"
      ls -la "$APACHE_ROOT"/mods-available/http2* 2>/dev/null | sed 's/^/         /' || true
      ls -la /usr/lib/apache2/modules/mod_http2.so 2>/dev/null | sed 's/^/         /' || true
    else
      ok "No mod_http2 module files found"
    fi

    # --- enabled (Debian-style mods-enabled) ---
    if ls "$APACHE_ROOT"/mods-enabled/http2.load >/dev/null 2>&1 \
      || ls "$APACHE_ROOT"/mods-enabled/http2.conf >/dev/null 2>&1; then
      HTTP2_MODULE_ENABLED=1
      bad "http2 is linked in mods-enabled (module configured to load)"
      ls -la "$APACHE_ROOT"/mods-enabled/http2* 2>/dev/null | sed 's/^/         /'
    else
      if [[ -d "$APACHE_ROOT/mods-enabled" ]]; then
        ok "http2 is NOT in mods-enabled"
      else
        info "No mods-enabled/ dir (RHEL-style?) — will rely on LoadModule / apachectl -M"
      fi
    fi

    # LoadModule lines anywhere under config tree
    info "Searching for LoadModule http2 / mod_http2 ..."
    if run grep -RniE '^\s*LoadModule\s+(http2_module|proxy_http2_module)' \
        "$APACHE_ROOT" 2>/dev/null | grep -vE 'mods-available|\.dpkg-|~$' | head -20; then
      # Matches outside mods-available strongly suggest enabled
      if run grep -RniE '^\s*LoadModule\s+http2_module' \
          "$APACHE_ROOT" 2>/dev/null | grep -vE 'mods-available|\.dpkg-|~$' >/dev/null; then
        HTTP2_MODULE_ENABLED=1
        bad "Active LoadModule http2_module found outside mods-available"
      fi
    else
      ok "No active LoadModule http2_module outside mods-available"
    fi
  else
    warn "Could not locate Apache config directory"
  fi

  # --- loaded in running process ---
  CTL=""
  if [[ -x /usr/sbin/apache2ctl ]]; then
    CTL=/usr/sbin/apache2ctl
  elif command -v apache2ctl >/dev/null 2>&1; then
    CTL="$(command -v apache2ctl)"
  elif command -v apachectl >/dev/null 2>&1; then
    CTL="$(command -v apachectl)"
  elif [[ -n "$APACHE_BIN" ]]; then
    CTL="$APACHE_BIN"
  fi

  if [[ -n "$CTL" ]]; then
    info "Module list via: $CTL -M"
    MODS="$(run "$CTL" -M 2>/dev/null || true)"
    if echo "$MODS" | grep -qiE 'http2_module'; then
      HTTP2_MODULE_LOADED=1
      bad "http2_module is LOADED in the running/config-tested Apache"
      echo "$MODS" | grep -iE 'http2' | sed 's/^/         /'
    else
      ok "http2_module is NOT loaded"
      echo "$MODS" | grep -iE 'http|ssl|proxy_fcgi' | sed 's/^/         /' || true
    fi
  else
    warn "apache2ctl/apachectl not found — cannot confirm loaded modules"
  fi
else
  skip "Skipped — Apache not installed"
fi

# =============================================================================
section "5. Protocols directive (h2 / h2c) in enabled config"
# =============================================================================
# HTTP/2 only runs where Protocols includes h2 or h2c.
if [[ "$APACHE_INSTALLED" -eq 1 && -n "$APACHE_ROOT" ]]; then
  info "Scanning enabled Apache configs for Protocols h2/h2c ..."
  # Prefer enabled trees; also check main conf. Exclude mods-available noise unless enabled.
  SEARCH_PATHS=()
  for p in \
    "$APACHE_ROOT/apache2.conf" \
    "$APACHE_ROOT/httpd.conf" \
    "$APACHE_ROOT/ports.conf" \
    "$APACHE_ROOT/sites-enabled" \
    "$APACHE_ROOT/conf-enabled" \
    "$APACHE_ROOT/mods-enabled" \
    "$APACHE_ROOT/conf.d" \
    "$APACHE_ROOT/sites.d"; do
    [[ -e "$p" ]] && SEARCH_PATHS+=("$p")
  done

  PROTO_HITS=""
  if [[ ${#SEARCH_PATHS[@]} -gt 0 ]]; then
    PROTO_HITS="$(run grep -RniE '^\s*Protocols\s+.*\b(h2|h2c)\b' "${SEARCH_PATHS[@]}" 2>/dev/null || true)"
  fi

  if [[ -n "$PROTO_HITS" ]]; then
    PROTOCOLS_H2_ENABLED=1
    bad "Protocols enables h2 and/or h2c in active config:"
    echo "$PROTO_HITS" | sed 's/^/         /'
  else
    ok "No active Protocols h2/h2c in enabled Apache configs"

    # Show unused mods-available default for awareness
    if [[ -f "$APACHE_ROOT/mods-available/http2.conf" ]]; then
      info "Note: mods-available/http2.conf (NOT enabled) contains:"
      head -5 "$APACHE_ROOT/mods-available/http2.conf" 2>/dev/null | sed 's/^/         /'
    fi
  fi
else
  skip "Skipped — no Apache config root"
fi

# =============================================================================
section "6. Edge nginx HTTP/2 (informational — NOT this CVE)"
# =============================================================================
# CVE-2026-119618 is Apache mod_http2 only. nginx HTTP/2 is a different stack.
if command -v nginx >/dev/null 2>&1 || [[ -d /etc/nginx ]]; then
  info "nginx detected — checking for http2 listeners (not CVE-2026-119618)"
  NGINX_HITS="$(run grep -RniE '\bhttp2\b' /etc/nginx 2>/dev/null | grep -vE '#' | head -20 || true)"
  if [[ -n "$NGINX_HITS" ]]; then
    NGINX_HTTP2=1
    info "nginx has HTTP/2 configured (edge termination — separate from Apache CVE):"
    echo "$NGINX_HITS" | sed 's/^/         /'
  else
    ok "No nginx http2 directives found (or not readable)"
  fi
else
  skip "nginx not present"
fi

# =============================================================================
section "7. Verdict"
# =============================================================================

if [[ "$VERDICT" == "NOT_APPLICABLE" ]]; then
  ok "NOT APPLICABLE — Apache HTTP Server is not installed on this host"
elif [[ "$APACHE_FIXED" -eq 1 ]]; then
  VERDICT="PATCHED"
  ok "PATCHED — Apache >= 2.4.71"
elif [[ "$APACHE_IN_RANGE" -eq 1 ]]; then
  if [[ "$HTTP2_MODULE_LOADED" -eq 1 || "$PROTOCOLS_H2_ENABLED" -eq 1 ]]; then
    VERDICT="EXPOSED"
    bad "EXPOSED — vulnerable Apache version AND HTTP/2 appears enabled/loaded"
    bad "Action: upgrade to Apache 2.4.71+ OR disable HTTP/2:"
    info "  a2dismod http2 && systemctl reload apache2   # Debian/Ubuntu"
    info "  # or set:  Protocols http/1.1"
  elif [[ "$HTTP2_MODULE_ENABLED" -eq 1 ]]; then
    VERDICT="LIKELY_EXPOSED"
    bad "LIKELY EXPOSED — vulnerable version + http2 configured to load (confirm reload/runtime)"
  elif [[ "$HTTP2_MODULE_AVAILABLE" -eq 1 ]]; then
    VERDICT="NOT_EXPOSED_CONFIG"
    ok "NOT EXPOSED (config) — version is in range but mod_http2 is not enabled/loaded"
    info "Package is still outdated; patch when convenient. Do not a2enmod http2 until patched."
  else
    VERDICT="NOT_EXPOSED_CONFIG"
    ok "NOT EXPOSED — version in range but no mod_http2 present/enabled"
  fi
else
  VERDICT="NOT_AFFECTED_VERSION"
  ok "NOT AFFECTED — Apache version outside 2.4.55–2.4.70 (or unknown/unparsed)"
fi

echo
echo "${BLD}Summary flags${RST}"
printf "  %-28s %s\n" "apache_installed:" "$APACHE_INSTALLED"
printf "  %-28s %s\n" "apache_running:" "$APACHE_RUNNING"
printf "  %-28s %s\n" "apache_version:" "${APACHE_VERSION:-n/a}"
printf "  %-28s %s\n" "version_in_cve_range:" "$APACHE_IN_RANGE"
printf "  %-28s %s\n" "version_patched_2.4.71+:" "$APACHE_FIXED"
printf "  %-28s %s\n" "http2_module_available:" "$HTTP2_MODULE_AVAILABLE"
printf "  %-28s %s\n" "http2_module_enabled:" "$HTTP2_MODULE_ENABLED"
printf "  %-28s %s\n" "http2_module_loaded:" "$HTTP2_MODULE_LOADED"
printf "  %-28s %s\n" "protocols_h2_in_enabled:" "$PROTOCOLS_H2_ENABLED"
printf "  %-28s %s\n" "nginx_http2_present:" "$NGINX_HTTP2"
printf "  %-28s %s\n" "verdict:" "$VERDICT"
echo

# Machine-readable one-liner for fleet grepping
echo "RESULT hostname=$(hostname -f 2>/dev/null || hostname) version=${APACHE_VERSION:-none} in_range=$APACHE_IN_RANGE http2_loaded=$HTTP2_MODULE_LOADED protocols_h2=$PROTOCOLS_H2_ENABLED nginx_http2=$NGINX_HTTP2 verdict=$VERDICT"

# Exit codes for automation:
#   0 = not exposed / N/A / patched
#   1 = exposed or likely exposed
#   2 = script error (set -e already covers most)
case "$VERDICT" in
  EXPOSED|LIKELY_EXPOSED) exit 1 ;;
  *) exit 0 ;;
esac
