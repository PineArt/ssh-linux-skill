#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-tools.sh"

status() {
  printf '%s: %s\n' "$1" "$2"
}

command_file_large_heredoc_line_threshold=20
command_file_large_heredoc_byte_threshold=2048
command_file_python_stdin_line_threshold=5
command_file_python_stdin_byte_threshold=512
command_file_non_ascii_byte_threshold=64
command_file_payload_warning_labels=()
command_file_payload_warning_details=()
command_file_payload_warning_requires_confirmation=()

usage() {
  cat <<'EOF'
remote-exec.sh

SUMMARY
  Execute a command on a Linux host over SSH with auth and risk checks.

USAGE
  remote-exec.sh --host VALUE --command VALUE [options]
  remote-exec.sh --host VALUE --command-file VALUE [options]
  remote-exec.sh --help
  remote-exec.sh --help-json

ARGUMENTS
  --host VALUE
  --command VALUE | --command-file VALUE
  --user VALUE
  --port VALUE
  --auth-mode ssh-alias|identity-file|default-key-discovery|ssh-agent|password
  --identity-file VALUE
  --known-hosts-file VALUE
  --remote-dir VALUE
  --risk auto|low|high
  --confirmation-state pending|confirmed|none
  --password-env VALUE
  --timeout VALUE
  --exec-timeout VALUE
  --help | -h
  --help-json

OUTPUT CONTRACT
  Plain-text labels: STATUS, HOST, ACTION, AUTH_MODE, RISK, REASON, NEXT
  Additional labels: DURATION_MS, COMMAND_FILE_SIZE, WARNING, NEXT_COMMAND_FILE, NEXT_COMMAND_FILE_BOM, NEXT_COMMAND_FILE_PAYLOAD
  Optional blocks: OUTPUT, STDERR

EXAMPLES
  remote-exec.sh --host app-prod --command "uname -a"
  remote-exec.sh --host 10.0.0.8 --user deploy --command-file ./ops/healthcheck.sh
  remote-exec.sh --host app-prod --command "systemctl restart nginx" --confirmation-state confirmed

NOTES
  --command-file normalizes Windows CRLF line endings and a leading UTF-8 BOM before streaming to remote sh -s.
EOF
}

help_json() {
  cat <<'EOF'
{"name":"remote-exec.sh","summary":"Execute a command on a Linux host over SSH with auth and risk checks.","usage":["remote-exec.sh --host VALUE --command VALUE [options]","remote-exec.sh --host VALUE --command-file VALUE [options]","remote-exec.sh --help","remote-exec.sh --help-json"],"arguments":[{"name":"--host","required":true,"value":"VALUE","description":"SSH host, alias, or user@host target."},{"name":"--command","required":false,"value":"VALUE","description":"Inline command text to execute remotely."},{"name":"--command-file","required":false,"value":"VALUE","description":"Path to a local file containing remote shell script text streamed over stdin after CRLF/CR carriage returns and a leading UTF-8 BOM are removed."},{"name":"--user","required":false,"value":"VALUE","description":"Username, used when host is not in user@host form."},{"name":"--port","required":false,"value":"VALUE","description":"SSH port."},{"name":"--auth-mode","required":false,"value":"ssh-alias|identity-file|default-key-discovery|ssh-agent|password","description":"Authentication strategy."},{"name":"--identity-file","required":false,"value":"VALUE","description":"Private key path for identity-file mode."},{"name":"--known-hosts-file","required":false,"value":"VALUE","description":"known_hosts path for host key verification."},{"name":"--remote-dir","required":false,"value":"VALUE","description":"Remote working directory before command execution."},{"name":"--risk","required":false,"value":"auto|low|high","description":"Risk override. auto classifies command content."},{"name":"--confirmation-state","required":false,"value":"pending|confirmed|none","description":"High-risk confirmation gate."},{"name":"--password-env","required":false,"value":"VALUE","description":"Environment variable name for password mode."},{"name":"--timeout","required":false,"value":"VALUE","description":"SSH connect timeout in seconds."},{"name":"--exec-timeout","required":false,"value":"VALUE","description":"Remote command execution timeout in seconds. 0 means no execution timeout."},{"name":"--help|-h","required":false,"value":"","description":"Show human-readable help."},{"name":"--help-json","required":false,"value":"","description":"Show machine-readable JSON help."}],"examples":["remote-exec.sh --host app-prod --command \"uname -a\"","remote-exec.sh --host 10.0.0.8 --user deploy --command-file ./ops/healthcheck.sh","remote-exec.sh --host app-prod --command \"systemctl restart nginx\" --confirmation-state confirmed"],"notes":["--command-file normalizes Windows CRLF line endings and a leading UTF-8 BOM before streaming to remote sh -s."],"output_contract":{"format":"plain-text status labels with optional OUTPUT/STDERR blocks","labels":["STATUS","HOST","ACTION","AUTH_MODE","RISK","REASON","NEXT"],"extra_labels":["DURATION_MS","COMMAND_FILE_SIZE","WARNING","NEXT_COMMAND_FILE","NEXT_COMMAND_FILE_BOM","NEXT_COMMAND_FILE_PAYLOAD"],"common_statuses":["ok","invalid_arguments","pending_confirmation","missing_command_file","auth_tool_unavailable","missing_key","key_ambiguous","missing_known_hosts","interactive_password_required","auth_mode_unsupported","auth_failed","connect_failed","exec_timeout","command_failed"]}}
EOF
}

