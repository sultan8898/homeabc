#!/usr/bin/env python3
"""
Cloudways — list apps with Varnish enabled

Auth (pick one):
- Access token (recommended): cw_... from platform.cloudways.com/api — used
  directly as Bearer on API v2 (no OAuth exchange).
- Legacy API key: account email + API key → OAuth access token.

Modes:
  --server [ID]   Report for one server (auto-detects ID when run on a
                  Cloudways box; prompts if omitted).
  --account       Report for every server in the account.

Usage:
  export CW_ACCESS_TOKEN='cw_...'

  # One server
  python3 <(curl -s 'https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/main/sl_list_varnish_apps.py') --server
  python3 sl_list_varnish_apps.py --server 12345

  # Whole account
  python3 <(curl -s 'https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/main/sl_list_varnish_apps.py') --account

Env: CW_ACCESS_TOKEN, or CW_EMAIL + CW_API_KEY
Optional: CW_SERVER_ID, CW_WORKERS (default 6)
"""

from __future__ import annotations

import argparse
import getpass
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import requests

API_V1 = "https://api.cloudways.com/api/v1"
API_V2 = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600
RATE_SLEEP = 0.15  # polite pause between status calls when sequential

APP_FQDN_RE = re.compile(r"[a-zA-Z0-9_]+-(\d+)-(\d+)\.cloudwaysapps\.com")
APPS_ROOT = Path("/home/master/applications")

_token_cache: dict = {"token": None, "expires_at": None, "api_base": None}


# ── Auth (same pattern as sl_enable_cronoptimizer.py) ─────────────────────────
def is_access_token(value: str) -> bool:
    return value.startswith("cw_")


def auth_headers(token: str) -> dict:
    return {"Accept": "application/json", "Authorization": f"Bearer {token}"}


def oauth_error_help(status_code: int, body: str, api_base: str) -> str:
    lines = [f"HTTP {status_code} from {api_base}/oauth/access_token"]
    if body:
        lines.append(f"Response: {body[:400]}")
    if status_code == 403:
        lines.append(
            "Hint: a cw_ access token is NOT exchanged via OAuth. Paste it at the "
            "'Access token' prompt (or set CW_ACCESS_TOKEN). Legacy API keys need "
            "the account email plus the key from platform.cloudways.com/api."
        )
    return "\n  ".join(lines)


def fetch_oauth_token(email: str, api_key: str, api_base: str) -> Optional[str]:
    now = datetime.utcnow()
    if (
        _token_cache["token"]
        and _token_cache["expires_at"]
        and _token_cache["api_base"] == api_base
        and now < _token_cache["expires_at"]
    ):
        return _token_cache["token"]

    print(f"  [token] Requesting OAuth access token ({api_base}) ...")
    try:
        resp = requests.post(
            f"{api_base}/oauth/access_token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"email": email, "api_key": api_key},
            timeout=30,
        )
        if resp.status_code >= 400:
            print(
                f"  [token] Failed ({api_base}): "
                f"{oauth_error_help(resp.status_code, resp.text, api_base)}"
            )
            return None
        token = resp.json().get("access_token")
        if not token:
            print(f"  [token] No access_token in response ({api_base}): {resp.text[:300]}")
            return None
    except requests.RequestException as e:
        print(f"  [token] Request error ({api_base}): {e}")
        return None

    _token_cache["token"] = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    _token_cache["api_base"] = api_base
    print(f"  [token] OAuth token obtained ({api_base}).")
    return token


def resolve_auth(email: str, secret: str) -> tuple[str, str]:
    if is_access_token(secret):
        print("  [auth] Using cw_ access token directly (API v2).")
        return secret, API_V2

    if not email:
        print("[ERROR] Account email is required with a legacy API key.")
        sys.exit(1)

    for api_base in (API_V2, API_V1):
        token = fetch_oauth_token(email, secret, api_base)
        if token:
            return token, api_base

    print("[ERROR] Could not obtain an OAuth token on API v2 or v1.")
    sys.exit(1)


def load_credentials() -> tuple[str, str]:
    env_token = os.environ.get("CW_ACCESS_TOKEN", "").strip()
    if env_token:
        return "", env_token

    env_email = os.environ.get("CW_EMAIL", "").strip()
    env_key = os.environ.get("CW_API_KEY", "").strip()
    if env_key:
        return env_email, env_key

    print("\nAuth: cw_ access token (recommended) OR legacy email + API key.")
    print("  Tokens: https://platform.cloudways.com/api\n")

    secret = getpass.getpass("Access token / API key : ").strip()
    if not secret:
        print("[ERROR] Access token or API key is required.")
        sys.exit(1)

    if is_access_token(secret):
        return "", secret

    email = input("Email address          : ").strip()
    if not email:
        print("[ERROR] Email is required with a legacy API key.")
        sys.exit(1)
    return email, secret


