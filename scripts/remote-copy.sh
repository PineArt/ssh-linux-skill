#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-tools.sh"

status() {
  printf '%s: %s\n' "$1" "$2"
}

usage() {
  cat <<'EOF'
remote-copy.sh

SUMMARY
  Upload or download files over SSH/SCP with auth and risk checks.

USAGE
  remote-copy.sh --host VALUE --direction upload|download --source VALUE --target VALUE [options]
  remote-copy.sh --help
  remote-copy.sh --help-json

ARGUMENTS
  --host VALUE
  --direction upload|download
  --source VALUE
  --target VALUE
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --known-hosts-file VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
  --reuse-connection
  --control-persist VALUE
  --recursive
  --help | -h
  --help-json

OUTPUT CONTRACT
  Plain-text labels: STATUS, HOST, ACTION, AUTH_MODE, RISK, REASON, NEXT
  Transfer labels: DIRECTION, SOURCE, TARGET
  Additional labels: DURATION_MS, CONTROL_PATH, CONTROL_PERSIST, WARNING
  Optional blocks: OUTPUT, STDERR

EXAMPLES
  remote-copy.sh --host app-prod --direction upload --source ./build/app.tar.gz --target /tmp/app.tar.gz
  remote-copy.sh --host app-prod --direction download --source /var/log/nginx/access.log --target ./logs/access.log
  remote-copy.sh --host app-prod --direction upload --source ./config.env --target /etc/app/config.env --confirmation-state confirmed
  remote-copy.sh --host app-prod --reuse-connection --direction upload --source ./build/app.tar.gz --target /tmp/app.tar.gz
EOF
}

help_json() {
  cat <<'EOF'
{"name":"remote-copy.sh","summary":"Upload or download files over SSH/SCP with auth and risk checks.","usage":["remote-copy.sh --host VALUE --direction upload|download --source VALUE --target VALUE [options]","remote-copy.sh --help","remote-copy.sh --help-json"],"arguments":[{"name":"--host","required":true,"value":"VALUE","description":"SSH host, alias, or user@host target."},{"name":"--direction","required":true,"value":"upload|download","description":"Transfer direction."},{"name":"--source","required":true,"value":"VALUE","description":"Source path (local for upload, remote for download)."},{"name":"--target","required":true,"value":"VALUE","description":"Target path (remote for upload, local for download)."},{"name":"--user","required":false,"value":"VALUE","description":"Username, used when host is not in user@host form."},{"name":"--port","required":false,"value":"VALUE","description":"SSH port."},{"name":"--auth-mode","required":false,"value":"ssh-alias|identity-file|default-key-discovery|ssh-agent|password","description":"Authentication strategy."},{"name":"--identity-file","required":false,"value":"VALUE","description":"Private key path for identity-file mode."},{"name":"--known-hosts-file","required":false,"value":"VALUE","description":"known_hosts path for host key verification."},{"name":"--risk","required":false,"value":"auto|low|high","description":"Risk override. auto classifies path sensitivity."},{"name":"--confirmation-state","required":false,"value":"pending|confirmed|none","description":"High-risk confirmation gate."},{"name":"--password-env","required":false,"value":"VALUE","description":"Environment variable name for password mode."},{"name":"--timeout","required":false,"value":"VALUE","description":"SSH connect timeout in seconds."},{"name":"--reuse-connection","required":false,"value":"","description":"Reuse an OpenSSH connection via ControlMaster/ControlPersist when supported."},{"name":"--control-persist","required":false,"value":"VALUE","description":"ControlPersist lifetime in seconds when --reuse-connection is enabled. Default 60."},{"name":"--recursive","required":false,"value":"","description":"Enable recursive copy for directories."},{"name":"--help|-h","required":false,"value":"","description":"Show human-readable help."},{"name":"--help-json","required":false,"value":"","description":"Show machine-readable JSON help."}],"examples":["remote-copy.sh --host app-prod --direction upload --source ./build/app.tar.gz --target /tmp/app.tar.gz","remote-copy.sh --host app-prod --direction download --source /var/log/nginx/access.log --target ./logs/access.log","remote-copy.sh --host app-prod --direction upload --source ./config.env --target /etc/app/config.env --confirmation-state confirmed","remote-copy.sh --host app-prod --reuse-connection --direction upload --source ./build/app.tar.gz --target /tmp/app.tar.gz"],"output_contract":{"format":"plain-text status labels with transfer context and optional OUTPUT/STDERR blocks","labels":["STATUS","HOST","ACTION","AUTH_MODE","RISK","REASON","NEXT"],"extra_labels":["DIRECTION","SOURCE","TARGET","DURATION_MS","CONTROL_PATH","CONTROL_PERSIST","WARNING"],"common_statuses":["ok","invalid_arguments","pending_confirmation","missing_source","auth_tool_unavailable","missing_key","key_ambiguous","missing_known_hosts","interactive_password_required","auth_mode_unsupported","auth_failed","connect_failed","transfer_failed"]}}
EOF
}

