#!/usr/bin/env bash
# 進 VM。有帶參數就當指令執行：./vm/ssh.sh 'systemctl --user status hermes-gateway'
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
vm_running || die "VM '$VM_NAME' 沒在執行（virsh start $VM_NAME）"
exec_ip="$(vm_ip)" || die "取不到 IP"
[ -n "$exec_ip" ] || die "取不到 IP，qemu-guest-agent 可能還沒起來"
exec ssh "${ssh_opts[@]}" "$VM_USER@$exec_ip" "$@"