# ── Server / app discovery ────────────────────────────────────────────────────
def detect_server_id() -> str:
    try:
        for conf in APPS_ROOT.glob("*/conf/server.nginx"):
            text = conf.read_text(errors="ignore")
            m = APP_FQDN_RE.search(text)
            if m:
                return m.group(1)
    except OSError:
        pass
    return ""


def _parse_servers_payload(payload) -> list:
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("servers", "data"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict) and isinstance(value.get("servers"), list):
            return value["servers"]
    return []


def fetch_servers(token: str, api_base: str) -> list:
    servers = []
    seen_ids = set()

    def add_servers(items):
        for server in items:
            sid = str(server.get("id", ""))
            if sid and sid not in seen_ids:
                seen_ids.add(sid)
                servers.append(server)

    for path in ("server", "servers"):
        url = f"{api_base}/{path}"
        while url:
            try:
                resp = requests.get(url, headers=auth_headers(token), timeout=60)
                if resp.status_code >= 400:
                    break
                payload = resp.json()
            except (requests.RequestException, ValueError):
                break

            add_servers(_parse_servers_payload(payload))
            url = ""
            if isinstance(payload, dict):
                pagination = payload.get("pagination") or {}
                for key in ("next", "next_page_url", "next_url"):
                    nxt = pagination.get(key) or payload.get(key)
                    if nxt:
                        url = nxt
                        break

    return servers


def fetch_server_by_id(server_id: str, token: str, api_base: str) -> Optional[dict]:
    for path in (f"server/{server_id}", f"servers/{server_id}"):
        try:
            resp = requests.get(
                f"{api_base}/{path}",
                headers=auth_headers(token),
                timeout=60,
            )
            if resp.status_code >= 400:
                continue
            payload = resp.json()
            if isinstance(payload, dict):
                for key in ("server", "data"):
                    if isinstance(payload.get(key), dict):
                        return payload[key]
                if str(payload.get("id", "")) == str(server_id):
                    return payload
        except (requests.RequestException, ValueError):
            continue
    return None


def normalize_app(server: dict, app: dict) -> dict:
    aliases = app.get("aliases") or []
    if isinstance(aliases, str):
        aliases = [a.strip() for a in aliases.split(",") if a.strip()]
    return {
        "server_id": str(server.get("id", "")),
        "server_label": server.get("label") or server.get("server_label") or "",
        "app_id": str(app.get("id", "")),
        "app_label": app.get("label") or "",
        "application": str(app.get("application") or ""),
        "cname": app.get("cname") or app.get("app_fqdn") or "",
        "sys_user": str(app.get("sys_user") or ""),
        "is_staging": str(app.get("is_staging", "0")),
        "aliases": aliases,
    }


def apps_from_server(server: dict) -> list[dict]:
    return [normalize_app(server, app) for app in (server.get("apps") or [])]


def collect_apps(
    token: str,
    api_base: str,
    server_id: Optional[str] = None,
) -> list[dict]:
    servers = fetch_servers(token, api_base)

    if server_id:
        target = next((s for s in servers if str(s.get("id")) == str(server_id)), None)
        if target is None:
            target = fetch_server_by_id(server_id, token, api_base)
        if target is None:
            print(f"[ERROR] Server {server_id} not found via API.")
            sys.exit(1)
        servers = [target]

    apps = []
    for server in servers:
        apps.extend(apps_from_server(server))
    return apps


# ── Varnish status ────────────────────────────────────────────────────────────
def _truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on", "enable", "enabled"}


