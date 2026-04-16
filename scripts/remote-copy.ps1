[CmdletBinding()]
param(
    [string]$HostName,

    [string]$Direction,

    [string]$SourcePath,

    [string]$TargetPath,

    [string]$UserName,

    [string]$Port,

    [string]$AuthMode = "ssh-alias",

    [string]$IdentityFile,

    [string]$Risk = "auto",

    [string]$ConfirmationState = "none",

    [string]$PasswordEnv = "SSH_PASSWORD",

    [string]$Timeout = "15",

    [switch]$Recursive,

    [switch]$Help
)

. (Join-Path $PSScriptRoot "ssh-tools.ps1")

function Write-Status {
    param(
        [string]$Name,
        [string]$Value
    )
    Write-Output ("{0}: {1}" -f $Name, $Value)
}

function Show-Usage {
    @"
remote-copy.ps1

Required:
  --host VALUE
  --direction upload|download
  --source VALUE
  --target VALUE

Optional:
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
  --recursive
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($Direction) -or [string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
    Show-Usage
    exit 2
}

$target = if ($HostName -notmatch "@" -and $UserName) { "{0}@{1}" -f $UserName, $HostName } else { $HostName }

function Test-SensitivePath {
    param([string]$PathValue)
    $patterns = @('/etc', '/usr', '/bin', '/sbin', '/opt', '/var/www', '.env', 'id_rsa', 'id_ed25519', '.bashrc', '.profile', '.zshrc')
    foreach ($pattern in $patterns) {
        if ($PathValue -like "$pattern*" -or $PathValue -like "*$pattern*") {
            return $true
        }
    }
    return $false
}

function Test-SafeWorkspace {
    param([string]$PathValue)
    return (
        $PathValue -eq "/tmp" -or
        $PathValue -like "/tmp/*" -or
        $PathValue -eq "/var/tmp" -or
        $PathValue -like "/var/tmp/*" -or
        $PathValue -like "~/tmp*"
    )
}

if ($Risk -eq "auto") {
    $Risk = "low"
    switch ($Direction) {
        "upload" {
            if ((Test-SensitivePath -PathValue $TargetPath) -or -not (Test-SafeWorkspace -PathValue $TargetPath)) {
                $Risk = "high"
            }
        }
        "download" {
            if (Test-SensitivePath -PathValue $SourcePath) {
                $Risk = "high"
            }
        }
        default {
            Write-Status "STATUS" "invalid_arguments"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_copy"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "direction must be upload or download"
            Write-Status "NEXT" "provide a valid --direction"
            exit 2
        }
    }
}

if ($Risk -eq "high" -and $ConfirmationState -ne "confirmed") {
    Write-Status "STATUS" "pending_confirmation"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" "high"
    Write-Status "REASON" "transfer is classified as high risk"
    Write-Status "NEXT" "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
    Write-Output ("DIRECTION: {0}" -f $Direction)
    Write-Output ("SOURCE: {0}" -f $SourcePath)
    Write-Output ("TARGET: {0}" -f $TargetPath)
    exit 3
}

if ($Direction -eq "upload" -and -not (Test-Path $SourcePath)) {
    Write-Status "STATUS" "missing_source"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "local source path does not exist"
    Write-Status "NEXT" "provide a valid local source path"
    exit 4
}

$toolchain = Get-SshToolchain
if ($toolchain.backend -eq "none") {
    Write-Status "STATUS" "auth_tool_unavailable"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "no supported SSH or copy backend was found"
    Write-Status "NEXT" "install OpenSSH or PuTTY tools and ensure they are discoverable"
    exit 4
}

if ($toolchain.backend -eq "openssh" -and [string]::IsNullOrWhiteSpace($toolchain.scp)) {
    Write-Status "STATUS" "auth_tool_unavailable"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "OpenSSH was found but scp is unavailable"
    Write-Status "NEXT" "install OpenSSH scp or add it to PATH"
    exit 4
}

if ($toolchain.backend -eq "putty" -and [string]::IsNullOrWhiteSpace($toolchain.pscp)) {
    Write-Status "STATUS" "auth_tool_unavailable"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "PuTTY plink was found but pscp is unavailable"
    Write-Status "NEXT" "install PuTTY pscp or use OpenSSH tools"
    exit 4
}

switch ($AuthMode) {
    "ssh-alias" { }
    "identity-file" {
        if (-not $IdentityFile -or -not (Test-Path $IdentityFile)) {
            Write-Status "STATUS" "missing_key"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_copy"
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
            Write-Status "ACTION" "remote_copy"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" $Risk
            Write-Status "REASON" "no default private key was found"
            Write-Status "NEXT" "generate a key or choose a different auth mode"
            exit 5
        }
        if ($candidates.Count -gt 1) {
            Write-Status "STATUS" "key_ambiguous"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_copy"
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
            Write-Status "ACTION" "remote_copy"
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
            Write-Status "ACTION" "remote_copy"
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
            Write-Status "ACTION" "remote_copy"
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
        Write-Status "ACTION" "remote_copy"
        Write-Status "AUTH_MODE" $AuthMode
        Write-Status "RISK" $Risk
        Write-Status "REASON" "unsupported auth mode"
        Write-Status "NEXT" "choose a supported auth mode"
        exit 2
    }
}

$sshArgs = @()
$copyArgs = @()
$sshProgram = ""
$copyProgram = ""
if ($toolchain.backend -eq "openssh") {
    $sshProgram = $toolchain.ssh
    $copyProgram = $toolchain.scp
    $sshArgs += @("-o", "ConnectTimeout=$Timeout")
    $copyArgs += @("-o", "ConnectTimeout=$Timeout")
} else {
    $sshProgram = $toolchain.plink
    $copyProgram = $toolchain.pscp
    $sshArgs += @("-batch")
    $copyArgs += @("-batch")
}
if ($Port) {
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-p", $Port)
        $copyArgs += @("-P", $Port)
    } else {
        $sshArgs += @("-P", $Port)
        $copyArgs += @("-P", $Port)
    }
}
if ($IdentityFile) {
    $sshArgs += @("-i", $IdentityFile)
    $copyArgs += @("-i", $IdentityFile)
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-o", "IdentitiesOnly=yes")
        $copyArgs += @("-o", "IdentitiesOnly=yes")
    }
}
if ($AuthMode -eq "password") {
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no")
        $copyArgs += @("-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no")
    } else {
        Write-Status "STATUS" "auth_mode_unsupported"
        Write-Status "HOST" $target
        Write-Status "ACTION" "remote_copy"
        Write-Status "AUTH_MODE" $AuthMode
        Write-Status "RISK" $Risk
        Write-Status "REASON" "password automation is only implemented for OpenSSH"
        Write-Status "NEXT" "use OpenSSH or a key-based auth mode"
        exit 8
    }
} else {
    if ($toolchain.backend -eq "openssh") {
        $sshArgs += @("-o", "BatchMode=yes")
        $copyArgs += @("-o", "BatchMode=yes")
    }
}
if ($Recursive) {
    $copyArgs += "-r"
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$EnvironmentTable
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $previous = @{}
    try {
        if ($EnvironmentTable) {
            foreach ($key in $EnvironmentTable.Keys) {
                $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
                [Environment]::SetEnvironmentVariable($key, $EnvironmentTable[$key], "Process")
            }
        }
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        return @{
            ExitCode = $process.ExitCode
            StdOut = (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
            StdErr = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
        }
    } finally {
        foreach ($key in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
        }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

$envTable = @{}
$askPassPath = $null
try {
    if ($AuthMode -eq "password") {
        $passwordValue = [Environment]::GetEnvironmentVariable($PasswordEnv, "Process")
        if ([string]::IsNullOrWhiteSpace($passwordValue)) {
            Write-Status "STATUS" "interactive_password_required"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_copy"
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

    if ($Direction -eq "upload" -and $ConfirmationState -ne "confirmed") {
        $precheckArgs = @($sshArgs + @($target, "test -e '$($TargetPath)'"))
        $precheck = Invoke-ProcessCapture -FilePath $sshProgram -ArgumentList $precheckArgs -EnvironmentTable $envTable
        if ($precheck.ExitCode -eq 0) {
            Write-Status "STATUS" "pending_confirmation"
            Write-Status "HOST" $target
            Write-Status "ACTION" "remote_copy"
            Write-Status "AUTH_MODE" $AuthMode
            Write-Status "RISK" "high"
            Write-Status "REASON" "upload target already exists on the remote host"
            Write-Status "NEXT" "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
            Write-Output ("SOURCE: {0}" -f $SourcePath)
            Write-Output ("TARGET: {0}" -f $TargetPath)
            exit 3
        }
    }

    $remoteSpec = "{0}:{1}" -f $target, $TargetPath
    $scpArgList = @($copyArgs)
    if ($Direction -eq "upload") {
        $scpArgList += @($SourcePath, $remoteSpec)
    } else {
        $remoteSource = "{0}:{1}" -f $target, $SourcePath
        $scpArgList += @($remoteSource, $TargetPath)
    }

    $result = Invoke-ProcessCapture -FilePath $copyProgram -ArgumentList $scpArgList -EnvironmentTable $envTable
} finally {
    if ($askPassPath) {
        Remove-Item -LiteralPath $askPassPath -Force -ErrorAction SilentlyContinue
    }
}

if ($result.ExitCode -eq 0) {
    Write-Status "STATUS" "ok"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "file transfer completed successfully"
    Write-Status "NEXT" "none"
    Write-Output ("DIRECTION: {0}" -f $Direction)
    Write-Output ("SOURCE: {0}" -f $SourcePath)
    Write-Output ("TARGET: {0}" -f $TargetPath)
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
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "ssh authentication failed"
    Write-Status "NEXT" "check auth mode, identity, agent, or password environment"
} elseif ($stderrText -match 'could not resolve hostname|connection timed out|no route to host|connection refused|name or service not known') {
    Write-Status "STATUS" "connect_failed"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "ssh connection failed"
    Write-Status "NEXT" "check host, port, network reachability, and SSH service availability"
} else {
    Write-Status "STATUS" "transfer_failed"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "file transfer returned a non-zero status"
    Write-Status "NEXT" "inspect STDERR and source or target paths"
}

Write-Output ("DIRECTION: {0}" -f $Direction)
Write-Output ("SOURCE: {0}" -f $SourcePath)
Write-Output ("TARGET: {0}" -f $TargetPath)
if ($result.StdOut) {
    Write-Output "OUTPUT:"
    Write-Output $result.StdOut.TrimEnd()
}
if ($result.StdErr) {
    Write-Output "STDERR:"
    Write-Output $result.StdErr.TrimEnd()
}
exit $result.ExitCode
