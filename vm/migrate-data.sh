#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 在主機的 ~/.hermes 與 VM 的 ~hermes/.hermes 之間搬資料。
#
#   ./vm/migrate-data.sh            主機 → VM（把舊容器留下的狀態帶進去）
#   ./vm/migrate-data.sh --pull     VM → 主機（備份 / 砍 VM 前先撤出來）
#   ./vm/migrate-data.sh --dry-run  只看會搬什麼
#
# 刻意不搬的東西：
#   venv/ bin/     —— VM 由官方安裝腳本自建，主機那份是容器裡的 Python 3.13 環境
#   hermes-agent/  —— 原始碼 checkout，由 `hermes update` 管理
#   logs/ cache/   —— 純垃圾
#   .env           —— 已由 cloud-init 佈署過，重搬只會蓋掉權限
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOST_DATA="${HOST_HERMES_HOME:-$HOME/.hermes}"
VM_DATA="/home/$VM_USER/.hermes"

DIRECTION="push"
DRY=()
# dry-run 時不要 progress2 —— 它會噴出幾萬行進度，把真正有用的統計淹掉
INFO="--info=stats1,progress2"
while [ $# -gt 0 ]; do
    case "$1" in
        --pull)    DIRECTION="pull" ;;
        --dry-run) DRY=(--dry-run); INFO="--info=stats2" ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *)         die "未知參數：$1" ;;
    esac
    shift
done

vm_running || die "VM '$VM_NAME' 沒在執行"
IP="$(vm_ip)"; [ -n "$IP" ] || die "取不到 VM 的 IP"

EXCLUDES=(
    --exclude 'venv/'
    --exclude 'bin/'
    --exclude 'hermes-agent/'
    --exclude 'logs/'
    --exclude 'cache/'
    --exclude 'models_dev_cache.json'
    --exclude '.env'
    --exclude '*.sock'
)

RSYNC_SSH="ssh ${ssh_opts[*]}"

stop_services() {
    log "先停掉 VM 內的 Hermes 服務（避免 state.db 寫到一半）"
    vm_ssh "systemctl --user stop hermes-gateway.service hermes-dashboard.service" || true
}
start_services() {
    log "重新啟動 VM 內的 Hermes 服務"
    vm_ssh "systemctl --user start hermes-gateway.service hermes-dashboard.service" || \
        warn "服務啟動失敗，進 VM 看 journalctl --user -u hermes-gateway"
}

if [ "$DIRECTION" = "push" ]; then
    [ -d "$HOST_DATA" ] || die "主機上找不到 $HOST_DATA"
    log "主機 $HOST_DATA  →  VM $VM_DATA"
    du -sh "$HOST_DATA" 2>/dev/null || true
    [ ${#DRY[@]} -eq 0 ] && stop_services
    rsync -aH "$INFO" "${DRY[@]}" "${EXCLUDES[@]}" \
        -e "$RSYNC_SSH" "$HOST_DATA/" "$VM_USER@$IP:$VM_DATA/"
    if [ ${#DRY[@]} -eq 0 ]; then
        vm_ssh "chown -R $VM_USER:$VM_USER $VM_DATA && chmod 640 $VM_DATA/config.yaml 2>/dev/null || true"
        start_services
        ok "搬移完成。用 ./vm/ssh.sh 'journalctl --user -u hermes-gateway -n 50' 確認"
    fi
else
    log "VM $VM_DATA  →  主機 $HOST_DATA.from-vm"
    DEST="$HOST_DATA.from-vm"
    mkdir -p "$DEST"
    rsync -aH "$INFO" "${DRY[@]}" "${EXCLUDES[@]}" \
        -e "$RSYNC_SSH" "$VM_USER@$IP:$VM_DATA/" "$DEST/"
    [ ${#DRY[@]} -eq 0 ] && ok "已備份到 $DEST"
fi
