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
- shell wrappers such as `bash script.sh` or `python script.py`,
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

The confirmation is bound to that exact target, action, command or transfer paths, and risk reason. A confirmation for one host, command, path, or risk does not apply to a later or different operation.

For `--command-file`, show the command-file contents or a precise reviewed excerpt plus the file path before asking for confirmation. Showing only the file name is not enough. For `--command-stdin`, show the exact piped script text or a precise reviewed excerpt plus the producer path or here-string source when there is one. The execution helper removes Windows CRLF/CR carriage returns and a leading UTF-8 BOM before streaming command-file or command-stdin text to remote `sh -s`, so review the command semantics rather than treating local file encoding artifacts as meaningful shell syntax.

When a command-file references external payload files by path, argument, environment variable, pipe, or redirection, review the payload separately if it drives a risk-relevant action. Risk-relevant payload use includes executing the payload, writing it outside a disposable workspace, loading it into a state-mutating tool, or using it to control a privileged operation.

The confirmation must include the payload local path and remote path when applicable, size, content summary or hash, and whether the payload is encoding-sensitive or contains non-ASCII data. Showing only the shell control text is not sufficient when the payload itself carries the risk.

## Command-File Payload Policy

Treat `--command-file` and `--command-stdin` as shell control text. The helpers warn on likely payload misuse and force high-risk confirmation before SSH execution when the command-file or command-stdin text contains any of these patterns:

- a heredoc body over 20 non-empty lines or 2048 UTF-8 bytes,
- inline database heredoc or stdin payload for `mysql`, `mariadb`, `psql`, `sqlite3`, or `sqlcmd` when it is multiline, contains DDL/DML or psql meta-commands, writes through `INTO OUTFILE` or `INTO DUMPFILE`, or has any non-ASCII content,
- inline interpreted stdin or heredoc for `python`, `python3`, `node`, `ruby`, `perl`, `php`, `Rscript`, `lua`, `sh`, or `bash` when it has any non-ASCII content, or when it is over 5 non-empty lines or 512 UTF-8 bytes,
- non-ASCII content on more than one non-empty line, or more than 64 UTF-8 bytes of non-ASCII content in the command file.

Short inline UTF-8 tokens such as filenames or search patterns are allowed when the environment supports them. Payload policy warnings use `WARNING: command_file_*` plus `NEXT_COMMAND_FILE_PAYLOAD`; a triggered confirmation requirement upgrades the run to high risk even if `--risk low` was supplied.

## PowerShell Quoting Boundary

In PowerShell, `remote-exec.ps1 --command` should stay a short one-line command. Do not put multiline scripts, heredocs, nested Python or SQL snippets, or commands that require multiple layers of quote escaping into `--command`. Use `--command-file` or pipe one complete UTF-8 script string with `Get-Content -Raw script.sh | .\scripts\remote-exec.ps1 --command-stdin ...`. This avoids PowerShell parsing the remote shell text before the SSH helper sees it. If script text contains non-ASCII characters, keep the source file UTF-8 and avoid embedding it in ad hoc `powershell -Command` or `.ps1` snippets whose own source encoding is ambiguous.

The PowerShell helper writes SSH stdin as UTF-8 without BOM. If a command file or command-stdin text starts with a UTF-8 BOM, the helper strips it and emits `WARNING: command_file_bom_normalized`; otherwise remote `sh` can interpret the first command as a hidden-BOM token such as `cd`.

For production uploads, prefer a two-step flow: upload to a disposable path such as `/tmp/ssh-linux-<timestamp>/...`, verify it, then run a separately confirmed remote move, install, restart, or reload command.
