---
name: ssh-linux
description: SSH Linux remote operations for running commands, uploading and downloading files, selecting authentication, and requiring explicit human confirmation before high-risk actions. Use when connecting to a user-specified Linux host over SSH from Git Bash or PowerShell, including SSH key setup, SCP-style transfers, and remote inspection.
license: MIT
allowed-tools:
  - Bash
metadata:
  version: 0.1.0
  author: PineArt
  short-description: SSH remote operations for Linux hosts
  user-invocable: true
  argument-hint: user@host-or-alias exec-or-transfer args
  tags:
    - ssh
    - linux
    - remote
    - scp
---

# SSH Linux

Use this skill for SSH-based Linux work that needs a repeatable, safety-aware workflow.

This skill covers:

- remote command execution,
- file upload,
- file download,
- SSH key setup and selection,
- SSH auth troubleshooting,
- remote inspection on Linux hosts.

Prefer this skill when the user asks to:

- connect to a Linux server over SSH,
- run remote commands such as `ls`, `find`, `grep`, `git`, `rg`, `fd`, or `bat`,
- upload or download files with `scp`,
- choose or generate SSH keys,
- debug SSH auth or connectivity problems.

## Operating Rules

1. Determine the requested operation first: `exec`, `upload`, `download`, or `auth-setup`.
2. Require the target host or SSH alias before executing anything.
3. Prefer existing SSH aliases and explicit identity files over guessing keys.
4. Use the auth order from [references/auth-model.md](references/auth-model.md).
5. Apply the risk policy from [references/risk-rules.md](references/risk-rules.md) before invoking any script.
6. Use the Bash or PowerShell script that matches the local environment, but keep the same conceptual arguments and status labels.
7. Use [references/tool-fallbacks.md](references/tool-fallbacks.md) when the remote host lacks preferred tools.
8. Never store secrets in the repository or echo passwords into shell history.
9. Keep `remote-exec --command` for short one-line commands only. For complex remote commands with newlines, heredocs, shell wrappers, Python/SQL snippets, nested quotes, or mixed `$`, `"`, `'`, `;`, `|`, `<`, and `>` characters, use `remote-exec --command-file` or pipe one script value into `remote-exec --command-stdin` so the local shell does not re-parse the command text. Command-file and command-stdin execution stream normalized POSIX shell text to remote `sh -s`; Windows CRLF/CR carriage returns and a leading UTF-8 BOM are stripped before transport.
10. Treat `--command`, `--command-file`, and `--command-stdin` as shell control text channels, not general application payload channels. Short inline UTF-8 tokens such as filenames or search patterns can stay in command text when the environment supports them. For non-trivial business payloads such as SQL, JSON, YAML, Markdown, prompts, CSV, config fragments, or other data with locale-specific or non-ASCII content, prefer `remote-copy` to upload a UTF-8 file, verify the uploaded path, then reference that path from the command. Payload producers and receivers must specify encoding explicitly, defaulting to UTF-8 and avoiding platform defaults. Use a base64 envelope only when file transfer is not practical, and decode it explicitly at the receiver.
11. In sandboxed runtimes, CI, or environments where `$HOME` may not be the real user profile, pass an explicit `--known-hosts-file` instead of relying on automatic discovery.
12. Treat `--timeout` as an SSH connection timeout only. Use `remote-exec --exec-timeout` when a non-interactive remote command needs a runtime limit.
13. `--reuse-connection` is an opt-in latency knob for OpenSSH only. It prepares a ControlMaster before the requested command or transfer, then runs the requested operation through that master while preserving the wrapper's per-command stdout, stderr, exit code, and risk workflow. Use `--control-persist` only with a positive integer number of seconds. Control sockets are disposable, short, and partitioned by target, port, identity file, known-hosts file, and auth mode.

## Responsibility Split

The agent layer owns:

- intent parsing,
- risk classification,
- high-risk confirmation,
- auth-mode selection when multiple choices are possible.

The scripts own:

- connection preflight,
- argument normalization,
- command or transfer execution,
- plain-text status output,
- conservative path checks.

Scripts must not silently bypass a required confirmation decision that was already classified by the agent.

## Script Entry Points

Use these files:

- `scripts/remote-exec.sh`
- `scripts/remote-exec.ps1`
- `scripts/remote-copy.sh`
- `scripts/remote-copy.ps1`
- `scripts/setup-auth.sh`
- `scripts/setup-auth.ps1`

All entry points align on these conceptual fields:

- host or alias
- optional user
- optional port
- auth mode
- optional identity file
- optional known-hosts file
- optional remote working directory
- command or transfer source and target
- optional password environment variable name
- confirmation state

