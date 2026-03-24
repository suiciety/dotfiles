# bootstrap.ps1 — Windows setup for Mark's dotfiles
#
# Usage (run from an elevated PowerShell or Windows Terminal):
#   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#   irm https://raw.githubusercontent.com/suiciety/dotfiles/main/bootstrap.ps1 | iex
#
# What it does:
#   1. Checks/upgrades OpenSSH to 8.2+ (required for FIDO2)
#   2. Imports the GPG public key (requires Gpg4win)
#   3. Deploys YubiKey .pub files; prompts to insert each key and exports stubs via ssh-keygen -K
#   4. Writes SSH config with SecurityKeyProvider for FIDO2 support
#   5. Installs oh-my-posh via winget if missing
#   6. Deploys the atomic.omp.json theme
#   7. Configures PowerShell profile to use oh-my-posh

$ErrorActionPreference = 'Stop'

$BASE_URL  = 'https://raw.githubusercontent.com/suiciety/dotfiles/main'
$GPG_KEY_ID = '7190A66213322F4A'
$SSH_DIR   = "$env:USERPROFILE\.ssh"
$OMP_DIR   = "$env:USERPROFILE\.config\omp"
$OMP_THEME = "$OMP_DIR\atomic.omp.json"

function Info    { param($msg) Write-Host "[bootstrap] $msg" -ForegroundColor Cyan }
function Success { param($msg) Write-Host "[bootstrap] ✓ $msg" -ForegroundColor Green }
function Warn    { param($msg) Write-Host "[bootstrap] ! $msg" -ForegroundColor Yellow }
function Fail    { param($msg) Write-Host "[bootstrap] ✗ $msg" -ForegroundColor Red }

# ── 1. OpenSSH version check ──────────────────────────────────────────────────

Info "Checking OpenSSH version..."

$sshVer = $null
try {
    $sshOutput = & ssh -V 2>&1
    if ($sshOutput -match 'OpenSSH_(\d+\.\d+)') {
        $sshVer = [version]$Matches[1]
    }
} catch {}

if ($null -eq $sshVer) {
    Warn "OpenSSH not found."
} elseif ($sshVer -ge [version]'8.2') {
    Success "OpenSSH $sshVer supports FIDO2"
} else {
    Warn "OpenSSH $sshVer detected — FIDO2 requires 8.2+. Attempting upgrade via winget..."
    try {
        winget install --id Microsoft.OpenSSH.Beta -e --accept-package-agreements --accept-source-agreements
        Success "OpenSSH upgraded — restart this terminal then re-run the script."
        exit 0
    } catch {
        Warn "winget upgrade failed. Install manually:"
        Warn "  winget install Microsoft.OpenSSH.Beta"
        Warn "  or: Settings → Optional Features → OpenSSH Client"
    }
}

# ── 2. GPG public key ─────────────────────────────────────────────────────────

Info "Importing GPG public key $GPG_KEY_ID..."

if (-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
    Warn "gpg not found — install Gpg4win: https://www.gpg4win.org/"
    Warn "Skipping GPG key import."
} else {
    $gpgCheck = & gpg --list-keys $GPG_KEY_ID 2>&1
    if ($LASTEXITCODE -eq 0) {
        Success "GPG key $GPG_KEY_ID already imported"
    } else {
        $tmpGpg = [System.IO.Path]::GetTempFileName() + '.gpg.pub'
        try {
            Invoke-WebRequest -Uri "$BASE_URL/marcus.gpg.pub" -OutFile $tmpGpg -UseBasicParsing
            & gpg --import $tmpGpg 2>&1 | Where-Object { $_ -notmatch '^gpg:' } | ForEach-Object { Write-Host $_ }
            Success "GPG key imported"
        } finally {
            Remove-Item $tmpGpg -ErrorAction SilentlyContinue
        }
    }
}

# ── 3. YubiKey FIDO2 SSH stubs ────────────────────────────────────────────────

Info "Setting up YubiKey FIDO2 SSH keys..."
New-Item -ItemType Directory -Path $SSH_DIR -Force | Out-Null

# -- Deploy .pub files from repo ----------------------------------------------

foreach ($pub in @('homekey_sk.pub', 'backupkey_sk.pub')) {
    $dest = Join-Path $SSH_DIR $pub
    $remote = (Invoke-WebRequest -Uri "$BASE_URL/$pub" -UseBasicParsing).Content.Trim()

    if (Test-Path $dest) {
        $local = (Get-Content $dest -Raw).Trim()
        if ($local -eq $remote) {
            Success "$pub already up to date"
        } else {
            $backup = "$dest.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
            Copy-Item $dest $backup
            Warn "Existing $pub backed up to $backup"
            Set-Content -Path $dest -Value $remote -NoNewline
            Success "$pub updated"
        }
    } else {
        Set-Content -Path $dest -Value $remote -NoNewline
        Success "$pub deployed to $SSH_DIR"
    }
}

# -- Export private stubs from YubiKeys ---------------------------------------

