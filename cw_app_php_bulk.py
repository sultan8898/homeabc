#!/usr/bin/env python3
"""
Cloudways per-application PHP version audit and bulk update.

Uses the same auth model as sl_enable_cronoptimizer.py:
  CW_ACCESS_TOKEN (cw_... Bearer on API v2), or CW_EMAIL + CW_API_KEY (OAuth).

Primary update (API v2 playground):
  POST /apps/{app_id}/php/version
  JSON: {"version": "8.3"}   # field is "version", not "php_version"
  (optional server_id)

Use --debug --stop-on-fail to print every probe result.

Audit:
  GET /server — apps may omit php_version; on-server reads applications.fact /
  .php_version when available.

Playground (https://developers.cloudways.com/docs/ → Playground):
  1. Authorize (OAuth or paste cw_ token).
  2. GET /server — note server id, app id.
  3. POST /apps/{app_id}/php/version with server_id + php_version.
  4. GET /operation/{operation_id} until is_completed=1.

Examples:
  # All servers → 8.3 (dry-run)
  curl -fsSL '.../cw_app_php_bulk.py' | CW_ACCESS_TOKEN='cw_...' python3 - \\
    --all-servers --apply --target 8.3 --dry-run

  # Only apps currently on 7.4 → 8.3
  ... python3 - --all-servers --apply --from-php 7.4 --target 8.3

  # Upgrade all except leave 8.2 alone
  ... python3 - --all-servers --apply --skip-php 8.2 --target 8.3

Env: CW_ACCESS_TOKEN, or CW_EMAIL + CW_API_KEY
"""

from __future__ import annotations

import argparse
import csv
import getpass
import hashlib
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urljoin, urlparse

import requests

API_V1 = "https://api.cloudways.com/api/v1"
API_V2 = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600
POLL_INTERVAL = 10
POLL_TIMEOUT = 900
INPROG_WAIT = 10
INPROG_MAX = 60
RATE_SLEEP = 8
HEALTH_PAGE_COUNT = 3
HEALTH_FETCH_TIMEOUT = 25
HEALTH_USER_AGENT = (
    "Mozilla/5.0 (compatible; CloudwaysPHPHealthCheck/1.0; +https://platform.cloudways.com)"
)

APPS_ROOT = Path("/home/master/applications")
APP_FQDN_RE = re.compile(r"[a-zA-Z0-9_]+-(\d+)-(\d+)\.cloudwaysapps\.com")
TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)
HREF_RE = re.compile(r"""href\s*=\s*["']([^"'#]+)["']""", re.I)
SKIP_HREF_RE = re.compile(
    r"\.(?:css|js|png|jpe?g|gif|svg|webp|ico|pdf|zip|woff2?|ttf|eot|mp4|mp3)(?:\?|$)",
    re.I,
)

_token_cache: dict[str, Any] = {"token": None, "expires_at": None, "api_base": None}


def is_access_token(value: str) -> bool:
    return value.startswith("cw_")


def auth_headers(token: str) -> dict[str, str]:
    return {"Accept": "application/json", "Authorization": f"Bearer {token}"}


def fetch_oauth_token(email: str, api_key: str, api_base: str) -> Optional[str]:
    now = datetime.utcnow()
    if (
        _token_cache["token"]
        and _token_cache["expires_at"]
        and _token_cache["api_base"] == api_base
        and now < _token_cache["expires_at"]
    ):
        return _token_cache["token"]

    try:
        resp = requests.post(
            f"{api_base}/oauth/access_token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"email": email, "api_key": api_key},
            timeout=30,
        )
        if resp.status_code >= 400:
            print(f"[auth] OAuth failed ({api_base}): HTTP {resp.status_code} {resp.text[:300]}")
            return None
        token = resp.json().get("access_token")
    except requests.RequestException as exc:
        print(f"[auth] OAuth error ({api_base}): {exc}")
        return None

    if not token:
        return None
    _token_cache["token"] = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    _token_cache["api_base"] = api_base
    return token


def resolve_auth(email: str, secret: str) -> tuple[str, str]:
    if is_access_token(secret):
        return secret, API_V2
    if not email:
        print("[ERROR] CW_EMAIL is required with a legacy API key.")
        sys.exit(1)
    for api_base in (API_V2, API_V1):
        token = fetch_oauth_token(email, secret, api_base)
        if token:
            return token, api_base
    print("[ERROR] Could not obtain OAuth token.")
    sys.exit(1)


def load_credentials() -> tuple[str, str]:
    env_token = os.environ.get("CW_ACCESS_TOKEN", "").strip()
    if env_token:
        return "", env_token
    env_email = os.environ.get("CW_EMAIL", "").strip()
    env_key = os.environ.get("CW_API_KEY", "").strip()
    if env_key:
        return env_email, env_key

    print("Auth: cw_ access token OR email + legacy API key (https://platform.cloudways.com/api)")
    secret = getpass.getpass("Access token / API key: ").strip()
    if not secret:
        sys.exit("[ERROR] Token or API key required.")
    if is_access_token(secret):
        return "", secret
    email = input("Email: ").strip()
    if not email:
        sys.exit("[ERROR] Email required with legacy API key.")
    return email, secret