Expected plain-text status labels:

- `STATUS`
- `HOST`
- `ACTION`
- `AUTH_MODE`
- `RISK`
- `REASON`
- `NEXT`

Additional labels may appear when relevant:

- `DURATION_MS`
- `COMMAND_FILE_SIZE`
- `COMMAND_STDIN_SIZE`
- `WARNING`
- `NEXT_COMMAND_FILE`
- `NEXT_COMMAND_FILE_BOM`
- `NEXT_COMMAND_FILE_PAYLOAD`

## Safety Policy

Always stop for explicit human confirmation before:

- destructive or state-mutating remote commands,
- uploads to sensitive paths,
- downloads of likely secret-bearing files,
- overwriting existing remote files outside a clearly disposable workspace,
- generating a new SSH keypair if the user did not ask for it directly.

When confirmation is required, show:

- the target host or alias,
- the action type,
- the exact command or transfer,
- the affected local and remote paths,
- the reason the action is classified as high risk.

The confirmation applies only to the exact target, action, command or transfer paths, and risk reason shown to the user. Do not reuse a previous confirmation for a different host, command, path, or risk.

## Standard Runbook

For multi-step remote work:

1. Record the session parameters: host, user, port, auth mode, identity file, known-hosts file, remote directory, and whether mutation is allowed.
2. Start with a read-only probe such as `hostname; id; pwd; uname -a`.
3. Probe remote tool availability before assuming `rg`, `fd`, `bat`, `python3`, `bash`, `sh`, or `systemctl` exists.
4. Keep investigation commands read-only until a state-changing action is explicitly required.
5. Put complex commands in a local command file and run them with `remote-exec --command-file`, or pipe a single script value into `remote-exec --command-stdin`. On PowerShell, prefer `Get-Content -Raw script.sh | .\scripts\remote-exec.ps1 --command-stdin ...` or a here-string pipeline. Keep non-ASCII script sources in UTF-8 and avoid embedding them directly in ad hoc `powershell -Command` or `.ps1` snippets whose source encoding is ambiguous. Do not pass multiline scripts, heredocs, or nested quoting through `--command`.
6. Keep payload data out of command files when it is non-trivial, encoding-sensitive, or reused by an application. Upload the payload with `remote-copy`, verify the remote path, size, and when useful a hash, and have the remote command pass the file path to the application. Create, read, and decode payload content with explicit encoding at every producer and receiver boundary. For example, a Python receiver should read the file with `encoding="utf-8"` instead of relying on the platform default.
7. For production uploads, copy to a disposable path such as `/tmp/ssh-linux-<timestamp>/...` first, verify what was uploaded, then run a separately confirmed install or move command.
8. Summarize what changed, what failed, and whether temporary remote files remain.

Command files and command-stdin input authored on Windows may use CRLF or carry a leading UTF-8 BOM. The helper normalizes both before streaming the script text to remote `sh -s` and emits `WARNING: command_file_cr_normalized` or `WARNING: command_file_bom_normalized` when it changed the shell text. PowerShell helpers write SSH stdin as UTF-8 without BOM so the remote shell does not receive a hidden BOM before the first command. This normalization is not a general payload transport feature; data payloads should be transferred and decoded as data.

## Auth Policy

Use this order unless the user overrides it:

1. SSH alias
2. explicit identity file
3. default key discovery
4. `ssh-agent`
5. safe password handling
6. new key generation

Read the detailed rules in [references/auth-model.md](references/auth-model.md).

## Known Limitations

- `--timeout` maps to SSH connection timeout; remote command execution can run indefinitely unless `remote-exec --exec-timeout` is supplied.
- `--reuse-connection` depends on OpenSSH ControlMaster/ControlPersist and is refused on PuTTY paths. A master process can remain alive until `--control-persist` expires; use the emitted `CONTROL_PATH` for manual inspection or teardown if needed.
- File transfer uses `scp` or `pscp`. This skill does not automatically fall back to SFTP.
- Password automation is best-effort through `SSH_ASKPASS` and a named environment variable.
- On Windows, Git-for-Windows SSH can behave differently from system OpenSSH. Prefer the PowerShell entry points and system OpenSSH when available.
- The script risk classifier is a conservative helper, not a security boundary. The agent layer remains responsible for semantic risk classification.

## References

- [references/auth-model.md](references/auth-model.md): auth order, key selection, password rules, and missing-key behavior
- [references/risk-rules.md](references/risk-rules.md): high-risk command and transfer rules plus confirmation contract
- [references/tool-fallbacks.md](references/tool-fallbacks.md): remote tool detection and fallback commands