command_file_has_carriage_returns() {
  command -v od >/dev/null 2>&1 &&
    LC_ALL=C od -An -t x1 "$command_file" | grep -wiq '0d'
}

command_file_has_utf8_bom() {
  command -v od >/dev/null 2>&1 &&
    [[ "$(LC_ALL=C od -An -N3 -t x1 "$command_file" | tr -d '[:space:]')" == "efbbbf" ]]
}

stream_command_file_normalized() {
  if command_file_has_utf8_bom; then
    if command -v tail >/dev/null 2>&1; then
      tail -c +4 "$command_file" | LC_ALL=C tr -d '\015'
      return
    fi
    if command -v dd >/dev/null 2>&1; then
      dd if="$command_file" bs=1 skip=3 2>/dev/null | LC_ALL=C tr -d '\015'
      return
    fi
  fi

  LC_ALL=C tr -d '\015' <"$command_file"
}

write_command_file_normalization_warning() {
  if [[ "$command_file_had_carriage_returns" == "true" ]]; then
    printf 'WARNING: command_file_cr_normalized\n'
    printf 'NEXT_COMMAND_FILE: carriage returns were removed before streaming --command-file content to remote sh -s\n'
  fi
}

write_command_file_bom_warning() {
  if [[ "$command_file_had_utf8_bom" == "true" ]]; then
    printf 'WARNING: command_file_bom_normalized\n'
    printf 'NEXT_COMMAND_FILE_BOM: leading UTF-8 BOM was removed before streaming --command-file content to remote sh -s\n'
  fi
}

add_command_file_payload_warning() {
  command_file_payload_warning_labels+=("$1")
  command_file_payload_warning_details+=("$2")
  command_file_payload_warning_requires_confirmation+=("$3")
}

write_command_file_payload_warnings() {
  local index
  for index in "${!command_file_payload_warning_labels[@]}"; do
    printf 'WARNING: %s\n' "${command_file_payload_warning_labels[$index]}"
    printf 'NEXT_COMMAND_FILE_PAYLOAD: %s\n' "${command_file_payload_warning_details[$index]}"
  done
}

command_file_payload_requires_confirmation() {
  local value
  for value in "${command_file_payload_warning_requires_confirmation[@]}"; do
    if [[ "$value" == "true" ]]; then
      return 0
    fi
  done
  return 1
}

