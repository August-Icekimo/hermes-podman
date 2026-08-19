#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 砍掉 VM 與它的磁碟。~/.hermes 的資料如果只存在 VM 裡，會一起消失。
#   ./vm/destroy-vm.sh           會問過才動手
#   ./vm/destroy-vm.sh --yes     不問
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
if ! vm_exists; then
    warn "VM '$VM_NAME' 不存在 —— 只清理 pool 裡的殘留磁碟"
    for v in "$VM_NAME.qcow2" "$VM_NAME-seed.iso"; do
        "${VIRSH[@]}" vol-delete --pool "$VM_POOL" "$v" 2>/dev/null && ok "已刪除 $v"
    done
    exit 0
fi

if [ "${1:-}" != "--yes" ]; then
    warn "即將永久刪除 VM '$VM_NAME' 及其所有磁碟與快照。"
    warn "VM 內的 ~/.hermes（sessions、config、skills）會一起不見。"
    warn "要留資料請先跑：./vm/migrate-data.sh --pull"
    read -r -p "確定？打 $VM_NAME 繼續：" a
    [ "$a" = "$VM_NAME" ] || die "已取消"
fi

vm_running && "${VIRSH[@]}" destroy "$VM_NAME"
"${VIRSH[@]}" undefine "$VM_NAME" --remove-all-storage --snapshots-metadata --nvram 2>/dev/null \
    || "${VIRSH[@]}" undefine "$VM_NAME" --remove-all-storage --snapshots-metadata
"${VIRSH[@]}" vol-delete --pool "$VM_POOL" "$VM_NAME-seed.iso" 2>/dev/null || true
ok "VM '$VM_NAME' 已刪除"
