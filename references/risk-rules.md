# Risk Rules

## Rule Ownership

The agent layer owns final risk classification and confirmation gating. Scripts may add conservative safety checks, but they do not get to downgrade a high-risk action to safe.

## Always Require Confirmation

Require explicit human confirmation before:

- `rm`, forced overwrite, recursive delete, or truncating redirects,
- `chmod`, `chown`, `chgrp`,
- `kill`, `pkill`, `systemctl restart`, `systemctl stop`, `service restart`,
- package and system mutation such as `apt install`, `yum install`, `dnf install`, removals, or upgrade flows,
- `git push`, `git reset --hard`, `git clean -fd`, force checkout or rebase flows,
- `sudo` commands that mutate state,
- `curl | bash`, `wget | bash`, remote script execution, and heredoc-driven shell execution,
- `dd`, `mkfs`, `fdisk`, `parted`, `iptables`, `nft`, `crontab -r`,
- uploads to sensitive paths,
- downloads of likely secret-bearing files,
- uploads that may overwrite existing non-disposable remote files.

## Command-String Scope

Scan the full requested command string, not only the first token. Include:

- pipelines,
- `&&`, `||`, and `;`,
- heredocs,
- shell wrappers such as `bash script.sh` or `python script.py`.
- full command-file contents when the command is supplied indirectly from a local file.

Document variable-expansion evasion as a residual risk. If a command hides dangerous behavior behind variables or opaque scripts, classify it conservatively.

## Sensitive Path Heuristics

Treat these as sensitive by default:

- `/etc`
- `/usr`
- `/bin`
- `/sbin`
- `/opt`
- `/var/www`
- shell startup files such as `.bashrc`, `.profile`, `.zshrc`
- private keys, credential files, `.env`, production configs, token files, dumps, and likely secret-bearing logs

## Read-Only Allowlist

These are usually safe unless combined with mutating shell constructs:

- `ls`
- `pwd`
- `cat`
- `find`
- `grep`
- `git status`
- `git log`
- `git diff`
- `systemctl status`
- `apt list`

## Confirmation Contract

When confirmation is required, show:

- target host or alias,
- action type,
- exact command or transfer,
- local path and remote path when applicable,
- auth mode when relevant,
- risk reason,
- next step waiting for user confirmation.
