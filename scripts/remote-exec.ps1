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

    [Alias("h")]
    [switch]$Help,

    [Alias("help-json")]
    [switch]$HelpJson
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

function Get-HelpSpec {
    return [ordered]@{
        name = "remote-exec.ps1"
        summary = "Execute a command on a Linux host over SSH with auth and risk checks."
        usage = @(
            "remote-exec.ps1 --host VALUE --command VALUE [options]",
            "remote-exec.ps1 --host VALUE --command-file VALUE [options]",
            "remote-exec.ps1 --help",
            "remote-exec.ps1 --help-json"
        )
        arguments = @(
            [ordered]@{ name = "--host"; required = $true; value = "VALUE"; description = "SSH host, alias, or user@host target." },
            [ordered]@{ name = "--command"; required = $false; value = "VALUE"; description = "Inline command text to execute remotely." },
            [ordered]@{ name = "--command-file"; required = $false; value = "VALUE"; description = "Path to a local file containing remote shell script text streamed over stdin." },
            [ordered]@{ name = "--user"; required = $false; value = "VALUE"; description = "Username, used when host is not in user@host form." },
            [ordered]@{ name = "--port"; required = $false; value = "VALUE"; description = "SSH port." },
            [ordered]@{ name = "--auth-mode"; required = $false; value = "ssh-alias|identity-file|default-key-discovery|ssh-agent|password"; description = "Authentication strategy." },
            [ordered]@{ name = "--identity-file"; required = $false; value = "VALUE"; description = "Private key path for identity-file mode." },
            [ordered]@{ name = "--known-hosts-file"; required = $false; value = "VALUE"; description = "known_hosts path for host key verification." },
            [ordered]@{ name = "--remote-dir"; required = $false; value = "VALUE"; description = "Remote working directory before command execution." },
            [ordered]@{ name = "--risk"; required = $false; value = "auto|low|high"; description = "Risk override. auto classifies command content." },
            [ordered]@{ name = "--confirmation-state"; required = $false; value = "pending|confirmed|none"; description = "High-risk confirmation gate." },
            [ordered]@{ name = "--password-env"; required = $false; value = "VALUE"; description = "Environment variable name for password mode." },
            [ordered]@{ name = "--timeout"; required = $false; value = "VALUE"; description = "SSH connect timeout in seconds." },
            [ordered]@{ name = "--help|-h|-Help"; required = $false; value = ""; description = "Show human-readable help." },
            [ordered]@{ name = "--help-json|-help-json"; required = $false; value = ""; description = "Show machine-readable JSON help." }
        )
        examples = @(
            "remote-exec.ps1 --host app-prod --command `"uname -a`"",
            "remote-exec.ps1 --host 10.0.0.8 --user deploy --command-file .\ops\healthcheck.sh",
            "remote-exec.ps1 --host app-prod --command `"systemctl restart nginx`" --confirmation-state confirmed"
        )
        output_contract = [ordered]@{
            format = "plain-text status labels with optional OUTPUT/STDERR blocks"
            labels = @("STATUS", "HOST", "ACTION", "AUTH_MODE", "RISK", "REASON", "NEXT")
            common_statuses = @(
                "ok", "invalid_arguments", "pending_confirmation", "missing_command_file",
                "auth_tool_unavailable", "missing_key", "key_ambiguous", "missing_known_hosts",
                "interactive_password_required", "auth_mode_unsupported", "auth_failed",
                "connect_failed", "command_failed"
            )
        }
    }
}

function Show-Usage {
    @"
remote-exec.ps1

SUMMARY
  Execute a command on a Linux host over SSH with auth and risk checks.

USAGE
  remote-exec.ps1 --host VALUE --command VALUE [options]
  remote-exec.ps1 --host VALUE --command-file VALUE [options]
  remote-exec.ps1 --help
  remote-exec.ps1 --help-json

ARGUMENTS
  --host VALUE
  --command VALUE | --command-file VALUE
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --known-hosts-file VALUE
  --remote-dir VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
  --help | -h | -Help
  --help-json | -help-json

OUTPUT CONTRACT
  Plain-text labels: STATUS, HOST, ACTION, AUTH_MODE, RISK, REASON, NEXT
  Optional blocks: OUTPUT, STDERR

EXAMPLES
  remote-exec.ps1 --host app-prod --command "uname -a"
  remote-exec.ps1 --host 10.0.0.8 --user deploy --command-file .\ops\healthcheck.sh
  remote-exec.ps1 --host app-prod --command "systemctl restart nginx" --confirmation-state confirmed
"@
}

function Show-HelpJson {
    $helpSpec = Get-HelpSpec
    $helpSpec | ConvertTo-Json -Depth 8
}

function New-RemoteScriptInputText {
    param(
        [string]$ScriptText,
        [string]$RemoteDir
    )

    if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
        return $ScriptText
    }

    $prefix = 'cd {0} || exit $?' -f (ConvertTo-PosixSingleQuotedString -Value $RemoteDir)
    if ([string]::IsNullOrEmpty($ScriptText)) {
        return $prefix + "`n"
    }

    return "{0}`n{1}" -f $prefix, $ScriptText
}

$compatHelpRequested = $HostName -in @("--help", "-h", "-Help")
$compatHelpJsonRequested = $HostName -eq "--help-json"

if ($Help -or $compatHelpRequested) {
    Show-Usage
    exit 0
}

if ($HelpJson -or $compatHelpJsonRequested) {
    Show-HelpJson
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
        ) | Where-Object { Test-Path -LiteralPath $_ }

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

$isCommandFileMode = -not [string]::IsNullOrWhiteSpace($CommandFile)

# The caller owns remote shell quoting for CommandText. Only RemoteDir is
# shell-escaped here because it is always treated as a path literal.
$remoteCommand = if ($RemoteDir) { "cd {0} && {1}" -f (ConvertTo-PosixSingleQuotedString -Value $RemoteDir), $CommandText } else { $CommandText }
$remoteScriptInputText = if ($isCommandFileMode) { New-RemoteScriptInputText -ScriptText $CommandText -RemoteDir $RemoteDir } else { $null }

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
    $sshArgs += @("-o", (Format-OpenSshOptionAssignment -Name "UserKnownHostsFile" -Value $resolvedKnownHostsFile))
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
if ($isCommandFileMode) {
    $sshArgs += @($target, "sh -s")
} else {
    $sshArgs += @($target, $remoteCommand)
}

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

        $askPassPath = New-SshAskPassScript
        $envTable = @{
            SSH_LINUX_ASKPASS_SECRET = $passwordValue
            SSH_ASKPASS = $askPassPath
            SSH_ASKPASS_REQUIRE = "force"
            DISPLAY = "codex-ssh-linux"
        }
    }

    $invokeParams = @{
        FilePath = $sshProgram
        ArgumentList = $sshArgs
        EnvironmentTable = $envTable
    }
    if ($isCommandFileMode) {
        $invokeParams.InputText = $remoteScriptInputText
    }

    $result = Invoke-NativeProcessCapture @invokeParams
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
