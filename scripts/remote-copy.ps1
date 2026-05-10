[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RawArgs
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
        name = "remote-copy.ps1"
        summary = "Upload or download files over SSH/SCP with auth and risk checks."
        usage = @(
            "remote-copy.ps1 --host VALUE --direction upload|download --source VALUE --target VALUE [options]",
            "remote-copy.ps1 --help",
            "remote-copy.ps1 --help-json"
        )
        arguments = @(
            [ordered]@{ name = "--host"; required = $true; value = "VALUE"; description = "SSH host, alias, or user@host target." },
            [ordered]@{ name = "--direction"; required = $true; value = "upload|download"; description = "Transfer direction." },
            [ordered]@{ name = "--source"; required = $true; value = "VALUE"; description = "Source path (local for upload, remote for download)." },
            [ordered]@{ name = "--target"; required = $true; value = "VALUE"; description = "Target path (remote for upload, local for download)." },
            [ordered]@{ name = "--user"; required = $false; value = "VALUE"; description = "Username, used when host is not in user@host form." },
            [ordered]@{ name = "--port"; required = $false; value = "VALUE"; description = "SSH port." },
            [ordered]@{ name = "--auth-mode"; required = $false; value = "ssh-alias|identity-file|default-key-discovery|ssh-agent|password"; description = "Authentication strategy." },
            [ordered]@{ name = "--identity-file"; required = $false; value = "VALUE"; description = "Private key path for identity-file mode." },
            [ordered]@{ name = "--known-hosts-file"; required = $false; value = "VALUE"; description = "known_hosts path for host key verification." },
            [ordered]@{ name = "--risk"; required = $false; value = "auto|low|high"; description = "Risk override. auto classifies path sensitivity." },
            [ordered]@{ name = "--confirmation-state"; required = $false; value = "pending|confirmed|none"; description = "High-risk confirmation gate." },
            [ordered]@{ name = "--password-env"; required = $false; value = "VALUE"; description = "Environment variable name for password mode." },
            [ordered]@{ name = "--timeout"; required = $false; value = "VALUE"; description = "SSH connect timeout in seconds." },
            [ordered]@{ name = "--reuse-connection"; required = $false; value = ""; description = "Reuse an OpenSSH connection via ControlMaster/ControlPersist when supported." },
            [ordered]@{ name = "--control-persist"; required = $false; value = "VALUE"; description = "ControlPersist lifetime in seconds when --reuse-connection is enabled. Default 60." },
            [ordered]@{ name = "--recursive"; required = $false; value = ""; description = "Enable recursive copy for directories." },
            [ordered]@{ name = "--help|-h|-Help"; required = $false; value = ""; description = "Show human-readable help." },
            [ordered]@{ name = "--help-json|-help-json"; required = $false; value = ""; description = "Show machine-readable JSON help." }
        )
        examples = @(
            "remote-copy.ps1 --host app-prod --direction upload --source .\build\app.tar.gz --target /tmp/app.tar.gz",
            "remote-copy.ps1 --host app-prod --direction download --source /var/log/nginx/access.log --target .\logs\access.log",
            "remote-copy.ps1 --host app-prod --direction upload --source .\config.env --target /etc/app/config.env --confirmation-state confirmed",
            "remote-copy.ps1 --host app-prod --reuse-connection --direction upload --source .\build\app.tar.gz --target /tmp/app.tar.gz"
        )
        output_contract = [ordered]@{
            format = "plain-text status labels with transfer context and optional OUTPUT/STDERR blocks"
            labels = @("STATUS", "HOST", "ACTION", "AUTH_MODE", "RISK", "REASON", "NEXT")
            extra_labels = @("DIRECTION", "SOURCE", "TARGET", "CONTROL_PATH", "CONTROL_PERSIST")
            common_statuses = @(
                "ok", "invalid_arguments", "pending_confirmation", "missing_source",
                "auth_tool_unavailable", "missing_key", "key_ambiguous", "missing_known_hosts",
                "interactive_password_required", "auth_mode_unsupported", "auth_failed",
                "connect_failed", "transfer_failed"
            )
            additional_labels = @("DURATION_MS", "CONTROL_PATH", "CONTROL_PERSIST", "WARNING")
        }
    }
}

