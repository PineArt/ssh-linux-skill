function ConvertTo-WindowsCommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount += 1
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append('\', ($backslashCount * 2) + 1)
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append('\', $backslashCount)
            $backslashCount = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append('\', $backslashCount * 2)
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsCommandLine {
    param(
        [string[]]$ArgumentList
    )

    if (-not $ArgumentList) {
        return ""
    }

    $escaped = foreach ($argument in $ArgumentList) {
        ConvertTo-WindowsCommandLineArgument -Value ([string]$argument)
    }

    return ($escaped -join " ")
}

function ConvertTo-CmdPipelineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    $escaped = $Value.Replace('"', '\"').Replace('%', '%%').Replace('^', '^^')
    return '"{0}"' -f $escaped
}

function Join-CmdPipelineCommand {
    param(
        [string[]]$ArgumentList
    )

    return (@($ArgumentList) | ForEach-Object { ConvertTo-CmdPipelineArgument -Value ([string]$_) }) -join " "
}

function Set-ProcessEnvironmentValue {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string]$Name,
        [AllowEmptyString()]
        [string]$Value
    )

    $environmentProperty = $StartInfo.GetType().GetProperty("Environment")
    if ($environmentProperty) {
        $environment = $environmentProperty.GetValue($StartInfo, $null)
        $environment[$Name] = $Value
        return
    }

    $StartInfo.EnvironmentVariables[$Name] = $Value
}

