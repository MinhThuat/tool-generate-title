#!/usr/bin/env bash
# One-click launcher: finds/installs Python, sets up deps, runs the tool.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# Double-clicked (no terminal attached)? Relaunch inside a terminal emulator.
if [ -z "${IN_TERMINAL:-}" ] && [ ! -t 0 ]; then
    INNER="IN_TERMINAL=1 bash '$DIR/run.sh'; echo; read -rp 'Press Enter to close...'"
    for t in x-terminal-emulator gnome-terminal konsole xfce4-terminal xterm; do
        command -v "$t" >/dev/null 2>&1 || continue
        case "$t" in
            gnome-terminal) exec "$t" -- bash -c "$INNER" ;;
            *)              exec "$t" -e bash -c "$INNER" ;;
        esac
    done
    # No terminal emulator found: fall through and run inline.
fi

# 0) Auto-update from the private GitHub repo. Needs a read-only token in
#    update_token.txt; any failure (offline, no/bad token) just runs this copy.
REPO=MinhThuat/tool-generate-title
self_update() {
    local tok sha cur tmp src old_req
    tok="$(tr -d '[:space:]' < "$DIR/update_token.txt")"
    sha="$(curl -fsS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github.sha" \
        "https://api.github.com/repos/$REPO/commits/main")" || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    cur="$(cat "$DIR/.version" 2>/dev/null || true)"
    [ "$sha" = "$cur" ] && return 0
    echo "Updating to ${sha:0:7}..."
    tmp="$(mktemp -d)"
    curl -fsSL -H "Authorization: Bearer $tok" "https://api.github.com/repos/$REPO/tarball/$sha" \
        | tar -xz -C "$tmp" || return 1
    src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$src" ] || return 1
    old_req="$(cksum < "$DIR/requirements.txt" 2>/dev/null || true)"
    cp -a "$src/." "$DIR/"
    [ "$old_req" = "$(cksum < "$DIR/requirements.txt")" ] || rm -f "$DIR/.venv/.deps_ok"
    echo "$sha" > "$DIR/.version"
    rm -rf "$tmp"
    # exec from inside the function: bash never reads the overwritten file further.
    KWGEN_UPDATED=1 exec bash "$DIR/run.sh"
}
if [ -f "$DIR/update_token.txt" ] && [ -z "${KWGEN_UPDATED:-}" ] && command -v curl >/dev/null 2>&1; then
    self_update || echo "Update check skipped."
fi

download_standalone() {
    # No sudo / no package manager needed — the tarball just unpacks and runs.
    echo "Downloading a standalone Python (no install/root needed)..."
    # ponytail: pinned build; if the download 404s, bump TAG/PYVER to a newer release.
    local TAG=20250115 PYVER=3.12.8 ARCH URL
    case "$(uname -m)" in
        x86_64)        ARCH=x86_64 ;;
        aarch64|arm64) ARCH=aarch64 ;;
        *) echo "Unsupported CPU: $(uname -m)"; exit 1 ;;
    esac
    URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/cpython-${PYVER}+${TAG}-${ARCH}-unknown-linux-gnu-install_only.tar.gz"
    mkdir -p "$DIR/.python"
    if   command -v curl >/dev/null 2>&1; then curl -fL "$URL" -o "$DIR/.python/py.tar.gz"
    elif command -v wget >/dev/null 2>&1; then wget -O "$DIR/.python/py.tar.gz" "$URL"
    else echo "Need curl or wget to download Python."; exit 1; fi
    tar -xzf "$DIR/.python/py.tar.gz" -C "$DIR/.python"
    PY="$DIR/.python/python/bin/python3"
}

# 1) Pick a Python. Use system python3 only if it has BOTH venv and pip
#    (Debian/Ubuntu without sudo often ship python3 but not python3-venv/pip).
#    Otherwise reuse the standalone build if already downloaded, else fetch it once.
PY=""
if command -v python3 >/dev/null 2>&1 && python3 -c "import venv, ensurepip" 2>/dev/null; then
    PY=python3
elif [ -x "$DIR/.python/python/bin/python3" ]; then
    PY="$DIR/.python/python/bin/python3"
else
    download_standalone
fi

# 2) venv + dependencies. Self-heals: if the venv is missing OR has no working
#    pip (a broken venv from an earlier run), rebuild it from scratch.
VPY="$DIR/.venv/bin/python"
if ! "$VPY" -m pip --version >/dev/null 2>&1; then
    rm -rf "$DIR/.venv"
    "$PY" -m venv "$DIR/.venv"
fi
if [ ! -f "$DIR/.venv/.deps_ok" ]; then
    "$VPY" -m pip install --upgrade pip
    "$VPY" -m pip install -r "$DIR/requirements.txt"
    touch "$DIR/.venv/.deps_ok"
fi

# 3) The `claude` CLI does the title/tag generation — warn early if it's missing.
if ! command -v claude >/dev/null 2>&1; then
    echo "Warning: 'claude' CLI not found on PATH. Install Claude Code and log in,"
    echo "         or the title/tag generation step will fail."
fi

# 4) Run the web studio (opens the browser to the UI).
exec "$VPY" "$DIR/web_studio.py"