def normalize_php_version(raw: str) -> str:
    if not raw:
        return ""
    s = str(raw).strip().lower()
    s = s.removeprefix("php")
    m = re.search(r"(\d+\.\d+)", s)
    return m.group(1) if m else s


def app_php_from_api(app: dict) -> str:
    for key in ("php_version", "phpVersion", "php"):
        if app.get(key):
            return normalize_php_version(str(app[key]))
    return ""


APPLICATIONS_FACT = Path("/etc/ansible/facts.d/applications.fact")


def parse_app_php_from_facts(text: str) -> dict[str, str]:
    """Parse [app_php_version] from applications.fact."""
    versions: dict[str, str] = {}
    in_section = False
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            in_section = line[1:-1].strip().lower() == "app_php_version"
            continue
        if not in_section or "=" not in line:
            continue
        key, val = line.split("=", 1)
        su = key.strip()
        php = normalize_php_version(val)
        if su and php:
            versions[su] = php
    return versions


def read_local_facts_php() -> dict[str, str]:
    try:
        return parse_app_php_from_facts(APPLICATIONS_FACT.read_text(errors="ignore"))
    except OSError:
        return {}


def local_php_version(sys_user: str, facts_map: Optional[dict[str, str]] = None) -> str:
    if not sys_user:
        return ""
    if facts_map and facts_map.get(sys_user):
        return facts_map[sys_user]
    if APPLICATIONS_FACT.is_file():
        mapped = read_local_facts_php().get(sys_user)
        if mapped:
            return mapped
    base = APPS_ROOT / sys_user
    dot = base / ".php_version"
    if dot.is_file():
        return normalize_php_version(dot.read_text(errors="ignore"))
    shim = base / ".cw" / "bin" / "php"
    if shim.is_symlink():
        target = os.readlink(shim)
        return normalize_php_version(target)
    return ""


def parse_servers_payload(payload: Any) -> list[dict]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("servers", "data"):
        val = payload.get(key)
        if isinstance(val, list):
            return [x for x in val if isinstance(x, dict)]
        if isinstance(val, dict) and isinstance(val.get("servers"), list):
            return [x for x in val["servers"] if isinstance(x, dict)]
    return []


def fetch_all_servers(token: str, api_base: str) -> list[dict]:
    servers: list[dict] = []
    seen: set[str] = set()

    for path in ("server", "servers"):
        url: Optional[str] = f"{api_base}/{path}"
        while url:
            try:
                resp = requests.get(url, headers=auth_headers(token), timeout=90)
                if resp.status_code >= 400:
                    break
                payload = resp.json()
            except (requests.RequestException, ValueError):
                break
            for srv in parse_servers_payload(payload):
                sid = str(srv.get("id", ""))
                if sid and sid not in seen:
                    seen.add(sid)
                    servers.append(srv)
            url = None
            if isinstance(payload, dict):
                pag = payload.get("pagination") or {}
                for key in ("next", "next_page_url", "next_url"):
                    nxt = pag.get(key) or payload.get(key)
                    if nxt:
                        url = str(nxt)
                        break
        if servers:
            break
    return servers


def fetch_server(token: str, api_base: str, server_id: str) -> Optional[dict]:
    for path in (f"servers/{server_id}", f"server/{server_id}"):
        try:
            resp = requests.get(f"{api_base}/{path}", headers=auth_headers(token), timeout=60)
            if resp.status_code >= 400:
                continue
            payload = resp.json()
            if isinstance(payload, dict):
                for key in ("server", "data"):
                    inner = payload.get(key)
                    if isinstance(inner, dict):
                        return inner
                if str(payload.get("id", "")) == str(server_id):
                    return payload
        except (requests.RequestException, ValueError):
            continue
    return None


def detect_server_id() -> str:
    if not APPS_ROOT.is_dir():
        return ""
    for conf in APPS_ROOT.glob("*/conf/server.nginx"):
        try:
            m = APP_FQDN_RE.search(conf.read_text(errors="ignore"))
            if m:
                return m.group(1)
        except OSError:
            continue
    return ""


def fetch_application_records(token: str, api_base: str) -> list[dict]:
    """GET /applications (v2) — apps often listed here without nested /server.apps."""
    records: list[dict] = []
    for path in ("applications", "apps"):
        url: Optional[str] = f"{api_base}/{path}"
        while url:
            try:
                resp = requests.get(url, headers=auth_headers(token), timeout=90)
                if resp.status_code >= 400:
                    break
                payload = resp.json()
            except (requests.RequestException, ValueError):
                break
            chunk = []
            if isinstance(payload, dict):
                chunk = payload.get("applications") or payload.get("apps") or []
            if isinstance(chunk, list):
                records.extend(a for a in chunk if isinstance(a, dict))
            url = None
            if isinstance(payload, dict):
                pag = payload.get("pagination") or {}
                for key in ("next", "next_page_url", "next_url"):
                    nxt = pag.get(key) or payload.get(key)
                    if nxt:
                        url = str(nxt)
                        break
        if records:
            break
    return records