non_empty_line_count() {
  awk 'NF { count++ } END { print count + 0 }'
}

non_ascii_line_count() {
  LC_ALL=C awk 'NF && /[^\000-\177]/ { count++ } END { print count + 0 }'
}

non_ascii_byte_count() {
  LC_ALL=C tr -cd '\200-\377' | wc -c | tr -d '[:space:]'
}

sql_body_requires_confirmation() {
  local body="$1"
  local non_empty_lines non_ascii_lines non_ascii_bytes
  non_empty_lines="$(printf '%s' "$body" | non_empty_line_count)"
  non_ascii_lines="$(printf '%s' "$body" | non_ascii_line_count)"
  non_ascii_bytes="$(printf '%s' "$body" | non_ascii_byte_count)"

  if grep -Eiq '^[[:space:]]*(insert|update|delete|drop|alter|create|truncate|grant|revoke|replace|merge)\b' <<<"$body"; then
    return 0
  fi
  if grep -Eiq '\binto[[:space:]]+(outfile|dumpfile)\b' <<<"$body"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*\\' <<<"$body"; then
    return 0
  fi
  if [[ "$non_empty_lines" -gt 1 || "$non_ascii_lines" -gt 1 || "$non_ascii_bytes" -gt "$command_file_non_ascii_byte_threshold" ]]; then
    return 0
  fi
  return 1
}

