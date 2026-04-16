# Tool Fallbacks

Remote Linux hosts may not have the same tools installed. Probe availability before assuming preferred commands exist.

## Preferred Tools

- `rg`
- `fd`
- `bat`

## Fallbacks

### Search text

- preferred: `rg`
- fallback: `grep -R`

### Find files

- preferred: `fd`
- fallback: `find`

### View file contents

- preferred: `bat`
- fallback: `cat`
- fallback for ranges: `sed -n`

## Guidance

- Prefer the preferred tool when present because output is usually cleaner.
- Fall back automatically when the remote host lacks the tool.
- Do not make tool absence a hard failure for basic inspection workflows.
