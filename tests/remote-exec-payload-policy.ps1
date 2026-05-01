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

function Invoke-PowerShellEntry {
    param(
        [string]$CommandFile,
        [string[]]$ExtraArgs = @()
    )

    $outputLines = & $psEntry --host example.invalid --command-file $CommandFile @ExtraArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($outputLines -join "`n")
    }
}

function Invoke-BashEntry {
    param(
        [string]$BashPath,
        [string]$CommandFile,
        [string[]]$ExtraArgs = @()
    )

    $outputLines = & $BashPath -- (ConvertTo-GitBashPath $shEntry) --host example.invalid --command-file (ConvertTo-GitBashPath $CommandFile) @ExtraArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($outputLines -join "`n")
    }
}

function Assert-PolicyCase {
    param(
        [string]$Name,
        [string]$Body,
        [scriptblock]$Assert,
        [string[]]$ExtraArgs = @("--risk", "low")
    )

    $commandFile = Join-Path $tempDir ($Name + ".sh")
    [System.IO.File]::WriteAllText($commandFile, $Body, [System.Text.UTF8Encoding]::new($false))

    $psResult = Invoke-PowerShellEntry -CommandFile $commandFile -ExtraArgs $ExtraArgs
    & $Assert $psResult "PowerShell $Name"

    if ($script:bash) {
        $shResult = Invoke-BashEntry -BashPath $script:bash -CommandFile $commandFile -ExtraArgs $ExtraArgs
        & $Assert $shResult "Bash $Name"
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-linux-payload-policy-test-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null

$bashCandidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe"
)
$script:bash = $bashCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

try {
    Assert-PolicyCase `
        -Name "short-utf8-token" `
        -Body "grep '中文' /tmp/app.log`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -ne 3) "$Label should not require confirmation for a short UTF-8 token."
            Assert-True ($Result.Output -notmatch 'command_file_non_ascii_payload') "$Label should not warn for a single short UTF-8 token."
        }

    Assert-PolicyCase `
        -Name "multi-line-non-ascii" `
        -Body "printf '第一行'`nprintf '第二行'`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -eq 3) "$Label should require confirmation for multi-line non-ASCII payload."
            Assert-True ($Result.Output -match 'WARNING: command_file_non_ascii_payload') "$Label should emit non-ASCII payload warning."
            Assert-True ($Result.Output -match 'RISK: high') "$Label should upgrade risk to high."
        }

    Assert-PolicyCase `
        -Name "inline-sql" `
        -Body "mysql app <<'SQL'`nupdate users set name = '张三';`nSQL`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -eq 3) "$Label should require confirmation for inline mutating SQL."
            Assert-True ($Result.Output -match 'WARNING: command_file_inline_sql') "$Label should emit inline SQL warning."
            Assert-True ($Result.Output -match 'RISK: high') "$Label should upgrade inline SQL risk to high."
        }

    Assert-PolicyCase `
        -Name "read-only-sql-non-ascii" `
        -Body "psql app <<'SQL'`nselect '张三';`nSQL`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -eq 3) "$Label should require confirmation for read-only SQL with non-ASCII stdin."
            Assert-True ($Result.Output -match 'WARNING: command_file_inline_sql') "$Label should emit inline SQL warning."
            Assert-True ($Result.Output -match 'RISK: high') "$Label should upgrade non-ASCII SQL stdin risk to high."
        }

    Assert-PolicyCase `
        -Name "short-interpreter-ascii" `
        -Body "python3 - <<'PY'`nprint('ok')`nPY`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -ne 3) "$Label should not require confirmation for short ASCII interpreter stdin control script."
            Assert-True ($Result.Output -match 'WARNING: command_file_interpreted_stdin') "$Label should warn for inline interpreter stdin."
        }

    foreach ($interpreter in @("python3", "node", "ruby", "bash", "perl")) {
        Assert-PolicyCase `
            -Name ("interpreter-non-ascii-" + $interpreter) `
            -Body "$interpreter <<'EOF'`nprintf '中文'`nEOF`n" `
            -Assert {
                param($Result, $Label)
                Assert-True ($Result.ExitCode -eq 3) "$Label should require confirmation for interpreter stdin with non-ASCII."
                Assert-True ($Result.Output -match 'WARNING: command_file_interpreted_stdin') "$Label should emit interpreted stdin warning."
                Assert-True ($Result.Output -match 'RISK: high') "$Label should upgrade non-ASCII interpreter stdin risk to high."
            }
        }

    $largeHeredocLines = 1..21 | ForEach-Object { "line $_" }
    $largeHeredocBody = "cat <<'EOF' > /tmp/payload.txt`n" + ($largeHeredocLines -join "`n") + "`nEOF`n"
    Assert-PolicyCase `
        -Name "large-heredoc" `
        -Body $largeHeredocBody `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -eq 3) "$Label should require confirmation for large heredoc."
            Assert-True ($Result.Output -match 'WARNING: command_file_large_heredoc') "$Label should emit large heredoc warning."
        }

    $nestedLikeBody = "cat <<'OUTER' > /tmp/template.txt`ncat <<'INNER'`nnested content`nINNER`nOUTER`n"
    Assert-PolicyCase `
        -Name "heredoc-like-body" `
        -Body $nestedLikeBody `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.Output -notmatch 'command_file_inline_sql|command_file_interpreted_stdin|command_file_large_heredoc') "$Label should not parse heredoc-like body text as a second heredoc."
        }

    Assert-PolicyCase `
        -Name "kubectl-apply-non-ascii-yaml" `
        -Body "kubectl apply -f - <<'YAML'`nmetadata: {name: 中文}`nYAML`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -ne 3) "$Label should not hard-block kubectl stdin with a small non-ASCII YAML token."
            Assert-True ($Result.Output -notmatch 'command_file_interpreted_stdin|command_file_large_heredoc|command_file_non_ascii_payload') "$Label should not emit interpreter, large heredoc, or whole-file non-ASCII warnings."
        }

    Assert-PolicyCase `
        -Name "multi-heredoc-scoping" `
        -Body "python3 <<'PY'`nprint('中文')`nPY`ncat <<'TXT' >/tmp/msg.txt`n中文`nTXT`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -eq 3) "$Label should block for the interpreter heredoc."
            Assert-True ($Result.Output -match 'WARNING: command_file_interpreted_stdin') "$Label should emit interpreted stdin warning."
            Assert-True ($Result.Output -notmatch 'WARNING: command_file_large_heredoc') "$Label should not add a large-heredoc warning for a small plain cat heredoc."
        }

    Assert-PolicyCase `
        -Name "python-input-redirection" `
        -Body "python3 < /tmp/check.py`n" `
        -Assert {
            param($Result, $Label)
            Assert-True ($Result.ExitCode -ne 3) "$Label should not classify python stdin file redirection differently from short stdin control script policy."
        }

    if (-not $script:bash) {
        Write-Output "SKIP: Git Bash not found; Bash path not executed."
    }

    Write-Output "PASS: remote-exec command-file payload policy"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
