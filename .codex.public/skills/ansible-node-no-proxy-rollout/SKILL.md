---
name: ansible-node-no-proxy-rollout
description: >-
  Roll out host-scoped NO_PROXY/no_proxy bypass values for node startup on any
  Ansible target, persist them in .bashrc and systemd env files, restart node
  services, and verify health. Use when users ask to make one or more addresses
  bypass proxy on a node host and apply changes immediately.
---

# Ansible Node NO_PROXY Rollout

Use this skill to avoid ad-hoc one-liners and apply the same safe rollout flow.

## Defaults

- Inventory: `/root/ansible/inventory`
- Node env file: `/etc/agent-node.env`
- Unit globs: `agent-node.service,agent-node@*.service`
- Bashrc targets: `/root/.bashrc` and `/home/<user>/.bashrc`

## Workflow

1. Confirm host exists in inventory.
2. Confirm host connectivity (`ansible ping`).
3. Merge bypass addresses into `NO_PROXY/no_proxy` in `.bashrc`.
4. Merge bypass addresses into node `EnvironmentFile`.
5. Restart discovered node services.
6. Print final env lines and service status summary.

## Run

```bash
bash skills/ansible-node-no-proxy-rollout/scripts/apply_no_proxy_rollout.sh \
  --host cloud_home \
  --bypass "MANAGER_PUBLIC_IP" \
  --users "root,lcj"
```

Multiple bypass addresses:

```bash
bash skills/ansible-node-no-proxy-rollout/scripts/apply_no_proxy_rollout.sh \
  --host cloud_home \
  --bypass "MANAGER_PUBLIC_IP,10.10.10.10,example.internal" \
  --users "root,lcj"
```

## Options

- `--inventory <path>`: Override inventory path.
- `--node-env-file <path>`: Override environment file path.
- `--service-globs "<glob1,glob2>"`: Override node service match patterns.
- `--check`: Run in Ansible check mode.

## Guardrails

- Prefer one host per run unless user explicitly requests batch rollout.
- Do not edit inventory unless explicitly requested.
- Keep idempotent merge behavior (append only when missing).
- Report exact failing units if restart errors occur.
