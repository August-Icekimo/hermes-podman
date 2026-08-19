# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

這個 repo 是 [NousResearch Hermes Agent](https://hermes-agent.nousresearch.com/) 的
**KVM/libvirt VM 佈署設定**。Hermes 在 VM 內以官方安裝腳本原生安裝，不是跑容器。

原本是 Podman Compose 佈署，於 2026-08-19 改為 VM。原因：容器限制了 agent 的
自主性（不能裝套件、沒有 systemd、`keep-id` 權限問題），而且沒有快照回滾機制。
舊設定完整保留在 `legacy-podman/`，沒有刪除。

## 架構

- **主機端腳本**（`vm/*.sh`）：用 `virsh` / `virt-install` 管 VM 生命週期，全部
  source `vm/lib.sh` 取得共用函式與 `vm.conf` 的設定。
- **cloud-init**（`vm/cloud-init/user-data.tpl`）：`create-vm.sh` 會把 `@@佔位符@@`
  換成實際值（SSH 公鑰、base64 過的 `.env` 與 `provision.sh`），用 `xorriso` 打成
  NoCloud seed ISO。
- **VM 內佈署**（`vm/files/provision.sh`）：以 root 由 cloud-init `runcmd` 觸發，
  裝系統相依套件 → 跑 Hermes 官方 `install.sh` → 佈署 `.env` → 條件式套用 LINE 修正
  → 裝 gateway/dashboard 的 systemd user unit。

## 關鍵約束

**`vm/files/provision.sh` 必須維持可重複執行。** 它同時是首次佈署路徑與修復路徑
（`./vm/ssh.sh 'sudo /root/hermes-provision/provision.sh'`）。加東西時一律用
idempotent 寫法。

**cloud-init 的 `write_files` 跑在 `users-groups` 之前。** 所以 `user-data.tpl` 裡
所有檔案都先寫到 `/root/hermes-provision/`（root 所有），由 `provision.sh` 再搬到
定位並改擁有者。不要在 `write_files` 裡寫 `owner: hermes`，那時使用者還不存在。

**LINE adapter 的修正是條件式的。** `provision.sh` 只在偵測到舊版寫法時才套用
`sed`。上游修好之後不該重複動它 —— 不要改成無條件套用。

**憑證只以 base64 存在於 seed ISO。** `create-vm.sh` 在佈署完成後會退掉並刪除
seed ISO、shred 掉 `vm/.build/user-data`。改動這條流程時要維持這個清理行為。

**UEFI + qcow2 nvram 是綁在一起的硬需求。** Debian 13 cloud image 只能 UEFI 開機；
而 `virsh snapshot-create-as`（內部快照）要求 nvram 是 qcow2，libvirt 又拒絕把 raw
樣板轉檔。所以 `create-vm.sh` 自己用 `qemu-img convert` 產一份 qcow2 樣板。
**不要改用 `--boot uefi`** —— 那會產生 `<os firmware='efi'>`，libvirt 會用韌體描述檔
裡的 raw 樣板覆寫掉指定的路徑，快照就壞了。必須明確給 `loader=` + `nvram.template=`，
再用 `--print-xml` → sed 補上 `format="qcow2"` → `virsh define`
（virt-install 沒有 `nvram.format` 選項）。

**Dashboard 只能綁 127.0.0.1。** Hermes 0.20 起非 loopback 綁定必須有 auth provider，
`--insecure` 已是 NO-OP。要遠端看就開 SSH 通道，不要為了方便把它改成 0.0.0.0 ——
它會直接拒絕啟動並進入崩潰迴圈。

**橋接網路沒有 libvirt DHCP lease。** 取 VM 的 IP 一律透過 qemu-guest-agent
（`vm_ip()` 用 `virsh domifaddr --source agent`），不要改用 `--source lease`。

## 常用指令

```bash
./vm/create-vm.sh                    # 建 VM + 佈署（免 sudo）
./vm/create-vm.sh --render-only      # 只產生 seed，不碰 libvirt（改樣板時用這個測）
./vm/create-vm.sh --no-wait          # 不等 cloud-init
./vm/ssh.sh 'systemctl --user status hermes-gateway'
./vm/migrate-data.sh [--pull] [--dry-run]
./vm/snapshot.sh create|list|revert|delete <名稱>
./vm/destroy-vm.sh

virsh -c qemu:///system console hermes    # 序列主控台，離開按 Ctrl+]
```

## 主機環境（已實測）

- Debian 13 trixie、AMD Ryzen 7 5825U（8C/16T）、62 GB RAM
- libvirt pool `default` → `/datapool/libvirt`（**ZFS**，681 GB 可用）
  - ZFS 不要用 `cache=none`（O_DIRECT），磁碟一律 `cache=writeback`
  - pool 目錄是 root 所有，但**不要用 sudo cp** —— 走 `virsh vol-create-as` /
    `vol-upload` / `vol-resize`，libvirtd 會處理擁有者與權限，腳本因此免 sudo
- **必須 `--boot uefi`**：Debian 13 genericcloud 在 SeaBIOS（傳統 BIOS）下會卡在
  GRUB 無限迴圈，每秒重印 `Booting \`Debian GNU/Linux'`，讀 2 GB／寫 0 位元組，
  序列埠看不到任何核心訊息。OVMF 在 `/usr/share/OVMF/`，這台其他能開的 VM 也都是
  `firmware='efi'`。改用 UEFI 後 26 秒開機完成。
- `osinfo-db` 沒有 debian13 條目，`--osinfo` 只能用 `detect=on,require=off`
  （實際會 fallback 到 generic，所以 virtio 要在 `--disk` / `--network` 明寫；
  也因為 fallback，virt-install 不會自動幫你選 UEFI，得手動指定）
- `virt-xml` 預設連 `qemu:///session`，一定要加 `--connect qemu:///system`
- `~/.ssh` 只有 `id_rsa` 沒有 `.pub`；公鑰改從 `~/.ssh/authorized_keys` 取
  （註解行要濾掉，每行用 `ssh-keygen -l` 驗過）
- libvirt 網路 `host-bridge` → `br0`（LAN 192.168.68.0/22）
- 主機上另有 7 個 `omni-agent-*` 容器在跑，**與本專案無關，不要動它們**
- `cloud-image-utils`（`cloud-localds`）沒裝，seed ISO 用 `xorriso` 產生

## 服務與路徑（VM 內）

| 項目 | 路徑 / 名稱 |
|---|---|
| 資料目錄 | `/home/hermes/.hermes` |
| 原始碼 | `/home/hermes/.hermes/hermes-agent`（git checkout，`hermes update` 管理） |
| 指令 | `/home/hermes/.local/bin/hermes` |
| Gateway | `hermes-gateway.service`（user unit，Hermes 自己產生），8642 / 8646 |
| Dashboard | `hermes-dashboard.service`（user unit，本專案提供），9119 僅 127.0.0.1 |

systemd user unit 靠 `loginctl enable-linger hermes` 才會開機自啟。