function Invoke-NativeProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$EnvironmentTable,
        [AllowEmptyString()]
        [string]$InputText,
        [int]$TimeoutSeconds = 0
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = ($PSBoundParameters.ContainsKey('InputText'))
    $startInfo.CreateNoWindow = $true
    $stdinEncodingProperty = $startInfo.GetType().GetProperty("StandardInputEncoding")
    if ($PSBoundParameters.ContainsKey('InputText') -and -not $stdinEncodingProperty) {
        return Invoke-NativeProcessCaptureWithInputFile `
            -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -EnvironmentTable $EnvironmentTable `
            -InputText $InputText `
            -TimeoutSeconds $TimeoutSeconds
    }
    if ($PSBoundParameters.ContainsKey('InputText') -and $stdinEncodingProperty) {
        $stdinEncodingProperty.SetValue($startInfo, [System.Text.UTF8Encoding]::new($false), $null)
    }

    $argumentListProperty = $startInfo.GetType().GetProperty("ArgumentList")
    if ($argumentListProperty) {
        foreach ($argument in $ArgumentList) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    } else {
        $startInfo.Arguments = Join-WindowsCommandLine -ArgumentList $ArgumentList
    }

    if ($EnvironmentTable) {
        foreach ($key in $EnvironmentTable.Keys) {
            Set-ProcessEnvironmentValue -StartInfo $startInfo -Name $key -Value ([string]$EnvironmentTable[$key])
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $inputEncoding = [System.Text.UTF8Encoding]::new($false)
            $inputBytes = $inputEncoding.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
            $process.StandardInput.Close()
        }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($TimeoutSeconds -gt 0) {
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $completed) {
                try {
                    $process.Kill()
                } catch {
                }
                $process.WaitForExit()
                [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
                $stopwatch.Stop()

                return @{
                    ExitCode = 124
                    StdOut = $stdoutTask.GetAwaiter().GetResult()
                    StdErr = $stderrTask.GetAwaiter().GetResult()
                    TimedOut = $true
                    DurationMs = [int64]$stopwatch.ElapsedMilliseconds
                }
            }
        } else {
            $process.WaitForExit()
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $stopwatch.Stop()

        return @{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
            DurationMs = [int64]$stopwatch.ElapsedMilliseconds
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-NativeProcessCaptureWithInputFile {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$EnvironmentTable,
        [AllowEmptyString()]
        [string]$InputText,
        [int]$TimeoutSeconds = 0
    )

    $inputFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($inputFile, $InputText, [System.Text.UTF8Encoding]::new($false))
        $cmdPath = Join-Path $env:SystemRoot "System32\cmd.exe"
        $commandLine = 'type {0} | {1}' -f (ConvertTo-CmdPipelineArgument -Value $inputFile), (Join-CmdPipelineCommand -ArgumentList (@($FilePath) + @($ArgumentList)))
        return Invoke-NativeProcessCaptureRawArguments -FilePath $cmdPath -Arguments ("/d /c " + $commandLine) -EnvironmentTable $EnvironmentTable -TimeoutSeconds $TimeoutSeconds
    } finally {
        Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeProcessCaptureWithOutputFiles {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$EnvironmentTable,
        [AllowEmptyString()]
        [string]$InputText,
        [int]$TimeoutSeconds = 0
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $inputFile = $null
    $commandFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-linux-capture-{0}.cmd" -f [System.Guid]::NewGuid().ToString("N"))
    try {
        $nativeCommand = Join-CmdPipelineCommand -ArgumentList (@($FilePath) + @($ArgumentList))
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $inputFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($inputFile, $InputText, [System.Text.UTF8Encoding]::new($false))
            $nativeCommand = 'type {0} | {1}' -f (ConvertTo-CmdPipelineArgument -Value $inputFile), $nativeCommand
        }

        $redirectedCommand = '{0} > {1} 2> {2}' -f $nativeCommand, (ConvertTo-CmdPipelineArgument -Value $stdoutFile), (ConvertTo-CmdPipelineArgument -Value $stderrFile)
        $commandLine = @(
            '@echo off',
            'setlocal',
            $redirectedCommand,
            'exit /b %ERRORLEVEL%'
        ) -join "`r`n"
        $commandLine += "`r`n"
        [System.IO.File]::WriteAllText($commandFile, $commandLine, [System.Text.Encoding]::ASCII)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Join-Path $env:SystemRoot "System32\cmd.exe")
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $false
        $startInfo.RedirectStandardError = $false
        $startInfo.RedirectStandardInput = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.Arguments = '/d /c ' + (ConvertTo-WindowsCommandLineArgument -Value $commandFile)

        if ($EnvironmentTable) {
            foreach ($key in $EnvironmentTable.Keys) {
                Set-ProcessEnvironmentValue -StartInfo $startInfo -Name $key -Value ([string]$EnvironmentTable[$key])
            }
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            if ($TimeoutSeconds -gt 0) {
                $completed = $process.WaitForExit($TimeoutSeconds * 1000)
                if (-not $completed) {
                    try {
                        $process.Kill()
                    } catch {
                    }
                    $process.WaitForExit()
                    $stopwatch.Stop()
                    $result = @{
                        ExitCode = 124
                        StdOut = ""
                        StdErr = ""
                        TimedOut = $true
                        DurationMs = [int64]$stopwatch.ElapsedMilliseconds
                    }
                } else {
                    $stopwatch.Stop()
                    $result = @{
                        ExitCode = $process.ExitCode
                        StdOut = ""
                        StdErr = ""
                        TimedOut = $false
                        DurationMs = [int64]$stopwatch.ElapsedMilliseconds
                    }
                }
        } else {
                $process.WaitForExit()
                $stopwatch.Stop()
                $result = @{
                    ExitCode = $process.ExitCode
                    StdOut = ""
                    StdErr = ""
                    TimedOut = $false
                    DurationMs = [int64]$stopwatch.ElapsedMilliseconds
                }
            }
        } finally {
            $process.Dispose()
        }
        $stdoutText = ""
        $stderrText = ""
        try {
            $stdoutText = [System.IO.File]::ReadAllText($stdoutFile, [System.Text.UTF8Encoding]::new($false))
        } catch {
        }
        try {
            $stderrText = [System.IO.File]::ReadAllText($stderrFile, [System.Text.UTF8Encoding]::new($false))
        } catch {
        }
        if ($result.StdOut) {
            $stdoutText += $result.StdOut
        }
        if ($result.StdErr) {
            $stderrText += $result.StdErr
        }
        return @{
            ExitCode = $result.ExitCode
            StdOut = $stdoutText
            StdErr = $stderrText
            TimedOut = $result.TimedOut
            DurationMs = $result.DurationMs
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        if ($inputFile) {
            Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $commandFile -Force -ErrorAction SilentlyContinue
    }
}

function Remove-OpenSshMuxNoise {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $lines = @($Text -split "\r?\n")
    $kept = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -match '^mux_client_request_session: read from master failed: ') {
            continue
        }
        if ($line -match '^ControlSocket .+ already exists, disabling multiplexing$') {
            continue
        }
        $kept += $line
    }
    if (-not $kept) {
        return ""
    }
    return ($kept -join "`n")
}

