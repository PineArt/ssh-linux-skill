[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$psEntry = Join-Path $repoRoot "scripts\remote-exec.ps1"
$processUtils = Join-Path $repoRoot "scripts\process-utils.ps1"
$powerShellExe = (Get-Command powershell).Source

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-linux-pwsh-quoting-test-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $byteDumpScript = Join-Path $tempDir "stdin-byte-dump.ps1"
    @'
$bytes = New-Object byte[] 128
$count = [Console]::OpenStandardInput().Read($bytes, 0, 128)
if ($count -eq 0) {
    Write-Output "EMPTY"
    exit 0
}
($bytes[0..($count - 1)] | ForEach-Object { $_.ToString("X2") }) -join " "
'@ | Set-Content -LiteralPath $byteDumpScript -Encoding ASCII

    $probe = @"
. '$processUtils'
`$inputText = "cd /tmp`n" + [string]([char]0x4e2d) + [string]([char]0x6587) + "`n"
`$result = Invoke-NativeProcessCapture -FilePath '$powerShellExe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$byteDumpScript') -EnvironmentTable @{} -InputText `$inputText
Write-Output ("EC={0}" -f `$result.ExitCode)
Write-Output ("OUT={0}" -f `$result.StdOut.Trim())
Write-Output ("ERR={0}" -f `$result.StdErr.Trim())
"@
    $probeFile = Join-Path $tempDir "probe-native-stdin.ps1"
    [System.IO.File]::WriteAllText($probeFile, $probe, [System.Text.UTF8Encoding]::new($false))
    $nativeBytes = & powershell -NoProfile -ExecutionPolicy Bypass -File $probeFile
    Assert-True ($LASTEXITCODE -eq 0) "Windows PowerShell native stdin probe should exit successfully."
    $nativeText = $nativeBytes -join "`n"
    Assert-True ($nativeText -match 'EC=0') "Windows PowerShell native stdin child should exit successfully."
    Assert-True ($nativeText -notmatch 'EMPTY') "Invoke-NativeProcessCapture should deliver stdin to the child process."
    Assert-True ($nativeText -match '63 64 20') "Invoke-NativeProcessCapture should write stdin content bytes."
    Assert-True ($nativeText -match 'E4 B8 AD E6 96 87') "Invoke-NativeProcessCapture should preserve UTF-8 stdin bytes."
    Assert-True ($nativeText -notmatch 'EF BB BF') "Invoke-NativeProcessCapture should write stdin without a UTF-8 BOM."

    $bomCommandFile = Join-Path $tempDir "command-bom.sh"
    $bomBytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("cd /tmp`nprintf 'ok'`n")
    [System.IO.File]::WriteAllBytes($bomCommandFile, $bomBytes)
    $fileOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $psEntry --host example.invalid --command-file $bomCommandFile --risk high 2>&1
    $fileText = $fileOutput -join "`n"
    Assert-True ($LASTEXITCODE -eq 3) "BOM command-file probe should stop at pending confirmation."
    Assert-True ($fileText -match 'WARNING: command_file_bom_normalized') "BOM command-file probe should emit a BOM normalization warning."
    Assert-True ($fileText -notmatch '(?m)^WARNING:\s*$') "BOM command-file probe should not emit empty warning labels."
    Assert-True ($fileText -match 'COMMAND: cd /tmp') "BOM command-file probe should show cd without a leading BOM."
    Assert-True (-not $fileText.Contains([char]0xFEFF)) "BOM command-file probe output should not contain a literal BOM marker."

    $stdinFile = Join-Path $tempDir "stdin-body.txt"
    [System.IO.File]::WriteAllText($stdinFile, ([string]([char]0xFEFF) + "cd /tmp`nprintf 'quoted `"value`" and `$STAGE'`n"), [System.Text.UTF8Encoding]::new($false))
    $stdinOutput = & powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '$stdinFile' -Raw | & '$psEntry' --host example.invalid --command-stdin --risk high" 2>&1
    $stdinText = $stdinOutput -join "`n"
    Assert-True ($stdinText -match 'STATUS: pending_confirmation') "command-stdin probe should stop at pending confirmation."
    Assert-True ($stdinText -notmatch '(?m)^WARNING:\s*$') "command-stdin probe should not emit empty warning labels."
    Assert-True ($stdinText -match 'COMMAND: cd /tmp') "command-stdin probe should show cd without a leading BOM."
    Assert-True ($stdinText -match 'quoted "value" and \$STAGE') "command-stdin should preserve quotes and dollar signs after PowerShell pipeline input."
    Assert-True (-not $stdinText.Contains([char]0xFEFF)) "command-stdin output should not contain a literal BOM marker."

    $unsafeInline = & powershell -NoProfile -ExecutionPolicy Bypass -File $psEntry --host example.invalid --command "python - <<'PY'`nprint('ok')`nPY" --risk low 2>&1
    $unsafeText = $unsafeInline -join "`n"
    Assert-True ($LASTEXITCODE -eq 2) "Multiline inline --command should be rejected before SSH."
    Assert-True ($unsafeText -match '--command-file|--command-stdin') "Multiline inline rejection should guide users to safer transports."

    Write-Output "PASS: remote-exec PowerShell quoting and BOM hardening"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
