#!/usr/bin/env python3
"""
Cloudways Cron Optimizer Bulk Enabler

Auth (pick one):
- Access token (recommended): cw_... from platform.cloudways.com/api — used
  directly as Bearer on API v2 (no OAuth exchange).
- Legacy API key: account email + API key → OAuth access token (v2, then v1).

Cron optimizer endpoints:
- v2: PUT /api/v2/applications/{app_id}/cron-optimizer  {"enabled": true}
- v1: POST /api/v1/app/manage/cron_setting (legacy fallback)

Flow:
- App list from GET /server(s); filters application type + is_staging == "0"
- If run on a Cloudways server, server ID is auto-detected from nginx configs
- Enables Cron Optimizer per app, retrying on in-progress conflicts (v1)
- Polls async operations when an operation_id is returned
- failed_apps.txt / completed_apps.txt; re-run skips completed apps
- Verify on-server: /etc/ansible/facts.d/wp_cron.fact

Env: CW_ACCESS_TOKEN, or CW_EMAIL + CW_API_KEY
"""

from typing import Optional
import glob
import os
import re
import sys
import time
import getpass
from datetime import datetime, timedelta
from pathlib import Path

import requests

# ── Config ────────────────────────────────────────────────────────────────────
API_V1        = "https://api.cloudways.com/api/v1"
API_V2        = "https://api.cloudways.com/api/v2"
TOKEN_TTL     = 3600
POLL_INTERVAL = 10     # matches the proven shell script's cadence
POLL_TIMEOUT  = 600
INPROG_WAIT   = 10     # sleep when "operation already in progress"
INPROG_MAX    = 60     # max retries for in-progress conflicts (60 x 10s = 10 min)
RATE_SLEEP    = 5      # polite gap between apps

# Logs go to a writable dir. Path(__file__).parent breaks when the
# script is run via process substitution (python3 <(curl ...)) because
# __file__ is /dev/fd/N. Prefer /var/cw/systeam, fall back to cwd.
_pref   = Path("/var/cw/systeam")
LOG_DIR = _pref if _pref.is_dir() else Path.cwd()
FAILED_LOG    = LOG_DIR / "failed_apps.txt"
COMPLETED_LOG = LOG_DIR / "completed_apps.txt"

# Server-side state written by the Cloudways playbook when Cron Optimizer
# is enabled. Only readable when this script runs on the target server.
WP_CRON_FACT  = Path("/etc/ansible/facts.d/wp_cron.fact")

# App types eligible for Cron Optimizer. Zeeshan's script uses only the
# first two; woocommerce/wordpressmu added since docs state Woo and
# Multisite are supported. Trim if you want to match his filter exactly.
ELIGIBLE_TYPES = {"wordpress", "wordpressdefault", "woocommerce", "wordpressmu"}
SKIP_STAGING   = True

CRON_STATUS    = "enable"   # "disable" for bulk rollback

# ── Token cache (legacy OAuth only) ───────────────────────────────────────────
_token_cache: dict = {"token": None, "expires_at": None, "api_base": None}


def is_access_token(value: str) -> bool:
    """Cloudways RBAC access tokens are issued with a cw_ prefix."""
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
            print(f"  [token] Failed ({api_base}): {oauth_error_help(resp.status_code, resp.text, api_base)}")
            return None
        token = resp.json().get("access_token")
        if not token:
            print(f"  [token] No access_token in response ({api_base}): {resp.text[:300]}")
            return None
    except requests.RequestException as e:
        print(f"  [token] Request error ({api_base}): {e}")
        return None

    _token_cache["token"]      = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    _token_cache["api_base"]   = api_base
    print(f"  [token] OAuth token obtained ({api_base}).")
    return token


def resolve_auth(email: str, secret: str) -> tuple[str, str]:
    """
    Return (bearer_token, api_base).
    cw_ secrets are used directly on v2; legacy keys use OAuth (v2 then v1).
    """
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
    if not is_access_token(secret):
        print(
            "  If you have a cw_ access token, paste that instead of a legacy API key."
        )
    sys.exit(1)