def local_ids_for_sys_user(sys_user: str) -> tuple[str, str]:
    """On-server: parse server_id and app_id from cloudwaysapps FQDN in nginx."""
    conf = APPS_ROOT / sys_user / "conf" / "server.nginx"
    if not conf.is_file():
        return "", ""
    try:
        m = APP_FQDN_RE.search(conf.read_text(errors="ignore"))
        if m:
            return m.group(1), m.group(2)
    except OSError:
        pass
    return "", ""


def build_app_rows(
    token: str,
    api_base: str,
    servers: list[dict],
    *,
    server_id: str = "",
    include_staging: bool = False,
) -> list[dict]:
    """Merge /applications records with /server payloads and local nginx IDs."""
    server_labels = {
        str(s.get("id", "")): s.get("label") or s.get("server_label") or str(s.get("id", ""))
        for s in servers
    }
    nested = iter_apps(
        servers,
        server_id=server_id,
        include_staging=include_staging,
    )
    by_key: dict[tuple[str, str], dict] = {}
    for r in nested:
        by_key[(r["server_id"], r["app_id"])] = r

    api_apps = fetch_application_records(token, api_base)
    for app in api_apps:
        sid = str(app.get("server_id") or app.get("serverId") or app.get("server") or "")
        aid = str(app.get("id") or app.get("app_id") or "")
        if not aid:
            continue
        if server_id and sid and sid != str(server_id):
            continue
        if not include_staging and str(app.get("is_staging", "0")) == "1":
            continue
        sys_user = str(app.get("sys_user") or app.get("sysUser") or "")
        api_php = app_php_from_api(app)
        local_php = local_php_version(sys_user)
        if not sid and sys_user:
            sid, aid_from_nginx = local_ids_for_sys_user(sys_user)
            if aid_from_nginx and not aid:
                aid = aid_from_nginx
        row = {
            "server_id": sid,
            "server_label": server_labels.get(sid, sid),
            "app_id": aid,
            "label": app.get("label") or app.get("app_label") or sys_user,
            "application": str(app.get("application", "")),
            "sys_user": sys_user,
            "cname": app.get("cname") or app.get("app_fqdn") or "",
            "php_api": api_php,
            "php_local": local_php,
            "php_effective": local_php or api_php,
        }
        key = (row["server_id"], row["app_id"])
        if key in by_key:
            prev = by_key[key]
            for field in ("php_api", "php_local", "php_effective", "sys_user", "cname", "label"):
                if not prev.get(field) and row.get(field):
                    prev[field] = row[field]
        else:
            by_key[key] = row

    if APPS_ROOT.is_dir() and server_id:
        for conf in APPS_ROOT.glob("*/conf/server.nginx"):
            sys_user = conf.parent.parent.name
            sid_l, aid_l = local_ids_for_sys_user(sys_user)
            if server_id and sid_l and sid_l != str(server_id):
                continue
            if not sid_l or not aid_l:
                continue
            key = (sid_l, aid_l)
            if key not in by_key:
                by_key[key] = {
                    "server_id": sid_l,
                    "server_label": server_labels.get(sid_l, sid_l),
                    "app_id": aid_l,
                    "label": sys_user,
                    "application": "",
                    "sys_user": sys_user,
                    "cname": "",
                    "php_api": "",
                    "php_local": local_php_version(sys_user),
                    "php_effective": local_php_version(sys_user),
                }

    return sorted(by_key.values(), key=lambda r: (r["server_id"], r["sys_user"] or r["label"]))


def parse_php_list(raw: str) -> set[str]:
    """Comma/space-separated PHP versions -> normalized set, e.g. '7.4,8.0'."""
    out: set[str] = set()
    for part in (raw or "").replace(",", " ").split():
        v = normalize_php_version(part)
        if v:
            out.add(v)
    return out


def filter_rows(
    rows: list[dict],
    *,
    sys_users: set[str],
    from_php: str,
    skip_php: str = "",
) -> list[dict]:
    out = rows
    if sys_users:
        out = [r for r in out if r.get("sys_user") in sys_users]
    from_set = parse_php_list(from_php)
    if from_set:
        out = [
            r
            for r in out
            if normalize_php_version(r.get("php_effective") or r.get("php_api") or "")
            in from_set
        ]
    skip_set = parse_php_list(skip_php)
    if skip_set:
        out = [
            r
            for r in out
            if normalize_php_version(r.get("php_effective") or r.get("php_api") or "")
            not in skip_set
        ]
    return out


def iter_apps(
    servers: list[dict],
    *,
    server_id: str = "",
    include_staging: bool = False,
) -> list[dict]:
    rows: list[dict] = []
    for srv in servers:
        sid = str(srv.get("id", ""))
        if server_id and sid != str(server_id):
            continue
        s_label = srv.get("label") or srv.get("server_label") or sid
        public_ip = str(srv.get("public_ip") or srv.get("ip") or "").strip()
        for app in srv.get("apps") or []:
            if not isinstance(app, dict):
                continue
            if not include_staging and str(app.get("is_staging", "0")) == "1":
                continue
            sys_user = str(app.get("sys_user") or app.get("sysUser") or "")
            api_php = app_php_from_api(app)
            local_php = local_php_version(sys_user)
            rows.append(
                {
                    "server_id": sid,
                    "server_label": s_label,
                    "server_ip": public_ip,
                    "app_id": str(app.get("id", "")),
                    "label": app.get("label") or app.get("app_label") or sys_user,
                    "application": str(app.get("application", "")),
                    "sys_user": sys_user,
                    "cname": app.get("cname") or app.get("app_fqdn") or "",
                    "app_fqdn": app.get("app_fqdn") or "",
                    "php_api": api_php,
                    "php_local": local_php,
                    "php_effective": local_php or api_php,
                }
            )
    return rows


