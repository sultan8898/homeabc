#!/usr/bin/env python3
"""
Cloudways Cron Optimizer Bulk Enabler (v1 API - confirmed working endpoint)

Endpoint confirmed from enable_cronoptimizer_server.sh (szeeshan10/scripts):
    POST https://api.cloudways.com/api/v1/app/manage/cron_setting
    data: server_id, app_id, status=enable

Flow:
- OAuth via v1 (email + api_key), token cached ~3600s
- App list pulled from GET /api/v1/server (not nginx parsing):
    filters application type + is_staging == "0"
- If run on a Cloudways server, server ID is auto-detected from nginx
  configs and offered as default; otherwise prompted
- Enables Cron Optimizer per app, retrying on
  "An operation is already in progress" (ops are serialized per server)
- Polls each operation to completion before the next app
- failed_apps.txt / completed_apps.txt; re-run skips completed apps
- Verify on-server after run: /etc/ansible/facts.d/wp_cron.fact
"""

import glob
import re
import sys
import time
import getpass
from datetime import datetime, timedelta
from pathlib import Path

import requests

# ── Config ────────────────────────────────────────────────────────────────────
API_BASE      = "https://api.cloudways.com/api/v1"
TOKEN_TTL     = 3600
POLL_INTERVAL = 10     # matches the proven shell script's cadence
POLL_TIMEOUT  = 600
INPROG_WAIT   = 10     # sleep when "operation already in progress"
INPROG_MAX    = 60     # max retries for in-progress conflicts (60 x 10s = 10 min)
RATE_SLEEP    = 5      # polite gap between apps

FAILED_LOG    = Path(__file__).parent / "failed_apps.txt"
COMPLETED_LOG = Path(__file__).parent / "completed_apps.txt"

# Server-side state written by the Cloudways playbook when Cron Optimizer
# is enabled. Only readable when this script runs on the target server.
WP_CRON_FACT  = Path("/etc/ansible/facts.d/wp_cron.fact")

# App types eligible for Cron Optimizer. Zeeshan's script uses only the
# first two; woocommerce/wordpressmu added since docs state Woo and
# Multisite are supported. Trim if you want to match his filter exactly.
ELIGIBLE_TYPES = {"wordpress", "wordpressdefault", "woocommerce", "wordpressmu"}
SKIP_STAGING   = True

CRON_STATUS    = "enable"   # "disable" for bulk rollback

# ── Token cache ───────────────────────────────────────────────────────────────
_token_cache: dict = {"token": None, "expires_at": None}


def fetch_token(email: str, api_key: str) -> str:
    now = datetime.utcnow()
    if (
        _token_cache["token"]
        and _token_cache["expires_at"]
        and now < _token_cache["expires_at"]
    ):
        return _token_cache["token"]

    print("  [token] Requesting new access token ...")
    try:
        resp = requests.post(
            f"{API_BASE}/oauth/access_token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"email": email, "api_key": api_key},
            timeout=30,
        )
        resp.raise_for_status()
        token = resp.json().get("access_token")
        if not token:
            print(f"[ERROR] No access_token in response: {resp.text[:300]}")
            sys.exit(1)
    except requests.RequestException as e:
        print(f"[ERROR] OAuth request failed: {e}")
        sys.exit(1)

    _token_cache["token"]      = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    print("  [token] Token obtained.")
    return token


def auth_headers(token: str) -> dict:
    return {"Accept": "application/json", "Authorization": f"Bearer {token}"}


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
def get_apps_for_server(server_id: str, token: str) -> list:
    """Return eligible apps [{app_id, label, application}] for server_id."""
    try:
        resp = requests.get(f"{API_BASE}/server", headers=auth_headers(token), timeout=60)
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
def _collect_strings(obj, out: set):
    """Recursively collect all keys/values from parsed JSON as strings."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.add(str(k))
            _collect_strings(v, out)
    elif isinstance(obj, (list, tuple)):
        for item in obj:
            _collect_strings(item, out)
    else:
        out.add(str(obj))


def load_fact_state():
    """
    Read /etc/ansible/facts.d/wp_cron.fact if present.
    Returns (raw_text, string_set) or (None, set()) when unavailable.
    Format-tolerant: tries JSON, falls back to raw text scanning.
    """
    if not WP_CRON_FACT.exists():
        return None, set()
    try:
        raw = WP_CRON_FACT.read_text(errors="ignore")
    except OSError as e:
        print(f"  [warn] Could not read {WP_CRON_FACT}: {e}")
        return None, set()

    strings: set = set()
    try:
        import json
        _collect_strings(json.loads(raw), strings)
    except (ValueError, TypeError):
        pass  # not JSON; raw text scan will be used

    return raw, strings


def is_already_enabled(app_id: str, raw: str, strings: set) -> bool:
    """
    True if app_id appears in wp_cron.fact.
    Exact match against parsed JSON strings first; otherwise a
    word-boundary regex on the raw text (so 1234 won't match 12345).
    """
    if raw is None:
        return False
    if app_id in strings:
        return True
    # digit-boundary match: finds 777 in "app_777" but not in "7777"
    return re.search(rf"(?<![0-9]){re.escape(app_id)}(?![0-9])", raw) is not None


# ── Enable Cron Optimizer (confirmed v1 endpoint) ─────────────────────────────
def enable_cron_optimizer(app_id: str, server_id: str, token: str):
    """
    POST /app/manage/cron_setting with status=enable.
    Retries while 'An operation is already in progress'.
    Returns operation_id or None (with reason printed).
    """
    url  = f"{API_BASE}/app/manage/cron_setting"
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
def wait_for_operation(op_id: str, token: str):
    url      = f"{API_BASE}/operation/{op_id}"
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


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("  Cloudways Cron Optimizer Bulk Enabler (v1 API)")
    print("=" * 60)

    email   = input("\nEmail address : ").strip()
    api_key = getpass.getpass("API key       : ").strip()
    if not email or not api_key:
        print("[ERROR] Email and API key are required.")
        sys.exit(1)

    detected = detect_server_id()
    prompt   = f"Server ID [{detected}] : " if detected else "Server ID     : "
    server_id = input(prompt).strip() or detected
    if not server_id:
        print("[ERROR] Server ID is required.")
        sys.exit(1)

    print()
    token = fetch_token(email, api_key)

    print(f"\n[1] Fetching apps for server {server_id} via API ...")
    apps = get_apps_for_server(server_id, token)
    if not apps:
        print("[ERROR] No eligible WordPress apps found on this server.")
        sys.exit(1)

    done = load_completed()

    fact_raw, fact_strings = load_fact_state()
    if fact_raw is None:
        print("    [note] wp_cron.fact not readable (script not on target "
              "server?) -- skipping already-enabled detection.")

    pending = []
    skipped_done = skipped_fact = 0
    for a in apps:
        if (server_id, a["app_id"]) in done:
            skipped_done += 1
            continue
        if is_already_enabled(a["app_id"], fact_raw, fact_strings):
            print(f"  [skip] {a['label']} (app_id={a['app_id']}) -- "
                  f"already enabled per wp_cron.fact")
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

        token = fetch_token(email, api_key)

        print("    -> Enabling Cron Optimizer ...")
        op_id, err = enable_cron_optimizer(app_id, server_id, token)
        if not op_id:
            reason = f"Enable request failed: {err}"
            print(f"    x {reason}\n")
            log_failure(server_id, app, reason)
            failed += 1
            continue

        print(f"    -> Operation ID: {op_id}")
        ok, msg = wait_for_operation(op_id, token)
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
