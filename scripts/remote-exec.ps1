[CmdletBinding()]
param(
    [string]$HostName,

    [string]$CommandText,

    [string]$CommandFile,

    [string]$UserName,

    [string]$Port,

    [string]$AuthMode = "ssh-alias",

    [string]$IdentityFile,

    [string]$KnownHostsFile,

    [string]$RemoteDir,

    [string]$Risk = "auto",

    [string]$ConfirmationState = "none",

    [string]$PasswordEnv = "SSH_PASSWORD",

    [string]$Timeout = "15",

    [switch]$Help
)

. (Join-Path $PSScriptRoot "ssh-tools.ps1")
. (Join-Path $PSScriptRoot "process-utils.ps1")

function Write-Status {
    param(
        [string]$Name,
        [string]$Value
    )
    Write-Output ("{0}: {1}" -f $Name, $Value)
}

function Show-Usage {
    @"
remote-exec.ps1

Required:
  --host VALUE
  --command VALUE | --command-file VALUE

Optional:
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --known-hosts-file VALUE
  --command-file VALUE
  --remote-dir VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($CommandText) -and -not [string]::IsNullOrWhiteSpace($CommandFile)) {
    Write-Status "STATUS" "invalid_arguments"
    Write-Status "ACTION" "remote_exec"
    Write-Status "REASON" "provide either --command or --command-file, not both"
    Write-Status "NEXT" "choose one command input mode and rerun"
    exit 2
}

if (-not [string]::IsNullOrWhiteSpace($CommandFile)) {
    if (-not (Test-Path -LiteralPath $CommandFile)) {
        Write-Status "STATUS" "missing_command_file"
        Write-Status "ACTION" "remote_exec"
        Write-Status "REASON" "command file was not found"
        Write-Status "NEXT" "provide a valid --command-file"
        Write-Output ("COMMAND_FILE: {0}" -f $CommandFile)
        exit 4
    }
    $CommandText = Read-TextFileAuto -LiteralPath $CommandFile
}

if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($CommandText)) {
    Show-Usage
    exit 2
}

$target = if ($HostName -notmatch "@" -and $UserName) { "{0}@{1}" -f $UserName, $HostName } else { $HostName }

function Test-HighRiskCommand {
    param([string]$CommandText)

    $patterns = @(
        '(^|[\s;|&])(rm|chmod|chown|chgrp|kill|pkill)([\s]|$)',
        'systemctl\s+(restart|stop)',
        'service\s+.+\s+restart',
        'git\s+push',
        'git\s+reset\s+--hard',
        'git\s+clean\s+-fd',
        'sudo\s',
        'dd\s',
        'mkfs',
        'fdisk',
        'parted',
        'iptables',
        'nft',
        'crontab\s+-r',
        '(^|[^>])>>?\s*(/etc|/usr|/bin|/sbin|/opt|/var/www)',
        '(^|[\s;|&])(bash|sh|python|python3)\s+\S+'
    )
    foreach ($pattern in $patterns) {
        if ($CommandText -match $pattern) {
            return $true
        }
    }
    if ($CommandText -match 'curl' -and $CommandText -match '\|\s*bash') {
        return $true
    }
    if ($CommandText -match 'wget' -and $CommandText -match '\|\s*bash') {
        return $true
    }
    return $false
}

if ($Risk -eq "auto") {
    $Risk = if (Test-HighRiskCommand -CommandText $CommandText) { "high" } else { "low" }
}

if ($Risk -eq "high" -and $ConfirmationState -ne "confirmed") {
    Write-Status "STATUS" "pending_confirmation"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" "high"
    Write-Status "REASON" "command is classified as high risk"
    Write-Status "NEXT" "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
    Write-Output ("COMMAND: {0}" -f $CommandText)
    exit 3
}

$toolchain = Get-SshToolchain
if ($toolchain.backend -eq "none") {
    Write-Status "STATUS" "auth_tool_unavailable"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "no supported SSH backend was found"
    Write-Status "NEXT" "install OpenSSH or PuTTY tools and ensure they are discoverable"
    exit 4
}