def refresh_token(email: str, secret: str, api_base: str) -> str:
    if is_access_token(secret):
        return secret
    token = fetch_oauth_token(email, secret, api_base)
    if not token:
        print("[ERROR] OAuth token refresh failed.")
        sys.exit(1)
    return token


# ── Server ID auto-detect (when run on the target server) ────────────────────
def detect_server_id() -> str:
    """Parse server_id from local cloudwaysapps domains in nginx configs."""
    try:
        for conf in glob.glob("/home/master/applications/*/conf/server.nginx"):
            text = Path(conf).read_text(errors="ignore")
            m = re.search(r"[a-z]+-(\d+)-\d+\.cloudwaysapps\.com", text)
            if m:
                return m.group(1)
    except OSError:
        pass
    return ""


# ── App discovery via API ─────────────────────────────────────────────────────
def get_apps_for_server(server_id: str, token: str, api_base: str) -> list:
    """Return eligible apps [{app_id, label, application}] for server_id."""
    servers_path = "servers" if api_base == API_V2 else "server"
    try:
        resp = requests.get(
            f"{api_base}/{servers_path}",
            headers=auth_headers(token),
            timeout=60,
        )
        resp.raise_for_status()
        servers = resp.json().get("servers", [])
    except requests.RequestException as e:
        print(f"[ERROR] Failed to fetch server list: {e}")
        sys.exit(1)

    target = next((s for s in servers if str(s.get("id")) == str(server_id)), None)
    if target is None:
        print(f"[ERROR] Server ID {server_id} not found on this account.")
        sys.exit(1)

    apps = []
    for app in target.get("apps", []):
        app_type = str(app.get("application", "")).lower()
        if app_type not in ELIGIBLE_TYPES:
            print(f"  [skip] {app.get('label','?')} (type={app_type})")
            continue
        if SKIP_STAGING and str(app.get("is_staging", "0")) == "1":
            print(f"  [skip] {app.get('label','?')} (staging app)")
            continue
        apps.append({
            "app_id":      str(app.get("id")),
            "label":       app.get("label", ""),
            "application": app_type,
            "sys_user":    str(app.get("sys_user", "")),
        })
    return apps


# ── Resume support ────────────────────────────────────────────────────────────
def load_completed() -> set:
    done = set()
    if COMPLETED_LOG.exists():
        for line in COMPLETED_LOG.read_text().splitlines():
            m = re.search(r"server_id=(\d+)\s+app_id=(\d+)", line)
            if m:
                done.add((m.group(1), m.group(2)))
    return done


