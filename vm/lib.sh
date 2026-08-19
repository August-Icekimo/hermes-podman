# ---------------------------------------------------------------------------
# vm/*.sh 共用的小工具。用 `. "$(dirname "$0")/lib.sh"` 載入。
# ---------------------------------------------------------------------------
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$VM_DIR/.." && pwd)"

# shellcheck disable=SC1091
. "$REPO_ROOT/vm.conf"

# LC_ALL=C 是必要的：這台機器是 zh_TW locale，沒有它 `virsh domstate` 會回
# 「執行中」而不是 "running"，底下所有字串比對都會誤判。
VIRSH=(env LC_ALL=C virsh -c "$LIBVIRT_URI")

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31m錯誤:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "找不到指令 '$c'，請先安裝"
    done
}

vm_exists() { "${VIRSH[@]}" dominfo "$VM_NAME" >/dev/null 2>&1; }

vm_running() { [ "$("${VIRSH[@]}" domstate "$VM_NAME" 2>/dev/null || true)" = "running" ]; }

# 透過 qemu-guest-agent 取得 VM 的 IPv4（橋接網路沒有 libvirt DHCP lease 可查）
vm_ip() {
    "${VIRSH[@]}" domifaddr "$VM_NAME" --source agent 2>/dev/null \
        | awk '$3 == "ipv4" && $1 != "lo" { split($4, a, "/"); print a[1]; exit }'
}

vm_ip_wait() {
    local timeout="${1:-300}" ip=""
    for _ in $(seq 1 "$timeout"); do
        ip="$(vm_ip || true)"
        [ -n "$ip" ] && { echo "$ip"; return 0; }
        sleep 1
    done
    return 1
}

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

vm_ssh() {
    local ip; ip="$(vm_ip)" || die "取不到 VM 的 IP（VM 有在跑嗎？qemu-guest-agent 起來了嗎？）"
    [ -n "$ip" ] || die "取不到 VM 的 IP"
    ssh "${ssh_opts[@]}" "$VM_USER@$ip" "$@"
}

# 收集要塞進 VM 的 SSH 公鑰，正規化後寫到 .build/authorized_keys 並回傳路徑。
# 來源優先序：vm.conf 指定 > ~/.ssh/authorized_keys > 現成的 .pub > 從私鑰推導
#
# 用 authorized_keys 當預設來源，是因為這台機器的 ~/.ssh 只有私鑰沒有 .pub，
# 而 authorized_keys 裡那把的指紋跟 id_rsa 相同（確認過），又帶了正確的 comment。
# 註解行與空行會被濾掉，每一行都會用 ssh-keygen -l 驗過才收。
detect_pubkeys() {
    local out="$VM_DIR/.build/authorized_keys"
    mkdir -p "$VM_DIR/.build"
    : > "$out"
    chmod 600 "$out"

    _collect_from() {
        local src="$1" line n=0 tmp
        [ -f "$src" ] || return 1
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            printf '%s\n' "$line" > "$tmp"
            if ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
                printf '%s\n' "$line" >> "$out"
                n=$((n + 1))
            fi
        done < "$src"
        rm -f "$tmp"
        [ "$n" -gt 0 ]
    }

    if [ -n "${SSH_PUBKEY_FILE:-}" ]; then
        [ -f "$SSH_PUBKEY_FILE" ] || die "vm.conf 指定的 SSH_PUBKEY_FILE 不存在：$SSH_PUBKEY_FILE"
        _collect_from "$SSH_PUBKEY_FILE" || die "$SSH_PUBKEY_FILE 裡沒有合法的公鑰"
        echo "$out"; return
    fi

    if _collect_from "$HOME/.ssh/authorized_keys"; then echo "$out"; return; fi

    local k
    for k in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_ecdsa.pub "$HOME"/.ssh/id_rsa.pub; do
        if _collect_from "$k"; then echo "$out"; return; fi
    done

    # 最後手段：從私鑰推導（不會動到 ~/.ssh）
    local priv derived="$VM_DIR/.build/derived.pub"
    for priv in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_ecdsa "$HOME"/.ssh/id_rsa; do
        [ -f "$priv" ] || continue
        if ssh-keygen -y -P "" -f "$priv" > "$derived" 2>/dev/null && [ -s "$derived" ]; then
            warn "$priv 沒有對應的 .pub，已從私鑰推導"
            _collect_from "$derived" && { rm -f "$derived"; echo "$out"; return; }
        fi
    done
    rm -f "$derived"

    die "找不到可用的 SSH 公鑰。
  - 產一把新的：ssh-keygen -t ed25519
  - 或在 vm.conf 設定 SSH_PUBKEY_FILE"
}