host=""
direction=""
source_path=""
target_path=""
user_name=""
port=""
auth_mode="ssh-alias"
identity_file=""
known_hosts_file=""
risk="auto"
confirmation_state="none"
password_env="SSH_PASSWORD"
timeout="15"
reuse_connection="false"
control_persist="60"
recursive="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      host="${2:-}"
      shift 2
      ;;
    --direction)
      direction="${2:-}"
      shift 2
      ;;
    --source)
      source_path="${2:-}"
      shift 2
      ;;
    --target)
      target_path="${2:-}"
      shift 2
      ;;
    --user)
      user_name="${2:-}"
      shift 2
      ;;
    --port)
      port="${2:-}"
      shift 2
      ;;
    --auth-mode)
      auth_mode="${2:-}"
      shift 2
      ;;
    --identity-file)
      identity_file="${2:-}"
      shift 2
      ;;
    --known-hosts-file)
      known_hosts_file="${2:-}"
      shift 2
      ;;
    --risk)
      risk="${2:-}"
      shift 2
      ;;
    --confirmation-state)
      confirmation_state="${2:-}"
      shift 2
      ;;
    --password-env)
      password_env="${2:-}"
      shift 2
      ;;
    --timeout)
      timeout="${2:-}"
      shift 2
      ;;
    --reuse-connection)
      reuse_connection="true"
      shift
      ;;
    --control-persist)
      control_persist="${2:-}"
      if [[ ! "$control_persist" =~ ^[0-9]+$ || "$control_persist" -lt 1 ]]; then
        status STATUS invalid_arguments
        status ACTION remote_copy
        status REASON "--control-persist must be a positive integer number of seconds"
        status NEXT "provide a valid --control-persist value"
        exit 2
      fi
      shift 2
      ;;
    --recursive)
      recursive="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --help-json)
      help_json
      exit 0
      ;;
    *)
      status STATUS invalid_arguments
      status ACTION remote_copy
      status REASON "unknown argument: $1"
      status NEXT "run with --help"
      exit 2
      ;;
  esac
done

if [[ -z "$host" || -z "$direction" || -z "$source_path" || -z "$target_path" ]]; then
  usage
  exit 2
fi

target="$host"
if [[ "$host" != *@* && -n "$user_name" ]]; then
  target="${user_name}@${host}"
fi

is_sensitive_path() {
  local path_value="$1"
  [[ "$path_value" == /etc* ]] && return 0
  [[ "$path_value" == /usr* ]] && return 0
  [[ "$path_value" == /bin* ]] && return 0
  [[ "$path_value" == /sbin* ]] && return 0
  [[ "$path_value" == /opt* ]] && return 0
  [[ "$path_value" == /var/www* ]] && return 0
  [[ "$path_value" == *".env"* ]] && return 0
  [[ "$path_value" == *"id_rsa"* ]] && return 0
  [[ "$path_value" == *"id_ed25519"* ]] && return 0
  [[ "$path_value" == *".bashrc"* ]] && return 0
  [[ "$path_value" == *".profile"* ]] && return 0
  [[ "$path_value" == *".zshrc"* ]] && return 0
  return 1
}

