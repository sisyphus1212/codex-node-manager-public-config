#!/usr/bin/env bash
set -euo pipefail

INVENTORY="/root/ansible/inventory"
HOST=""
BYPASS=""
USERS="root"
NODE_ENV_FILE="/etc/agent-node.env"
SERVICE_GLOBS="agent-node.service,agent-node@*.service"
CHECK_MODE=0

usage() {
  cat <<USAGE
Usage:
  $0 --host <inventory-host> --bypass <addr1[,addr2,...]> [options]

Required:
  --host            Inventory host/group pattern (prefer single host)
  --bypass          Comma-separated bypass addresses to append into NO_PROXY/no_proxy

Options:
  --inventory       Inventory path (default: /root/ansible/inventory)
  --users           Comma-separated users for .bashrc update (default: root)
  --node-env-file   Node EnvironmentFile path (default: /etc/agent-node.env)
  --service-globs   Comma-separated systemd unit globs (default: agent-node.service,agent-node@*.service)
  --check           Run ansible-playbook with --check
  -h, --help        Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) INVENTORY="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --bypass) BYPASS="$2"; shift 2 ;;
    --users) USERS="$2"; shift 2 ;;
    --node-env-file) NODE_ENV_FILE="$2"; shift 2 ;;
    --service-globs) SERVICE_GLOBS="$2"; shift 2 ;;
    --check) CHECK_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$HOST" || -z "$BYPASS" ]]; then
  usage
  exit 2
fi

ansible -i "$INVENTORY" "$HOST" --list-hosts
ansible -i "$INVENTORY" "$HOST" -m ping -o

tmp_playbook="$(mktemp /tmp/no-proxy-rollout.XXXXXX.yml)"
trap 'rm -f "$tmp_playbook"' EXIT

cat > "$tmp_playbook" <<'YAML'
- name: Roll out NO_PROXY/no_proxy and restart node units
  hosts: "{{ target_host }}"
  gather_facts: false
  become: true
  vars:
    bypass_csv: "{{ bypass_csv }}"
    users_csv: "{{ users_csv }}"
    node_env_file: "{{ node_env_file }}"
    service_globs_csv: "{{ service_globs_csv }}"

  tasks:
    - name: Build bypass list
      ansible.builtin.set_fact:
        bypass_list: >-
          {{ bypass_csv.split(',') | map('trim') | reject('equalto','') | list | unique }}

    - name: Build .bashrc target list
      ansible.builtin.set_fact:
        bashrc_targets: >-
          {{
            ['/root/.bashrc']
            + (
                users_csv.split(',')
                | map('trim')
                | reject('equalto','')
                | reject('equalto','root')
                | map('regex_replace', '^(.*)$', '/home/\\1/.bashrc')
                | list
              )
          }}

    - name: Stat bashrc targets
      ansible.builtin.stat:
        path: "{{ item }}"
      loop: "{{ bashrc_targets }}"
      register: bashrc_stats

    - name: Insert NO_PROXY block into bashrc
      ansible.builtin.blockinfile:
        path: "{{ item.stat.path }}"
        marker: "# {mark} CODEX_NO_PROXY_ROLLOUT"
        create: true
        block: |
          __codex_merge_no_proxy() {
            local current="$1"
            local merged="$current"
            local addr
            for addr in {{ bypass_list | map('quote') | join(' ') }}; do
              case ",${merged}," in
                *",${addr},"*) ;;
                *) merged="${merged:+${merged},}${addr}" ;;
              esac
            done
            printf '%s' "$merged"
          }
          export NO_PROXY="$(__codex_merge_no_proxy "${NO_PROXY:-}")"
          export no_proxy="$(__codex_merge_no_proxy "${no_proxy:-}")"
          unset -f __codex_merge_no_proxy
      loop: "{{ bashrc_stats.results }}"
      when: item.stat.exists

    - name: Ensure node env file exists
      ansible.builtin.file:
        path: "{{ node_env_file }}"
        state: touch
        mode: "0600"

    - name: Merge bypass into node env NO_PROXY/no_proxy
      ansible.builtin.shell: |
        set -euo pipefail
        f="{{ node_env_file }}"
        current_up="$(awk -F= '/^[[:space:]]*NO_PROXY=/{print substr($0,index($0,$2))}' "$f" | tail -n1)"
        current_low="$(awk -F= '/^[[:space:]]*no_proxy=/{print substr($0,index($0,$2))}' "$f" | tail -n1)"
        merged="$current_up"
        [ -n "$merged" ] || merged="$current_low"
        for addr in {{ bypass_list | map('quote') | join(' ') }}; do
          case ",${merged}," in
            *",${addr},"*) ;;
            *) merged="${merged:+${merged},}${addr}" ;;
          esac
        done
        t="$(mktemp)"
        sed -e '/^[[:space:]]*NO_PROXY=/d' -e '/^[[:space:]]*no_proxy=/d' "$f" > "$t"
        {
          echo "NO_PROXY=$merged"
          echo "no_proxy=$merged"
        } >> "$t"
        install -m 0600 "$t" "$f"
        rm -f "$t"
      args:
        executable: /bin/bash

    - name: Show NO_PROXY values after update
      ansible.builtin.shell: |
        set -euo pipefail
        grep -E '^(NO_PROXY|no_proxy)=' "{{ node_env_file }}"
      args:
        executable: /bin/bash
      register: proxy_lines
      changed_when: false

    - name: Build target unit list
      ansible.builtin.shell: |
        set -euo pipefail
        IFS=',' read -r -a globs <<< "{{ service_globs_csv }}"
        units=""
        for g in "${globs[@]}"; do
          g="${g//[[:space:]]/}"
          [ -n "$g" ] || continue
          while read -r unit _; do
            [ -n "${unit:-}" ] || continue
            units+="$unit "
          done < <(systemctl list-unit-files "$g" --no-legend 2>/dev/null || true)
          while read -r unit _ _ _ _; do
            [ -n "${unit:-}" ] || continue
            units+="$unit "
          done < <(systemctl list-units "$g" --all --no-legend 2>/dev/null || true)
        done
        units="$(printf '%s\n' $units | awk 'NF' | sort -u | tr '\n' ' ')"
        echo "$units"
      args:
        executable: /bin/bash
      register: unit_list
      changed_when: false

    - name: Restart discovered units
      ansible.builtin.systemd:
        name: "{{ item }}"
        state: restarted
      loop: "{{ unit_list.stdout.split() }}"
      when: unit_list.stdout | trim | length > 0

    - name: Show unit status summary
      ansible.builtin.shell: |
        set -euo pipefail
        units="{{ unit_list.stdout | trim }}"
        if [ -z "$units" ]; then
          echo "No matching units found"
          exit 0
        fi
        systemctl is-active $units || true
        systemctl --no-pager --full status $units | sed -n '1,140p'
      args:
        executable: /bin/bash
      changed_when: false
YAML

check_flag=()
if [[ "$CHECK_MODE" == "1" ]]; then
  check_flag+=(--check)
fi

ansible-playbook -i "$INVENTORY" "$tmp_playbook" \
  -e "target_host=$HOST" \
  -e "bypass_csv=$BYPASS" \
  -e "users_csv=$USERS" \
  -e "node_env_file=$NODE_ENV_FILE" \
  -e "service_globs_csv=$SERVICE_GLOBS" \
  "${check_flag[@]}"