# ── wp_cron.fact check (already-enabled detection) ────────────────────────────
def load_fact_enabled() -> set:
    """
    Parse /etc/ansible/facts.d/wp_cron.fact (confirmed format):
        [wp_cron]
        <sys_user>=enabled
    Returns set of sys_user names with cron optimizer enabled.
    Empty set when the file is absent (e.g. script run off-server).
    """
    if not WP_CRON_FACT.exists():
        return set()
    enabled = set()
    try:
        for line in WP_CRON_FACT.read_text(errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("["):
                continue
            if "=" in line:
                key, _, val = line.partition("=")
                if val.strip().lower() == "enabled":
                    enabled.add(key.strip())
    except OSError as e:
        print(f"  [warn] Could not read {WP_CRON_FACT}: {e}")
    return enabled


# ── Enable Cron Optimizer ───────────────────────────────────────────────────────
def enable_cron_optimizer(app_id: str, server_id: str, token: str, api_base: str):
    """
    v2: PUT /applications/{app_id}/cron-optimizer
    v1: POST /app/manage/cron_setting (retries on in-progress conflicts)
    Returns (operation_id_or_None, error_message).
    """
    if api_base == API_V2:
        return _enable_cron_v2(app_id, token)
    return _enable_cron_v1(app_id, server_id, token, api_base)


def _enable_cron_v2(app_id: str, token: str):
    url = f"{API_V2}/applications/{app_id}/cron-optimizer"
    enabled = CRON_STATUS == "enable"
    try:
        resp = requests.put(
            url,
            headers={**auth_headers(token), "Content-Type": "application/json"},
            json={"enabled": enabled},
            timeout=30,
        )
    except requests.RequestException as e:
        return None, str(e)

    try:
        body = resp.json() if resp.text else {}
    except ValueError:
        body = {"raw": resp.text[:300]}

    if resp.status_code == 403:
        return None, (
            f"HTTP 403: {body}. Token may lack FULL ACCESS scope for this app."
        )
    if resp.status_code not in (200, 201, 202):
        return None, f"HTTP {resp.status_code}: {body}"

    op_id = body.get("operation_id")
    if op_id:
        return str(op_id), ""
    # v2 may complete synchronously without an operation_id
    return "sync", ""


def _enable_cron_v1(app_id: str, server_id: str, token: str, api_base: str):
    url  = f"{api_base}/app/manage/cron_setting"
    data = {"server_id": server_id, "app_id": app_id, "status": CRON_STATUS}

    for attempt in range(INPROG_MAX):
        try:
            resp = requests.post(
                url,
                headers={**auth_headers(token),
                         "Content-Type": "application/x-www-form-urlencoded"},
                data=data,
                timeout=30,
            )
        except requests.RequestException as e:
            print(f"    [error] Request failed: {e}")
            return None, str(e)

        try:
            body = resp.json()
        except ValueError:
            return None, f"HTTP {resp.status_code}, non-JSON: {resp.text[:300]}"

        message = str(body.get("message", ""))
        if message.startswith("An operation is already in progress"):
            print(f"    [wait] Operation in progress on server, retrying in {INPROG_WAIT}s "
                  f"({attempt + 1}/{INPROG_MAX}) ...")
            time.sleep(INPROG_WAIT)
            continue

        if resp.status_code != 200:
            return None, f"HTTP {resp.status_code}: {body}"

        op_id = body.get("operation_id")
        if op_id:
            return str(op_id), ""
        return None, f"No operation_id in response: {body}"

    return None, "Gave up after repeated 'operation in progress' conflicts"


# ── Poll operation ────────────────────────────────────────────────────────────
def wait_for_operation(op_id: str, token: str, api_base: str):
    if op_id == "sync":
        return True, "enabled (synchronous)"

    url      = f"{api_base}/operation/{op_id}"
    deadline = time.time() + POLL_TIMEOUT

    while time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        try:
            resp = requests.get(url, headers=auth_headers(token), timeout=30)
            resp.raise_for_status()
            data = resp.json()
        except requests.RequestException as e:
            print(f"    [poll] Request error: {e} -- retrying ...")
            continue

        operation    = data.get("operation", {})
        is_completed = str(operation.get("is_completed", "0"))
        status_msg   = operation.get("status", "")
        message      = operation.get("message", "")

        print(f"    [poll] {op_id} -> status='{status_msg}'  completed={is_completed}")

        if is_completed == "1":
            combined = (str(status_msg) + " " + str(message)).lower()
            if "completed" in combined or "success" in combined:
                return True, status_msg
            return False, status_msg or message

    return False, "Timed out waiting for operation"


# ── Loggers ───────────────────────────────────────────────────────────────────
def _ts() -> str:
    return datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")


def log_failure(server_id: str, app: dict, reason: str):
    with open(FAILED_LOG, "a") as f:
        f.write(f"[{_ts()}] server_id={server_id} app_id={app['app_id']} "
                f"label={app['label']} reason={reason}\n")


def log_success(server_id: str, app: dict):
    with open(COMPLETED_LOG, "a") as f:
        f.write(f"[{_ts()}] server_id={server_id} app_id={app['app_id']} "
                f"label={app['label']}\n")


# ── Credentials ───────────────────────────────────────────────────────────────
def load_credentials() -> tuple[str, str]:
    """
    Return (email, secret).
    secret is either a cw_ access token or a legacy API key.
    """
    env_token = os.environ.get("CW_ACCESS_TOKEN", "").strip()
    if env_token:
        return "", env_token

    env_email = os.environ.get("CW_EMAIL", "").strip()
    env_key   = os.environ.get("CW_API_KEY", "").strip()
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


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("  Cloudways Cron Optimizer Bulk Enabler")
    print("=" * 60)

    email, secret = load_credentials()

    detected = detect_server_id()
    prompt   = f"Server ID [{detected}] : " if detected else "Server ID     : "
    server_id = input(prompt).strip() or detected
    if not server_id:
        print("[ERROR] Server ID is required.")
        sys.exit(1)

    print()
    token, api_base = resolve_auth(email, secret)
    api_label = "v2" if api_base == API_V2 else "v1"
    print(f"  [auth] API {api_label}")

    print(f"\n[1] Fetching apps for server {server_id} via API ...")
    apps = get_apps_for_server(server_id, token, api_base)
    if not apps:
        print("[ERROR] No eligible WordPress apps found on this server.")
        sys.exit(1)

    done = load_completed()

    fact_enabled = load_fact_enabled()
    if not WP_CRON_FACT.exists():
        print("    [note] wp_cron.fact not found (script not on target "
              "server, or nothing enabled yet) -- skipping fact check.")

    pending = []
    skipped_done = skipped_fact = 0
    for a in apps:
        if (server_id, a["app_id"]) in done:
            skipped_done += 1
            continue
        if a["sys_user"] and a["sys_user"] in fact_enabled:
            print(f"  [skip] {a['label']} (app_id={a['app_id']}, "
                  f"sys_user={a['sys_user']}) -- already enabled per wp_cron.fact")
            log_success(server_id, a)  # record so future runs skip via log too
            skipped_fact += 1
            continue
        pending.append(a)

    skipped = skipped_done + skipped_fact
    print(f"    {len(apps)} eligible app(s); {skipped_done} already completed "
          f"(log), {skipped_fact} already enabled (wp_cron.fact), "
          f"{len(pending)} to process.\n")

    if not pending:
        print("Nothing to do. Delete completed_apps.txt to force a full re-run.")
        return

    failed = success = 0

    for idx, app in enumerate(pending, 1):
        app_id = app["app_id"]
        print(f"[{idx}/{len(pending)}] {app['label']} (app_id={app_id}, "
              f"type={app['application']})")

        token = refresh_token(email, secret, api_base)

        print("    -> Enabling Cron Optimizer ...")
        op_id, err = enable_cron_optimizer(app_id, server_id, token, api_base)
        if not op_id:
            reason = f"Enable request failed: {err}"
            print(f"    x {reason}\n")
            log_failure(server_id, app, reason)
            failed += 1
            continue

        if op_id != "sync":
            print(f"    -> Operation ID: {op_id}")
        ok, msg = wait_for_operation(op_id, token, api_base)
        if ok:
            print(f"    OK Done -- {msg}\n")
            log_success(server_id, app)
            success += 1
        else:
            reason = f"Operation {op_id} failed/timed-out: {msg}"
            print(f"    x {reason}\n")
            log_failure(server_id, app, reason)
            failed += 1

        time.sleep(RATE_SLEEP)

    print("=" * 60)
    print(f"  Finished:  {success} succeeded,  {failed} failed,  "
          f"{skipped} skipped (already done)")
    if failed:
        print(f"  Failed apps logged to:    {FAILED_LOG.resolve()}")
    print(f"  Completed apps logged to: {COMPLETED_LOG.resolve()}")
    print("  Verify on server: cat /etc/ansible/facts.d/wp_cron.fact")
    print("=" * 60)


if __name__ == "__main__":
    main()
