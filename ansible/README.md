# Ubuntu Fleet Initial Setup (Ansible)

This Ansible automation configures the initial baseline and observability telemetry stack for the Ubuntu fleet (`servers` and `workstations`) in the AIOps incident management lab.

## Inventory Architecture

Target nodes are reachable via their dedicated **out-of-band management interfaces (`10.42.0.0/16`)**:

- **`mini21-srv-01` (`10.42.10.80`, `sysadmin`)**: Headless Ubuntu Server node.
- **`mini21-ws-01` (`10.42.10.81`, `bocal`)**: Headless Ubuntu Workstation node.

## Roles Included

| Role | Description | Key Artifacts |
|---|---|---|
| **`common`** | Base system administration, Asia/Bangkok (+07:00) timezone, base utilities (`curl`, `wget`, `jq`, `htop`, `iotop`, `sysstat`, `tmux`, `git`, `ufw`, `net-tools`, `unzip`, `tar`), UFW default-deny incoming with SSH (port 22) allowed. | `/etc/localtime`, `/etc/ufw/` |
| **`node_exporter`** | Prometheus Node Exporter `v1.9.0` running as dedicated system user `node_exporter`, listening on `:9100`. UFW rule permits metrics scraping strictly from `10.42.0.0/16`. | `/usr/local/bin/node_exporter`, `/etc/systemd/system/node_exporter.service` |
| **`promtail`** | Grafana Promtail `v3.3.2` running as dedicated system user `promtail` (in `systemd-journal` and `adm` groups), shipping systemd-journal and `/var/log/*.log` to VictoriaLogs at `http://10.42.0.1:9428/insert/loki/api/v1/push?_stream_fields=instance,job` with `_time` label dropping. | `/usr/local/bin/promtail`, `/etc/promtail/promtail.yml`, `/etc/systemd/system/promtail.service` |

## Quick Commands (`Makefile`)

All common operations are wrapped in the `ansible/Makefile`:

```bash
# 1. Test connectivity and Python interpreter on all nodes
make ping

# 2. Check playbook syntax
make syntax

# 3. Dry-run execution with diffs
make check

# 4. Apply configuration across all nodes
make apply

# 5. Clean up temporary and cache files
make clean
```

## Directory Structure

```
ansible/
├── Makefile
├── README.md
├── ansible.cfg
├── inventory.ini
├── site.yml
├── group_vars/
│   ├── all.yml
│   └── ubuntu_fleet.yml
└── roles/
    ├── common/
    │   ├── defaults/main.yml
    │   ├── handlers/main.yml
    │   └── tasks/main.yml
    ├── node_exporter/
    │   ├── defaults/main.yml
    │   ├── handlers/main.yml
    │   ├── tasks/main.yml
    │   └── templates/node_exporter.service.j2
    └── promtail/
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── tasks/main.yml
        └── templates/
            ├── promtail.service.j2
            └── promtail.yml.j2
```
