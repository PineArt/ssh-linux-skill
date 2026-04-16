function Get-UniqueExistingPaths {
    param(
        [string[]]$Candidates
    )

    $seen = @{}
    $results = @()
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path $candidate) {
            $normalized = [System.IO.Path]::GetFullPath($candidate)
            if (-not $seen.ContainsKey($normalized)) {
                $seen[$normalized] = $true
                $results += $normalized
            }
        }
    }
    return $results
}

function Find-ExecutableCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$KnownPaths = @()
    )

    $candidates = @()

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        $candidates += $command.Source
    }

    $whereExe = Get-Command where.exe -ErrorAction SilentlyContinue
    if ($whereExe) {
        try {
            $whereResults = & $whereExe.Source $Name 2>$null
            if ($whereResults) {
                $candidates += $whereResults
            }
        } catch {
        }
    }

    $candidates += $KnownPaths
    Get-UniqueExistingPaths -Candidates $candidates
}

function Get-SshToolchain {
    $windowsOpenSsh = "C:\Windows\System32\OpenSSH"
    $gitUsrBin = "C:\Program Files\Git\usr\bin"
    $gitBin = "C:\Program Files\Git\bin"
    $puttyDir = "C:\Program Files\PuTTY"

    $sshCandidates = Find-ExecutableCandidates -Name "ssh" -KnownPaths @(
        (Join-Path $windowsOpenSsh "ssh.exe"),
        (Join-Path $gitUsrBin "ssh.exe"),
        (Join-Path $gitBin "ssh.exe")
    )
    $scpCandidates = Find-ExecutableCandidates -Name "scp" -KnownPaths @(
        (Join-Path $windowsOpenSsh "scp.exe"),
        (Join-Path $gitUsrBin "scp.exe"),
        (Join-Path $gitBin "scp.exe")
    )
    $sftpCandidates = Find-ExecutableCandidates -Name "sftp" -KnownPaths @(
        (Join-Path $windowsOpenSsh "sftp.exe"),
        (Join-Path $gitUsrBin "sftp.exe"),
        (Join-Path $gitBin "sftp.exe")
    )
    $sshAddCandidates = Find-ExecutableCandidates -Name "ssh-add" -KnownPaths @(
        (Join-Path $windowsOpenSsh "ssh-add.exe"),
        (Join-Path $gitUsrBin "ssh-add.exe"),
        (Join-Path $gitBin "ssh-add.exe")
    )
    $sshKeygenCandidates = Find-ExecutableCandidates -Name "ssh-keygen" -KnownPaths @(
        (Join-Path $windowsOpenSsh "ssh-keygen.exe"),
        (Join-Path $gitUsrBin "ssh-keygen.exe"),
        (Join-Path $gitBin "ssh-keygen.exe")
    )

    if ($sshCandidates.Count -gt 0) {
        return @{
            backend = "openssh"
            ssh = $sshCandidates[0]
            scp = if ($scpCandidates.Count -gt 0) { $scpCandidates[0] } else { "" }
            sftp = if ($sftpCandidates.Count -gt 0) { $sftpCandidates[0] } else { "" }
            ssh_add = if ($sshAddCandidates.Count -gt 0) { $sshAddCandidates[0] } else { "" }
            ssh_keygen = if ($sshKeygenCandidates.Count -gt 0) { $sshKeygenCandidates[0] } else { "" }
            ssh_candidates = $sshCandidates
            scp_candidates = $scpCandidates
            sftp_candidates = $sftpCandidates
        }
    }

    $plinkCandidates = Find-ExecutableCandidates -Name "plink" -KnownPaths @(
        (Join-Path $puttyDir "plink.exe")
    )
    $pscpCandidates = Find-ExecutableCandidates -Name "pscp" -KnownPaths @(
        (Join-Path $puttyDir "pscp.exe")
    )
    $pageantCandidates = Find-ExecutableCandidates -Name "pageant" -KnownPaths @(
        (Join-Path $puttyDir "pageant.exe")
    )

    if ($plinkCandidates.Count -gt 0) {
        return @{
            backend = "putty"
            plink = $plinkCandidates[0]
            pscp = if ($pscpCandidates.Count -gt 0) { $pscpCandidates[0] } else { "" }
            pageant = if ($pageantCandidates.Count -gt 0) { $pageantCandidates[0] } else { "" }
            plink_candidates = $plinkCandidates
            pscp_candidates = $pscpCandidates
        }
    }

    return @{
        backend = "none"
        ssh_candidates = $sshCandidates
        scp_candidates = $scpCandidates
        plink_candidates = $plinkCandidates
        pscp_candidates = $pscpCandidates
    }
}