function Show-Usage {
    @"
remote-copy.ps1

SUMMARY
  Upload or download files over SSH/SCP with auth and risk checks.

USAGE
  remote-copy.ps1 --host VALUE --direction upload|download --source VALUE --target VALUE [options]
  remote-copy.ps1 --help
  remote-copy.ps1 --help-json

ARGUMENTS
  --host VALUE
  --direction upload|download
  --source VALUE
  --target VALUE
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --known-hosts-file VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
  --reuse-connection
  --control-persist VALUE
  --recursive
  --help | -h | -Help
  --help-json | -help-json

OUTPUT CONTRACT
  Plain-text labels: STATUS, HOST, ACTION, AUTH_MODE, RISK, REASON, NEXT
  Transfer labels: DIRECTION, SOURCE, TARGET
  Additional labels: DURATION_MS, CONTROL_PATH, CONTROL_PERSIST, WARNING
  Optional blocks: OUTPUT, STDERR

EXAMPLES
  remote-copy.ps1 --host app-prod --direction upload --source .\build\app.tar.gz --target /tmp/app.tar.gz
  remote-copy.ps1 --host app-prod --direction download --source /var/log/nginx/access.log --target .\logs\access.log
  remote-copy.ps1 --host app-prod --direction upload --source .\config.env --target /etc/app/config.env --confirmation-state confirmed
  remote-copy.ps1 --host app-prod --reuse-connection --direction upload --source .\build\app.tar.gz --target /tmp/app.tar.gz
"@
}

function Show-HelpJson {
    $helpSpec = Get-HelpSpec
    $helpSpec | ConvertTo-Json -Depth 8
}

$HostName = ""
$Direction = ""
$SourcePath = ""
$TargetPath = ""
$UserName = ""
$Port = ""
$AuthMode = "ssh-alias"
$IdentityFile = ""
$KnownHostsFile = ""
$Risk = "auto"
$ConfirmationState = "none"
$PasswordEnv = "SSH_PASSWORD"
$Timeout = "15"
$ReuseConnection = $false
$ControlPersist = 60
$Recursive = $false
$Help = $false
$HelpJson = $false

function Get-RequiredOptionValue {
    param(
        [int]$Index,
        [string]$Name
    )

    if (($Index + 1) -ge $RawArgs.Count) {
        Write-Status "STATUS" "invalid_arguments"
        Write-Status "ACTION" "remote_copy"
        Write-Status "REASON" ("missing value for {0}" -f $Name)
        Write-Status "NEXT" "run with --help"
        exit 2
    }

    return $RawArgs[$Index + 1]
}

