#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-tools.sh"

status() {
  printf '%s: %s\n' "$1" "$2"
}

usage() {
  cat <<'EOF'
remote-exec.sh

Required:
  --host VALUE
  --command VALUE | --command-file VALUE

Optional:
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --known-hosts-file VALUE
  --command-file VALUE
  --remote-dir VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
EOF
}

host=""
command_text=""
command_file=""
user_name=""
port=""
auth_mode="ssh-alias"
identity_file=""
known_hosts_file=""
remote_dir=""
risk="auto"
confirmation_state="none"
password_env="SSH_PASSWORD"
timeout="15"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      host="${2:-}"
      shift 2
      ;;
    --command)
      command_text="${2:-}"
      shift 2
      ;;
    --command-file)
      command_file="${2:-}"
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
    --remote-dir)
      remote_dir="${2:-}"
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      status STATUS invalid_arguments
      status ACTION remote_exec
      status REASON "unknown argument: $1"
      status NEXT "run with --help"
      exit 2
      ;;
  esac
done

if [[ -n "$command_text" && -n "$command_file" ]]; then
  status STATUS invalid_arguments
  status ACTION remote_exec
  status REASON "provide either --command or --command-file, not both"
  status NEXT "choose one command input mode and rerun"
  exit 2
fi

if [[ -n "$command_file" ]]; then
  if [[ ! -f "$command_file" ]]; then
    status STATUS missing_command_file
    status ACTION remote_exec
    status REASON "command file was not found"
    status NEXT "provide a valid --command-file"
    printf 'COMMAND_FILE: %s\n' "$command_file"
    exit 4
  fi
  command_text="$(<"$command_file")"
fi

if [[ -z "$host" || -z "$command_text" ]]; then
  usage
  exit 2
fi

target="$host"
if [[ "$host" != *@* && -n "$user_name" ]]; then
  target="${user_name}@${host}"
fi

is_high_risk() {
  local value="$1"
  if grep -Eiq '(^|[[:space:];|&])(rm|chmod|chown|chgrp|kill|pkill)([[:space:]]|$)' <<<"$value"; then
    return 0
  fi
  if grep -Eiq 'systemctl[[:space:]]+(restart|stop)|service[[:space:]].*[[:space:]]restart|git[[:space:]]+push|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-fd|sudo[[:space:]]|dd[[:space:]]|mkfs|fdisk|parted|iptables|nft|crontab[[:space:]]+-r' <<<"$value"; then
    return 0
  fi
  if [[ "$value" == *"curl"* && "$value" == *"| bash"* ]]; then
    return 0
  fi
  if [[ "$value" == *"wget"* && "$value" == *"| bash"* ]]; then
    return 0
  fi
  if grep -Eiq '(^|[^>])>>?[[:space:]]*(/etc|/usr|/bin|/sbin|/opt|/var/www)' <<<"$value"; then
    return 0
  fi
  if grep -Eiq '(^|[[:space:];|&])(bash|sh|python|python3)[[:space:]]+[^[:space:]]+' <<<"$value"; then
    return 0
  fi
  return 1
}

if [[ "$risk" == "auto" ]]; then
  if is_high_risk "$command_text"; then
    risk="high"
  else
    risk="low"
  fi
fi

if [[ "$risk" == "high" && "$confirmation_state" != "confirmed" ]]; then
  status STATUS pending_confirmation
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK high
  status REASON "command is classified as high risk"
  status NEXT "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
  printf 'COMMAND: %s\n' "$command_text"
  exit 3
fi

load_ssh_toolchain || true
if [[ "$ssh_toolchain_backend" == "none" ]]; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "no supported SSH backend was found"
  status NEXT "install OpenSSH or PuTTY tools and ensure they are discoverable"
  exit 4
fi

