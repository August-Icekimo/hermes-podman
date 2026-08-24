#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 建立並佈署 Hermes VM。
#
#   ./vm/create-vm.sh            建立 + 等待佈署完成 + 清掉 seed ISO
#   ./vm/create-vm.sh --no-wait  建完就返回，不等 cloud-init
#   ./vm/create-vm.sh --keep-seed  保留 seed ISO（除錯用，內含 .env 明文）
#   ./vm/create-vm.sh --render-only 只做前置檢查與產生 seed ISO，不碰 libvirt
#
# 不需要 sudo：磁碟透過 libvirtd 的 storage pool API 建立（你在 libvirt 群組裡）。
#
# --boot uefi 是必要的，不是偏好：Debian 13 genericcloud 映像在傳統 BIOS
# (SeaBIOS) 下會卡在 GRUB 無限迴圈 —— 每秒重印一次 "Booting `Debian GNU/Linux'"，
# 讀了 2 GB 卻寫不進半個位元組，序列埠也看不到核心訊息。實測踩過。
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WAIT=1
KEEP_SEED=0
RENDER_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-wait)   WAIT=0 ;;
        --keep-seed) KEEP_SEED=1 ;;
        --render-only) RENDER_ONLY=1 ;;
        -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
        *)           die "未知參數：$1" ;;
    esac
    shift
done

# --- 前置檢查 --------------------------------------------------------------
log "前置檢查"
need virsh virt-install qemu-img xorriso curl awk sha512sum
if [ "$RENDER_ONLY" = "0" ] && vm_exists; then
    die "VM '$VM_NAME' 已存在。要重建請先跑 ./vm/destroy-vm.sh"
fi
[ -f "$REPO_ROOT/.env" ] || die "找不到 $REPO_ROOT/.env（LINE 憑證）"
"${VIRSH[@]}" net-info "$VM_NETWORK" >/dev/null 2>&1 \
    || die "libvirt 網路 '$VM_NETWORK' 不存在。virsh net-list --all 看看有哪些"
PUBKEY_FILE="$(detect_pubkeys)"
ok "SSH 公鑰：$(grep -c . "$PUBKEY_FILE") 把（來源見上）"
ok "libvirt 網路：$VM_NETWORK"

CACHE_DIR="$VM_DIR/.cache"
BUILD_DIR="$VM_DIR/.build"
mkdir -p "$CACHE_DIR" "$BUILD_DIR"

# --- 下載基礎映像 ----------------------------------------------------------
BASE_IMG="$CACHE_DIR/$(basename "$CLOUD_IMAGE_URL")"
log "取得 Debian 13 cloud image"
if [ -f "$BASE_IMG" ]; then
    ok "已有快取：$BASE_IMG"
else
    curl -fL --progress-bar -o "$BASE_IMG.part" "$CLOUD_IMAGE_URL"
    mv "$BASE_IMG.part" "$BASE_IMG"
    ok "下載完成"
fi

log "驗證 SHA512"
if EXPECTED="$(curl -fsSL "$CLOUD_IMAGE_SUMS_URL" | awk -v f="$(basename "$BASE_IMG")" '$2 == f {print $1}')" \
   && [ -n "$EXPECTED" ]; then
    ACTUAL="$(sha512sum "$BASE_IMG" | awk '{print $1}')"
    [ "$EXPECTED" = "$ACTUAL" ] || die "映像校驗失敗，請刪掉 $BASE_IMG 重來"
    ok "校驗通過"
else
    warn "取不到 SHA512SUMS，略過校驗"
fi

# --- 產生 cloud-init seed ISO ---------------------------------------------
log "產生 cloud-init seed"
b64() { base64 -w0 "$1"; }

# 公鑰可能有多把，先攤成 YAML 清單項目，再用 sed 的 r/d 把整塊塞進去
KEYS_YAML="$BUILD_DIR/keys.yaml"
awk 'NF {printf "      - %s\n", $0}' "$PUBKEY_FILE" > "$KEYS_YAML"

