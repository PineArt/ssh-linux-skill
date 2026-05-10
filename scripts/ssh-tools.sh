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

convert_to_openssh_control_path_token() {
  local value="${1-}"
  value="${value//[^A-Za-z0-9._-]/_}"
  while [[ "$value" == _* ]]; do
    value="${value#_}"
  done
  while [[ "$value" == *_ ]]; do
    value="${value%_}"
  done
  if [[ -z "$value" ]]; then
    printf 'default'
    return 0
  fi
  if (( ${#value} > 48 )); then
    printf '%s' "${value:0:48}"
    return 0
  fi
  printf '%s' "$value"
}

new_openssh_control_base_dir() {
  local uid_value="${UID:-$(id -u 2>/dev/null || printf 'unknown')}"
  local temp_root="${TMPDIR:-/tmp}"
  local uname_value

  uname_value="$(uname -s 2>/dev/null || printf '')"
  if [[ "$uname_value" == MINGW* || "$uname_value" == MSYS* || "$uname_value" == CYGWIN* ]]; then
    if [[ -n "${LOCALAPPDATA:-}" ]] && command -v cygpath >/dev/null 2>&1; then
      temp_root="$(cygpath -u "${LOCALAPPDATA}\\Temp" 2>/dev/null || printf '%s' "$temp_root")"
    fi
    printf '%s/slc-%s' "$temp_root" "$uid_value"
    return 0
  fi

  printf '%s/slc-%s' "$temp_root" "$uid_value"
}

ensure_private_openssh_control_dir() {
  local base_dir="$1"
  local uname_value

  uname_value="$(uname -s 2>/dev/null || printf '')"
  if [[ -L "$base_dir" ]]; then
    printf 'refusing symlinked SSH control directory: %s\n' "$base_dir" >&2
    return 1
  fi

  mkdir -p "$base_dir"
  chmod 700 "$base_dir" 2>/dev/null || true

  if [[ "$uname_value" == MINGW* || "$uname_value" == MSYS* || "$uname_value" == CYGWIN* ]]; then
    return 0
  fi

  if [[ -L "$base_dir" ]]; then
    printf 'refusing symlinked SSH control directory: %s\n' "$base_dir" >&2
    return 1
  fi
  if command -v stat >/dev/null 2>&1; then
    local mode
    mode="$(stat -c '%a' "$base_dir" 2>/dev/null || printf '')"
    if [[ -n "$mode" && "$mode" != "700" ]]; then
      printf 'refusing SSH control directory with mode %s: %s\n' "$mode" "$base_dir" >&2
      return 1
    fi
  fi
}

new_openssh_control_path() {
  local target="${1-}"
  local port="${2-}"
  local identity_file="${3-}"
  local known_hosts_file="${4-}"
  local auth_mode="${5-}"
  local base_dir
  local target_token port_value identity_value known_hosts_value auth_mode_value fingerprint_source fingerprint_hash file_name

  base_dir="$(new_openssh_control_base_dir)"
  ensure_private_openssh_control_dir "$base_dir"
  target_token="$(convert_to_openssh_control_path_token "$target")"
  if (( ${#target_token} > 12 )); then
    target_token="${target_token:0:12}"
  fi
  port_value="${port:-22}"
  if [[ -z "$identity_file" ]]; then
    identity_value="default"
  elif command -v realpath >/dev/null 2>&1; then
    identity_value="$(realpath "$identity_file" 2>/dev/null || printf '%s' "$identity_file")"
  else
    identity_value="$identity_file"
  fi
  if [[ -z "$known_hosts_file" ]]; then
    known_hosts_value="default"
  elif command -v realpath >/dev/null 2>&1; then
    known_hosts_value="$(realpath "$known_hosts_file" 2>/dev/null || printf '%s' "$known_hosts_file")"
  else
    known_hosts_value="$known_hosts_file"
  fi
  auth_mode_value="${auth_mode:-default}"

  fingerprint_source="${target}|${port_value}|${identity_value}|${known_hosts_value}|${auth_mode_value}"
  if command -v sha256sum >/dev/null 2>&1; then
    fingerprint_hash="$(printf '%s' "$fingerprint_source" | sha256sum | awk '{ print $1 }')"
  elif command -v shasum >/dev/null 2>&1; then
    fingerprint_hash="$(printf '%s' "$fingerprint_source" | shasum -a 256 | awk '{ print $1 }')"
  else
    fingerprint_hash="$(printf '%s' "$fingerprint_source" | cksum | awk '{ print $1 }')"
  fi

  file_name="cm-${target_token}-${fingerprint_hash:0:16}.sock"
  printf '%s/%s' "$base_dir" "$file_name"
}

ensure_openssh_control_master() {
  local ssh_program="$1"
  local control_path="$2"
  local control_persist="$3"
  local target="$4"
  shift 4
  local base_args=("$@")

  if "$ssh_program" "${base_args[@]}" -O check -o "ControlPath=$control_path" "$target" >/dev/null 2>&1; then
    return 0
  fi

  "$ssh_program" "${base_args[@]}" \
    -N \
    -f \
    -o "ControlMaster=yes" \
    -o "ControlPath=$control_path" \
    -o "ControlPersist=${control_persist}s" \
    "$target"
}

remove_openssh_mux_noise() {
  grep -Ev '^(mux_client_request_session: read from master failed: |ControlSocket .+ already exists, disabling multiplexing$)' || true
}

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
