#!/bin/bash
# ============================================================================ #
#  CLOUDWAYS / VARNISH CACHE AUDIT                                             #
#  Run on the server as root (London 167.71.138.182 or NY 161.35.127.98).      #
#  Read-only: inspects Varnish params, VCL TTL/grace, and per-vhost settings.  #
# ============================================================================ #

set -euo pipefail

echo "=========================================================="
echo " VARNISH SERVICE"
echo "=========================================================="
systemctl is-active varnish 2>/dev/null || true
varnishd -V 2>&1 | head -n 3

echo -e "\n=========================================================="
echo " GLOBAL TTL / GRACE / KEEP (why Age can exceed UI TTL)"
echo "=========================================================="
# default_grace: after object TTL expires, Varnish may still serve it as HIT
# and Age keeps climbing until the object is fetched again or discarded.
for P in default_ttl default_grace default_keep default_grace_ttl; do
    echo "--- param.show $P ---"
    varnishadm param.show "$P" 2>/dev/null || echo "(not available)"
done

echo -e "\n=========================================================="
echo " LOADED VCL (TTL / grace / beresp rules)"
echo "=========================================================="
varnishadm vcl.list 2>/dev/null || true
VCL=$(varnishadm vcl.list 2>/dev/null | awk '/available/ {print $3; exit}')
if [ -n "${VCL:-}" ]; then
    echo "Active VCL label: $VCL"
    varnishadm vcl.show "$VCL" 2>/dev/null | grep -nE 'ttl|grace|keep|Cache-Control|max-age|beresp|hash|purge|ban|return \(hit\)|stale' || true
else
    echo "Could not detect active VCL name; try: varnishadm vcl.list"
fi

echo -e "\n=========================================================="
echo " VCL FILES ON DISK"
echo "=========================================================="
for f in /etc/varnish/default.vcl /etc/varnish/*.vcl; do
    [ -f "$f" ] || continue
    echo "--- $f (ttl/grace lines) ---"
    grep -nE 'ttl|grace|keep|max-age|Cache-Control|beresp' "$f" 2>/dev/null || echo "(no matches)"
done

echo -e "\n=========================================================="
echo " PER-APPLICATION NGINX / CACHE HINTS"
echo "=========================================================="
for A in /home/master/applications/*/conf/server.nginx; do
    [ -f "$A" ] || continue
    APP=$(echo "$A" | cut -d/ -f5)
    DOM=$(awk 'NR==1{print substr($NF,1,length($NF)-1)}' "$A" 2>/dev/null)
    echo "--- App: $APP  Domain: $DOM ---"
    grep -nE 'cache|varnish|expires|fastcgi_cache|X-Cache|ttl' "$A" 2>/dev/null | head -n 15 || echo "(no cache directives in server.nginx snippet)"
done

echo -e "\n=========================================================="
echo " LIVE OBJECT TTL (replace HOST and PATH)"
echo "=========================================================="
cat <<'EOF'
# In one terminal, stream Varnish decisions for one URL:
varnishlog -g request -q 'ReqURL ~ "^/$"' -i ReqURL,ReqHeader,RespHeader,Hit,HitMiss,VCL_call,TTL,Grace,Age,Backend,BackendResp

# Or for a path:
varnishlog -g request -q 'ReqURL ~ "/jobs/"' -i ReqURL,Hit,HitMiss,TTL,Grace,Age,RespHeader

# One-shot: fetch via localhost with Host header (bypasses Cloudflare):
curl -sI -H 'Host: www.fialkov.co.il' "http://127.0.0.1/?bust=$(date +%s)" | grep -iE 'age|x-cache|cache-control'
EOF

echo -e "\n=========================================================="
echo " CACHE FOOTPRINT"
echo "=========================================================="
varnishstat -1 2>/dev/null | grep -E 'cache_hit|cache_miss|n_object|n_expired|grace|MAIN.cache' | head -n 25 || varnishstat -1 2>/dev/null | head -n 25

echo -e "\n=========================================================="
echo " BANS (stale content if purge failed)"
echo "=========================================================="
varnishadm ban.list 2>/dev/null | tail -n 20 || echo "ban.list not available"

echo -e "\n=========================================================="
echo " ORIGIN Cache-Control FROM PHP (per app docroot)"
echo "=========================================================="
cat <<'EOF'
# From app folder, compare what WordPress sends before Varnish rewrites it:
cd /home/master/applications/<APP_FOLDER>/public_html
curl -sI -H 'Host: www.example.com' "http://127.0.0.1/?nocache=$(date +%s)" | grep -i cache-control

# Breeze / platform TTL (if present):
grep -R "cache.*ttl\|TTL\|varnish" wp-content/plugins/breeze wp-content/breeze-config 2>/dev/null | head
EOF

echo -e "\n=========================================================="
echo " EXTERNAL Age vs expected TTL (from anywhere)"
echo "=========================================================="
cat <<'EOF'
for d in www.fialkov.co.il www.inbala.co.il www.dralmogvet.co.il www.orfialkov.co.il; do
  printf "%s " "$d"
  curl -sI "https://$d/" | awk 'tolower($1)=="age:"{print $2} tolower($1)=="x-cache:"{print $2}'
done
# Cache bust (should MISS, age 0):
curl -sI "https://www.fialkov.co.il/?bust=$(date +%s%N)" | grep -iE 'age|x-cache'
EOF

echo -e "\n=========================================================="
echo " END VARNISH AUDIT"
echo "=========================================================="
