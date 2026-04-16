[CmdletBinding()]
param(
    [string]$Action,

    [string]$KeyPath,

    [string]$KeyType = "ed25519",

    [string]$Comment = ("{0}@{1}" -f $env:USERNAME, $env:COMPUTERNAME),

    [string]$ConfirmationState = "pending",

    [switch]$Help
)

function Write-Status {
    param(
        [string]$Name,
        [string]$Value
    )
    Write-Output ("{0}: {1}" -f $Name, $Value)
}

function Show-Usage {
    @"
setup-auth.ps1

Required:
  --action discover|agent|generate|show-public

Optional:
  --key-path VALUE
  --key-type ed25519|ecdsa|rsa
  --comment VALUE
  --confirmation-state pending|confirmed
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    Show-Usage
    exit 2
}

function Get-DefaultKeyPaths {
    $userHome = [Environment]::GetFolderPath("UserProfile")
    @(
        (Join-Path $userHome ".ssh\id_ed25519"),
        (Join-Path $userHome ".ssh\id_ecdsa"),
        (Join-Path $userHome ".ssh\id_rsa")
    )
}

switch ($Action) {
    "discover" {
        $keys = Get-DefaultKeyPaths | Where-Object { Test-Path $_ }
        if (-not $keys) {
            Write-Status "STATUS" "no_keys_found"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "no default private keys found"
            Write-Status "NEXT" "generate a key or provide an explicit identity file"
            exit 0
        }
        Write-Status "STATUS" "ok"
        Write-Status "ACTION" "auth_setup"
        Write-Status "REASON" "discovered default private keys"
        Write-Status "NEXT" "choose a key or continue with default-key-discovery"
        Write-Output "FOUND_KEYS:"
        $keys
    }
    "agent" {
        $sshAdd = Get-Command ssh-add -ErrorAction SilentlyContinue
        if (-not $sshAdd) {
            Write-Status "STATUS" "auth_tool_unavailable"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "ssh-add is not available"
            Write-Status "NEXT" "use explicit key files instead"
            exit 4
        }
        $output = & ssh-add -l 2>&1
        if ($LASTEXITCODE -ne 0 -and ($output -join "`n") -match "The agent has no identities") {
            Write-Status "STATUS" "no_agent_keys"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "ssh-agent is running but has no identities"
            Write-Status "NEXT" "add a key or use a file-based auth mode"
            exit 0
        }
        Write-Status "STATUS" "ok"
        Write-Status "ACTION" "auth_setup"
        Write-Status "REASON" "listed ssh-agent identities"
        Write-Status "NEXT" "choose one identity if more than one is available"
        Write-Output "AGENT_IDENTITIES:"
        $output
    }
    "generate" {
        $userHome = [Environment]::GetFolderPath("UserProfile")
        $keyPath = if ($KeyPath) { $KeyPath } else { Join-Path $userHome ".ssh\id_ed25519" }
        $dir = Split-Path -Parent $keyPath
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }

        if ((Test-Path $keyPath) -and $ConfirmationState -ne "confirmed") {
            Write-Status "STATUS" "pending_confirmation"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "key path already exists and generation would overwrite or replace an existing key"
            Write-Status "NEXT" "rerun with --confirmation-state confirmed if this is intended"
            Write-Output ("KEY_PATH: {0}" -f $keyPath)
            exit 3
        }

        if ($ConfirmationState -ne "confirmed") {
            Write-Status "STATUS" "pending_confirmation"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "generating a new SSH keypair changes local auth state"
            Write-Status "NEXT" "rerun with --confirmation-state confirmed"
            Write-Output ("KEY_PATH: {0}" -f $keyPath)
            exit 3
        }

        & ssh-keygen -t $KeyType -f $keyPath -N "" -C $Comment | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Status "STATUS" "auth_setup_failed"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "ssh-keygen failed"
            Write-Status "NEXT" "inspect the local environment and retry"
            exit 5
        }

        Write-Status "STATUS" "ok"
        Write-Status "ACTION" "auth_setup"
        Write-Status "REASON" "generated new SSH keypair"
        Write-Status "NEXT" "install the public key on the remote host or print it with --action show-public"
        Write-Output ("KEY_PATH: {0}" -f $keyPath)
        Write-Output ("PUBLIC_KEY_PATH: {0}.pub" -f $keyPath)
    }
    "show-public" {
        $userHome = [Environment]::GetFolderPath("UserProfile")
        $keyPath = if ($KeyPath) { $KeyPath } else { Join-Path $userHome ".ssh\id_ed25519" }
        $publicPath = "{0}.pub" -f $keyPath
        if (-not (Test-Path $publicPath)) {
            Write-Status "STATUS" "missing_key"
            Write-Status "ACTION" "auth_setup"
            Write-Status "REASON" "public key file not found"
            Write-Status "NEXT" "generate a new key or provide a valid --key-path"
            Write-Output ("PUBLIC_KEY_PATH: {0}" -f $publicPath)
            exit 5
        }
        Write-Status "STATUS" "ok"
        Write-Status "ACTION" "auth_setup"
        Write-Status "REASON" "printed public key"
        Write-Status "NEXT" "install the key on the remote host"
        Write-Output ("PUBLIC_KEY_PATH: {0}" -f $publicPath)
        Write-Output "PUBLIC_KEY:"
        Get-Content -LiteralPath $publicPath
    }
    default {
        Write-Status "STATUS" "invalid_arguments"
        Write-Status "ACTION" "auth_setup"
        Write-Status "REASON" ("unsupported action: {0}" -f $Action)
        Write-Status "NEXT" "run with --help"
        exit 2
    }
}