sed -e "s|@@HOSTNAME@@|$VM_HOSTNAME|g" \
    -e "s|@@VM_USER@@|$VM_USER|g" \
    -e "s|@@ENV_B64@@|$(b64 "$REPO_ROOT/.env")|g" \
    -e "s|@@PROVISION_B64@@|$(b64 "$VM_DIR/files/provision.sh")|g" \
    -e "s|@@DASHBOARD_UNIT_B64@@|$(b64 "$VM_DIR/files/hermes-dashboard.service")|g" \
    -e "s|@@CHROME_CDP_UNIT_B64@@|$(b64 "$VM_DIR/files/hermes-chrome-cdp.service")|g" \
    -e "s|@@HERMES_INSTALL_ARGS@@|$HERMES_INSTALL_ARGS|g" \
    -e "s|@@VM_TIMEZONE@@|$VM_TIMEZONE|g" \
    "$VM_DIR/cloud-init/user-data.tpl" \
  | sed -e "/@@SSH_AUTHORIZED_KEYS@@/{r $KEYS_YAML" -e "d}" > "$BUILD_DIR/user-data"

sed -e "s|@@HOSTNAME@@|$VM_HOSTNAME|g" \
    -e "s|@@INSTANCE_SUFFIX@@|$(date +%Y%m%d%H%M%S)|g" \
    "$VM_DIR/cloud-init/meta-data.tpl" > "$BUILD_DIR/meta-data"

chmod 600 "$BUILD_DIR/user-data"     # 內含 LINE 憑證
xorriso -as mkisofs -quiet -output "$BUILD_DIR/seed.iso" \
        -volid CIDATA -joliet -rock "$BUILD_DIR/user-data" "$BUILD_DIR/meta-data"
ok "seed.iso 已產生"

if [ "$RENDER_ONLY" = "1" ]; then
    cat <<MSG

--render-only：已停在產生 seed 之後，沒有動 libvirt。
  user-data : $BUILD_DIR/user-data   （0600，內含 LINE 憑證明文）
  seed ISO  : $BUILD_DIR/seed.iso
檢查完請自行清掉：shred -u $BUILD_DIR/user-data && rm -f $BUILD_DIR/seed.iso
MSG
    exit 0
fi

# --- 建立磁碟 --------------------------------------------------------------
# 全部走 libvirtd 的 storage pool API：不必 sudo，擁有者/權限由 libvirt 處理。
vol_exists() { "${VIRSH[@]}" vol-info --pool "$VM_POOL" "$1" >/dev/null 2>&1; }

for v in "$VM_NAME.qcow2" "$VM_NAME-seed.iso"; do
    vol_exists "$v" && die "pool '$VM_POOL' 裡已經有 $v（上次建立失敗留下的？）
  清掉：virsh -c $LIBVIRT_URI vol-delete --pool $VM_POOL $v"
done

log "建立系統磁碟（${VM_DISK_GB}G，qcow2 精簡配置）"
"${VIRSH[@]}" vol-create-as "$VM_POOL" "$VM_NAME.qcow2" "${VM_DISK_GB}G" --format qcow2 >/dev/null
# 把 cloud image 的內容灌進去，再把虛擬容量撐到目標大小
"${VIRSH[@]}" vol-upload --pool "$VM_POOL" "$VM_NAME.qcow2" "$BASE_IMG"
"${VIRSH[@]}" pool-refresh "$VM_POOL" >/dev/null      # 讓 libvirt 重讀上傳後的實際容量
"${VIRSH[@]}" vol-resize --pool "$VM_POOL" "$VM_NAME.qcow2" "${VM_DISK_GB}G" >/dev/null
DISK="$("${VIRSH[@]}" vol-path --pool "$VM_POOL" "$VM_NAME.qcow2")"
ok "系統磁碟：$DISK"

