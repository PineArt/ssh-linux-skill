[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$processUtils = Join-Path $repoRoot "scripts\process-utils.ps1"
$psExec = Join-Path $repoRoot "scripts\remote-exec.ps1"
$psCopy = Join-Path $repoRoot "scripts\remote-copy.ps1"
$shExec = Join-Path $repoRoot "scripts\remote-exec.sh"
$shCopy = Join-Path $repoRoot "scripts\remote-copy.sh"

. $processUtils

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function ConvertTo-GitBashPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.Length -gt 2 -and $fullPath[1] -eq ':') {
        $drive = $fullPath[0].ToString().ToLowerInvariant()
        $rest = $fullPath.Substring(3).Replace('\', '/')
        return "/$drive/$rest"
    }

    return $fullPath.Replace('\', '/')
}

function Assert-HelpSpec {
    param(
        [object]$Spec,
        [string]$Label
    )

    $argumentNames = @($Spec.arguments | ForEach-Object { $_.name })
    Assert-True ($argumentNames -contains "--reuse-connection") "$Label should expose --reuse-connection in help-json."
    Assert-True ($argumentNames -contains "--control-persist") "$Label should expose --control-persist in help-json."
    $labels = @($Spec.output_contract.extra_labels) + @($Spec.output_contract.additional_labels)
    Assert-True ($labels -contains "CONTROL_PATH") "$Label should expose CONTROL_PATH in help-json output labels."
    Assert-True ($labels -contains "CONTROL_PERSIST") "$Label should expose CONTROL_PERSIST in help-json output labels."
}

function Invoke-PowerShellJsonHelp {
    param([string]$Entry)

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $Entry --help-json
    Assert-True ($LASTEXITCODE -eq 0) "$Entry --help-json should exit successfully."
    return ($output -join "`n") | ConvertFrom-Json
}

function Invoke-PowerShellInvalidPersist {
    param(
        [string]$Entry,
        [string[]]$EntryArgs
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $Entry @EntryArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
}

function Invoke-BashJsonHelp {
    param(
        [string]$BashPath,
        [string]$Entry
    )

    $output = & $BashPath -- (ConvertTo-GitBashPath $Entry) --help-json
    Assert-True ($LASTEXITCODE -eq 0) "$Entry --help-json should exit successfully through Git Bash."
    return ($output -join "`n") | ConvertFrom-Json
}

function Invoke-BashInvalidPersist {
    param(
        [string]$BashPath,
        [string]$Entry,
        [string[]]$EntryArgs
    )

    $convertedArgs = @((ConvertTo-GitBashPath $Entry)) + $EntryArgs
    $output = & $BashPath -- @convertedArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
}

function Invoke-BashPasswordReuseProbe {
    param(
        [string]$BashPath,
        [string]$Entry
    )

    $entryPath = ConvertTo-GitBashPath $Entry
    $script = @(
        "cd '$((ConvertTo-GitBashPath $repoRoot).Replace("'", "'\''"))'",
        "SSH_PASSWORD=placeholder '$($entryPath.Replace("'", "'\''"))' --host example.invalid --auth-mode password --reuse-connection --control-persist 1 --timeout 1 --risk low --command 'true'"
    ) -join "; "
    $output = & $BashPath -lc $script 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
}

function Invoke-BashControlPath {
    param(
        [string]$BashPath,
        [string]$Target,
        [string]$Port,
        [string]$IdentityFile,
        [string]$KnownHostsFile,
        [string]$AuthMode
    )

    $sshTools = ConvertTo-GitBashPath (Join-Path $repoRoot "scripts\ssh-tools.sh")
    $parts = @(
        "source '$($sshTools.Replace("'", "'\''"))'",
        "new_openssh_control_path '$($Target.Replace("'", "'\''"))' '$($Port.Replace("'", "'\''"))' '$((ConvertTo-GitBashPath $IdentityFile).Replace("'", "'\''"))' '$((ConvertTo-GitBashPath $KnownHostsFile).Replace("'", "'\''"))' '$($AuthMode.Replace("'", "'\''"))'"
    )
    $output = & $BashPath -lc ($parts -join "; ")
    Assert-True ($LASTEXITCODE -eq 0) "Bash new_openssh_control_path should exit successfully."
    return ($output -join "`n").Trim()
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-linux-reuse-contract-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $longTarget = "very-long-host-name-" + ("x" * 120) + ".example.internal"
    $identityFile = Join-Path $tempDir ("identity-" + ("y" * 80))
    $knownHostsA = Join-Path $tempDir "known_hosts_a"
    $knownHostsB = Join-Path $tempDir "known_hosts_b"
    [System.IO.File]::WriteAllText($identityFile, "placeholder", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($knownHostsA, "host-a", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($knownHostsB, "host-b", [System.Text.Encoding]::ASCII)
    $controlPath = New-OpenSshControlPath -Target $longTarget -Port "2222" -IdentityFile $identityFile -KnownHostsFile $knownHostsA -AuthMode "identity-file"
    Assert-True ((Split-Path -Leaf $controlPath).Length -le 40) "PowerShell control socket filename should remain short."
    Assert-True ((Split-Path -Leaf $controlPath) -match '^cm-[A-Za-z0-9._-]+-[0-9a-f]+\.sock$') "PowerShell control socket filename should be sanitized and hashed."
    Assert-True ((Test-Path -LiteralPath (Split-Path -Parent $controlPath))) "PowerShell control socket directory should be created."
    $controlPathWithOtherKnownHosts = New-OpenSshControlPath -Target $longTarget -Port "2222" -IdentityFile $identityFile -KnownHostsFile $knownHostsB -AuthMode "identity-file"
    Assert-True ($controlPath -ne $controlPathWithOtherKnownHosts) "PowerShell ControlPath should include known_hosts policy in its fingerprint."
    $controlPathWithOtherAuth = New-OpenSshControlPath -Target $longTarget -Port "2222" -IdentityFile $identityFile -KnownHostsFile $knownHostsA -AuthMode "ssh-agent"
    Assert-True ($controlPath -ne $controlPathWithOtherAuth) "PowerShell ControlPath should include auth mode in its fingerprint."

    $captureProbe = Invoke-NativeProcessCaptureWithOutputFiles -FilePath "whoami.exe" -ArgumentList @() -EnvironmentTable @{} -TimeoutSeconds 10
    Assert-True ($captureProbe.ExitCode -eq 0) "Output-file capture should run a simple native process successfully."
    Assert-True (-not [string]::IsNullOrWhiteSpace($captureProbe.StdOut)) "Output-file capture should preserve stdout."
    Assert-True ([string]::IsNullOrWhiteSpace($captureProbe.StdErr)) "Output-file capture should not invent stderr."

    Assert-HelpSpec -Spec (Invoke-PowerShellJsonHelp -Entry $psExec) -Label "remote-exec.ps1"
    Assert-HelpSpec -Spec (Invoke-PowerShellJsonHelp -Entry $psCopy) -Label "remote-copy.ps1"

    $psExecInvalid = Invoke-PowerShellInvalidPersist -Entry $psExec -EntryArgs @("--host", "example.invalid", "--command", "uname -a", "--control-persist", "0", "--risk", "low")
    $psExecInvalidOutput = [string]$psExecInvalid.Output
    Assert-True ($psExecInvalid.ExitCode -eq 2) "remote-exec.ps1 should reject --control-persist 0 before SSH."
    Assert-True ($psExecInvalidOutput.Contains("--control-persist must be a positive integer number of seconds")) "remote-exec.ps1 invalid persist output should explain the contract."

    $sourceFile = Join-Path $tempDir "source.txt"
    [System.IO.File]::WriteAllText($sourceFile, "payload", [System.Text.Encoding]::ASCII)
    $psCopyInvalid = Invoke-PowerShellInvalidPersist -Entry $psCopy -EntryArgs @("--host", "example.invalid", "--direction", "upload", "--source", $sourceFile, "--target", "/tmp/source.txt", "--control-persist", "0", "--risk", "low")
    $psCopyInvalidOutput = [string]$psCopyInvalid.Output
    Assert-True ($psCopyInvalid.ExitCode -eq 2) "remote-copy.ps1 should reject --control-persist 0 before SSH."
    Assert-True ($psCopyInvalidOutput.Contains("--control-persist must be a positive integer number of seconds")) "remote-copy.ps1 invalid persist output should explain the contract."

    $bashCandidates = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files\Git\usr\bin\bash.exe"
    )
    $bash = $bashCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($bash) {
        $bashControlPath = Invoke-BashControlPath -BashPath $bash -Target $longTarget -Port "2222" -IdentityFile $identityFile -KnownHostsFile $knownHostsA -AuthMode "identity-file"
        Assert-True ((Split-Path -Leaf $bashControlPath).Length -le 40) "Bash control socket filename should remain short."
        Assert-True ((Split-Path -Leaf $bashControlPath) -match '^cm-[A-Za-z0-9._-]+-[0-9a-f]+\.sock$') "Bash control socket filename should be sanitized and hashed."
        $bashControlPathOtherKnownHosts = Invoke-BashControlPath -BashPath $bash -Target $longTarget -Port "2222" -IdentityFile $identityFile -KnownHostsFile $knownHostsB -AuthMode "identity-file"
        Assert-True ($bashControlPath -ne $bashControlPathOtherKnownHosts) "Bash ControlPath should include known_hosts policy in its fingerprint."
        $bashControlPathOtherAuth = Invoke-BashControlPath -BashPath $bash -Target $longTarget -Port "2222" -IdentityFile $identityFile -KnownHostsFile $knownHostsA -AuthMode "ssh-agent"
        Assert-True ($bashControlPath -ne $bashControlPathOtherAuth) "Bash ControlPath should include auth mode in its fingerprint."

        Assert-HelpSpec -Spec (Invoke-BashJsonHelp -BashPath $bash -Entry $shExec) -Label "remote-exec.sh"
        Assert-HelpSpec -Spec (Invoke-BashJsonHelp -BashPath $bash -Entry $shCopy) -Label "remote-copy.sh"

        $bashExecInvalid = Invoke-BashInvalidPersist -BashPath $bash -Entry $shExec -EntryArgs @("--host", "example.invalid", "--command", "uname -a", "--control-persist", "0", "--risk", "low")
        $bashExecInvalidOutput = [string]$bashExecInvalid.Output
        Assert-True ($bashExecInvalid.ExitCode -eq 2) "remote-exec.sh should reject --control-persist 0 before SSH."
        Assert-True ($bashExecInvalidOutput.Contains("--control-persist must be a positive integer number of seconds")) "remote-exec.sh invalid persist output should explain the contract."

        $bashPasswordReuse = Invoke-BashPasswordReuseProbe -BashPath $bash -Entry $shExec
        Assert-True ($bashPasswordReuse.ExitCode -ne 127) "remote-exec.sh password reuse should call the control-master shell function instead of execing it through env."
        Assert-True (-not ([string]$bashPasswordReuse.Output).Contains("ensure_openssh_control_master")) "remote-exec.sh password reuse should not fail with missing shell function."

        $bashCopyInvalid = Invoke-BashInvalidPersist -BashPath $bash -Entry $shCopy -EntryArgs @("--host", "example.invalid", "--direction", "upload", "--source", (ConvertTo-GitBashPath $sourceFile), "--target", "/tmp/source.txt", "--control-persist", "0", "--risk", "low")
        $bashCopyInvalidOutput = [string]$bashCopyInvalid.Output
        Assert-True ($bashCopyInvalid.ExitCode -eq 2) "remote-copy.sh should reject --control-persist 0 before SSH."
        Assert-True ($bashCopyInvalidOutput.Contains("--control-persist must be a positive integer number of seconds")) "remote-copy.sh invalid persist output should explain the contract."
    } else {
        Write-Output "SKIP: Git Bash not found; Bash path not executed."
    }

    Write-Output "PASS: SSH connection reuse contract"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
