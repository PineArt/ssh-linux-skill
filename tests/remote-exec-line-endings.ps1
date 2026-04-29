[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$psEntry = Join-Path $repoRoot "scripts\remote-exec.ps1"
$shEntry = Join-Path $repoRoot "scripts\remote-exec.sh"

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

function Assert-EscapedCarriageReturnTextPreserved {
    param(
        [string]$Output,
        [string]$Label
    )

    $literalLine = ($Output -split "`n" | Where-Object { $_ -like "printf '*literal*'" } | Select-Object -First 1)
    Assert-True (-not [string]::IsNullOrEmpty($literalLine)) "$Label should include the printf literal line."
    Assert-True (-not $literalLine.Contains("`r")) "$Label printf literal line should not contain literal CR bytes."
    Assert-True ($literalLine.Contains('\r') -and $literalLine.Contains('\n')) "$Label should preserve escaped CR/LF text."
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-linux-line-ending-test-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $commandFile = Join-Path $tempDir "command-crlf.sh"
    $body = "git status --short`r`nprintf 'literal\\r\\n'`r`n"
    [System.IO.File]::WriteAllText($commandFile, $body, [System.Text.Encoding]::UTF8)

    $psOutputLines = & $psEntry --host example.invalid --command-file $commandFile --risk high 2>&1
    $psExitCode = $LASTEXITCODE
    $psOutput = $psOutputLines -join "`n"

    Assert-True ($psExitCode -eq 3) "PowerShell path should stop at pending confirmation."
    Assert-True ($psOutput -match 'WARNING: command_file_cr_normalized') "PowerShell path should warn when CR is normalized."
    Assert-True (-not $psOutput.Contains("`r")) "PowerShell pending-confirmation output should not contain literal CR bytes."
    Assert-True (-not $psOutput.Contains([char]0xFEFF)) "PowerShell pending-confirmation output should not contain a UTF-8 BOM marker."
    Assert-True ($psOutput -match 'COMMAND: git status --short') "PowerShell command text should preserve --short without CR."
    Assert-EscapedCarriageReturnTextPreserved -Output $psOutput -Label "PowerShell normalization"

    $bashCandidates = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files\Git\usr\bin\bash.exe"
    )
    $bash = $bashCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($bash) {
        $shOutputLines = & $bash -- (ConvertTo-GitBashPath $shEntry) --host example.invalid --command-file (ConvertTo-GitBashPath $commandFile) --risk high 2>&1
        $shExitCode = $LASTEXITCODE
        $shOutput = $shOutputLines -join "`n"

        Assert-True ($shExitCode -eq 3) "Bash path should stop at pending confirmation."
        Assert-True ($shOutput -match 'WARNING: command_file_cr_normalized') "Bash path should warn when CR is normalized."
        Assert-True (-not $shOutput.Contains("`r")) "Bash pending-confirmation output should not contain literal CR bytes."
        Assert-True (-not $shOutput.Contains([char]0xFEFF)) "Bash pending-confirmation output should not contain a UTF-8 BOM marker."
        Assert-True ($shOutput -match 'COMMAND: git status --short') "Bash command text should preserve --short without CR."
        Assert-EscapedCarriageReturnTextPreserved -Output $shOutput -Label "Bash normalization"
    } else {
        Write-Output "SKIP: Git Bash not found; Bash path not executed."
    }

    Write-Output "PASS: remote-exec command-file CRLF normalization"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
