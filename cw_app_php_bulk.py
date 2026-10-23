#!/usr/bin/env python3
"""
Cloudways per-application PHP version audit and bulk update.

Uses the same auth model as sl_enable_cronoptimizer.py:
  CW_ACCESS_TOKEN (cw_... Bearer on API v2), or CW_EMAIL + CW_API_KEY (OAuth).

Primary update endpoint (API v1 / v2, matches Cloudways MCP set_php_version):
  POST /app/manage/php_version
  Content-Type: application/x-www-form-urlencoded
  server_id, app_id, php_version=8.3

Audit:
  GET /server or GET /server/{id} — each app may expose php_version (or phpVersion).

On-server verification (when run on the Cloudways box):
  /home/master/applications/<sys_user>/.php_version
  readlink /home/master/applications/<sys_user>/.cw/bin/php  -> /usr/bin/php8.3

Playground (https://developers.cloudways.com/docs/ → Playground):
  1. Authorize (OAuth or paste cw_ token).
  2. GET /server — note server id, app id, current php_version per app.
  3. POST /app/manage/php_version with server_id, app_id, php_version=8.3.
  4. GET /operation/{operation_id} until is_completed=1.

Examples:
  export CW_ACCESS_TOKEN='cw_...'
  ./cw_app_php_bulk.py --server-id 123456 --audit
  ./cw_app_php_bulk.py --server-id 123456 --apply --target 8.3 --dry-run
  ./cw_app_php_bulk.py --server-id 123456 --apply --target 8.3
  ./cw_app_php_bulk.py --all-servers --audit --csv > php_audit.csv

Env: CW_ACCESS_TOKEN, or CW_EMAIL + CW_API_KEY
"""

from __future__ import annotations

import argparse
import csv
import getpass
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Optional

import requests

API_V1 = "https://api.cloudways.com/api/v1"
API_V2 = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600
POLL_INTERVAL = 10
POLL_TIMEOUT = 900
INPROG_WAIT = 10
INPROG_MAX = 60
RATE_SLEEP = 8

APPS_ROOT = Path("/home/master/applications")
APP_FQDN_RE = re.compile(r"[a-zA-Z0-9_]+-(\d+)-(\d+)\.cloudwaysapps\.com")

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


def local_php_version(sys_user: str) -> str:
    if not sys_user:
        return ""
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
        local_php = local_php_version(sys_user) if APPS_ROOT.is_dir() else ""
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