is_safe_workspace() {
  local path_value="$1"
  [[ "$path_value" == /tmp/* ]] && return 0
  [[ "$path_value" == /tmp ]] && return 0
  [[ "$path_value" == /var/tmp/* ]] && return 0
  [[ "$path_value" == /var/tmp ]] && return 0
  [[ "$path_value" == ~/tmp* ]] && return 0
  return 1
}

if [[ "$risk" == "auto" ]]; then
  risk="low"
  if [[ "$direction" == "upload" ]]; then
    if is_sensitive_path "$target_path" || ! is_safe_workspace "$target_path"; then
      risk="high"
    fi
  elif [[ "$direction" == "download" ]]; then
    if is_sensitive_path "$source_path"; then
      risk="high"
    fi
  else
    status STATUS invalid_arguments
    status HOST "$target"
    status ACTION remote_copy
    status AUTH_MODE "$auth_mode"
    status RISK "$risk"
    status REASON "direction must be upload or download"
    status NEXT "provide a valid --direction"
    exit 2
  fi
fi

if [[ "$risk" == "high" && "$confirmation_state" != "confirmed" ]]; then
  status STATUS pending_confirmation
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK high
  status REASON "transfer is classified as high risk"
  status NEXT "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
  printf 'DIRECTION: %s\n' "$direction"
  printf 'SOURCE: %s\n' "$source_path"
  printf 'TARGET: %s\n' "$target_path"
  exit 3
fi

if [[ "$direction" == "upload" && ! -e "$source_path" ]]; then
  status STATUS missing_source
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "local source path does not exist"
  status NEXT "provide a valid local source path"
  exit 4
fi

load_ssh_toolchain || true
if [[ "$ssh_toolchain_backend" == "none" ]]; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "no supported SSH or copy backend was found"
  status NEXT "install OpenSSH or PuTTY tools and ensure they are discoverable"
  exit 4
fi

if [[ "$reuse_connection" == "true" && "$ssh_toolchain_backend" != "openssh" ]]; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "--reuse-connection requires OpenSSH ControlMaster support"
  status NEXT "use OpenSSH or rerun without --reuse-connection"
  exit 4
fi
if [[ "$ssh_toolchain_backend" == "openssh" && -z "$scp_tool" ]]; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "OpenSSH was found but scp is unavailable"
  status NEXT "install OpenSSH scp or add it to PATH"
  exit 4
fi

if [[ "$ssh_toolchain_backend" == "putty" && -z "$pscp_tool" ]]; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "PuTTY plink was found but pscp is unavailable"
  status NEXT "install PuTTY pscp or use OpenSSH tools"
  exit 4
fi

case "$auth_mode" in
  ssh-alias)
    ;;
  identity-file)
    if [[ -z "$identity_file" || ! -f "$identity_file" ]]; then
      status STATUS missing_key
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "explicit identity file was required but not found"
      status NEXT "provide a valid --identity-file"
      exit 5
    fi
    ;;
  default-key-discovery)
    candidates=()
    for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
      [[ -f "$candidate" ]] && candidates+=("$candidate")
    done
    if (( ${#candidates[@]} == 0 )); then
      status STATUS missing_key
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "no default private key was found"
      status NEXT "generate a key or choose a different auth mode"
      exit 5
    fi
    if (( ${#candidates[@]} > 1 )); then
      status STATUS key_ambiguous
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "multiple default private keys were found"
      status NEXT "choose one key explicitly with --identity-file"
      printf 'CANDIDATE_KEYS:\n'
      printf '%s\n' "${candidates[@]}"
      exit 6
    fi
    identity_file="${candidates[0]}"
    ;;
  ssh-agent)
    if [[ "$ssh_toolchain_backend" != "openssh" || -z "$ssh_add_tool" ]]; then
      status STATUS auth_tool_unavailable
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "ssh-agent support requires OpenSSH ssh-add"
      status NEXT "use a file-based auth mode or install OpenSSH tools"
      exit 4
    fi
    agent_output="$("$ssh_add_tool" -l 2>&1 || true)"
    if [[ "$agent_output" == *"The agent has no identities."* ]]; then
      status STATUS missing_key
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "ssh-agent has no identities"
      status NEXT "add a key or use another auth mode"
      exit 5
    fi
    identity_count="$(grep -Ec '^[0-9]+' <<<"$agent_output" || true)"
    if [[ "${identity_count:-0}" -gt 1 ]]; then
      status STATUS key_ambiguous
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "ssh-agent contains multiple identities"
      status NEXT "choose an explicit identity file or narrow the agent state"
      printf 'AGENT_IDENTITIES:\n%s\n' "$agent_output"
      exit 6
    fi
    ;;
  password)
    ;;
  *)
    status STATUS invalid_arguments
    status HOST "$target"
    status ACTION remote_copy
    status AUTH_MODE "$auth_mode"
    status RISK "$risk"
    status REASON "unsupported auth mode"
    status NEXT "choose a supported auth mode"
    exit 2
    ;;
esac

if [[ -z "$known_hosts_file" && -f "${HOME:-}/.ssh/known_hosts" ]]; then
  known_hosts_file="${HOME}/.ssh/known_hosts"
fi

if [[ -n "$known_hosts_file" && ! -f "$known_hosts_file" ]]; then
  status STATUS missing_known_hosts
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "known_hosts file was not found"
  status NEXT "provide a valid --known-hosts-file or accept the host key once outside the sandbox"
  printf 'KNOWN_HOSTS_FILE: %s\n' "$known_hosts_file"
  exit 5
fi

key_permission_warning="false"
if [[ -n "$identity_file" && -f "$identity_file" ]]; then
  if command -v stat >/dev/null 2>&1; then
    key_mode="$(stat -c '%a' "$identity_file" 2>/dev/null || true)"
    if [[ -n "$key_mode" ]]; then
      group_other=$((10#$key_mode % 100))
      if (( group_other > 0 )); then
        key_permission_warning="true"
      fi
    fi
  fi
fi

control_path=""
if [[ "$reuse_connection" == "true" ]]; then
  control_path="$(new_openssh_control_path "$target" "$port" "$identity_file" "$known_hosts_file" "$auth_mode")"
fi

ssh_args=()
copy_args=()
ssh_connection_args=()
copy_connection_args=()
ssh_program=""
copy_program=""
if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
  ssh_program="$ssh_tool"
  copy_program="$scp_tool"
  ssh_connection_args+=(-o "ConnectTimeout=$timeout")
  copy_connection_args+=(-o "ConnectTimeout=$timeout")
else
  ssh_program="$plink_tool"
  copy_program="$pscp_tool"
  ssh_args+=(-batch)
  copy_args+=(-batch)
fi
if [[ -n "$port" ]]; then
  if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
    ssh_connection_args+=(-p "$port")
    copy_connection_args+=(-P "$port")
  else
    ssh_args+=(-P "$port")
    copy_args+=(-P "$port")
  fi
fi
if [[ -n "$identity_file" ]]; then
  if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
    ssh_connection_args+=(-i "$identity_file")
    copy_connection_args+=(-i "$identity_file")
    ssh_connection_args+=(-o "IdentitiesOnly=yes")
    copy_connection_args+=(-o "IdentitiesOnly=yes")
  else
    ssh_args+=(-i "$identity_file")
    copy_args+=(-i "$identity_file")
  fi
fi
if [[ -n "$known_hosts_file" && "$ssh_toolchain_backend" == "openssh" ]]; then
  ssh_connection_args+=(-o "UserKnownHostsFile=$known_hosts_file")
  copy_connection_args+=(-o "UserKnownHostsFile=$known_hosts_file")
fi
if [[ "$auth_mode" == "password" ]]; then
  if [[ "$ssh_toolchain_backend" != "openssh" ]]; then
    status STATUS auth_mode_unsupported
    status HOST "$target"
    status ACTION remote_copy
    status AUTH_MODE "$auth_mode"
    status RISK "$risk"
    status REASON "password automation is only implemented for OpenSSH"
    status NEXT "use OpenSSH or a key-based auth mode"
    exit 8
  fi
  ssh_connection_args+=(-o "PreferredAuthentications=password" -o "PubkeyAuthentication=no")
  copy_connection_args+=(-o "PreferredAuthentications=password" -o "PubkeyAuthentication=no")
else
  if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
    ssh_connection_args+=(-o "BatchMode=yes")
    copy_connection_args+=(-o "BatchMode=yes")
  fi
fi
if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
  ssh_args+=("${ssh_connection_args[@]}")
  copy_args+=("${copy_connection_args[@]}")
  if [[ "$reuse_connection" == "true" ]]; then
    control_options=(
      -o "ControlMaster=no"
      -o "ControlPath=$control_path"
      -o "ControlPersist=${control_persist}s"
    )
    ssh_args+=("${control_options[@]}")
    copy_args+=("${control_options[@]}")
  fi
fi
if [[ "$recursive" == "true" ]]; then
  copy_args+=(-r)
fi

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
askpass_file=""
control_master_failed="false"
cleanup() {
  rm -f "$stdout_file" "$stderr_file"
  [[ -n "$askpass_file" ]] && rm -f "$askpass_file"
  return 0
}
trap cleanup EXIT

maybe_precheck_remote_exists() {
  if [[ "$direction" != "upload" || "$confirmation_state" == "confirmed" ]]; then
    return 0
  fi
  local escaped_target_path
  escaped_target_path="${target_path//\'/\'\\\'\'}"
  set +e
  "$ssh_program" "${ssh_args[@]}" "$target" "test -e '$escaped_target_path'" >/dev/null 2>&1
  local exists_code=$?
  set -e
  if [[ "$exists_code" -eq 0 ]]; then
    status STATUS pending_confirmation
    status HOST "$target"
    status ACTION remote_copy
    status AUTH_MODE "$auth_mode"
    status RISK high
    status REASON "upload target already exists on the remote host"
    status NEXT "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
    printf 'SOURCE: %s\n' "$source_path"
    printf 'TARGET: %s\n' "$target_path"
    exit 3
  fi
}

run_copy() {
  local remote_spec

  if [[ "$auth_mode" == "password" ]]; then
    password_value="${!password_env-}"
    if [[ -z "$password_value" ]]; then
      status STATUS interactive_password_required
      status HOST "$target"
      status ACTION remote_copy
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "password auth requires an environment variable such as SSH_PASSWORD"
      status NEXT "set the password environment variable and rerun"
      return 7
    fi
    askpass_file="$(mktemp)"
    cat >"$askpass_file" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$SSH_LINUX_ASKPASS_SECRET"
EOF
    chmod 700 "$askpass_file"
    if [[ "$reuse_connection" == "true" ]]; then
      SSH_LINUX_ASKPASS_SECRET="$password_value" \
        SSH_ASKPASS="$askpass_file" \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY="${DISPLAY:-codex-ssh-linux}" \
        ensure_openssh_control_master "$ssh_program" "$control_path" "$control_persist" "$target" "${ssh_connection_args[@]}" >"$stdout_file" 2>"$stderr_file"
      local master_exit_code=$?
      if [[ "$master_exit_code" -ne 0 ]]; then
        control_master_failed="true"
        return "$master_exit_code"
      fi
    fi
    if [[ "$direction" == "upload" ]]; then
      remote_spec="${target}:${target_path}"
      env SSH_LINUX_ASKPASS_SECRET="$password_value" SSH_ASKPASS="$askpass_file" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-codex-ssh-linux}" "$copy_program" "${copy_args[@]}" "$source_path" "$remote_spec" >"$stdout_file" 2>"$stderr_file"
    else
      remote_spec="${target}:${source_path}"
      env SSH_LINUX_ASKPASS_SECRET="$password_value" SSH_ASKPASS="$askpass_file" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-codex-ssh-linux}" "$copy_program" "${copy_args[@]}" "$remote_spec" "$target_path" >"$stdout_file" 2>"$stderr_file"
    fi
  else
    if [[ "$reuse_connection" == "true" ]]; then
      ensure_openssh_control_master "$ssh_program" "$control_path" "$control_persist" "$target" "${ssh_connection_args[@]}" >"$stdout_file" 2>"$stderr_file"
      local master_exit_code=$?
      if [[ "$master_exit_code" -ne 0 ]]; then
        control_master_failed="true"
        return "$master_exit_code"
      fi
    fi
    if [[ "$direction" == "upload" ]]; then
      remote_spec="${target}:${target_path}"
      "$copy_program" "${copy_args[@]}" "$source_path" "$remote_spec" >"$stdout_file" 2>"$stderr_file"
    else
      remote_spec="${target}:${source_path}"
      "$copy_program" "${copy_args[@]}" "$remote_spec" "$target_path" >"$stdout_file" 2>"$stderr_file"
    fi
  fi
}

maybe_precheck_remote_exists

start_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
set +e
run_copy
exit_code=$?
set -e
end_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
duration_ms=$((end_ms - start_ms))

stderr_text="$(cat "$stderr_file" 2>/dev/null || true)"
if [[ "$reuse_connection" == "true" && -n "$stderr_text" ]]; then
  stderr_text="$(printf '%s\n' "$stderr_text" | remove_openssh_mux_noise)"
fi
stdout_text="$(cat "$stdout_file" 2>/dev/null || true)"

if [[ "$exit_code" -eq 0 ]]; then
  status STATUS ok
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "file transfer completed successfully"
  status NEXT "none"
  status DURATION_MS "$duration_ms"
  printf 'DIRECTION: %s\n' "$direction"
  printf 'SOURCE: %s\n' "$source_path"
  printf 'TARGET: %s\n' "$target_path"
  if [[ "$reuse_connection" == "true" ]]; then
    printf 'CONTROL_PATH: %s\n' "$control_path"
    printf 'CONTROL_PERSIST: %ss\n' "$control_persist"
  fi
  if [[ "$key_permission_warning" == "true" ]]; then
    printf 'WARNING: key_permissions_wide\n'
    printf 'NEXT_KEY_PERMISSIONS: inspect and restrict permissions for %s\n' "$identity_file"
  fi
  if [[ -n "$stdout_text" ]]; then
    printf 'OUTPUT:\n%s\n' "$stdout_text"
  fi
  if [[ -n "$stderr_text" ]]; then
    printf 'STDERR:\n%s\n' "$stderr_text"
  fi
  exit 0
fi

if [[ "$exit_code" -eq 7 ]]; then
  exit 7
fi

if grep -Eiq 'permission denied|authentication failed' <<<"$stderr_text"; then
  status STATUS auth_failed
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "ssh authentication failed"
  status NEXT "check auth mode, identity, agent, or password environment"
elif [[ "$control_master_failed" == "true" ]]; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "failed to establish SSH control master"
  status NEXT "inspect STDERR and reuse-connection support"
elif grep -Eiq 'could not resolve hostname|connection timed out|no route to host|connection refused|name or service not known' <<<"$stderr_text"; then
  status STATUS connect_failed
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "ssh connection failed"
  status NEXT "check host, port, network reachability, and SSH service availability"
else
  status STATUS transfer_failed
  status HOST "$target"
  status ACTION remote_copy
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "file transfer returned a non-zero status"
  status NEXT "inspect STDERR and source or target paths"
fi

status DURATION_MS "$duration_ms"
printf 'DIRECTION: %s\n' "$direction"
printf 'SOURCE: %s\n' "$source_path"
printf 'TARGET: %s\n' "$target_path"
if [[ "$reuse_connection" == "true" ]]; then
  printf 'CONTROL_PATH: %s\n' "$control_path"
  printf 'CONTROL_PERSIST: %ss\n' "$control_persist"
fi
if [[ "$key_permission_warning" == "true" ]]; then
  printf 'WARNING: key_permissions_wide\n'
  printf 'NEXT_KEY_PERMISSIONS: inspect and restrict permissions for %s\n' "$identity_file"
fi
if [[ -n "$stdout_text" ]]; then
  printf 'OUTPUT:\n%s\n' "$stdout_text"
fi
if [[ -n "$stderr_text" ]]; then
  printf 'STDERR:\n%s\n' "$stderr_text"
fi
exit "$exit_code"
