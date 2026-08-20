# hermes-vm

在本機 KVM/libvirt 上，以**原生安裝**方式跑 [NousResearch Hermes Agent](https://hermes-agent.nousresearch.com/) 的佈署設定。

> **這個專案原本是 Podman Compose 佈署**（見 [`legacy-podman/`](legacy-podman/)）。
> 容器化的 Hermes 對 AI agent 綁手綁腳：agent 不能自由裝套件、沒有真正的 systemd、
> `userns_mode: keep-id` 造成一連串權限問題、而且沒有「弄壞了回滾」的機制。
> VM 把這些問題一次解決 —— 而且 Hermes 本來就有官方的原生安裝腳本與 systemd 整合，
> 容器反而是繞路。

## 為什麼是 VM 而不是容器

| | 容器（舊） | VM（現在） |
|---|---|---|
| agent 裝系統套件 | 要改 Dockerfile 重 build | 直接 `sudo apt install` |
| sudo | 要硬塞 sudoers 才有 | 原生具備，且爆炸半徑限於 VM |
| systemd | 沒有 | 完整，`hermes gateway install` 直接可用 |
| 檔案權限 | `keep-id` / uid 對映地獄 | 一般 Linux 使用者，沒這問題 |
| 弄壞了怎麼辦 | 重建容器、資料另外救 | `./vm/snapshot.sh revert clean` |
| 升級 | 重拉 image | `hermes update`（官方管道） |

## 快速開始

```bash
# 0. 準備 LINE 憑證（沿用舊的即可，格式沒變）
cp .env.example .env && $EDITOR .env

# 1. 檢視/調整資源配置
$EDITOR vm.conf

# 2. 建立 VM（不需要 sudo，磁碟走 libvirtd 的 storage pool API）
./vm/create-vm.sh

# 3. 把舊容器留下的 ~/.hermes 狀態搬進去（config、skills、sessions）
./vm/migrate-data.sh

# 4. 照一張乾淨快照，之後才讓 agent 放手做事
./vm/snapshot.sh create clean "首次安裝完成"
```

完成後 `./vm/create-vm.sh` 會印出 VM 的 LAN IP 與三個服務網址。

## 預設配置

`vm.conf` 的預設值是照這台機器的實測條件挑的（Ryzen 7 5825U 8C/16T、62 GB RAM、
`/datapool` 681 GB 可用、已存在 `br0` 橋接）：

| 項目 | 值 | 說明 |
|---|---|---|
| OS | Debian 13 trixie genericcloud | 與 Hermes 官方 image 底層一致（Debian 13 / Python 3.13） |
| vCPU | 4 | Hermes 是 API/IO bound，不吃算力 |
| RAM | 8 GB | 要跑 browser/playwright 類 skill 建議調到 16 GB |
| 磁碟 | 64 GB qcow2 | 精簡配置，實際只佔用寫入量 |
| 網路 | `host-bridge`（→ `br0`） | VM 直接拿 LAN IP，LINE webhook 打得進來 |
| 儲存 | libvirt pool `default` | 磁碟由 libvirtd 建立，權限它自己處理，腳本免 sudo |
| GPU | 不需要 | 推論走遠端 API（`config.yaml` 的 `provider`） |

## 目錄結構

```
vm.conf                        佈署參數（唯一要改的設定檔）
.env                           LINE 憑證（不進 git，由 cloud-init 注入 VM）
vm/
  create-vm.sh                 建 VM + 佈署 + 清掉含憑證的 seed ISO
  destroy-vm.sh                砍 VM 與磁碟
  migrate-data.sh              主機 ↔ VM 之間搬 ~/.hermes
  snapshot.sh                  快照 create / list / revert / delete
  ssh.sh                       進 VM 或在 VM 上跑指令
  dashboard-tunnel.sh          開 dashboard 的 SSH 通道（它只綁 VM 內的 loopback）
  lib.sh                       共用函式
  cloud-init/
    user-data.tpl              cloud-init 樣板（@@佔位符@@ 由 create-vm.sh 填）
    meta-data.tpl
  files/
    provision.sh               VM 內的佈署腳本（可重複執行）
    hermes-dashboard.service   dashboard 的 systemd user unit
    hermes-chrome-cdp.service  常駐 headless Chrome（CDP 給瀏覽器工具用）
legacy-podman/                 舊的 Podman Compose 佈署，保留備查
```

## 服務

VM 內以 `hermes` 使用者的 **systemd user unit** 執行，`loginctl enable-linger` 確保
開機即啟動、不需登入。

| 服務 | Unit | 埠 | 來源 |
|---|---|---|---|
| Gateway | `hermes-gateway.service` | 8642 | Hermes 內建（`hermes gateway install` 產生） |
| LINE webhook | 同上 | 8646 | Gateway 的 LINE adapter |
| Dashboard | `hermes-dashboard.service` | 9119（**僅 127.0.0.1**） | 本專案提供（Hermes 沒內建） |
| Chrome CDP | `hermes-chrome-cdp.service` | 9222（**僅 127.0.0.1**） | 本專案提供（瀏覽器工具的前提） |

```bash
./vm/ssh.sh 'systemctl --user status hermes-gateway'
./vm/ssh.sh 'journalctl --user -u hermes-gateway -f'
./vm/ssh.sh 'systemctl --user restart hermes-dashboard'
```

### Dashboard 只綁 127.0.0.1

Hermes 0.20 起，非 loopback 綁定會啟動認證閘門，沒有註冊 auth provider 就**拒絕啟動**
（`--insecure` 已標為 DEPRECATED / NO-OP，不再能繞過）。

所以 `http://<VM_IP>:9119/` **連不上是正常的** —— 那個位址上沒有任何 process 在聽。
要從別台機器看，開通道：

```bash
./vm/dashboard-tunnel.sh          # 然後開 http://127.0.0.1:9119/
./vm/dashboard-tunnel.sh 9200     # 本機 9119 被占用時，改用本機 9200
```

真的要對外綁，先設好認證再改 `vm/files/hermes-dashboard.service` 的 `--host`：
`config.yaml` 的 `dashboard.basic_auth.username` + `password_hash`，或 `hermes dashboard register`。

### 瀏覽器工具需要常駐的 Chrome

Hermes 的 `browser_exec`（Browser Use 後端）不會自己開瀏覽器 —— 它透過 CDP 附掛到一個
**已在執行**的 Chrome。這台 VM 沒有 X/Wayland，harness 自行啟動一定失敗：

```
browser-harness: fatal: chrome-not-running: no supported Chromium-family
  browser is running -- start Chrome, then retry
```

所以 `hermes-chrome-cdp.service` 常駐一個 headless Chrome，`browser.cdp_url` 指過去：

```bash
./vm/ssh.sh 'systemctl --user status hermes-chrome-cdp'
./vm/ssh.sh 'curl -s http://127.0.0.1:9222/json/version'   # 確認 CDP 活著
```

`cdp_url` 存的是 `http://127.0.0.1:9222` 而不是 `ws://…`：Chrome 重啟後 ws 端點的 GUID
會變，存 http 才能每次重新探索。

**CDP 沒有任何認證** —— 連得到那個埠就等於完全控制瀏覽器（讀 cookie、用已登入的
session、透過 `file://` 讀本機檔案），所以它只綁 127.0.0.1，不要對外開。

不想用 Browser Use、想回到內建的 `browser_*`（走 agent-browser，一樣可用）：

```bash
./vm/ssh.sh 'hermes config set browser.backend off'
```

> Gateway 不監聽 8642 —— 那是舊 compose 時代的埠。0.20 的 gateway 只開各平台
> adapter 的埠（LINE 是 8646）。

## 日常操作

```bash
virsh -c qemu:///system start hermes       # 開機
virsh -c qemu:///system shutdown hermes    # 關機
./vm/ssh.sh                                # 進去
./vm/ssh.sh 'hermes update'                # 升級 Hermes 本體

./vm/snapshot.sh create before-experiment  # 動大手術前先照一張
./vm/snapshot.sh list
./vm/snapshot.sh revert before-experiment  # 回滾
```

## 憑證處理

`.env` 的內容由 `create-vm.sh` 以 base64 塞進 cloud-init seed ISO，開機後
`provision.sh` 會把它寫成 `~hermes/.hermes/.env`（`0600`），然後：

1. `shred` 掉 VM 內 `/root/hermes-provision/` 的那份副本
2. 主機端退掉並刪除 seed ISO（`--keep-seed` 可保留供除錯，但裡面是明文）
3. `shred` 掉主機 `vm/.build/user-data`

`vm/.build/` 與 `vm/.cache/` 都在 `.gitignore` 裡。

## LINE adapter 修正

舊版 Hermes（0.14.0）的 `plugins/platforms/line/adapter.py` 把 `home_channel`
設成字串，但 `gateway/config.py` 要的是 `{"chat_id": "..."}`，不修就接不上 HomeChannel。
`provision.sh` 會**條件式**套用這個修正 —— 偵測不到舊寫法就跳過，
所以上游修好之後不會重複動它。

> 順帶一提：舊的容器 image 停在 **0.14.0**，PyPI 上的 `hermes-agent` 已經到 **0.19.0**。
> 原生安裝走 git checkout，`hermes update` 就能跟上。

## 疑難排解

```bash
# 開機/佈署卡住 —— 看序列主控台
virsh -c qemu:///system console hermes        # 離開按 Ctrl+]

# 佈署紀錄
./vm/ssh.sh 'sudo tail -100 /var/log/hermes-provision.log'
./vm/ssh.sh 'sudo cloud-init status --long'

# 重跑佈署（provision.sh 設計成可重複執行）
./vm/ssh.sh 'sudo /root/hermes-provision/provision.sh'

# 取不到 IP：qemu-guest-agent 還沒起來，或 VM 還在開機
virsh -c qemu:///system domifaddr hermes --source agent

# VM 在跑但完全沒動靜（TX 0 封包、磁碟只讀不寫）→ 開機迴圈
virsh -c qemu:///system domifstat hermes vnet1    # tx_packets 是 0 就是沒開起來
virsh -c qemu:///system domblkstat hermes vda     # wr_req 是 0 就是根本沒開機成功
```

### 開機迴圈：一定要用 UEFI

Debian 13 genericcloud 映像在傳統 BIOS（SeaBIOS）下會卡在 GRUB 無限迴圈 ——
每秒重印一次 `Booting \`Debian GNU/Linux'`，讀了 2 GB 卻寫不進任何東西。
`create-vm.sh` 已固定帶 `--boot uefi`。手動修既有的 VM：

```bash
virsh -c qemu:///system destroy hermes
virt-xml --connect qemu:///system hermes --edit --boot uefi   # 注意 --connect
virsh -c qemu:///system start hermes
```

## 舊的 Podman 佈署

`legacy-podman/` 保留了完整的 compose 設定，包含 `task-broker` + `claude-code-worker`
的委派架構。要回頭用的話：

```bash
cd legacy-podman && ./podman-compose up -d
```

注意該架構的 broker 是靠 `podman exec` 進 worker 容器 —— 在 VM 模式下這一層通常
不需要了，agent 直接在 VM 裡跑就好。
