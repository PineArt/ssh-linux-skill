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
                "Invoke-NativeProcessCaptureRawArguments",
                "Read-TextFileAuto",
                "Get-PowerShellExecutablePath",
                "Format-OpenSshOptionAssignment",
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
  Invoke-NativeProcessCaptureRawArguments
  Read-TextFileAuto
  Get-PowerShellExecutablePath
  Format-OpenSshOptionAssignment
  New-SshAskPassScript
  ConvertTo-PosixSingleQuotedString
  Resolve-KnownHostsFile
  Test-WindowsPrivateKeyPermissionWarning
"@ | Write-Output
        exit 0
    }
}
