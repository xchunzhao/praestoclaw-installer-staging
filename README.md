# PraestoClaw Installer — Staging Channel

This is the **staging** branch of the PraestoClaw installer mirror. It hosts
pre-release wheels and install scripts for testers who want to validate
upcoming changes against the staging gateway without touching the prod path.

## Install

```powershell
# Windows
irm https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/install.ps1 | iex
```

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/install.sh | bash
```

After install, the staging client is exposed as **`praestoclaw-staging`** /
**`pc-staging`**. It coexists with any existing prod `praestoclaw` / `pc`
install on the same machine:

| Command | Channel | Data dir | Gateway |
|---|---|---|---|
| `pc s` | production | `~/.praestoclaw/` | `praestoclawgateway-…` |
| `pc-staging s` | staging | `~/.praestoclaw-staging/` | `praestoclawgatewaystaging-…` |

## Update

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/update.sh | bash
```

```powershell
# Windows
irm https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/update.ps1 | iex
```

## Artifacts

- [install.ps1](install.ps1) / [install.sh](install.sh) — staging installers
- [update.ps1](update.ps1) / [update.sh](update.sh) — staging updaters
- [latest.txt](latest.txt) — current published staging version
- `dist/` — version-pinned wheels (praestoclaw + agent_gateway_protocol)

`latest.txt` and `dist/` are published automatically by the
[mirror-installer-staging](https://github.com/gim-home/PraestoClaw/actions/workflows/mirror-installer-staging.yml)
workflow on every `staging-v*` tag.

**Install/update scripts on this branch are hand-maintained** — the workflow
does not overwrite them. Source of truth lives in this branch directly.