case "$auth_mode" in
  ssh-alias)
    ;;
  identity-file)
    if [[ -z "$identity_file" || ! -f "$identity_file" ]]; then
      status STATUS missing_key
      status HOST "$target"
      status ACTION remote_exec
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
      status ACTION remote_exec
      status AUTH_MODE "$auth_mode"
      status RISK "$risk"
      status REASON "no default private key was found"
      status NEXT "generate a key or choose a different auth mode"
      exit 5
    fi
    if (( ${#candidates[@]} > 1 )); then
      status STATUS key_ambiguous
      status HOST "$target"
      status ACTION remote_exec
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
      status ACTION remote_exec
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
      status ACTION remote_exec
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
      status ACTION remote_exec
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
    status ACTION remote_exec
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
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "known_hosts file was not found"
  status NEXT "provide a valid --known-hosts-file or accept the host key once outside the sandbox"
  printf 'KNOWN_HOSTS_FILE: %s\n' "$known_hosts_file"
  exit 5
fi

escaped_dir="${remote_dir//\'/\'\\\'\'}"
remote_command="$command_text"
if [[ -n "$remote_dir" ]]; then
  remote_command="cd '$escaped_dir' && $command_text"
fi

ssh_args=()
ssh_program=""
if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
  ssh_program="$ssh_tool"
  ssh_args+=(-o "ConnectTimeout=$timeout")
else
  ssh_program="$plink_tool"
  ssh_args+=(-batch)
fi
if [[ -n "$port" ]]; then
  if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
    ssh_args+=(-p "$port")
  else
    ssh_args+=(-P "$port")
  fi
fi
if [[ -n "$identity_file" ]]; then
  ssh_args+=(-i "$identity_file")
  if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
    ssh_args+=(-o "IdentitiesOnly=yes")
  fi
fi
if [[ -n "$known_hosts_file" && "$ssh_toolchain_backend" == "openssh" ]]; then
  ssh_args+=(-o "UserKnownHostsFile=$known_hosts_file")
fi
if [[ "$auth_mode" == "password" ]]; then
  if [[ "$ssh_toolchain_backend" != "openssh" ]]; then
    status STATUS auth_mode_unsupported
    status HOST "$target"
    status ACTION remote_exec
    status AUTH_MODE "$auth_mode"
    status RISK "$risk"
    status REASON "password automation is only implemented for OpenSSH"
    status NEXT "use OpenSSH or a key-based auth mode"
    exit 8
  fi
  ssh_args+=(-o "PreferredAuthentications=password" -o "PubkeyAuthentication=no")
else
  if [[ "$ssh_toolchain_backend" == "openssh" ]]; then
    ssh_args+=(-o "BatchMode=yes")
  fi
fi

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
askpass_file=""
cleanup() {
  rm -f "$stdout_file" "$stderr_file"
  [[ -n "$askpass_file" ]] && rm -f "$askpass_file"
}
trap cleanup EXIT

run_ssh() {
  if [[ "$auth_mode" == "password" ]]; then
    password_value="${!password_env-}"
    if [[ -z "$password_value" ]]; then
      status STATUS interactive_password_required
      status HOST "$target"
      status ACTION remote_exec
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
    env \
      SSH_LINUX_ASKPASS_SECRET="$password_value" \
      SSH_ASKPASS="$askpass_file" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY="${DISPLAY:-codex-ssh-linux}" \
      "$ssh_program" "${ssh_args[@]}" "$target" "$remote_command" >"$stdout_file" 2>"$stderr_file"
  else
    "$ssh_program" "${ssh_args[@]}" "$target" "$remote_command" >"$stdout_file" 2>"$stderr_file"
  fi
}

set +e
run_ssh
exit_code=$?
set -e

stderr_text="$(cat "$stderr_file" 2>/dev/null || true)"
stdout_text="$(cat "$stdout_file" 2>/dev/null || true)"

if [[ "$exit_code" -eq 0 ]]; then
  status STATUS ok
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "remote command executed successfully"
  status NEXT "none"
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
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "ssh authentication failed"
  status NEXT "check auth mode, identity, agent, or password environment"
elif grep -Eiq 'could not resolve hostname|connection timed out|no route to host|connection refused|name or service not known' <<<"$stderr_text"; then
  status STATUS connect_failed
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "ssh connection failed"
  status NEXT "check host, port, network reachability, and SSH service availability"
else
  status STATUS command_failed
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "remote command returned a non-zero status"
  status NEXT "inspect STDERR and remote state"
fi

if [[ -n "$stdout_text" ]]; then
  printf 'OUTPUT:\n%s\n' "$stdout_text"
fi
if [[ -n "$stderr_text" ]]; then
  printf 'STDERR:\n%s\n' "$stderr_text"
fi
exit "$exit_code"
