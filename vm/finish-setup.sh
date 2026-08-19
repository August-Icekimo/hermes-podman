#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 等 VM 佈署完成，然後收尾（退掉並刪除含憑證的 seed ISO、印出連線資訊）。
#
# create-vm.sh 最後會呼叫這支；但它也可以獨立執行 —— 如果建立過程被中斷
# （Ctrl-C、SSH 斷線、腳本被 kill），VM 內的 cloud-init 還是會自己跑完，
# 這時直接跑這支就能把收尾補上，不用重建 VM。
#
#   ./vm/finish-setup.sh              等完成 + 清掉 seed ISO
#   ./vm/finish-setup.sh --keep-seed  保留 seed ISO（除錯用，內含 .env 明文）
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

KEEP_SEED=0
[ "${1:-}" = "--keep-seed" ] && KEEP_SEED=1

vm_exists  || die "VM '$VM_NAME' 不存在"
vm_running || die "VM '$VM_NAME' 沒在執行（virsh start $VM_NAME）"

log "等待 VM 取得 IP（qemu-guest-agent 由 cloud-init 安裝，需要一點時間）"
IP="$(vm_ip_wait 900)" || die "15 分鐘內沒等到 IP。用 virsh console $VM_NAME 看開機狀況"
ok "IP：$IP"

log "等待 SSH"
DEADLINE=$(( $(date +%s) + 900 ))
until ssh "${ssh_opts[@]}" -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$IP" true 2>/dev/null; do
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "SSH 一直連不上"
    sleep 5
done
ok "SSH 已通"

log "等待 cloud-init 佈署完成（首次安裝含 Playwright/Chromium，約 10–25 分鐘）"
if ssh "${ssh_opts[@]}" "$VM_USER@$IP" "sudo cloud-init status --wait" 2>&1 | tail -1; then
    ok "cloud-init 完成"
else
    warn "cloud-init 回報非零狀態 —— 看 ./vm/ssh.sh 'sudo tail -50 /var/log/hermes-provision.log'"
fi

# --- 服務健康檢查 ----------------------------------------------------------
log "檢查服務"
for unit in hermes-gateway hermes-dashboard; do
    st="$(ssh "${ssh_opts[@]}" "$VM_USER@$IP" "systemctl --user is-active $unit.service" 2>/dev/null || echo unknown)"
    case "$st" in
        active) ok "$unit: $st" ;;
        *)      warn "$unit: $st  →  ./vm/ssh.sh 'journalctl --user -u $unit -n 50'" ;;
    esac
done

# --- 清掉 seed ISO（內含 LINE 憑證明文） -----------------------------------
if [ "$KEEP_SEED" = "0" ]; then
    log "移除 seed ISO（內含 .env 明文）"
    "${VIRSH[@]}" change-media "$VM_NAME" sda --eject --config >/dev/null 2>&1 \
        || "${VIRSH[@]}" detach-disk "$VM_NAME" sda --config >/dev/null 2>&1 || true
    "${VIRSH[@]}" vol-delete --pool "$VM_POOL" "$VM_NAME-seed.iso" >/dev/null 2>&1 || true
    [ -f "$VM_DIR/.build/user-data" ] && { shred -u "$VM_DIR/.build/user-data" 2>/dev/null || rm -f "$VM_DIR/.build/user-data"; }
    rm -f "$VM_DIR/.build/seed.iso" "$VM_DIR/.build/keys.yaml"
    ok "已清除（seed 的退片在 VM 下次重開機後生效）"
else
    warn "--keep-seed：seed ISO 與 .build/user-data 內含 LINE 憑證明文，請自行處理"
fi

cat <<MSG

────────────────────────────────────────────────────────────
 Hermes VM「$VM_NAME」已就緒 — $IP
────────────────────────────────────────────────────────────
 SSH       : ./vm/ssh.sh
 Gateway   : http://$IP:$HERMES_GATEWAY_PORT
 LINE hook : http://$IP:$HERMES_LINE_PORT
 Dashboard : http://$IP:$HERMES_DASHBOARD_PORT

 下一步：
   ./vm/migrate-data.sh              把舊的 ~/.hermes 資料搬進去
   ./vm/snapshot.sh create clean     先照一張乾淨快照再讓 agent 動手
────────────────────────────────────────────────────────────
MSG
