#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 快照包裝 —— 這是 VM 取代容器最實際的理由：讓 agent 放手做，弄壞了就回滾。
#
#   ./vm/snapshot.sh create <名稱> [說明]
#   ./vm/snapshot.sh list
#   ./vm/snapshot.sh revert <名稱>
#   ./vm/snapshot.sh delete <名稱>
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
vm_exists || die "VM '$VM_NAME' 不存在"

cmd="${1:-list}"; shift || true

case "$cmd" in
    create)
        name="${1:?用法：snapshot.sh create <名稱> [說明]}"
        desc="${2:-建立於 $(date '+%F %T')}"
        log "建立快照 '$name'"
        vm_running && warn "VM 執行中 —— 會一併存下記憶體狀態，需要一點時間"
        "${VIRSH[@]}" snapshot-create-as "$VM_NAME" "$name" "$desc" --atomic
        ok "完成"
        ;;
    list)
        "${VIRSH[@]}" snapshot-list "$VM_NAME"
        ;;
    revert)
        name="${1:?用法：snapshot.sh revert <名稱>}"
        warn "即將把 '$VM_NAME' 回滾到 '$name'，之後的所有變更都會消失"
        read -r -p "確定？打 yes 繼續：" a
        [ "$a" = "yes" ] || die "已取消"
        "${VIRSH[@]}" snapshot-revert "$VM_NAME" "$name"
        ok "已回滾"
        ;;
    delete)
        name="${1:?用法：snapshot.sh delete <名稱>}"
        "${VIRSH[@]}" snapshot-delete "$VM_NAME" "$name"
        ok "已刪除快照 '$name'"
        ;;
    *)
        die "未知子指令：$cmd（create|list|revert|delete）"
        ;;
esac