def wait_for_operation(op_id: str, token: str, api_base: str) -> tuple[bool, str]:
    url = f"{api_base}/operation/{op_id}"
    deadline = time.time() + POLL_TIMEOUT
    while time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        try:
            resp = requests.get(url, headers=auth_headers(token), timeout=30)
            resp.raise_for_status()
            data = resp.json()
        except requests.RequestException as exc:
            print(f"    [poll] {exc}; retrying ...")
            continue
        op = data.get("operation") or {}
        done = str(op.get("is_completed", "0"))
        status = str(op.get("status", ""))
        message = str(op.get("message", ""))
        print(f"    [poll] {op_id} completed={done} status={status!r}")
        if done == "1":
            combined = (status + " " + message).lower()
            if "complete" in combined or "success" in combined:
                return True, status or message
            return False, status or message or "operation finished with error"
    return False, "timed out waiting for operation"


def app_primary_host(row: dict) -> str:
    """Prefer custom CNAME; fall back to cloudwaysapps FQDN."""
    for key in ("cname", "app_fqdn", "label"):
        val = str(row.get(key) or "").strip()
        if not val:
            continue
        # label may be a domain already
        host = val
        if "://" in host:
            host = urlparse(host).hostname or ""
        host = host.split("/")[0].strip().lower().rstrip(".")
        if host and "." in host and " " not in host:
            return host
    return ""


def resolve_dns(host: str) -> dict[str, Any]:
    """Resolve A/AAAA and best-effort CNAME for host."""
    info: dict[str, Any] = {"host": host, "cname": "", "a": [], "aaaa": [], "error": ""}
    if not host:
        info["error"] = "empty host"
        return info

    # CNAME via dig/host when available
    for cmd in (
        ["dig", "+short", "CNAME", host],
        ["host", "-t", "CNAME", host],
    ):
        if not shutil_which(cmd[0]):
            continue
        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=8,
            )
            out = (proc.stdout or "").strip()
            if cmd[0] == "dig" and out:
                info["cname"] = out.splitlines()[0].strip().rstrip(".")
                break
            if cmd[0] == "host" and "is an alias for" in out:
                info["cname"] = out.split("is an alias for")[-1].strip().rstrip(".")
                break
        except (OSError, subprocess.TimeoutExpired):
            continue

    try:
        for fam, _, _, _, sockaddr in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM):
            if fam == socket.AF_INET:
                ip = sockaddr[0]
                if ip not in info["a"]:
                    info["a"].append(ip)
            elif fam == socket.AF_INET6:
                ip = sockaddr[0]
                if ip not in info["aaaa"]:
                    info["aaaa"].append(ip)
    except socket.gaierror as exc:
        info["error"] = str(exc)
    return info


def shutil_which(name: str) -> Optional[str]:
    return shutil.which(name)


def normalize_html_for_hash(html: str) -> str:
    """Strip noisy bits so pre/post hashes stay stable across cache/csrf noise."""
    text = html or ""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(
        r"<script\b[^>]*>.*?</script>",
        "",
        text,
        flags=re.I | re.S,
    )
    text = re.sub(r"<style\b[^>]*>.*?</style>", "", text, flags=re.I | re.S)
    text = re.sub(r"\s+", " ", text)
    return text.strip().lower()


def extract_title(html: str) -> str:
    m = TITLE_RE.search(html or "")
    if not m:
        return ""
    return re.sub(r"\s+", " ", m.group(1)).strip()[:200]


def fetch_page(url: str) -> dict[str, Any]:
    """Fetch one URL; return status/title/hash/final_url."""
    rec: dict[str, Any] = {
        "url": url,
        "final_url": "",
        "status": 0,
        "title": "",
        "hash": "",
        "error": "",
    }
    try:
        resp = requests.get(
            url,
            headers={"User-Agent": HEALTH_USER_AGENT, "Accept": "text/html,application/xhtml+xml"},
            timeout=HEALTH_FETCH_TIMEOUT,
            allow_redirects=True,
            verify=True,
        )
        rec["status"] = int(resp.status_code)
        rec["final_url"] = str(resp.url or url)
        ctype = (resp.headers.get("Content-Type") or "").lower()
        body = resp.text if "html" in ctype or not ctype else ""
        if not body and resp.content:
            try:
                body = resp.content.decode("utf-8", errors="ignore")
            except Exception:
                body = ""
        rec["title"] = extract_title(body)
        digest = hashlib.sha256(normalize_html_for_hash(body).encode("utf-8", errors="ignore"))
        rec["hash"] = digest.hexdigest()[:16]
    except requests.RequestException as exc:
        rec["error"] = str(exc)[:200]
    return rec


