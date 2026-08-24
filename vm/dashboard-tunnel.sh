#!/usr/bin/env bash
# Dashboard 的 SSH 通道。
#
# Hermes dashboard 只綁 VM 內的 127.0.0.1（見 vm/files/hermes-dashboard.service），
# 所以 http://<VM_IP>:9119/ 一定連不上 —— 那不是故障，是 Hermes 0.20+ 的硬性要求：
# 非 loopback 綁定必須先有 auth provider，`--insecure` 已是 NO-OP。
#
#   ./vm/dashboard-tunnel.sh          # 本機 9119 → VM 的 9119
#   ./vm/dashboard-tunnel.sh 9200     # 本機 9119 被占用時，改用本機 9200
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

remote_port="$HERMES_DASHBOARD_PORT"
local_port="${1:-$remote_port}"

case "$local_port" in
    ''|*[!0-9]*) die "本機埠號要是數字：$local_port" ;;
esac
[ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || die "本機埠號超出範圍：$local_port"

vm_running || die "VM '$VM_NAME' 沒在執行（virsh start $VM_NAME）"

ip="$(vm_ip)" || die "取不到 VM 的 IP"
[ -n "$ip" ] || die "取不到 VM 的 IP，qemu-guest-agent 可能還沒起來"

# 先擋掉埠被占用的情況。不擋的話 ssh 只會印一行 warning 就繼續掛著，
# 使用者會以為通道通了，其實瀏覽器連到的是別的服務。
if command -v ss >/dev/null 2>&1 &&
   ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$local_port\$"; then
    die "本機的 $local_port 埠已被占用。換一個：./vm/dashboard-tunnel.sh $((local_port + 1))"
fi

log "通道：127.0.0.1:$local_port → $ip:$remote_port（VM 內的 loopback）"
ok  "瀏覽器開 http://127.0.0.1:$local_port/"
log "Ctrl-C 結束通道"

exec ssh "${ssh_opts[@]}" -N -L "$local_port:127.0.0.1:$remote_port" "$VM_USER@$ip"
