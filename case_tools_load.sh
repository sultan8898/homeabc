#!/bin/bash
# Loaded by case_*.sh scripts. Resolves install dir and sources case_lib.sh.
# Do not pipe individual scripts to bash — run install_case_tools.sh once, then ./script

if [[ -n "${CASE_LIB_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

case_tools_resolve_install_dir() {
    local caller_dir="${1:-}"

    if [[ -n "${CASE_TOOLS_DIR:-}" && -f "${CASE_TOOLS_DIR}/case_lib.sh" ]]; then
        echo "$CASE_TOOLS_DIR"
        return 0
    fi

    if [[ -n "$caller_dir" && -f "$caller_dir/case_lib.sh" ]]; then
        echo "$caller_dir"
        return 0
    fi

    local hid d
    hid=$(hostname 2>/dev/null | grep -oE '^[0-9]+' || true)

    for d in \
        /home/master/case-tools \
        "${HOME}/case-tools" \
        "/home/${hid}.cloudwaysapps.com/case-tools" \
        "/home/master/homeabc" \
        ; do
        [[ -n "$d" && -f "$d/case_lib.sh" ]] && { echo "$d"; return 0; }
    done

    return 1
}

_CALLER_DIR=""
if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
    _CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
elif [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if ! CASE_TOOLS_DIR="$(case_tools_resolve_install_dir "$_CALLER_DIR")"; then
    cat >&2 <<'EOF'
Could not find case_lib.sh.

One-time install (downloads all tools to a case-tools folder):

  curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/case-investigation-scripts-c2b2/install_case_tools.sh | bash

Then:

  cd "$(case-tools path printed by installer)"
  ./case_triage.sh 2000 afurtxebjn

Do not run: curl .../case_slice.sh | bash
EOF
    exit 1
fi

export CASE_TOOLS_DIR
# shellcheck source=case_lib.sh
source "$CASE_TOOLS_DIR/case_lib.sh"
CASE_LIB_LOADED=1
