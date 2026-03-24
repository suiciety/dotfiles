# deploy-keys.ps1 — push SSH public keys and GPG public key to remote hosts
#
# Usage:
#   .\deploy-keys.ps1 ubuntu@host1 ubuntu@host2
#
# What it does:
#   1. Ensures ~/.ssh/authorized_keys exists on each remote host
#   2. Adds homekey_sk.pub (primary YubiKey) if not already present
#   3. Adds backupkey_sk.pub (backup YubiKey) if not already present
#   4. Imports the GPG public key into the remote user's keyring

param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Hosts
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GPG_KEY_ID = '7190A66213322F4A'

$SshKeys = @(
    Join-Path $ScriptDir 'homekey_sk.pub'
    Join-Path $ScriptDir 'backupkey_sk.pub'
)
$GpgKey = Join-Path $ScriptDir 'marcus.gpg.pub'

function Info    { param($msg) Write-Host "[deploy-keys] $msg" -ForegroundColor Cyan }
function Success { param($msg) Write-Host "[deploy-keys] ✓ $msg" -ForegroundColor Green }
function Warn    { param($msg) Write-Host "[deploy-keys] ! $msg" -ForegroundColor Yellow }

function Deploy-ToHost {
    param([string]$Host)

    Info "Deploying keys to $Host..."

    # Ensure ~/.ssh/authorized_keys exists with correct permissions
    & ssh $Host 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
    if ($LASTEXITCODE -ne 0) {
        Warn "Could not connect to $Host — skipping."
        return
    }

    # ── SSH public keys ───────────────────────────────────────────────────────
    foreach ($keyFile in $SshKeys) {
        if (-not (Test-Path $keyFile)) {
            Warn "$keyFile not found locally — skipping."
            continue
        }

        $keyName    = Split-Path $keyFile -Leaf
        $keyContent = (Get-Content $keyFile -Raw).Trim()

        $alreadyPresent = & ssh $Host "grep -qF '$keyContent' ~/.ssh/authorized_keys 2>/dev/null; echo `$?"
        if ($alreadyPresent.Trim() -eq '0') {
            Success "$keyName already present on $Host"
        } else {
            & ssh $Host "echo '$keyContent' >> ~/.ssh/authorized_keys"
            Success "$keyName added to ${Host}:~/.ssh/authorized_keys"
        }
    }

    # ── GPG public key ────────────────────────────────────────────────────────
    if (-not (Test-Path $GpgKey)) {
        Warn "marcus.gpg.pub not found locally — skipping GPG import."
    } else {
        $gpgPresent = & ssh $Host "gpg --list-keys $GPG_KEY_ID &>/dev/null 2>&1; echo `$?"
        if ($gpgPresent.Trim() -eq '0') {
            Success "GPG key $GPG_KEY_ID already imported on $Host"
        } else {
            $gpgContent = Get-Content $GpgKey -Raw
            & ssh $Host "echo '$gpgContent' | gpg --import 2>&1 | grep -v '^gpg:' || true"
            Success "GPG key imported on $Host"
        }
    }

    Success "All keys deployed to $Host"
    Write-Host ""
}

foreach ($h in $Hosts) {
    Deploy-ToHost $h
}

Write-Host "[deploy-keys] Done." -ForegroundColor Green