switch ($AuthMode) {
    "ssh-alias" { }
    "identity-file" {
        if (-not $IdentityFile -or -not (Test-Path -LiteralPath $IdentityFile)) {
            Write-Status "STATUS" "missing_key"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "explicit identity file was required but not found"
            Write-Status "NEXT" "provide a valid --identity-file"
            exit 5
        }
    }
    "default-key-discovery" {
        $userHome = [Environment]::GetFolderPath("UserProfile")
        $candidates = @(
            (Join-Path $userHome ".ssh\id_ed25519"),
            (Join-Path $userHome ".ssh\id_ecdsa"),
            (Join-Path $userHome ".ssh\id_rsa")
        ) | Where-Object { Test-Path $_ }

        if (-not $candidates) {
            Write-Status "STATUS" "missing_key"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "no default private key was found"
            Write-Status "NEXT" "generate a key or choose a different auth mode"
            exit 5
        }
        if ($candidates.Count -gt 1) {
            Write-Status "STATUS" "key_ambiguous"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "multiple default private keys were found"
            Write-Status "NEXT" "choose one key explicitly with --identity-file"
            Write-Output "CANDIDATE_KEYS:"
            $candidates
            exit 6
        }
        $IdentityFile = $candidates[0]
    }
    "ssh-agent" {
        if ($toolchain.backend -ne "openssh" -or [string]::IsNullOrWhiteSpace($toolchain.ssh_add)) {
            Write-Status "STATUS" "auth_tool_unavailable"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "ssh-agent support requires OpenSSH ssh-add"
            Write-Status "NEXT" "use a file-based auth mode or install OpenSSH tools"
            exit 4
        }
        $agentOutput = & $toolchain.ssh_add -l 2>&1
        $agentText = ($agentOutput | Out-String)
        if ($agentText -match "The agent has no identities") {
            Write-Status "STATUS" "missing_key"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "ssh-agent has no identities"
            Write-Status "NEXT" "add a key or use another auth mode"
            exit 5
        }
        $identityCount = ($agentOutput | Where-Object { $_ -match '^\d+' }).Count
        if ($identityCount -gt 1) {
            Write-Status "STATUS" "key_ambiguous"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "ssh-agent contains multiple identities"
            Write-Status "NEXT" "choose an explicit identity file or narrow the agent state"
            Write-Output "AGENT_IDENTITIES:"
            $agentOutput
            exit 6
        }
    }
    "password" { }
    default {
        Write-Status "STATUS" "invalid_arguments"
        Write-Status "HOST" $target
        Write-Status "ACTION" "remote_exec"
        Write-Status "AUTH_MODE" $AuthMode
        Write-Status "RISK" $Risk
        Write-Status "REASON" "unsupported auth mode"
        Write-Status "NEXT" "choose a supported auth mode"
        exit 2
    }
}

$resolvedKnownHostsFile = Resolve-KnownHostsFile -KnownHostsFile $KnownHostsFile
if (-not [string]::IsNullOrWhiteSpace($resolvedKnownHostsFile) -and -not (Test-Path -LiteralPath $resolvedKnownHostsFile)) {
    Write-Status "STATUS" "missing_known_hosts"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "known_hosts file was not found"
    Write-Status "NEXT" "provide a valid --known-hosts-file or accept the host key once outside the sandbox"
    Write-Output ("KNOWN_HOSTS_FILE: {0}" -f $resolvedKnownHostsFile)
    exit 5
}

$remoteCommand = if ($RemoteDir) { "cd {0} && {1}" -f (ConvertTo-PosixSingleQuotedString -Value $RemoteDir), $CommandText } else { $CommandText }