function Export-YubiKeyStub {
    param([string]$KeyName)

    $destPriv = Join-Path $SSH_DIR $KeyName
    $destPub  = Join-Path $SSH_DIR "$KeyName.pub"

    if ((Test-Path $destPriv) -and (Test-Path $destPub)) {
        Success "$KeyName stub already present — skipping"
        return
    }

    Write-Host ""
    $response = Read-Host "[bootstrap] Insert your YubiKey for '$KeyName' then press Enter (or 's' to skip)"
    if ($response -match '^[Ss]$') {
        Warn "Skipping $KeyName — run 'cd `$env:USERPROFILE\.ssh; ssh-keygen -K' manually when ready"
        return
    }

    $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "yk-export-$(Get-Random)") -Force
    Info "Exporting resident keys from YubiKey (touch the key if it flashes)..."

    try {
        Push-Location $tmp.FullName
        & ssh-keygen -K 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen -K failed"
        }
    } catch {
        Warn "ssh-keygen -K failed — ensure YubiKey is fully inserted and try again."
        Warn "Manual fallback: cd `$env:USERPROFILE\.ssh; ssh-keygen -K"
        Warn "  Then rename: id_ed25519_sk_rk → $KeyName and id_ed25519_sk_rk.pub → $KeyName.pub"
        Pop-Location
        Remove-Item $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
        return
    } finally {
        Pop-Location
    }

    # Find exported private stubs (files without .pub extension)
    $privKeys = Get-ChildItem $tmp.FullName -Filter 'id_*_sk_rk*' |
                Where-Object { $_.Extension -ne '.pub' }

    if ($privKeys.Count -eq 0) {
        Warn "No resident keys found on this YubiKey — ensure key was generated with -O resident"
        Remove-Item $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    if ($privKeys.Count -gt 1) {
        Warn "$($privKeys.Count) resident keys found — using first for $KeyName"
        Warn "Other exported stubs left in $($tmp.FullName) — review and move manually if needed"
    }

    $first = $privKeys[0]
    Move-Item $first.FullName $destPriv -Force
    Move-Item "$($first.FullName).pub" $destPub -Force
    Remove-Item $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Success "$KeyName stub exported to $SSH_DIR"
}

$sshFido2Ready = ($null -ne $sshVer -and $sshVer -ge [version]'8.2')

if ($sshFido2Ready) {
    Export-YubiKeyStub 'homekey_sk'
    Export-YubiKeyStub 'backupkey_sk'
} else {
    Warn "Skipping YubiKey stub export — fix OpenSSH version first"
    Warn "Manual fallback: cd `$env:USERPROFILE\.ssh; ssh-keygen -K"
}

# ── 4. SSH config — FIDO2 settings ───────────────────────────────────────────

Info "Configuring SSH client for FIDO2..."

$sshConfig = Join-Path $SSH_DIR 'config'
$fido2Block = @"
Host *
    SecurityKeyProvider internal
    PreferredAuthentications publickey,password
    IdentityFile ~/.ssh/homekey_sk
    IdentityFile ~/.ssh/backupkey_sk
    IdentitiesOnly yes
"@

if (Test-Path $sshConfig) {
    $content = Get-Content $sshConfig -Raw
    if ($content -match 'SecurityKeyProvider') {
        Success "SSH config already has FIDO2 settings"
    } else {
        $backup = "$sshConfig.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $sshConfig $backup
        Warn "Existing SSH config backed up to $backup"
        Set-Content $sshConfig -Value ($fido2Block + "`n" + $content)
        Success "SSH config updated with FIDO2 settings"
    }
} else {
    Set-Content $sshConfig -Value $fido2Block
    Success "SSH config created with FIDO2 settings"
}

# ── 5. oh-my-posh ─────────────────────────────────────────────────────────────

Info "Checking oh-my-posh..."

if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $ompVer = & oh-my-posh version 2>$null
    Success "oh-my-posh already installed ($ompVer)"
} else {
    Info "Installing oh-my-posh via winget..."
    try {
        winget install --id JanDeDobbeleer.OhMyPosh -e --accept-package-agreements --accept-source-agreements
        # Refresh PATH so oh-my-posh is available immediately
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        Success "oh-my-posh installed"
    } catch {
        Warn "winget install failed. Install manually: winget install JanDeDobbeleer.OhMyPosh"
    }
}

# ── 6. oh-my-posh theme ───────────────────────────────────────────────────────

Info "Deploying oh-my-posh theme..."
New-Item -ItemType Directory -Path $OMP_DIR -Force | Out-Null

$remoteTheme = (Invoke-WebRequest -Uri "$BASE_URL/atomic.omp.json" -UseBasicParsing).Content

if (Test-Path $OMP_THEME) {
    $localTheme = Get-Content $OMP_THEME -Raw
    if ($localTheme -eq $remoteTheme) {
        Success "oh-my-posh theme already up to date"
    } else {
        $backup = "$OMP_THEME.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $OMP_THEME $backup
        Warn "Existing theme backed up to $backup"
        Set-Content $OMP_THEME -Value $remoteTheme
        Success "oh-my-posh theme updated"
    }
} else {
    Set-Content $OMP_THEME -Value $remoteTheme
    Success "oh-my-posh theme deployed to $OMP_THEME"
}

# ── 7. PowerShell profile ─────────────────────────────────────────────────────

Info "Configuring PowerShell profile..."

$ompLine = 'oh-my-posh init pwsh --config "$env:USERPROFILE\.config\omp\atomic.omp.json" | Invoke-Expression'

# Ensure profile file and its directory exist
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue

if ($profileContent -match 'oh-my-posh') {
    # Replace existing oh-my-posh line
    $updated = ($profileContent -split "`n" | Where-Object { $_ -notmatch 'oh-my-posh' }) -join "`n"
    Set-Content $PROFILE -Value ($updated.TrimEnd() + "`n$ompLine`n")
    Success "oh-my-posh profile line updated"
} else {
    Add-Content $PROFILE -Value "`n$ompLine"
    Success "oh-my-posh added to PowerShell profile"
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "[bootstrap] Done." -ForegroundColor Green
Write-Host "[bootstrap] Restart Windows Terminal (or open a new tab) to activate oh-my-posh."
Write-Host ""
Write-Host "[bootstrap] Nerd Font note: Windows Terminal ships with 'CaskaydiaCove Nerd Font'."
Write-Host "[bootstrap]   Settings → your profile → Appearance → Font face"
Write-Host "[bootstrap]   Set to: CaskaydiaCove Nerd Font"