def filter_rows(
    rows: list[dict],
    *,
    sys_users: set[str],
    from_php: str,
) -> list[dict]:
    out = rows
    if sys_users:
        out = [r for r in out if r.get("sys_user") in sys_users]
    if from_php:
        fp = normalize_php_version(from_php)
        out = [
            r
            for r in out
            if normalize_php_version(r.get("php_effective") or r.get("php_api") or "") == fp
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
        for app in srv.get("apps") or []:
            if not isinstance(app, dict):
                continue
            if not include_staging and str(app.get("is_staging", "0")) == "1":
                continue
            sys_user = str(app.get("sys_user") or app.get("sysUser") or "")
            api_php = app_php_from_api(app)
            local_php = local_php_version(sys_user) if APPS_ROOT.is_dir() else ""
            rows.append(
                {
                    "server_id": sid,
                    "server_label": s_label,
                    "app_id": str(app.get("id", "")),
                    "label": app.get("label") or app.get("app_label") or sys_user,
                    "application": str(app.get("application", "")),
                    "sys_user": sys_user,
                    "cname": app.get("cname") or app.get("app_fqdn") or "",
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


def post_php_version(
    token: str,
    api_base: str,
    server_id: str,
    app_id: str,
    target: str,
) -> tuple[Optional[str], str]:
    """Try known Cloudways PHP version endpoints; return (operation_id, error)."""
    form_data = {"server_id": server_id, "app_id": app_id, "php_version": target}
    json_min = {"php_version": target}
    json_srv = {"php_version": target, "server_id": server_id}
    attempts: list[tuple[str, str, dict, Any]] = []
    if api_base == API_V2:
        attempts.extend(
            [
                ("PUT", f"{api_base}/applications/{app_id}/php-version", {"Content-Type": "application/json"}, json_min),
                ("PUT", f"{api_base}/applications/{app_id}/php-version?server_id={server_id}", {"Content-Type": "application/json"}, json_min),
                ("PUT", f"{api_base}/applications/{app_id}/php-version", {"Content-Type": "application/json"}, json_srv),
                ("PATCH", f"{api_base}/applications/{app_id}/php-version", {"Content-Type": "application/json"}, json_min),
                ("POST", f"{api_base}/applications/{app_id}/php-version", {"Content-Type": "application/json"}, json_srv),
                ("PUT", f"{api_base}/apps/{app_id}/php-version", {"Content-Type": "application/json"}, json_srv),
                ("POST", f"{api_base}/apps/{app_id}/php-version", {"Content-Type": "application/json"}, json_srv),
            ]
        )
    attempts.extend(
        [
            ("POST", f"{API_V2}/app/manage/php_version", {"Content-Type": "application/x-www-form-urlencoded"}, form_data),
            ("POST", f"{API_V1}/app/manage/php_version", {"Content-Type": "application/x-www-form-urlencoded"}, form_data),
        ]
    )

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
                break

            try:
                payload = resp.json()
            except ValueError:
                payload = {"raw": resp.text[:400]}

            message = str(payload.get("message", ""))
            if message.startswith("An operation is already in progress"):
                print(f"    [wait] Server busy, retry {attempt + 1}/{INPROG_MAX} ...")
                time.sleep(INPROG_WAIT)
                continue

            if resp.status_code in (200, 201, 202):
                op_id = payload.get("operation_id") or payload.get("operationId")
                if op_id:
                    return str(op_id), ""
                if payload.get("status") is True or str(payload.get("status", "")).lower() == "success":
                    return "", ""
                last_err = f"{method} {url}: HTTP {resp.status_code} {payload}"
                break

            if resp.status_code == 404:
                last_err = f"{method} {url}: HTTP 404"
                break
            last_err = f"{method} {url}: HTTP {resp.status_code} {payload}"
            break

    return None, last_err or "no endpoint accepted the request"


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
        help="With --apply, only apps on this version (e.g. 7.4). Matches API or local .php_version",
    )
    args = parser.parse_args()

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
    rows = filter_rows(rows, sys_users=sys_user_filter, from_php=args.from_php or "")
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
        if sys_user_filter or args.from_php:
            print(
                f"Filtered scope: {len(rows)} app(s)"
                + (f", sys_users={len(sys_user_filter)}" if sys_user_filter else "")
                + (f", from_php={args.from_php}" if args.from_php else "")
            )
        print(f"Target PHP {target} — {len(pending)} app(s) to update, {len(rows) - len(pending)} already match.")
        ok = fail = 0
        for idx, r in enumerate(pending, 1):
            print(
                f"[{idx}/{len(pending)}] server={r['server_id']} app={r['app_id']} "
                f"{r['label']} {r['php_effective'] or '?'} -> {target}"
            )
            if args.dry_run:
                continue
            op_id, err = post_php_version(token, api_base, r["server_id"], r["app_id"], target)
            if err and not op_id:
                print(f"    x {err}")
                fail += 1
                continue
            if op_id:
                print(f"    operation_id={op_id}")
                done, msg = wait_for_operation(op_id, token, api_base)
                if not done:
                    print(f"    x {msg}")
                    fail += 1
                    continue
                print(f"    OK {msg}")
            else:
                print("    OK (synchronous response)")
            ok += 1
            time.sleep(RATE_SLEEP)
        print(f"Done: {ok} updated, {fail} failed, {len(rows) - len(pending)} unchanged.")
        if APPS_ROOT.is_dir():
            print("Verify on server: cat /home/master/applications/<sys_user>/.php_version")


if __name__ == "__main__":
    main()