function Invoke-NativeProcessCaptureRawArguments {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [hashtable]$EnvironmentTable,
        [int]$TimeoutSeconds = 0
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    if ($EnvironmentTable) {
        foreach ($key in $EnvironmentTable.Keys) {
            Set-ProcessEnvironmentValue -StartInfo $startInfo -Name $key -Value ([string]$EnvironmentTable[$key])
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($TimeoutSeconds -gt 0) {
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $completed) {
                try {
                    $process.Kill()
                } catch {
                }
                $process.WaitForExit()
                [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
                $stopwatch.Stop()

                return @{
                    ExitCode = 124
                    StdOut = $stdoutTask.GetAwaiter().GetResult()
                    StdErr = $stderrTask.GetAwaiter().GetResult()
                    TimedOut = $true
                    DurationMs = [int64]$stopwatch.ElapsedMilliseconds
                }
            }
        } else {
            $process.WaitForExit()
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $stopwatch.Stop()

        return @{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
            DurationMs = [int64]$stopwatch.ElapsedMilliseconds
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-NativeProcessExitOnly {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$EnvironmentTable,
        [int]$TimeoutSeconds = 0
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.RedirectStandardInput = $false
    $startInfo.CreateNoWindow = $true

    $argumentListProperty = $startInfo.GetType().GetProperty("ArgumentList")
    if ($argumentListProperty) {
        foreach ($argument in $ArgumentList) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    } else {
        $startInfo.Arguments = Join-WindowsCommandLine -ArgumentList $ArgumentList
    }

    if ($EnvironmentTable) {
        foreach ($key in $EnvironmentTable.Keys) {
            Set-ProcessEnvironmentValue -StartInfo $startInfo -Name $key -Value ([string]$EnvironmentTable[$key])
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($TimeoutSeconds -gt 0) {
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $completed) {
                try {
                    $process.Kill()
                } catch {
                }
                $process.WaitForExit()
                $stopwatch.Stop()
                return @{
                    ExitCode = 124
                    DurationMs = [int64]$stopwatch.ElapsedMilliseconds
                    TimedOut = $true
                }
            }
        } else {
            $process.WaitForExit()
        }
        $stopwatch.Stop()
        return @{
            ExitCode = $process.ExitCode
            DurationMs = [int64]$stopwatch.ElapsedMilliseconds
            TimedOut = $false
        }
    } finally {
        $process.Dispose()
    }
}

function Test-WindowsPrivateKeyPermissionWarning {
    param(
        [string]$LiteralPath
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return $false
    }
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
        return $false
    }

    try {
        $acl = Get-Acl -LiteralPath $LiteralPath
    } catch {
        return $false
    }

    foreach ($entry in $acl.Access) {
        $identity = [string]$entry.IdentityReference
        $rights = [string]$entry.FileSystemRights
        $allowsRead = $entry.AccessControlType -eq "Allow" -and (
            $rights -match "Read" -or
            $rights -match "FullControl" -or
            $rights -match "Modify"
        )
        if (-not $allowsRead) {
            continue
        }
        if ($identity -match "(?i)(Everyone|BUILTIN\\Users|Authenticated Users|Users)$") {
            return $true
        }
    }

    return $false
}

function Read-TextFileAuto {
    param(
        [string]$LiteralPath
    )

    $reader = New-Object System.IO.StreamReader($LiteralPath, $true)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Get-PowerShellExecutablePath {
    $candidates = @()

    try {
        $currentProcessPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($currentProcessPath)) {
            $candidates += $currentProcessPath
        }
    } catch {
    }

    if (-not [string]::IsNullOrWhiteSpace($PSHOME)) {
        $candidates += (Join-Path $PSHOME "pwsh.exe")
        $candidates += (Join-Path $PSHOME "powershell.exe")
    }

    foreach ($commandName in @("pwsh", "powershell")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            $candidates += $command.Source
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        $normalized = [System.IO.Path]::GetFullPath($candidate)
        if ($seen.ContainsKey($normalized)) {
            continue
        }

        $seen[$normalized] = $true
        return $normalized
    }

    throw "Unable to resolve a PowerShell executable for SSH_ASKPASS."
}

function Format-OpenSshOptionAssignment {
    param(
        [string]$Name,
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    $escapedValue = $Value -replace '"', '\"'
    if ($escapedValue -match '[\s"]') {
        return '{0}="{1}"' -f $Name, $escapedValue
    }

    return '{0}={1}' -f $Name, $escapedValue
}

function ConvertTo-OpenSshControlPathToken {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    $token = $Value -replace '[^A-Za-z0-9._-]', '_'
    $token = $token.Trim("_")
    if ([string]::IsNullOrWhiteSpace($token)) {
        return "default"
    }

    if ($token.Length -gt 48) {
        return $token.Substring(0, 48)
    }

    return $token
}

function New-OpenSshControlPath {
    param(
        [string]$Target,
        [AllowEmptyString()]
        [string]$Port,
        [AllowEmptyString()]
        [string]$IdentityFile,
        [AllowEmptyString()]
        [string]$KnownHostsFile,
        [AllowEmptyString()]
        [string]$AuthMode
    )

    $userSource = "{0}\{1}" -f $env:USERDOMAIN, [Environment]::UserName
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $userHashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($userSource))
    } finally {
        $sha256.Dispose()
    }
    $userHash = -join ($userHashBytes | ForEach-Object { $_.ToString("x2") })
    $baseDir = Join-Path ([System.IO.Path]::GetTempPath()) ("slc-{0}" -f $userHash.Substring(0, 8))
    if ((Test-Path -LiteralPath $baseDir) -and ((Get-Item -LiteralPath $baseDir).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "refusing reparse-point SSH control directory: $baseDir"
    }
    if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }
    if ((Get-Item -LiteralPath $baseDir).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "refusing reparse-point SSH control directory: $baseDir"
    }

    $identityValue = if ([string]::IsNullOrWhiteSpace($IdentityFile)) { "default" } else { [System.IO.Path]::GetFullPath($IdentityFile) }
    $knownHostsValue = if ([string]::IsNullOrWhiteSpace($KnownHostsFile)) { "default" } else { [System.IO.Path]::GetFullPath($KnownHostsFile) }
    $authModeValue = if ([string]::IsNullOrWhiteSpace($AuthMode)) { "default" } else { $AuthMode.ToLowerInvariant() }
    $fingerprintSource = "{0}|{1}|{2}|{3}|{4}" -f $Target, $(if ([string]::IsNullOrWhiteSpace($Port)) { "22" } else { $Port }), $identityValue, $knownHostsValue, $authModeValue
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fingerprintSource))
    } finally {
        $sha256.Dispose()
    }
    $hash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    $targetToken = ConvertTo-OpenSshControlPathToken -Value $Target
    if ($targetToken.Length -gt 12) {
        $targetToken = $targetToken.Substring(0, 12)
    }

    $fileName = "cm-{0}-{1}.sock" -f $targetToken, $hash.Substring(0, 16)
    return (Join-Path $baseDir $fileName).Replace('\', '/')
}

function Invoke-OpenSshControlMaster {
    param(
        [string]$SshProgram,
        [string[]]$BaseArguments,
        [string]$Target,
        [string]$ControlPath,
        [int]$ControlPersist,
        [hashtable]$EnvironmentTable
    )

    $controlPathOption = Format-OpenSshOptionAssignment -Name "ControlPath" -Value $ControlPath
    $checkArgs = @($BaseArguments + @("-O", "check", "-o", $controlPathOption, $Target))
    $checkResult = Invoke-NativeProcessCaptureWithOutputFiles -FilePath $SshProgram -ArgumentList $checkArgs -EnvironmentTable $EnvironmentTable
    if ($checkResult.ExitCode -eq 0) {
        return @{
            ExitCode = 0
            StdOut = $checkResult.StdOut
            StdErr = $checkResult.StdErr
            DurationMs = $checkResult.DurationMs
            Created = $false
        }
    }

    $startArgs = @(
        $BaseArguments +
        @(
            "-N",
            "-f",
            "-o", "ControlMaster=yes",
            "-o", $controlPathOption,
            "-o", "ControlPersist=${ControlPersist}s",
            $Target
        )
    )
    $startResult = Invoke-NativeProcessCaptureWithOutputFiles -FilePath $SshProgram -ArgumentList $startArgs -EnvironmentTable $EnvironmentTable -TimeoutSeconds 30
    if ($startResult.ExitCode -ne 0) {
        return @{
            ExitCode = $startResult.ExitCode
            StdOut = $startResult.StdOut
            StdErr = $startResult.StdErr
            DurationMs = $startResult.DurationMs
            Created = $true
        }
    }

    $postCheckResult = Invoke-NativeProcessCaptureWithOutputFiles -FilePath $SshProgram -ArgumentList $checkArgs -EnvironmentTable $EnvironmentTable
    if ($postCheckResult.ExitCode -ne 0) {
        return @{
            ExitCode = $postCheckResult.ExitCode
            StdOut = $postCheckResult.StdOut
            StdErr = $postCheckResult.StdErr
            DurationMs = $startResult.DurationMs + $postCheckResult.DurationMs
            Created = $true
        }
    }

    return @{
        ExitCode = 0
        StdOut = $postCheckResult.StdOut
        StdErr = $postCheckResult.StdErr
        DurationMs = $startResult.DurationMs + $postCheckResult.DurationMs
        Created = $true
    }
}

function New-SshAskPassScript {
    $askPassPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".cmd")
    $powerShellPath = Get-PowerShellExecutablePath

    $scriptContent = @"
@echo off
"$powerShellPath" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Write-Output `$env:SSH_LINUX_ASKPASS_SECRET"
"@

    Set-Content -LiteralPath $askPassPath -Encoding ASCII -Value $scriptContent
    return $askPassPath
}

function ConvertTo-PosixSingleQuotedString {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    return "'{0}'" -f ($Value -replace "'", "'\''")
}

function Resolve-KnownHostsFile {
    param(
        [string]$KnownHostsFile
    )

    if (-not [string]::IsNullOrWhiteSpace($KnownHostsFile)) {
        return $KnownHostsFile
    }

    $candidates = @()
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $candidates += (Join-Path $userProfile ".ssh\known_hosts")
    }
    if (-not [string]::IsNullOrWhiteSpace($HOME)) {
        $candidates += (Join-Path $HOME ".ssh\known_hosts")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates += (Join-Path $env:USERPROFILE ".ssh\known_hosts")
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

if ($MyInvocation.InvocationName -ne ".") {
    $showHelp = $args -contains "-h" -or $args -contains "--help" -or $args -contains "-Help"
    $showHelpJson = $args -contains "--help-json" -or $args -contains "-help-json"

    if ($showHelpJson) {
        [ordered]@{
            name = "process-utils.ps1"
            summary = "PowerShell utility module for native process invocation and SSH helper utilities."
            exported_functions = @(
                "ConvertTo-WindowsCommandLineArgument",
                "Join-WindowsCommandLine",
                "ConvertTo-CmdPipelineArgument",
                "Join-CmdPipelineCommand",
                "Set-ProcessEnvironmentValue",
                "Invoke-NativeProcessCapture",
                "Invoke-NativeProcessCaptureWithInputFile",
                "Invoke-NativeProcessCaptureWithOutputFiles",
                "Invoke-NativeProcessCaptureRawArguments",
                "Invoke-NativeProcessExitOnly",
                "Remove-OpenSshMuxNoise",
                "Read-TextFileAuto",
                "Get-PowerShellExecutablePath",
                "Format-OpenSshOptionAssignment",
                "ConvertTo-OpenSshControlPathToken",
                "New-OpenSshControlPath",
                "Invoke-OpenSshControlMaster",
                "New-SshAskPassScript",
                "ConvertTo-PosixSingleQuotedString",
                "Resolve-KnownHostsFile",
                "Test-WindowsPrivateKeyPermissionWarning"
            )
            usage = @(
                "Dot-source from entry scripts: . .\\process-utils.ps1",
                "Direct run for diagnostics: .\\process-utils.ps1 --help",
                "Direct run for machine-readable diagnostics: .\\process-utils.ps1 --help-json"
            )
        } | ConvertTo-Json -Depth 4
        exit 0
    }

    if ($showHelp -or $args.Count -eq 0) {
        @"
process-utils.ps1

SUMMARY
  PowerShell utility module for native process invocation and SSH helper utilities.

USAGE
  Dot-source from entry scripts:
    . .\process-utils.ps1
  Direct run for diagnostics:
    .\process-utils.ps1 --help
    .\process-utils.ps1 --help-json

EXPORTED FUNCTIONS
  ConvertTo-WindowsCommandLineArgument
  Join-WindowsCommandLine
  ConvertTo-CmdPipelineArgument
  Join-CmdPipelineCommand
  Set-ProcessEnvironmentValue
  Invoke-NativeProcessCapture
  Invoke-NativeProcessCaptureWithInputFile
  Invoke-NativeProcessCaptureWithOutputFiles
  Invoke-NativeProcessCaptureRawArguments
  Invoke-NativeProcessExitOnly
  Remove-OpenSshMuxNoise
  Read-TextFileAuto
  Get-PowerShellExecutablePath
  Format-OpenSshOptionAssignment
  ConvertTo-OpenSshControlPathToken
  New-OpenSshControlPath
  Invoke-OpenSshControlMaster
  New-SshAskPassScript
  ConvertTo-PosixSingleQuotedString
  Resolve-KnownHostsFile
  Test-WindowsPrivateKeyPermissionWarning
"@ | Write-Output
        exit 0
    }
}