def fetch_varnish_status(token: str, api_base: str, server_id: str, app_id: str) -> dict:
    """
    Prefer GET /app/manage/varnish_setting (varnish_app_enabled / varnish_enabled).
    Fall back to GET /service/appVarnish.
    """
    headers = auth_headers(token)
    params = {"server_id": server_id, "app_id": app_id}

    try:
        resp = requests.get(
            f"{api_base}/app/manage/varnish_setting",
            headers=headers,
            params=params,
            timeout=45,
        )
        if resp.status_code == 429:
            time.sleep(2)
            resp = requests.get(
                f"{api_base}/app/manage/varnish_setting",
                headers=headers,
                params=params,
                timeout=45,
            )
        if resp.status_code < 400:
            payload = resp.json()
            body = payload.get("response", payload) if isinstance(payload, dict) else {}
            return {
                "varnish_app_enabled": _truthy(body.get("varnish_app_enabled")),
                "varnish_enabled": _truthy(body.get("varnish_enabled")),
                "source": "varnish_setting",
                "error": "",
            }
        setting_err = f"HTTP {resp.status_code}: {resp.text[:200]}"
    except (requests.RequestException, ValueError) as e:
        setting_err = str(e)

    try:
        resp = requests.get(
            f"{api_base}/service/appVarnish",
            headers=headers,
            params=params,
            timeout=45,
        )
        if resp.status_code == 429:
            time.sleep(2)
            resp = requests.get(
                f"{api_base}/service/appVarnish",
                headers=headers,
                params=params,
                timeout=45,
            )
        if resp.status_code < 400:
            payload = resp.json()
            body = payload.get("response", payload) if isinstance(payload, dict) else {}
            # Response shapes vary; look for common keys.
            enabled = None
            for key in (
                "varnish_app_enabled",
                "status",
                "service_status",
                "state",
                "app_varnish",
            ):
                if key in body:
                    enabled = body.get(key)
                    break
            if enabled is None and isinstance(body, dict):
                apps_block = body.get("apps")
                if isinstance(apps_block, dict):
                    enabled = apps_block.get(str(app_id)) or apps_block.get(app_id)
            return {
                "varnish_app_enabled": _truthy(enabled),
                "varnish_enabled": _truthy(enabled),
                "source": "appVarnish",
                "error": "",
            }
        return {
            "varnish_app_enabled": False,
            "varnish_enabled": False,
            "source": "",
            "error": f"appVarnish HTTP {resp.status_code}; also {setting_err}",
        }
    except (requests.RequestException, ValueError) as e:
        return {
            "varnish_app_enabled": False,
            "varnish_enabled": False,
            "source": "",
            "error": f"{e}; also {setting_err}",
        }


def enrich_with_varnish(token: str, api_base: str, apps: list[dict], workers: int) -> list[dict]:
    rows: list[dict] = []
    total = len(apps)
    print(f"  [scan] Checking Varnish on {total} app(s) ...")

    def one(app: dict) -> dict:
        status = fetch_varnish_status(token, api_base, app["server_id"], app["app_id"])
        return {**app, **status}

    if workers <= 1:
        for i, app in enumerate(apps, 1):
            rows.append(one(app))
            if i % 25 == 0 or i == total:
                print(f"    ... {i}/{total}")
            time.sleep(RATE_SLEEP)
        return rows

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(one, app): app for app in apps}
        done = 0
        for fut in as_completed(futures):
            rows.append(fut.result())
            done += 1
            if done % 25 == 0 or done == total:
                print(f"    ... {done}/{total}")
    return rows


# ── Output formats ────────────────────────────────────────────────────────────
def _app_line(app: dict) -> str:
    domain = app.get("cname") or app.get("application") or "-"
    staging = " [staging]" if app.get("is_staging") == "1" else ""
    return (
        f"    - {app['app_label'] or '(no label)'}{staging}"
        f"  app_id={app['app_id']}"
        f"  sys_user={app.get('sys_user') or '-'}"
        f"  domain={domain}"
    )


def print_server_report(server_id: str, server_label: str, rows: list[dict]) -> None:
    enabled = [r for r in rows if r.get("varnish_app_enabled") and not r.get("error")]
    errors = [r for r in rows if r.get("error")]

    print()
    print("=" * 64)
    print("  Cloudways Varnish Apps Report  [server]")
    print("=" * 64)
    print(f"  Server : {server_label or '(unknown)'}  (id={server_id})")
    print(f"  Apps   : {len(rows)} total, {len(enabled)} with Varnish ENABLED")
    print("-" * 64)

    if enabled:
        print("\n  Apps with Varnish ENABLED:")
        for app in sorted(enabled, key=lambda a: (a.get("app_label") or "").lower()):
            print(_app_line(app))
    else:
        print("\n  (none) No apps with Varnish enabled on this server.")

    if errors:
        print(f"\n  Errors ({len(errors)}):")
        for app in errors:
            print(f"    ! {app['app_label']} app_id={app['app_id']}: {app['error']}")

    print("=" * 64)


