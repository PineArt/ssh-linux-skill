#!/usr/bin/env bash
set -euo pipefail

unique_existing_paths() {
  local seen=""
  local candidate normalized
  for candidate in "$@"; do
    [[ -z "$candidate" ]] && continue
    [[ -e "$candidate" ]] || continue
    normalized="$candidate"
    if [[ ":$seen:" != *":$normalized:"* ]]; then
      printf '%s\n' "$normalized"
      seen="${seen}:$normalized"
    fi
  done
}

find_executable_candidates() {
  local name="$1"
  shift || true

  local results=()
  if command -v "$name" >/dev/null 2>&1; then
    results+=("$(command -v "$name")")
  fi
  if command -v where.exe >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && results+=("$line")
    done < <(where.exe "$name" 2>/dev/null || true)
  fi
  while (($# > 0)); do
    results+=("$1")
    shift
  done

  unique_existing_paths "${results[@]}"
}

ssh_toolchain_backend=""
ssh_tool=""
scp_tool=""
sftp_tool=""
ssh_add_tool=""
ssh_keygen_tool=""
plink_tool=""
pscp_tool=""
pageant_tool=""

load_ssh_toolchain() {
  local windows_ssh='C:\Windows\System32\OpenSSH'
  local git_usr='C:\Program Files\Git\usr\bin'
  local git_bin='C:\Program Files\Git\bin'
  local putty_dir='C:\Program Files\PuTTY'

  mapfile -t ssh_candidates < <(find_executable_candidates ssh \
    "$windows_ssh\\ssh.exe" \
    "$git_usr\\ssh.exe" \
    "$git_bin\\ssh.exe")
  mapfile -t scp_candidates < <(find_executable_candidates scp \
    "$windows_ssh\\scp.exe" \
    "$git_usr\\scp.exe" \
    "$git_bin\\scp.exe")
  mapfile -t sftp_candidates < <(find_executable_candidates sftp \
    "$windows_ssh\\sftp.exe" \
    "$git_usr\\sftp.exe" \
    "$git_bin\\sftp.exe")
  mapfile -t ssh_add_candidates < <(find_executable_candidates ssh-add \
    "$windows_ssh\\ssh-add.exe" \
    "$git_usr\\ssh-add.exe" \
    "$git_bin\\ssh-add.exe")
  mapfile -t ssh_keygen_candidates < <(find_executable_candidates ssh-keygen \
    "$windows_ssh\\ssh-keygen.exe" \
    "$git_usr\\ssh-keygen.exe" \
    "$git_bin\\ssh-keygen.exe")

  if ((${#ssh_candidates[@]} > 0)); then
    ssh_toolchain_backend="openssh"
    ssh_tool="${ssh_candidates[0]}"
    scp_tool="${scp_candidates[0]:-}"
    sftp_tool="${sftp_candidates[0]:-}"
    ssh_add_tool="${ssh_add_candidates[0]:-}"
    ssh_keygen_tool="${ssh_keygen_candidates[0]:-}"
    return 0
  fi

  mapfile -t plink_candidates < <(find_executable_candidates plink "$putty_dir\\plink.exe")
  mapfile -t pscp_candidates < <(find_executable_candidates pscp "$putty_dir\\pscp.exe")
  mapfile -t pageant_candidates < <(find_executable_candidates pageant "$putty_dir\\pageant.exe")

  if ((${#plink_candidates[@]} > 0)); then
    ssh_toolchain_backend="putty"
    plink_tool="${plink_candidates[0]}"
    pscp_tool="${pscp_candidates[0]:-}"
    pageant_tool="${pageant_candidates[0]:-}"
    return 0
  fi

  ssh_toolchain_backend="none"
  return 1
}