def discover_sample_urls(base_url: str, count: int = HEALTH_PAGE_COUNT) -> list[str]:
    """Homepage + up to (count-1) random same-host HTML links."""
    count = max(1, min(int(count), 5))
    urls = [base_url.rstrip("/") + "/"]
    home = fetch_page(urls[0])
    html = ""
    if not home.get("error") and home.get("status", 0):
        # Need raw HTML again for links — light second fetch already have title/hash;
        # re-request body via requests for link discovery only when home worked.
        try:
            resp = requests.get(
                urls[0],
                headers={"User-Agent": HEALTH_USER_AGENT, "Accept": "text/html"},
                timeout=HEALTH_FETCH_TIMEOUT,
                allow_redirects=True,
            )
            html = resp.text or ""
            base_url = str(resp.url or base_url)
            urls[0] = base_url if base_url.endswith("/") else base_url.rstrip("/") + "/"
        except requests.RequestException:
            html = ""

    host = (urlparse(urls[0]).hostname or "").lower()
    candidates: list[str] = []
    seen = {urls[0].rstrip("/")}
    for href in HREF_RE.findall(html):
        href = href.strip()
        if not href or href.startswith(("mailto:", "tel:", "javascript:", "data:")):
            continue
        if SKIP_HREF_RE.search(href):
            continue
        abs_url = urljoin(urls[0], href)
        parsed = urlparse(abs_url)
        if parsed.scheme not in ("http", "https"):
            continue
        if (parsed.hostname or "").lower() != host:
            continue
        clean = f"{parsed.scheme}://{parsed.netloc}{parsed.path or '/'}"
        if parsed.query:
            clean += "?" + parsed.query
        key = clean.rstrip("/")
        if key in seen:
            continue
        seen.add(key)
        candidates.append(clean)

    random.shuffle(candidates)
    for u in candidates:
        if len(urls) >= count:
            break
        urls.append(u)
    return urls[:count]


def capture_site_baseline(
    row: dict,
    *,
    page_count: int = HEALTH_PAGE_COUNT,
    server_ip: str = "",
) -> dict[str, Any]:
    """DNS + 2-3 page snapshots before PHP change."""
    host = app_primary_host(row)
    result: dict[str, Any] = {
        "host": host,
        "dns": {},
        "pages": [],
        "ok": False,
        "error": "",
    }
    if not host:
        result["error"] = "no domain/cname for app"
        return result

    dns = resolve_dns(host)
    result["dns"] = dns
    cname = dns.get("cname") or ""
    a_recs = dns.get("a") or []
    print(
        f"    [health] DNS {host}"
        + (f" CNAME={cname}" if cname else "")
        + (f" A={','.join(a_recs[:3])}" if a_recs else "")
        + (f" err={dns.get('error')}" if dns.get("error") else "")
    )
    if server_ip and a_recs and server_ip not in a_recs:
        print(
            f"    [health] note: A record {a_recs[0]} != server public_ip {server_ip} "
            "(CDN/proxy or different IP OK)"
        )

    base = f"https://{host}"
    sample_urls = discover_sample_urls(base, count=page_count)
    pages = [fetch_page(u) for u in sample_urls]
    result["pages"] = pages
    ok_pages = [p for p in pages if not p.get("error") and 200 <= int(p.get("status") or 0) < 400]
    for p in pages:
        if p.get("error"):
            print(f"    [health] GET {p['url']} ERR {p['error']}")
        else:
            print(
                f"    [health] GET {p['url']} -> {p['status']} "
                f"title={p.get('title')!r:.60} hash={p.get('hash')}"
            )
    if not ok_pages:
        result["error"] = "no reachable sample pages before upgrade"
        return result
    result["ok"] = True
    return result


def compare_site_snapshots(
    before: dict[str, Any],
    after_pages: list[dict[str, Any]],
    *,
    soft: bool = False,
) -> tuple[bool, list[str]]:
    """
    Compare pre/post page snapshots.
    Strict: status + title + content hash.
    Soft: both reachable (2xx/3xx) + same title.
    """
    notes: list[str] = []
    pre_pages = [p for p in (before.get("pages") or []) if not p.get("error")]
    if not pre_pages:
        return False, ["no baseline pages"]
    by_url = {p.get("url"): p for p in after_pages}
    matched = 0
    for pre in pre_pages:
        url = pre.get("url")
        post = by_url.get(url)
        if not post:
            notes.append(f"missing after fetch for {url}")
            continue
        if post.get("error"):
            notes.append(f"after error {url}: {post['error']}")
            continue
        pre_st = int(pre.get("status") or 0)
        post_st = int(post.get("status") or 0)
        if soft:
            if not (200 <= pre_st < 400 and 200 <= post_st < 400):
                notes.append(f"status class mismatch {url}: {pre_st} -> {post_st}")
                continue
            if (pre.get("title") or "") != (post.get("title") or ""):
                notes.append(
                    f"title mismatch {url}: {pre.get('title')!r} -> {post.get('title')!r}"
                )
                continue
        else:
            if pre_st != post_st:
                notes.append(f"status mismatch {url}: {pre_st} -> {post_st}")
                continue
            if (pre.get("title") or "") != (post.get("title") or ""):
                notes.append(
                    f"title mismatch {url}: {pre.get('title')!r} -> {post.get('title')!r}"
                )
                continue
            if (pre.get("hash") or "") != (post.get("hash") or ""):
                notes.append(
                    f"content hash mismatch {url}: {pre.get('hash')} -> {post.get('hash')}"
                )
                continue
        matched += 1
        print(
            f"    [health] OK match {url} status={post_st} "
            f"title={post.get('title')!r:.50}"
        )
    ok = matched == len(pre_pages) and not notes
    return ok, notes