def print_account_report(rows: list[dict]) -> None:
    by_server: dict[str, list[dict]] = {}
    for row in rows:
        by_server.setdefault(row["server_id"], []).append(row)

    enabled_all = [r for r in rows if r.get("varnish_app_enabled") and not r.get("error")]

    print()
    print("=" * 64)
    print("  Cloudways Varnish Apps Report  [account]")
    print("=" * 64)
    print(
        f"  Servers : {len(by_server)}  |  Apps : {len(rows)}  |  "
        f"Varnish ENABLED : {len(enabled_all)}"
    )
    print("-" * 64)

    for sid in sorted(by_server.keys(), key=lambda s: (by_server[s][0].get("server_label") or "").lower()):
        group = by_server[sid]
        label = group[0].get("server_label") or "(unknown)"
        enabled = [r for r in group if r.get("varnish_app_enabled") and not r.get("error")]
        print(f"\n── Server: {label} (id={sid}) ──")
        print(f"   {len(enabled)} / {len(group)} app(s) with Varnish ENABLED")
        if enabled:
            for app in sorted(enabled, key=lambda a: (a.get("app_label") or "").lower()):
                print(_app_line(app))
        else:
            print("    (none)")

    print()
    print("-" * 64)
    print("  ACCOUNT SUMMARY — apps with Varnish ENABLED:")
    if enabled_all:
        for app in sorted(
            enabled_all,
            key=lambda a: (
                (a.get("server_label") or "").lower(),
                (a.get("app_label") or "").lower(),
            ),
        ):
            print(
                f"    [{app.get('server_label') or app['server_id']}] "
                f"{app['app_label'] or '(no label)'}  "
                f"app_id={app['app_id']}  domain={app.get('cname') or '-'}"
            )
    else:
        print("    (none)")
    print("=" * 64)


# ── CLI ───────────────────────────────────────────────────────────────────────
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="List Cloudways apps that have Varnish enabled (access token)."
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--server",
        nargs="?",
        const="",
        default=None,
        metavar="ID",
        help="Server mode. Optional ID; auto-detect / prompt if omitted.",
    )
    mode.add_argument(
        "--account",
        action="store_true",
        help="Account mode — scan every server.",
    )
    p.add_argument(
        "--all",
        action="store_true",
        help="Also print apps where Varnish is disabled (still reports enabled first).",
    )
    p.add_argument(
        "--workers",
        type=int,
        default=int(os.environ.get("CW_WORKERS", "6")),
        help="Parallel API workers (default 6). Use 1 to go sequential.",
    )
    return p.parse_args()


def resolve_mode(args: argparse.Namespace) -> tuple[str, Optional[str]]:
    """Return (mode, server_id). mode is 'server' or 'account'."""
    if args.account:
        return "account", None

    if args.server is not None:
        sid = (args.server or "").strip() or os.environ.get("CW_SERVER_ID", "").strip()
        if not sid:
            detected = detect_server_id()
            prompt = f"Server ID [{detected}] : " if detected else "Server ID     : "
            try:
                sid = input(prompt).strip() or detected
            except EOFError:
                sid = detected
        if not sid:
            print("[ERROR] Server ID is required for --server mode.")
            sys.exit(1)
        return "server", sid

    # No flag: prefer account when not on a Cloudways box; else server.
    detected = detect_server_id()
    env_sid = os.environ.get("CW_SERVER_ID", "").strip()
    if env_sid or detected:
        return "server", env_sid or detected

    print("No mode given. Use --server [ID] or --account.")
    print("Defaulting to --account.\n")
    return "account", None


def main() -> int:
    args = parse_args()
    mode, server_id = resolve_mode(args)

    print("=" * 64)
    print("  Cloudways — list apps with Varnish enabled")
    print("=" * 64)

    email, secret = load_credentials()
    token, api_base = resolve_auth(email, secret)
    print(f"  [auth] API {'v2' if api_base == API_V2 else 'v1'}")
    print(f"  [mode] {mode}" + (f"  server_id={server_id}" if server_id else ""))

    print("\n[1] Fetching apps via API ...")
    apps = collect_apps(token, api_base, server_id=server_id)
    if not apps:
        print("[ERROR] No apps found.")
        return 1
    print(f"    Found {len(apps)} app(s).")

    print("\n[2] Checking Varnish status ...")
    rows = enrich_with_varnish(token, api_base, apps, workers=max(1, args.workers))

    if mode == "server":
        label = next((r.get("server_label") for r in rows if r.get("server_label")), "")
        print_server_report(server_id or "", label, rows)
        if args.all:
            disabled = [
                r for r in rows
                if not r.get("varnish_app_enabled") and not r.get("error")
            ]
            if disabled:
                print("\n  Apps with Varnish DISABLED:")
                for app in sorted(disabled, key=lambda a: (a.get("app_label") or "").lower()):
                    print(_app_line(app))
    else:
        print_account_report(rows)

    return 0


if __name__ == "__main__":
    sys.exit(main())
