# Auth Model

## Preferred Order

Use this order unless the user explicitly overrides it:

1. `ssh-alias`
2. `identity-file`
3. `default-key-discovery`
4. `ssh-agent`
5. `password`
6. `generate-key`

## Auth Modes

### `ssh-alias`

Use when the user provides an alias from their SSH config. Do not override alias-bound identity settings unless the user asks.

### `identity-file`

Use when the user explicitly gives a private key path.

When the local runtime is sandboxed or home-directory remapping affects host key verification, pass an explicit known-hosts path with `--known-hosts-file`.

### `default-key-discovery`

Probe standard keys in a fixed order:

1. `~/.ssh/id_ed25519`
2. `~/.ssh/id_ecdsa`
3. `~/.ssh/id_rsa`

If exactly one usable key exists, use it. If more than one exists, stop and ask the user to choose.

### `ssh-agent`

Query the local agent after direct file-based options. If exactly one usable identity is available, use it. If multiple identities are available, show the choices and ask the user to choose.

### `password`

Password mode is allowed only when it is handled safely:

- do not accept a password as a positional CLI argument,
- prefer a named environment variable such as `SSH_PASSWORD` or a user-specified `--password-env`,
- optionally support a user-provided resolver hook later,
- never print the password in logs or status output.

In these scripts, password automation is best-effort via `SSH_ASKPASS` and a named environment variable. If password automation is unavailable, the scripts return a clear status instead of pretending the operation completed.

### `generate-key`

Only generate a new keypair after explicit user approval. If a remote install step is not possible, print the public key and next-step instructions instead of pretending setup is complete.

## Missing-Key Behavior

When no usable key exists:

1. ask the user to choose between an existing key, password auth, new key generation, or stopping,
2. do not silently create keys,
3. do not assume remote key installation is possible without a verified path.

## Failure Handling

At minimum, distinguish:

- auth failure,
- network or host failure,
- key ambiguity,
- missing key,
- command timeout,
- transfer failure.

## Setup Scripts

Use:

- `scripts/setup-auth.sh`
- `scripts/setup-auth.ps1`

Supported setup actions:

- discover default keys,
- inspect `ssh-agent`,
- generate a new keypair,
- print a public key for manual installation.