def recheck_site_after(before: dict[str, Any]) -> list[dict[str, Any]]:
    urls = [p.get("url") for p in (before.get("pages") or []) if p.get("url")]
    return [fetch_page(u) for u in urls]


def post_php_version(
    token: str,
    api_base: str,
    server_id: str,
    app_id: str,
    target: str,
    *,
    debug: bool = False,
) -> tuple[Optional[str], str]:
    """
    Update per-app PHP version. Return (operation_id, error).

    Cloudways has shifted routes/methods; 405 means wrong HTTP method on that
    path. Try PUT and POST on manage + playground apps/.../php/version.
    """
    # Playground POST /apps/{id}/php/version expects field name "version"
    # (422 "Version is required" when only php_version is sent).
    sid_i = int(server_id) if str(server_id).isdigit() else server_id
    aid_i = int(app_id) if str(app_id).isdigit() else app_id

    form_php = {"server_id": str(server_id), "app_id": str(app_id), "php_version": target}
    form_ver = {"server_id": str(server_id), "app_id": str(app_id), "version": target}
    form_ver_i = {"server_id": sid_i, "app_id": aid_i, "version": target}

    json_ver_min = {"version": target}
    json_ver_srv = {"version": target, "server_id": sid_i}
    json_ver_full = {"version": target, "server_id": sid_i, "app_id": aid_i}
    json_php_min = {"php_version": target}
    json_php_srv = {"php_version": target, "server_id": sid_i}
    json_php_full = {"php_version": target, "server_id": sid_i, "app_id": aid_i}
    # Some gateways accept both keys
    json_both = {"version": target, "php_version": target, "server_id": sid_i}

    ctype_form = {"Content-Type": "application/x-www-form-urlencoded"}
    ctype_json = {"Content-Type": "application/json"}

    # Working path from probe: POST /apps/{id}/php/version (needs "version")
    attempts: list[tuple[str, str, dict, Any]] = [
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_ver_min),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_ver_srv),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_ver_full),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_both),
        ("POST", f"{API_V2}/apps/{app_id}/php/version?server_id={server_id}", ctype_json, json_ver_min),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_form, form_ver),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_form, form_ver_i),
        ("PUT", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_ver_min),
        ("PUT", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_ver_srv),
        ("POST", f"{API_V2}/applications/{app_id}/php/version", ctype_json, json_ver_min),
        ("POST", f"{API_V2}/applications/{app_id}/php/version", ctype_json, json_ver_srv),
        # Legacy field name php_version (kept as fallback)
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_php_min),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_php_srv),
        ("POST", f"{API_V2}/apps/{app_id}/php/version", ctype_json, json_php_full),
        ("POST", f"{API_V2}/app/manage/php_version", ctype_form, form_php),
        ("PUT", f"{API_V2}/app/manage/php_version", ctype_form, form_php),
        ("POST", f"{API_V1}/app/manage/php_version", ctype_form, form_php),
        ("PUT", f"{API_V1}/app/manage/php_version", ctype_form, form_php),
    ]

    probe_log: list[str] = []
    last_err = ""
    for method, url, extra_headers, body in attempts:
        headers = {**auth_headers(token), **extra_headers}
        for attempt in range(INPROG_MAX):
            try:
                if extra_headers.get("Content-Type") == "application/x-www-form-urlencoded":
                    resp = requests.request(method, url, headers=headers, data=body, timeout=45)
                else:
                    resp = requests.request(method, url, headers=headers, json=body, timeout=45)
            except requests.RequestException as exc:
                last_err = f"{method} {url}: {exc}"
                probe_log.append(last_err)
                break

            try:
                payload = resp.json()
            except ValueError:
                payload = {"raw": (resp.text or "")[:400]}

            message = str(payload.get("message", ""))
            if message.startswith("An operation is already in progress"):
                print(f"    [wait] Server busy, retry {attempt + 1}/{INPROG_MAX} ...")
                time.sleep(INPROG_WAIT)
                continue

            short = f"{method} {url} -> HTTP {resp.status_code}"
            if resp.status_code in (200, 201, 202):
                op_id = payload.get("operation_id") or payload.get("operationId")
                if op_id:
                    if debug:
                        print(f"    [ok] {short} operation_id={op_id}")
                    return str(op_id), ""
                if payload.get("status") is True or str(payload.get("status", "")).lower() == "success":
                    if debug:
                        print(f"    [ok] {short} status=success")
                    return "", ""
                op = payload.get("operation") or {}
                if isinstance(op, dict) and op.get("id"):
                    return str(op.get("id")), ""
                last_err = f"{short} {payload}"
                probe_log.append(last_err)
                break

            # Keep probing on 404/405 (wrong path/method)
            last_err = f"{short} {payload}"
            probe_log.append(last_err)
            if debug or resp.status_code not in (404, 405):
                # Show non-404/405 immediately (403/422 are actionable)
                if resp.status_code not in (404, 405):
                    print(f"    [probe] {short} {str(payload)[:180]}")
            if resp.status_code in (404, 405):
                break
            # 403/401/422 — still try other shapes once, but record
            break

    if debug and probe_log:
        print("    [probe] tried {} candidate(s):".format(len(probe_log)))
        for line in probe_log[:12]:
            print("      - {}".format(line[:200]))
        if len(probe_log) > 12:
            print("      - ... {} more".format(len(probe_log) - 12))

    # Prefer first non-405 error if any (more informative than final legacy 405)
    preferred = ""
    for line in probe_log:
        if "HTTP 405" not in line:
            preferred = line
            break
    return None, preferred or last_err or "no endpoint accepted the request"