$sshArgs = @()
$sshProgram = ""
if ($toolchain.backend -eq "openssh") {
    $sshProgram = $toolchain.ssh
    $sshArgs += @("-o", "ConnectTimeout=$Timeout")
} elseif ($toolchain.backend -eq "putty") {
    $sshProgram = $toolchain.plink
    $sshArgs += @("-batch")
}
if ($Port) {
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-p", $Port)
    } else {
        $sshArgs += @("-P", $Port)
    }
}
if ($IdentityFile) {
    $sshArgs += @("-i", $IdentityFile)
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-o", "IdentitiesOnly=yes")
    }
}
if ($resolvedKnownHostsFile -and $toolchain.backend -eq "openssh") {
    $sshArgs += @("-o", "UserKnownHostsFile=$resolvedKnownHostsFile")
}
if ($AuthMode -eq "password") {
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no")
    } else {
        Write-Status "STATUS" "auth_mode_unsupported"
        Write-Status "HOST" $target
        Write-Status "ACTION" "remote_exec"
        Write-Status "AUTH_MODE" $AuthMode
        Write-Status "RISK" $Risk
        Write-Status "REASON" "password automation is only implemented for OpenSSH"
        Write-Status "NEXT" "use OpenSSH or a key-based auth mode"
        exit 8
    }
} else {
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-o", "BatchMode=yes")
    }
}
$sshArgs += @($target, $remoteCommand)

$envTable = @{}
$askPassPath = $null
try {
    if ($AuthMode -eq "password") {
        $passwordValue = [Environment]::GetEnvironmentVariable($PasswordEnv, "Process")
        if ([string]::IsNullOrWhiteSpace($passwordValue)) {
            Write-Status "STATUS" "interactive_password_required"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_exec"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" ("password auth requires a named environment variable such as {0}" -f $PasswordEnv)
            Write-Status "NEXT" "set the password environment variable and rerun"
            exit 7
        }

        $askPassPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".cmd")
        Set-Content -LiteralPath $askPassPath -Encoding ASCII -Value "@echo off`r`necho %SSH_LINUX_ASKPASS_SECRET%`r`n"
        $envTable = @{
            SSH_LINUX_ASKPASS_SECRET = $passwordValue
            SSH_ASKPASS = $askPassPath
            SSH_ASKPASS_REQUIRE = "force"
            DISPLAY = "codex-ssh-linux"
        }
    }

    $result = Invoke-NativeProcessCapture -FilePath $sshProgram -ArgumentList $sshArgs -EnvironmentTable $envTable
} finally {
    if ($askPassPath) {
        Remove-Item -LiteralPath $askPassPath -Force -ErrorAction SilentlyContinue
    }
}

if ($result.ExitCode -eq 0) {
    Write-Status "STATUS" "ok"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "remote command executed successfully"
    Write-Status "NEXT" "none"
    if ($result.StdOut) {
        Write-Output "OUTPUT:"
        Write-Output $result.StdOut.TrimEnd()
    }
    if ($result.StdErr) {
        Write-Output "STDERR:"
        Write-Output $result.StdErr.TrimEnd()
    }
    exit 0
}

$stderrText = $result.StdErr
if ($stderrText -match 'permission denied|authentication failed') {
    Write-Status "STATUS" "auth_failed"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "ssh authentication failed"
    Write-Status "NEXT" "check auth mode, identity, agent, or password environment"
} elseif ($stderrText -match 'could not resolve hostname|connection timed out|no route to host|connection refused|name or service not known') {
    Write-Status "STATUS" "connect_failed"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "ssh connection failed"
    Write-Status "NEXT" "check host, port, network reachability, and SSH service availability"
} else {
    Write-Status "STATUS" "command_failed"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_exec"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "remote command returned a non-zero status"
    Write-Status "NEXT" "inspect STDERR and remote state"
}

if ($result.StdOut) {
    Write-Output "OUTPUT:"
    Write-Output $result.StdOut.TrimEnd()
}
if ($result.StdErr) {
    Write-Output "STDERR:"
    Write-Output $result.StdErr.TrimEnd()
}
exit $result.ExitCode