analyze_command_file_payload() {
  local text="$1"
  local non_ascii_lines non_ascii_bytes
  non_ascii_lines="$(printf '%s' "$text" | non_ascii_line_count)"
  non_ascii_bytes="$(printf '%s' "$text" | non_ascii_byte_count)"

  if [[ "$non_ascii_lines" -gt 1 || "$non_ascii_bytes" -gt "$command_file_non_ascii_byte_threshold" ]]; then
    add_command_file_payload_warning \
      command_file_non_ascii_payload \
      "non-ASCII content appears on ${non_ascii_lines} non-empty lines (${non_ascii_bytes} UTF-8 bytes); move non-trivial payload data to a UTF-8 file and pass its path" \
      true
  fi

  local in_heredoc=false
  local opener="" delimiter="" body=""
  local line body_line_count body_byte_count requires_confirmation
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_heredoc" == "true" ]]; then
      if [[ "${line#"${line%%[![:space:]]*}"}" == "$delimiter" ]]; then
        body_line_count="$(printf '%s' "$body" | non_empty_line_count)"
        body_byte_count="$(printf '%s' "$body" | wc -c | tr -d '[:space:]')"
        requires_confirmation=false

        if [[ "$opener" =~ (^|[[:space:]\;\|\&])(mysql|mariadb|psql|sqlite3)([[:space:]\<]|$) ]]; then
          if sql_body_requires_confirmation "$body"; then
            requires_confirmation=true
          fi
          add_command_file_payload_warning \
            command_file_inline_sql \
            "inline database heredoc uses delimiter ${delimiter}; upload SQL payloads as UTF-8 files for reviewable execution" \
            "$requires_confirmation"
        elif [[ "$opener" =~ (^|[[:space:]\;\|\&])(python|python3)([[:space:]\<]|$) ]]; then
          if [[ "$body_line_count" -gt "$command_file_python_stdin_line_threshold" || "$body_byte_count" -gt "$command_file_python_stdin_byte_threshold" ]]; then
            requires_confirmation=true
          fi
          add_command_file_payload_warning \
            command_file_inline_python \
            "inline Python stdin/heredoc has ${body_line_count} non-empty lines and ${body_byte_count} UTF-8 bytes; keep control scripts short and move payloads to explicit files" \
            "$requires_confirmation"
        elif [[ "$body_line_count" -gt "$command_file_large_heredoc_line_threshold" || "$body_byte_count" -gt "$command_file_large_heredoc_byte_threshold" ]]; then
          add_command_file_payload_warning \
            command_file_large_heredoc \
            "large heredoc uses delimiter ${delimiter} with ${body_line_count} non-empty lines and ${body_byte_count} UTF-8 bytes; review whether this is payload data that should be transferred separately" \
            true
        fi

        in_heredoc=false
        opener=""
        delimiter=""
        body=""
        continue
      fi
      if [[ -z "$body" ]]; then
        body="$line"
      else
        body+=$'\n'"$line"
      fi
      continue
    fi

    if [[ "$line" =~ \<\<-?[[:space:]]*\'([^\']+)\' ]]; then
      in_heredoc=true
      opener="$line"
      delimiter="${BASH_REMATCH[1]}"
      body=""
    elif [[ "$line" =~ \<\<-?[[:space:]]*\"([^\"]+)\" ]]; then
      in_heredoc=true
      opener="$line"
      delimiter="${BASH_REMATCH[1]}"
      body=""
    elif [[ "$line" =~ \<\<-?[[:space:]]*([^[:space:]\;\|\&]+) ]]; then
      in_heredoc=true
      opener="$line"
      delimiter="${BASH_REMATCH[1]}"
      body=""
    fi
  done <<<"$text"
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
exec_timeout="0"
command_file_had_carriage_returns="false"
command_file_had_utf8_bom="false"

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
    --exec-timeout)
      exec_timeout="${2:-}"
      shift 2
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
  if command_file_has_carriage_returns; then
    command_file_had_carriage_returns="true"
  fi
  if command_file_has_utf8_bom; then
    command_file_had_utf8_bom="true"
  fi
  command_text="$(stream_command_file_normalized)"
  analyze_command_file_payload "$command_text"
fi
command_file_size=""
if [[ -n "$command_file" ]]; then
  command_file_size="$(wc -c <"$command_file" | tr -d '[:space:]')"
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
  if grep -Eiq '(^|[[:space:];|&])(bash|sh)[[:space:]]+[^[:space:]]+' <<<"$value"; then
    return 0
  fi
  if grep -Eiq '(^|[[:space:];|&])(python|python3)[[:space:]]+(-m[[:space:]]+)?[^[:space:]<-][^[:space:]]*' <<<"$value"; then
    return 0
  fi
  return 1
}

if [[ "$risk" == "auto" ]]; then
  if command_file_payload_requires_confirmation; then
    risk="high"
  elif is_high_risk "$command_text"; then
    risk="high"
  else
    risk="low"
  fi
elif command_file_payload_requires_confirmation; then
  risk="high"
fi

if [[ "$risk" == "high" && "$confirmation_state" != "confirmed" ]]; then
  status STATUS pending_confirmation
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK high
  status REASON "command is classified as high risk"
  status NEXT "obtain explicit human confirmation and rerun with --confirmation-state confirmed"
  write_command_file_normalization_warning
  write_command_file_bom_warning
  write_command_file_payload_warnings
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

if [[ "$exec_timeout" != "0" && ! "$exec_timeout" =~ ^[0-9]+$ ]]; then
  status STATUS invalid_arguments
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "--exec-timeout must be 0 or a positive integer"
  status NEXT "provide a valid --exec-timeout value"
  exit 2
fi
if [[ "$exec_timeout" != "0" && "$exec_timeout" -gt 0 ]] && ! command -v timeout >/dev/null 2>&1; then
  status STATUS auth_tool_unavailable
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "--exec-timeout requires the timeout command"
  status NEXT "install coreutils timeout or rerun without --exec-timeout"
  exit 4
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

escaped_dir="${remote_dir//\'/\'\\\'\'}"
remote_command="$command_text"
if [[ -n "$remote_dir" ]]; then
  remote_command="cd '$escaped_dir' && $command_text"
fi
is_command_file_mode="false"
if [[ -n "$command_file" ]]; then
  is_command_file_mode="true"
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
  local remote_program=("$ssh_program" "${ssh_args[@]}")
  local remote_script_prefix=""
  local timeout_prefix=()

  if [[ "$exec_timeout" != "0" && "$exec_timeout" -gt 0 ]]; then
    timeout_prefix=(timeout "${exec_timeout}s")
  fi

  if [[ -n "$remote_dir" ]]; then
    remote_script_prefix=$(printf "cd '%s' || exit \$?\n" "$escaped_dir")
  fi

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
    if [[ "$is_command_file_mode" == "true" ]]; then
      {
        if [[ -n "$remote_script_prefix" ]]; then
          printf '%s' "$remote_script_prefix"
        fi
        stream_command_file_normalized
      } | env \
        SSH_LINUX_ASKPASS_SECRET="$password_value" \
        SSH_ASKPASS="$askpass_file" \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY="${DISPLAY:-codex-ssh-linux}" \
        "${timeout_prefix[@]}" "${remote_program[@]}" "$target" "sh -s" >"$stdout_file" 2>"$stderr_file"
    else
      env \
        SSH_LINUX_ASKPASS_SECRET="$password_value" \
        SSH_ASKPASS="$askpass_file" \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY="${DISPLAY:-codex-ssh-linux}" \
        "${timeout_prefix[@]}" "${remote_program[@]}" "$target" "$remote_command" >"$stdout_file" 2>"$stderr_file"
    fi
  else
    if [[ "$is_command_file_mode" == "true" ]]; then
      {
        if [[ -n "$remote_script_prefix" ]]; then
          printf '%s' "$remote_script_prefix"
        fi
        stream_command_file_normalized
      } | "${timeout_prefix[@]}" "${remote_program[@]}" "$target" "sh -s" >"$stdout_file" 2>"$stderr_file"
    else
      "${timeout_prefix[@]}" "${remote_program[@]}" "$target" "$remote_command" >"$stdout_file" 2>"$stderr_file"
    fi
  fi
}

start_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
set +e
run_ssh
exit_code=$?
set -e
end_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
duration_ms=$((end_ms - start_ms))

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
  status DURATION_MS "$duration_ms"
  if [[ -n "$command_file_size" ]]; then
    printf 'COMMAND_FILE_SIZE: %s\n' "$command_file_size"
  fi
  if [[ "$key_permission_warning" == "true" ]]; then
    printf 'WARNING: key_permissions_wide\n'
    printf 'NEXT_KEY_PERMISSIONS: inspect and restrict permissions for %s\n' "$identity_file"
  fi
  write_command_file_normalization_warning
  write_command_file_bom_warning
  write_command_file_payload_warnings
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

if [[ "$exit_code" -eq 124 && "$exec_timeout" != "0" ]]; then
  status STATUS exec_timeout
  status HOST "$target"
  status ACTION remote_exec
  status AUTH_MODE "$auth_mode"
  status RISK "$risk"
  status REASON "remote command exceeded exec timeout of $exec_timeout seconds"
  status NEXT "rerun with a larger --exec-timeout or inspect the remote command for prompts or hangs"
elif grep -Eiq 'permission denied|authentication failed' <<<"$stderr_text"; then
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

status DURATION_MS "$duration_ms"
if [[ -n "$command_file_size" ]]; then
  printf 'COMMAND_FILE_SIZE: %s\n' "$command_file_size"
fi
if [[ "$key_permission_warning" == "true" ]]; then
  printf 'WARNING: key_permissions_wide\n'
  printf 'NEXT_KEY_PERMISSIONS: inspect and restrict permissions for %s\n' "$identity_file"
fi
write_command_file_normalization_warning
write_command_file_bom_warning
write_command_file_payload_warnings
if [[ -n "$stdout_text" ]]; then
  printf 'OUTPUT:\n%s\n' "$stdout_text"
fi
if [[ -n "$stderr_text" ]]; then
  printf 'STDERR:\n%s\n' "$stderr_text"
fi
exit "$exit_code"
