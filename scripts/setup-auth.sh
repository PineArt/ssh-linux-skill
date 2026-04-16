#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-tools.sh"

status() {
  printf '%s: %s\n' "$1" "$2"
}

usage() {
  cat <<'EOF'
setup-auth.sh

Required:
  --action discover|agent|generate|show-public

Optional:
  --key-path VALUE
  --key-type ed25519|ecdsa|rsa
  --comment VALUE
  --confirmation-state pending|confirmed

Examples:
  setup-auth.sh --action discover
  setup-auth.sh --action agent
  setup-auth.sh --action generate --confirmation-state confirmed
  setup-auth.sh --action show-public --key-path ~/.ssh/id_ed25519
EOF
}

action=""
key_path=""
key_type="ed25519"
comment="${USER:-ssh-linux}@$(hostname 2>/dev/null || printf 'local')"
confirmation_state="pending"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)
      action="${2:-}"
      shift 2
      ;;
    --key-path)
      key_path="${2:-}"
      shift 2
      ;;
    --key-type)
      key_type="${2:-}"
      shift 2
      ;;
    --comment)
      comment="${2:-}"
      shift 2
      ;;
    --confirmation-state)
      confirmation_state="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      status STATUS invalid_arguments
      status ACTION auth_setup
      status REASON "unknown argument: $1"
      status NEXT "run with --help"
      exit 2
      ;;
  esac
done

if [[ -z "$action" ]]; then
  usage
  exit 2
fi

discover_keys() {
  local keys=()
  local candidate
  for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
    [[ -f "$candidate" ]] && keys+=("$candidate")
  done

  if (( ${#keys[@]} == 0 )); then
    status STATUS no_keys_found
    status ACTION auth_setup
    status REASON "no default private keys found"
    status NEXT "generate a key or provide an explicit identity file"
    return 0
  fi

  status STATUS ok
  status ACTION auth_setup
  status REASON "discovered default private keys"
  status NEXT "choose a key or continue with default-key-discovery"
  printf 'FOUND_KEYS:\n'
  printf '%s\n' "${keys[@]}"
}

agent_keys() {
  load_ssh_toolchain || true
  if [[ "$ssh_toolchain_backend" != "openssh" || -z "$ssh_add_tool" ]]; then
    status STATUS auth_tool_unavailable
    status ACTION auth_setup
    status REASON "ssh-add is not available from a detected OpenSSH toolchain"
    status NEXT "use explicit key files instead"
    return 4
  fi

  local output
  output="$("$ssh_add_tool" -l 2>&1 || true)"
  if [[ "$output" == *"The agent has no identities."* ]]; then
    status STATUS no_agent_keys
    status ACTION auth_setup
    status REASON "ssh-agent is running but has no identities"
    status NEXT "add a key or use a file-based auth mode"
    return 0
  fi

  status STATUS ok
  status ACTION auth_setup
  status REASON "listed ssh-agent identities"
  status NEXT "choose one identity if more than one is available"
  printf 'AGENT_IDENTITIES:\n%s\n' "$output"
}

generate_key() {
  load_ssh_toolchain || true
  if [[ "$ssh_toolchain_backend" != "openssh" || -z "$ssh_keygen_tool" ]]; then
    status STATUS auth_tool_unavailable
    status ACTION auth_setup
    status REASON "ssh-keygen is not available from a detected OpenSSH toolchain"
    status NEXT "install OpenSSH or Git for Windows OpenSSH tools"
    return 4
  fi

  local resolved_key_path="${key_path:-$HOME/.ssh/id_ed25519}"
  mkdir -p "$(dirname "$resolved_key_path")"

  if [[ -e "$resolved_key_path" && "$confirmation_state" != "confirmed" ]]; then
    status STATUS pending_confirmation
    status ACTION auth_setup
    status REASON "key path already exists and generation would overwrite or replace an existing key"
    status NEXT "rerun with --confirmation-state confirmed if this is intended"
    printf 'KEY_PATH: %s\n' "$resolved_key_path"
    return 3
  fi

  if [[ "$confirmation_state" != "confirmed" ]]; then
    status STATUS pending_confirmation
    status ACTION auth_setup
    status REASON "generating a new SSH keypair changes local auth state"
    status NEXT "rerun with --confirmation-state confirmed"
    printf 'KEY_PATH: %s\n' "$resolved_key_path"
    return 3
  fi

  "$ssh_keygen_tool" -t "$key_type" -f "$resolved_key_path" -N "" -C "$comment" >/dev/null
  status STATUS ok
  status ACTION auth_setup
  status REASON "generated new SSH keypair"
  status NEXT "install the public key on the remote host or print it with --action show-public"
  printf 'KEY_PATH: %s\n' "$resolved_key_path"
  printf 'PUBLIC_KEY_PATH: %s.pub\n' "$resolved_key_path"
}

show_public() {
  local resolved_key_path="${key_path:-$HOME/.ssh/id_ed25519}"
  local public_path="${resolved_key_path}.pub"

  if [[ ! -f "$public_path" ]]; then
    status STATUS missing_key
    status ACTION auth_setup
    status REASON "public key file not found"
    status NEXT "generate a new key or provide a valid --key-path"
    printf 'PUBLIC_KEY_PATH: %s\n' "$public_path"
    return 5
  fi

  status STATUS ok
  status ACTION auth_setup
  status REASON "printed public key"
  status NEXT "install the key on the remote host"
  printf 'PUBLIC_KEY_PATH: %s\n' "$public_path"
  printf 'PUBLIC_KEY:\n'
  cat "$public_path"
}

case "$action" in
  discover)
    discover_keys
    ;;
  agent)
    agent_keys
    ;;
  generate)
    generate_key
    ;;
  show-public)
    show_public
    ;;
  *)
    status STATUS invalid_arguments
    status ACTION auth_setup
    status REASON "unsupported action: $action"
    status NEXT "run with --help"
    exit 2
    ;;
esac
