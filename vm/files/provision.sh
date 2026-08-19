#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 在 VM 內以 root 執行（由 cloud-init runcmd 呼叫）。
# 設計成可重複執行：改完再跑一次不會壞掉。
#
#   sudo /root/hermes-provision/provision.sh
# ---------------------------------------------------------------------------
set -euo pipefail

PROV_DIR="/root/hermes-provision"
# shellcheck disable=SC1091
if [ -f "$PROV_DIR/provision.env" ]; then
    # 不要寫成 `[ -f x ] && . x` —— 那樣 `.` 是 && 串列的最後一個指令，
    # 載入失敗會直接觸發 set -e 讓整支腳本無聲結束。
    . "$PROV_DIR/provision.env" || echo "[警告] provision.env 載入失敗，改用預設值"
fi

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_INSTALL_ARGS="${HERMES_INSTALL_ARGS:---non-interactive --skip-setup}"

USER_HOME="$(getent passwd "$HERMES_USER" | cut -d: -f6)"
USER_UID="$(id -u "$HERMES_USER")"
HERMES_HOME="$USER_HOME/.hermes"
INSTALL_DIR="$HERMES_HOME/hermes-agent"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*"; }

# 以 hermes 身分執行，並補上 systemd --user 需要的 session 變數
as_hermes() {
    runuser -u "$HERMES_USER" -- env \
        HOME="$USER_HOME" \
        USER="$HERMES_USER" \
        LOGNAME="$HERMES_USER" \
        HERMES_HOME="$HERMES_HOME" \
        XDG_RUNTIME_DIR="/run/user/$USER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        PATH="$USER_HOME/.local/bin:$HERMES_HOME/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

# ---------------------------------------------------------------------------
log "1/7 安裝系統相依套件"
# 這份清單對齊 Hermes 官方 Dockerfile 的 apt 層，外加 rsync（給 migrate-data.sh）。
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential ca-certificates curl ffmpeg gcc git libffi-dev \
    openssh-client procps python3 python3-dev ripgrep rsync

# ---------------------------------------------------------------------------
log "1.5/7 啟動 qemu-guest-agent"
# cloud-init 是在開機之後才裝它的，觸發它的 udev 事件早就過去了，所以不會自己起來
# —— 主機端要靠它問 VM 的 IP（橋接網路沒有 DHCP lease 可查），這裡明確啟動。
if systemctl list-unit-files qemu-guest-agent.service >/dev/null 2>&1; then
    # 用 start 不用 enable：這個 unit 沒有 [Install] 段，是靠 udev 觸發的。
    # 下次開機時 virtio port 已經在了，udev 會自己啟動它。
    systemctl start qemu-guest-agent.service 2>/dev/null \
        && echo "qemu-guest-agent 已啟動" \
        || warn "qemu-guest-agent 啟動失敗，主機端將取不到 IP"
else
    warn "沒有 qemu-guest-agent.service"
fi

# ---------------------------------------------------------------------------
log "2/7 開啟 $HERMES_USER 的 systemd user session（linger）"
# 沒有 linger，使用者層級的 hermes-gateway.service 不會在開機時啟動，
# 也無法在沒有登入 session 的情況下存活。
loginctl enable-linger "$HERMES_USER"
for _ in $(seq 1 30); do
    [ -S "/run/user/$USER_UID/bus" ] && break
    sleep 1
done
[ -S "/run/user/$USER_UID/bus" ] || warn "user D-Bus 尚未就緒，後續 systemctl --user 可能失敗"

# ---------------------------------------------------------------------------
log "3/7 執行 Hermes 官方安裝腳本（原生安裝，非容器）"
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "已存在 $INSTALL_DIR，改跑 hermes update"
    as_hermes bash -lc 'hermes update' || warn "hermes update 失敗，改用安裝腳本重跑"
fi
if [ ! -d "$INSTALL_DIR/.git" ]; then
    as_hermes bash -lc \
        "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- $HERMES_INSTALL_ARGS"
fi

HERMES_BIN="$USER_HOME/.local/bin/hermes"
[ -x "$HERMES_BIN" ] || { warn "找不到 $HERMES_BIN，安裝可能失敗，停在這裡"; exit 1; }
echo "hermes 版本：$(as_hermes "$HERMES_BIN" --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
log "4/7 佈署 .env（LINE 憑證）"
if [ -f "$PROV_DIR/hermes.env" ]; then
    install -o "$HERMES_USER" -g "$HERMES_USER" -m 0600 \
        "$PROV_DIR/hermes.env" "$HERMES_HOME/.env"
    echo "已寫入 $HERMES_HOME/.env（0600, $HERMES_USER）"
    # seed ISO 會一直掛在 VM 上，憑證不留第二份
    shred -u "$PROV_DIR/hermes.env" 2>/dev/null || rm -f "$PROV_DIR/hermes.env"
else
    warn "沒有帶入 .env — LINE 整合不會啟動"
fi

# ---------------------------------------------------------------------------
log "5/7 檢查 LINE adapter 的 home_channel 修正"
# 舊版（0.14.0）的 _env_enablement() 把 home_channel 塞成字串，但
# gateway/config.py 要的是 {"chat_id": "..."}；不修的話 HomeChannel 接不起來。
# 上游若已修好就不要重複動它 —— 所以這裡是條件式套用，不是無腦 sed。
ADAPTER="$INSTALL_DIR/plugins/platforms/line/adapter.py"
if [ ! -f "$ADAPTER" ]; then
    warn "找不到 $ADAPTER，略過（版本結構可能已變動）"
elif grep -q 'seeded\["home_channel"\] = os\.environ\["LINE_HOME_CHANNEL"\]' "$ADAPTER"; then
    sed -i \
        's/seeded\["home_channel"\] = os\.environ\["LINE_HOME_CHANNEL"\]/seeded["home_channel"] = {"chat_id": os.environ["LINE_HOME_CHANNEL"]}/' \
        "$ADAPTER"
    echo "已套用 home_channel 修正"
else
    echo "偵測不到舊版寫法 — 上游應已修正，略過"
fi

# ---------------------------------------------------------------------------
log "6/7 安裝 gateway 服務（Hermes 自帶的 systemd 整合）"
# 以 hermes 身分執行 => 產生使用者層級的 hermes-gateway.service
as_hermes "$HERMES_BIN" gateway install || warn "gateway install 回報失敗"
as_hermes systemctl --user daemon-reload || true
as_hermes systemctl --user enable --now hermes-gateway.service || warn "gateway 啟動失敗，稍後看 journal"

# ---------------------------------------------------------------------------
log "7/7 安裝 dashboard 服務"
# Hermes 只內建 gateway 的 service 安裝，dashboard 由我們自己補一個 user unit。
install -d -o "$HERMES_USER" -g "$HERMES_USER" -m 0755 "$USER_HOME/.config/systemd/user"
install -o "$HERMES_USER" -g "$HERMES_USER" -m 0644 \
    "$PROV_DIR/hermes-dashboard.service" \
    "$USER_HOME/.config/systemd/user/hermes-dashboard.service"
as_hermes systemctl --user daemon-reload
as_hermes systemctl --user enable --now hermes-dashboard.service || warn "dashboard 啟動失敗，稍後看 journal"

# ---------------------------------------------------------------------------
IP="$(hostname -I | awk '{print $1}')"
cat <<EOF

────────────────────────────────────────────────────────────
 Hermes VM 佈署完成
────────────────────────────────────────────────────────────
 使用者   : $HERMES_USER
 資料目錄 : $HERMES_HOME
 程式碼   : $INSTALL_DIR   （hermes update 可原地升級）
 Gateway  : http://$IP:8642
 LINE hook: http://$IP:8646
 Dashboard: http://$IP:9119

 服務狀態：
   sudo -u $HERMES_USER XDG_RUNTIME_DIR=/run/user/$USER_UID systemctl --user status hermes-gateway
   sudo -u $HERMES_USER XDG_RUNTIME_DIR=/run/user/$USER_UID journalctl --user -u hermes-gateway -f
────────────────────────────────────────────────────────────
EOF
