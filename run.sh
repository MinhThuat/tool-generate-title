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

# 0) Auto-update from the public repo. With git: fast-forward only, skipped when
#    tracked files have local edits (a dev checkout is never clobbered). Without
#    git (needs root to install on Linux): fall back to downloading the tarball.
#    Any failure (offline, etc.) just runs this copy.
REPO=MinhThuat/tool-generate-title
git_update() {
    local G=(git -c safe.directory='*' -C "$DIR") before=""
    if [ ! -d "$DIR/.git" ]; then
        "${G[@]}" init -q && "${G[@]}" remote add origin "https://github.com/$REPO.git" || return 1
    else
        before="$("${G[@]}" rev-parse HEAD 2>/dev/null || true)"
        [ -z "$("${G[@]}" status --porcelain --untracked-files=no)" ] \
            || { echo "Local edits in tracked files: skip auto-update."; return 1; }
    fi
    "${G[@]}" fetch -q origin main || return 1
    if [ -n "$before" ]; then "${G[@]}" merge -q --ff-only origin/main || return 1
    else "${G[@]}" checkout -q -f -B main origin/main || return 1; fi  # first run: adopt folder
    NEW_SHA="$("${G[@]}" rev-parse HEAD)"
    [ "$NEW_SHA" != "$before" ]
}
tarball_update() {
    local sha tmp src
    sha="$(curl -fsS -H "Accept: application/vnd.github.sha" \
        "https://api.github.com/repos/$REPO/commits/main")" || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    [ "$sha" = "$(cat "$DIR/.version" 2>/dev/null || true)" ] && return 1
    tmp="$(mktemp -d)"
    curl -fsSL "https://api.github.com/repos/$REPO/tarball/$sha" | tar -xz -C "$tmp" || return 1
    src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$src" ] || return 1
    cp -a "$src/." "$DIR/"
    echo "$sha" > "$DIR/.version"
    rm -rf "$tmp"
    NEW_SHA="$sha"
}
self_update() {
    # Returns 0 only when new code landed.
    local old_req
    old_req="$(cksum < "$DIR/requirements.txt" 2>/dev/null || true)"
    if command -v git >/dev/null 2>&1; then git_update || return 1
    elif command -v curl >/dev/null 2>&1; then tarball_update || return 1
    else return 1; fi
    echo "Updated to ${NEW_SHA:0:7}."
    [ "$old_req" = "$(cksum < "$DIR/requirements.txt")" ] || rm -f "$DIR/.venv/.deps_ok"
}
if [ -z "${KWGEN_UPDATED:-}" ] && self_update; then
    # Re-run the (possibly new) launcher once; bash reads no further from this file.
    KWGEN_UPDATED=1 exec bash "$DIR/run.sh"
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