log "上傳 seed ISO"
"${VIRSH[@]}" vol-create-as "$VM_POOL" "$VM_NAME-seed.iso" \
    "$(stat -c%s "$BUILD_DIR/seed.iso")" --format raw >/dev/null
"${VIRSH[@]}" vol-upload --pool "$VM_POOL" "$VM_NAME-seed.iso" "$BUILD_DIR/seed.iso"
SEED="$("${VIRSH[@]}" vol-path --pool "$VM_POOL" "$VM_NAME-seed.iso")"
ok "seed：$SEED"

# --- 建立 VM ---------------------------------------------------------------
# --- UEFI nvram 樣板 -------------------------------------------------------
# 兩個限制疊在一起，所以要自己轉一份 qcow2 樣板：
#   1. Debian 13 cloud image 必須 UEFI 開機
#   2. 內部快照（virsh snapshot-create-as）要求 nvram 是 qcow2 格式，
#      而 libvirt 不會把 raw 樣板轉檔（"conversion of the nvram template
#      to another target format is not supported"）
# 另外不能用 `--boot uefi`：那會產生 <os firmware='efi'>，libvirt 會自動代入
# 韌體描述檔裡的 raw 樣板，把這裡指定的路徑覆寫掉。必須明確給 loader。
NVRAM_TPL="$CACHE_DIR/$(basename "${OVMF_VARS%.fd}").qcow2"
if [ ! -f "$NVRAM_TPL" ]; then
    log "轉換 UEFI nvram 樣板為 qcow2（內部快照需要）"
    qemu-img convert -f raw -O qcow2 "$OVMF_VARS" "$NVRAM_TPL"
    chmod 644 "$NVRAM_TPL"
    ok "$NVRAM_TPL"
fi

# --- 建立 VM ---------------------------------------------------------------
log "產生 domain XML"
virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$VM_NAME" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot "loader=$OVMF_CODE,loader.readonly=yes,loader.type=pflash,nvram.template=$NVRAM_TPL" \
    --import \
    --disk "path=$DISK,format=qcow2,bus=virtio,cache=writeback,discard=unmap" \
    --disk "path=$SEED,device=cdrom,readonly=on" \
    --network "network=$VM_NETWORK,model=virtio" \
    --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
    --graphics none \
    --console pty,target_type=serial \
    --osinfo detect=on,require=off \
    --print-xml > "$BUILD_DIR/domain.xml"

# virt-install 沒有 nvram.format / nvram.templateFormat 選項，只能事後補上
sed -i "s|<nvram template=\"\([^\"]*\)\"/>|<nvram template=\"\1\" templateFormat=\"qcow2\" format=\"qcow2\">/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.qcow2</nvram>|" \
    "$BUILD_DIR/domain.xml"
grep -q 'format="qcow2">' "$BUILD_DIR/domain.xml" || die "nvram 格式補丁沒套用成功，快照功能會壞掉"

log "定義並啟動 VM"
"${VIRSH[@]}" define "$BUILD_DIR/domain.xml" >/dev/null
"${VIRSH[@]}" start "$VM_NAME" >/dev/null
"${VIRSH[@]}" autostart "$VM_NAME" >/dev/null
ok "VM 已建立並設為開機自動啟動"

if [ "$WAIT" = "0" ]; then
    cat <<MSG

VM 正在背景佈署中。追蹤方式：
  virsh -c $LIBVIRT_URI console $VM_NAME     （離開按 Ctrl+])
  ./vm/ssh.sh 'sudo tail -f /var/log/hermes-provision.log'

佈署完成後記得收尾（會清掉含憑證的 seed ISO）：
  ./vm/finish-setup.sh
MSG
    exit 0
fi

# 等待與收尾交給 finish-setup.sh —— 同一份邏輯，中斷後也能單獨補跑。
FINISH_ARGS=()
[ "$KEEP_SEED" = "1" ] && FINISH_ARGS=(--keep-seed)
exec "$VM_DIR/finish-setup.sh" "${FINISH_ARGS[@]}"
