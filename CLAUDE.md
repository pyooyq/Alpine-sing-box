# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

Push changes for this project to:

```text
git@github.com:pyooyq/Alpine-sing-box.git
```

GitHub repository: `pyooyq/Alpine-sing-box`.

## Project overview

This repository contains a single Bash installer/manager script for deploying `sing-box` with only one inbound mode:

- VLESS Reality

The script is primarily intended for Alpine/OpenRC, and also supports common systemd-based distributions using `apt`, `dnf`, or `yum`. Runtime state is created under `/etc/sing-box`, including `config.json`, `reality.env`, downloaded `sing-box` binary, service files, logs, and the local script copy used by the `sb` shortcut.

The script intentionally does not install or configure nginx, Argo/Cloudflare Tunnel, VMess, Hysteria2, TUIC, QR codes, or subscription files.

## Common commands

There is no build system or test suite in this repository. Validate changes with shell syntax checks and targeted manual runs.

```bash
# Bash syntax check
bash -n sing-box.sh

# Show CLI help
bash sing-box.sh --help

# Run the interactive menu locally; requires root for most real actions
bash sing-box.sh

# Exercise argument parsing without remote curl wrapper
bash sing-box.sh -install -port 20086 -reality-domain example.com

# Optional lint if shellcheck is available
shellcheck sing-box.sh
```

The README documents the remote execution forms users are expected to run:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh)
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -port 20086
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -reality-domain example.com
```

## Architecture notes

`sing-box.sh` is both the installer and the management UI. It parses CLI flags at startup, sets defaults such as `work_dir=/etc/sing-box`, then either runs `run_install_flow` for `-install` or enters the interactive `menu` loop.

The install flow is:

1. `run_install_flow` checks whether Reality state and the sing-box binary already exist.
2. `ensure_dependencies` installs minimal dependencies using the detected package manager.
3. `install_singbox_binary` downloads the latest sing-box release for the current architecture.
4. `generate_reality_values` creates UUID, Reality keypair, and short ID.
5. `write_config` writes `/etc/sing-box/config.json` with a single VLESS Reality inbound and direct outbound.
6. `save_state` writes `/etc/sing-box/reality.env` for later menu operations.
7. `install_service` writes either a systemd or OpenRC service and starts sing-box.
8. `create_shortcut` creates `/usr/bin/sb`, which launches the installed script copy.
9. `show_reality_info` prints the client parameters and single VLESS link to stdout only.

Configuration mutation is handled by `change_port` and `change_reality_domain`, which update `reality.env`, rewrite `config.json`, restart sing-box, and print the updated Reality parameters. Keep `PORT`, `REALITY_DOMAIN`, `UUID`, `PRIVATE_KEY`, `PUBLIC_KEY`, and `SHORT_ID` in sync between state and generated config.

Service management should remain limited to sing-box. If service behavior changes, update both the systemd and OpenRC branches.

## Important implementation details

- The script performs privileged system changes: package installation, firewall rules, service files, `/etc/sing-box`, and `/usr/bin/sb`.
- The Reality inbound listens on `::` and uses TCP only.
- `-port` controls the Reality listen port; if omitted, the script chooses a random high port.
- `-reality-domain` controls both Reality `tls.server_name` and `reality.handshake.server`.
- The script prints a single VLESS Reality link but does not write subscription or node files.
- Keep edits compatible with Bash and the minimal command set expected on fresh VPS images; many target systems will be Alpine/OpenRC.