def print_audit_table(rows: list[dict], csv_out: bool) -> None:
    if csv_out:
        w = csv.writer(sys.stdout)
        w.writerow(
            [
                "server_id",
                "server_label",
                "app_id",
                "label",
                "application",
                "sys_user",
                "cname",
                "php_api",
                "php_local",
                "php_effective",
            ]
        )
        for r in rows:
            w.writerow(
                [
                    r["server_id"],
                    r["server_label"],
                    r["app_id"],
                    r["label"],
                    r["application"],
                    r["sys_user"],
                    r["cname"],
                    r["php_api"],
                    r["php_local"],
                    r["php_effective"],
                ]
            )
        return

    print(f"{'server':>8}  {'app':>8}  {'php':>5}  {'local':>5}  label / domain")
    print("-" * 72)
    for r in rows:
        print(
            f"{r['server_id']:>8}  {r['app_id']:>8}  "
            f"{r['php_api'] or '-':>5}  {r['php_local'] or '-':>5}  "
            f"{r['label']}  ({r['cname'] or r['sys_user']})"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Audit or bulk-set per-app PHP on Cloudways.")
    parser.add_argument("--server-id", help="Limit to one server (auto-detected on-server if omitted)")
    parser.add_argument("--all-servers", action="store_true", help="Include every server in the account")
    parser.add_argument("--audit", action="store_true", help="List current PHP per app (default if neither audit nor apply)")
    parser.add_argument("--apply", action="store_true", help="Change PHP version where it differs from --target")
    parser.add_argument("--target", default="8.3", help="Desired PHP version, e.g. 8.3 (default: 8.3)")
    parser.add_argument("--dry-run", action="store_true", help="With --apply, only print planned changes")
    parser.add_argument("--include-staging", action="store_true", help="Include staging apps")
    parser.add_argument("--csv", action="store_true", help="CSV output for --audit")
    parser.add_argument(
        "--sys-users",
        help="Comma-separated sys_user folder names (e.g. anwynsdpyw,csythsnghw)",
    )
    parser.add_argument(
        "--from-php",
        help="Only apps currently on these PHP version(s), comma-separated "
             "(e.g. 7.4 or 7.4,8.0). Matches facts/API php.",
    )
    parser.add_argument(
        "--skip-php",
        help="Skip apps currently on these PHP version(s), comma-separated "
             "(e.g. 8.2,8.3). Apps already on --target are always skipped.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Print each PHP-update API probe attempt (method/URL/status)",
    )
    parser.add_argument(
        "--stop-on-fail",
        action="store_true",
        help="With --apply, stop after the first failed update (useful with --debug)",
    )
    parser.add_argument(
        "--no-health-check",
        action="store_true",
        help="Disable before/after HTTP page comparison (enabled by default on --apply)",
    )
    parser.add_argument(
        "--health-pages",
        type=int,
        default=HEALTH_PAGE_COUNT,
        metavar="N",
        help="Number of pages to sample (default: 3, max 5)",
    )
    parser.add_argument(
        "--health-soft",
        action="store_true",
        help="Softer compare: require reachable + same <title>, ignore body hash",
    )
    parser.add_argument(
        "--health-allow-unreachable",
        action="store_true",
        help="Still upgrade if pre-check cannot reach the site",
    )
    args = parser.parse_args()
    args.health_check = not args.no_health_check

    if not args.audit and not args.apply:
        args.audit = True

    target = normalize_php_version(args.target)
    if not target:
        sys.exit("[ERROR] Invalid --target")

    email, secret = load_credentials()
    token, api_base = resolve_auth(email, secret)

    server_id = args.server_id or ""
    if not args.all_servers and not server_id:
        server_id = detect_server_id()

    if args.all_servers:
        servers = fetch_all_servers(token, api_base)
    elif server_id:
        one = fetch_server(token, api_base, server_id)
        servers = [one] if one else []
        if not servers:
            servers = [s for s in fetch_all_servers(token, api_base) if str(s.get("id")) == str(server_id)]
    else:
        print("[ERROR] Pass --server-id, run on a Cloudways server, or use --all-servers.")
        sys.exit(1)

    if not servers:
        sys.exit("[ERROR] No servers returned — check token scope and server id.")

    scope_server = "" if args.all_servers else server_id
    rows = build_app_rows(
        token,
        api_base,
        servers,
        server_id=scope_server,
        include_staging=args.include_staging,
    )
    sys_user_filter: set[str] = set()
    if args.sys_users:
        sys_user_filter = {u.strip() for u in args.sys_users.split(",") if u.strip()}
    rows = filter_rows(
        rows,
        sys_users=sys_user_filter,
        from_php=args.from_php or "",
        skip_php=args.skip_php or "",
    )
    if not rows:
        sys.exit("[ERROR] No applications found for the given scope.")

    if args.audit and not args.apply:
        print_audit_table(rows, args.csv)
        need = [r for r in rows if normalize_php_version(r["php_effective"]) != target]
        if not args.csv and need:
            print()
            print(f"Apps not on PHP {target}: {len(need)}")
        return

    if args.apply:
        pending = [r for r in rows if normalize_php_version(r["php_effective"]) != target]
        if sys_user_filter or args.from_php or args.skip_php:
            print(
                f"Filtered scope: {len(rows)} app(s)"
                + (f", sys_users={len(sys_user_filter)}" if sys_user_filter else "")
                + (f", from_php={args.from_php}" if args.from_php else "")
                + (f", skip_php={args.skip_php}" if args.skip_php else "")
            )
        print(f"Target PHP {target} — {len(pending)} app(s) to update, {len(rows) - len(pending)} already match.")
        if args.health_check and not args.dry_run:
            print(
                f"Health check ON: DNS + {args.health_pages} page(s) before/after "
                f"({'soft' if args.health_soft else 'strict'} compare)."
            )
        ok = fail = health_fail = skipped = 0
        for idx, r in enumerate(pending, 1):
            print(
                f"[{idx}/{len(pending)}] server={r['server_id']} app={r['app_id']} "
                f"{r['label']} {r['php_effective'] or '?'} -> {target}"
            )
            if args.dry_run:
                if args.health_check:
                    host = app_primary_host(r)
                    print(f"    [dry-run] would health-check https://{host or '?'} then upgrade")
                continue

            baseline: dict[str, Any] = {}
            if args.health_check:
                baseline = capture_site_baseline(
                    r,
                    page_count=args.health_pages,
                    server_ip=str(r.get("server_ip") or ""),
                )
                if not baseline.get("ok"):
                    print(f"    [health] pre-check failed: {baseline.get('error') or 'unknown'}")
                    if not args.health_allow_unreachable:
                        print("    x skip upgrade (site not reachable for baseline)")
                        skipped += 1
                        fail += 1
                        if args.stop_on_fail:
                            break
                        continue
                    print("    [health] continuing anyway (--health-allow-unreachable)")

            # Always debug-probe on the first failure so 405 noise is diagnosable
            debug_this = bool(args.debug or fail == 0)
            op_id, err = post_php_version(
                token,
                api_base,
                r["server_id"],
                r["app_id"],
                target,
                debug=debug_this,
            )
            if err and not op_id:
                print(f"    x {err}")
                fail += 1
                if args.stop_on_fail or (fail == 1 and not args.debug):
                    if fail == 1 and not args.debug:
                        print(
                            "    [hint] Re-run with --debug --stop-on-fail on one app "
                            "to see every probed URL/method."
                        )
                    if args.stop_on_fail:
                        break
                continue
            if op_id:
                print(f"    operation_id={op_id}")
                done, msg = wait_for_operation(op_id, token, api_base)
                if not done:
                    print(f"    x {msg}")
                    fail += 1
                    if args.stop_on_fail:
                        break
                    continue
                print(f"    OK {msg}")
            else:
                print("    OK (synchronous response)")

            if args.health_check and baseline.get("ok"):
                # Brief settle time for PHP-FPM/nginx reload after operation
                time.sleep(3)
                print("    [health] re-checking sample pages ...")
                after_pages = recheck_site_after(baseline)
                aligned, notes = compare_site_snapshots(
                    baseline, after_pages, soft=args.health_soft,
                )
                if aligned:
                    print("    [health] PASS pre/post pages align")
                else:
                    print("    [health] FAIL pre/post pages differ:")
                    for note in notes[:8]:
                        print(f"      - {note}")
                    health_fail += 1
                    fail += 1
                    if args.stop_on_fail:
                        break
                    time.sleep(RATE_SLEEP)
                    continue

            ok += 1
            time.sleep(RATE_SLEEP)
        print(
            f"Done: {ok} updated+verified, {fail} failed "
            f"(health mismatches={health_fail}, skipped unreachable={skipped}), "
            f"{len(rows) - len(pending)} unchanged."
        )
        if APPS_ROOT.is_dir():
            print("Verify on server: cat /home/master/applications/<sys_user>/.php_version")
            print("Or: cat /etc/ansible/facts.d/applications.fact  # [app_php_version]")


if __name__ == "__main__":
    main()
