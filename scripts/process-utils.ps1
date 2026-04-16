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
        [hashtable]$EnvironmentTable
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
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
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))

        return @{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
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
