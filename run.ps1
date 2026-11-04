# One-click Windows launcher (no admin needed).
# Bootstraps a portable Python, a venv + deps, and the Claude CLI, then runs the GUI.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # PS 5.1 progress bar makes downloads crawl
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DIR = $PSScriptRoot
Set-Location $DIR

# 0) Auto-update via git from the public repo. Uses system git, else a portable
#    MinGit unzipped into .git-portable (no admin). Fast-forward only, and skipped
#    when tracked files have local edits, so a dev checkout is never clobbered.
#    Any failure (offline, etc.) just runs this copy.
$REPO_URL = "https://github.com/MinhThuat/tool-generate-title.git"

function Get-Git {
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    $mg = Join-Path $DIR ".git-portable\cmd\git.exe"
    if (-not (Test-Path $mg)) {
        Write-Host "Downloading portable Git (MinGit, no admin needed)..."
        # ponytail: pinned build; if the download 404s, bump $GV to a newer release.
        $GV = "2.51.2"
        $zip = Join-Path $env:TEMP "mingit.zip"
        Invoke-WebRequest -UseBasicParsing -OutFile $zip `
            -Uri "https://github.com/git-for-windows/git/releases/download/v$GV.windows.1/MinGit-$GV-64-bit.zip"
        Expand-Archive -Force $zip (Join-Path $DIR ".git-portable")
        Remove-Item $zip -ErrorAction SilentlyContinue
    }
    return $mg
}

if (-not $env:KWGEN_UPDATED) {
    try {
        $git = Get-Git
        function G { & $git -c "safe.directory=*" -C $DIR @args; if ($LASTEXITCODE) { throw "git $args failed" } }
        $req = Join-Path $DIR "requirements.txt"
        $oldReq = if (Test-Path $req) { (Get-FileHash $req).Hash } else { "" }
        $before = ""
        if (-not (Test-Path (Join-Path $DIR ".git"))) {
            G init -q
            G remote add origin $REPO_URL
        } else {
            $before = (& $git -c "safe.directory=*" -C $DIR rev-parse -q --verify HEAD)
            $dirty = (& $git -c "safe.directory=*" -C $DIR status --porcelain --untracked-files=no)
            if ($dirty) { throw "local edits in tracked files" }
        }
        G fetch -q origin main
        if ($before) { G merge -q --ff-only origin/main }
        else { G checkout -q -f -B main origin/main }  # first run: adopt the unzipped folder
        $after = (& $git -c "safe.directory=*" -C $DIR rev-parse HEAD)
        if ($after -ne $before) {
            Write-Host "Updated to $($after.Substring(0,7))."
            if ((Get-FileHash $req).Hash -ne $oldReq) {
                Remove-Item -Force (Join-Path $DIR ".venv\.deps_ok") -ErrorAction SilentlyContinue
            }
            # Re-run the (possibly new) launcher once.
            $env:KWGEN_UPDATED = "1"
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DIR "run.ps1")
            exit $LASTEXITCODE
        }
    } catch {
        Write-Host "Update skipped: $($_.Exception.Message)"
    }
}

function Test-Py($exe) {
    try { & $exe -c "import venv, ensurepip" *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

# 1) Pick a Python. A system python with venv+pip wins; else reuse/fetch a
#    portable build (python-build-standalone unzips and runs, no install/root).
$PY = $null
$justInstalled = $false
foreach ($c in @("python", "python3", "py")) {
    if ((Get-Command $c -ErrorAction SilentlyContinue) -and (Test-Py $c)) { $PY = $c; break }
}
$portable = Join-Path $DIR ".python\python\python.exe"
if (-not $PY) {
    if (Test-Path $portable) {
        $PY = $portable
    } else {
        Write-Host "Downloading a standalone Python (no install/root needed)..."
        # ponytail: pinned build; if the download 404s, bump $TAG/$PYVER to a newer release.
        $TAG = "20250115"; $PYVER = "3.12.8"
        $name = "cpython-$PYVER+$TAG-x86_64-pc-windows-msvc-install_only.tar.gz"
        $url = "https://github.com/astral-sh/python-build-standalone/releases/download/$TAG/$name"
        New-Item -ItemType Directory -Force -Path "$DIR\.python" | Out-Null
        $tgz = "$DIR\.python\py.tar.gz"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tgz
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
            throw "Need 'tar' (built in on Windows 10 1803+). Update Windows or extract $tgz manually."
        }
        tar -xzf $tgz -C "$DIR\.python"
        $PY = $portable
    }
}

# 2) venv + dependencies. Self-heals a broken venv (missing/no working pip -> rebuild).
$VPY = Join-Path $DIR ".venv\Scripts\python.exe"
$venvOk = $false
if (Test-Path $VPY) {
    # try/catch: with ErrorActionPreference=Stop, PS 5.1 turns the broken venv's
    # stderr into a terminating NativeCommandError before we can self-heal.
    try { & $VPY -m pip --version *> $null; $venvOk = ($LASTEXITCODE -eq 0) }
    catch { $venvOk = $false }
}
if (-not $venvOk) {
    Remove-Item -Recurse -Force "$DIR\.venv" -ErrorAction SilentlyContinue
    & $PY -m venv "$DIR\.venv"
}
if (-not (Test-Path "$DIR\.venv\.deps_ok")) {
    # PS 5.1 doesn't throw on a native nonzero exit: check it, or .deps_ok gets
    # written after a failed install and deps are never retried.
    & $VPY -m pip install --upgrade pip
    & $VPY -m pip install -r "$DIR\requirements.txt"
    if ($LASTEXITCODE -ne 0) { throw "pip install failed (check internet), run again." }
    New-Item -ItemType File -Force -Path "$DIR\.venv\.deps_ok" | Out-Null
}

# 3) Claude CLI (title/tag generation). Native installer is per-user, no admin.
$claudeBin = Join-Path $env:USERPROFILE ".local\bin"
if (Test-Path $claudeBin) { $env:Path = "$claudeBin;$env:Path" }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Claude Code CLI (per-user, no admin)..."
    try {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        if (Test-Path $claudeBin) { $env:Path = "$claudeBin;$env:Path" }
        $justInstalled = $true
    } catch {
        Write-Host "Warning: could not auto-install Claude CLI. Install it manually from"
        Write-Host "         https://docs.claude.com/claude-code and log in, then re-run."
    }
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "Note: 'claude' still not on PATH; the title/tag step will fail until it is."
    Write-Host "      You may need to open a new terminal after install, then re-run."
}

# Fresh install is not logged in yet, and the UI has no terminal: log in here once.
if ($justInstalled -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "=== Dang nhap Claude: lam theo huong dan tren trinh duyet, xong go /exit de tiep tuc ==="
    & claude
}

# 4) Run the web studio (opens the browser to the UI).
& $VPY "$DIR\web_studio.py"