$RawArgs = @($RawArgs)
for ($i = 0; $i -lt $RawArgs.Count; $i++) {
    $arg = [string]$RawArgs[$i]
    switch ($arg.ToLowerInvariant()) {
        { $_ -in @("--help", "-h", "-help") } {
            $Help = $true
        }
        { $_ -in @("--help-json", "-help-json") } {
            $HelpJson = $true
        }
        { $_ -in @("--host", "-host", "-hostname") } {
            $HostName = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--direction", "-direction") } {
            $Direction = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--source", "-source", "-sourcepath") } {
            $SourcePath = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--target", "-target", "-targetpath") } {
            $TargetPath = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--user", "-user", "-username") } {
            $UserName = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--port", "-port") } {
            $Port = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--auth-mode", "-auth-mode", "-authmode") } {
            $AuthMode = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--identity-file", "-identity-file", "-identityfile") } {
            $IdentityFile = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--known-hosts-file", "-known-hosts-file", "-knownhostsfile") } {
            $KnownHostsFile = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--risk", "-risk") } {
            $Risk = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--confirmation-state", "-confirmation-state", "-confirmationstate") } {
            $ConfirmationState = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--password-env", "-password-env", "-passwordenv") } {
            $PasswordEnv = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--timeout", "-timeout") } {
            $Timeout = Get-RequiredOptionValue -Index $i -Name $arg
            $i++
        }
        { $_ -in @("--reuse-connection", "-reuse-connection", "-reuseconnection") } {
            $ReuseConnection = $true
        }
        { $_ -in @("--control-persist", "-control-persist", "-controlpersist") } {
            $value = Get-RequiredOptionValue -Index $i -Name $arg
            if (-not [int]::TryParse($value, [ref]$ControlPersist) -or $ControlPersist -lt 1) {
                Write-Status "STATUS" "invalid_arguments"
                Write-Status "ACTION" "remote_copy"
                Write-Status "REASON" "--control-persist must be a positive integer number of seconds"
                Write-Status "NEXT" "provide a valid --control-persist value"
                exit 2
            }
            $i++
        }
        { $_ -in @("--recursive", "-recursive") } {
            $Recursive = $true
        }
        default {
            Write-Status "STATUS" "invalid_arguments"
            Write-Status "ACTION" "remote_copy"
            Write-Status "REASON" ("unknown argument: {0}" -f $arg)
            Write-Status "NEXT" "run with --help"
            exit 2
        }
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

if ($HelpJson) {
    Show-HelpJson
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

if ($Direction -eq "upload" -and -not (Test-Path -LiteralPath $SourcePath)) {
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

if ($ReuseConnection -and $toolchain.backend -ne "openssh") {
    Write-Status "STATUS" "auth_tool_unavailable"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "--reuse-connection requires OpenSSH ControlMaster support"
    Write-Status "NEXT" "use OpenSSH or rerun without --reuse-connection"
    exit 4
}
if ($ReuseConnection) {
    $reuseToolchain = Select-OpenSshToolchainForConnectionReuse -Toolchain $toolchain -RequireScp
    if (-not $reuseToolchain.reuse_supported) {
        Write-Status "STATUS" "auth_tool_unavailable"
        Write-Status "HOST" $target
        Write-Status "ACTION" "remote_copy"
        Write-Status "AUTH_MODE" $AuthMode
        Write-Status "RISK" $Risk
        Write-Status "REASON" $reuseToolchain.reuse_reason
        Write-Status "NEXT" "install Git OpenSSH with scp or rerun without --reuse-connection"
        exit 4
    }
    $toolchain = $reuseToolchain
}

switch ($AuthMode) {
    "ssh-alias" { }
    "identity-file" {
        if (-not $IdentityFile -or -not (Test-Path -LiteralPath $IdentityFile)) {
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
        ) | Where-Object { Test-Path -LiteralPath $_ }
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

$resolvedKnownHostsFile = Resolve-KnownHostsFile -KnownHostsFile $KnownHostsFile
if (-not [string]::IsNullOrWhiteSpace($resolvedKnownHostsFile) -and -not (Test-Path -LiteralPath $resolvedKnownHostsFile)) {
    Write-Status "STATUS" "missing_known_hosts"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "known_hosts file was not found"
    Write-Status "NEXT" "provide a valid --known-hosts-file or accept the host key once outside the sandbox"
    Write-Output ("KNOWN_HOSTS_FILE: {0}" -f $resolvedKnownHostsFile)
    exit 5
}

$keyPermissionWarning = $false
if ($IdentityFile) {
    $keyPermissionWarning = Test-WindowsPrivateKeyPermissionWarning -LiteralPath $IdentityFile
}
$controlPath = $null
if ($ReuseConnection) {
    $controlPath = New-OpenSshControlPath -Target $target -Port $Port -IdentityFile $IdentityFile -KnownHostsFile $resolvedKnownHostsFile -AuthMode $AuthMode
}

$sshArgs = @()
$copyArgs = @()
$sshConnectionArgs = @()
$copyConnectionArgs = @()
$sshProgram = ""
$copyProgram = ""
if ($toolchain.backend -eq "openssh") {
    $sshProgram = $toolchain.ssh
    $copyProgram = $toolchain.scp
    $sshConnectionArgs += @("-o", "ConnectTimeout=$Timeout")
    $copyConnectionArgs += @("-o", "ConnectTimeout=$Timeout")
} else {
    $sshProgram = $toolchain.plink
    $copyProgram = $toolchain.pscp
    $sshArgs += @("-batch")
    $copyArgs += @("-batch")
}
if ($Port) {
    if ($toolchain.backend -eq "openssh") {
        $sshConnectionArgs += @("-p", $Port)
        $copyConnectionArgs += @("-P", $Port)
    } else {
        $sshArgs += @("-P", $Port)
        $copyArgs += @("-P", $Port)
    }
}
if ($IdentityFile) {
    if ($toolchain.backend -eq "openssh") {
        $sshConnectionArgs += @("-i", $IdentityFile)
        $copyConnectionArgs += @("-i", $IdentityFile)
        $sshConnectionArgs += @("-o", "IdentitiesOnly=yes")
        $copyConnectionArgs += @("-o", "IdentitiesOnly=yes")
    } else {
        $sshArgs += @("-i", $IdentityFile)
        $copyArgs += @("-i", $IdentityFile)
    }
}
if ($resolvedKnownHostsFile -and $toolchain.backend -eq "openssh") {
    $knownHostsOption = Format-OpenSshOptionAssignment -Name "UserKnownHostsFile" -Value $resolvedKnownHostsFile
    $sshConnectionArgs += @("-o", $knownHostsOption)
    $copyConnectionArgs += @("-o", $knownHostsOption)
}
if ($AuthMode -eq "password") {
    if ($toolchain.backend -eq "openssh") {
        $sshConnectionArgs += @("-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no")
        $copyConnectionArgs += @("-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no")
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
        $sshConnectionArgs += @("-o", "BatchMode=yes")
        $copyConnectionArgs += @("-o", "BatchMode=yes")
    }
}
if ($toolchain.backend -eq "openssh") {
    $sshArgs += $sshConnectionArgs
    $copyArgs += $copyConnectionArgs
    if ($ReuseConnection) {
        $controlOptions = @(
            "-o", "ControlMaster=no",
            "-o", (Format-OpenSshOptionAssignment -Name "ControlPath" -Value $controlPath),
            "-o", "ControlPersist=${ControlPersist}s"
        )
        $sshArgs += $controlOptions
        $copyArgs += $controlOptions
    }
}
if ($Recursive) {
    $copyArgs += "-r"
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

        $askPassPath = New-SshAskPassScript
        $envTable = @{
            SSH_LINUX_ASKPASS_SECRET = $passwordValue
            SSH_ASKPASS = $askPassPath
            SSH_ASKPASS_REQUIRE = "force"
            DISPLAY = "codex-ssh-linux"
        }
    }

    if ($ReuseConnection) {
        $masterResult = Invoke-OpenSshControlMaster -SshProgram $sshProgram -BaseArguments $sshConnectionArgs -Target $target -ControlPath $controlPath -ControlPersist $ControlPersist -EnvironmentTable $envTable
        if ($masterResult.ExitCode -ne 0) {
            $stderrText = $masterResult.StdErr
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
                Write-Status "STATUS" "auth_tool_unavailable"
                Write-Status "HOST" $target
                Write-Status "ACTION" "remote_copy"
                Write-Status "AUTH_MODE" $AuthMode
                Write-Status "RISK" $Risk
                Write-Status "REASON" "failed to establish SSH control master"
                Write-Status "NEXT" "inspect STDERR and reuse-connection support"
            }
            Write-Status "DURATION_MS" $masterResult.DurationMs
            Write-Output ("DIRECTION: {0}" -f $Direction)
            Write-Output ("SOURCE: {0}" -f $SourcePath)
            Write-Output ("TARGET: {0}" -f $TargetPath)
            Write-Output ("CONTROL_PATH: {0}" -f $controlPath)
            Write-Output ("CONTROL_PERSIST: {0}s" -f $ControlPersist)
            if ($masterResult.StdOut) {
                Write-Output "OUTPUT:"
                Write-Output $masterResult.StdOut.TrimEnd()
            }
            if ($masterResult.StdErr) {
                Write-Output "STDERR:"
                Write-Output $masterResult.StdErr.TrimEnd()
            }
            exit $masterResult.ExitCode
        }
    }

    if ($Direction -eq "upload" -and $ConfirmationState -ne "confirmed") {
        $precheckTarget = ConvertTo-PosixSingleQuotedString -Value $TargetPath
        $precheckArgs = @($sshArgs + @($target, "test -e $precheckTarget"))
        if ($ReuseConnection) {
            $precheck = Invoke-NativeProcessCaptureWithOutputFiles -FilePath $sshProgram -ArgumentList $precheckArgs -EnvironmentTable $envTable
        } else {
            $precheck = Invoke-NativeProcessCapture -FilePath $sshProgram -ArgumentList $precheckArgs -EnvironmentTable $envTable
        }
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

    if ($ReuseConnection) {
        $result = Invoke-NativeProcessCaptureWithOutputFiles -FilePath $copyProgram -ArgumentList $scpArgList -EnvironmentTable $envTable
    } else {
        $result = Invoke-NativeProcessCapture -FilePath $copyProgram -ArgumentList $scpArgList -EnvironmentTable $envTable
    }
} finally {
    if ($askPassPath) {
        Remove-Item -LiteralPath $askPassPath -Force -ErrorAction SilentlyContinue
    }
}
if ($ReuseConnection) {
    $result.StdErr = Remove-OpenSshMuxNoise -Text $result.StdErr
}

if ($result.ExitCode -eq 0) {
    Write-Status "STATUS" "ok"
    Write-Status "HOST" $target
    Write-Status "ACTION" "remote_copy"
    Write-Status "AUTH_MODE" $AuthMode
    Write-Status "RISK" $Risk
    Write-Status "REASON" "file transfer completed successfully"
    Write-Status "NEXT" "none"
    Write-Status "DURATION_MS" $result.DurationMs
    Write-Output ("DIRECTION: {0}" -f $Direction)
    Write-Output ("SOURCE: {0}" -f $SourcePath)
    Write-Output ("TARGET: {0}" -f $TargetPath)
    if ($ReuseConnection) {
        Write-Output ("CONTROL_PATH: {0}" -f $controlPath)
        Write-Output ("CONTROL_PERSIST: {0}s" -f $ControlPersist)
    }
    if ($keyPermissionWarning) {
        Write-Output ("WARNING: key_permissions_wide")
        Write-Output ("NEXT_KEY_PERMISSIONS: inspect and restrict ACLs for {0}" -f $IdentityFile)
    }
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

Write-Status "DURATION_MS" $result.DurationMs
Write-Output ("DIRECTION: {0}" -f $Direction)
Write-Output ("SOURCE: {0}" -f $SourcePath)
Write-Output ("TARGET: {0}" -f $TargetPath)
if ($ReuseConnection) {
    Write-Output ("CONTROL_PATH: {0}" -f $controlPath)
    Write-Output ("CONTROL_PERSIST: {0}s" -f $ControlPersist)
}
if ($keyPermissionWarning) {
    Write-Output ("WARNING: key_permissions_wide")
    Write-Output ("NEXT_KEY_PERMISSIONS: inspect and restrict ACLs for {0}" -f $IdentityFile)
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
