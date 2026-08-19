#cloud-config
# ---------------------------------------------------------------------------
# 由 vm/create-vm.sh 產生，請勿直接編輯這份 .tpl 的產物。
# @@...@@ 佔位符會在建立 seed ISO 時被替換掉。
#
# 注意：cloud-init 的 write-files 模組跑在 users-groups 之前，所以這裡所有檔案
# 都先落在 /root/hermes-provision/（root 所有），再由 provision.sh 於 runcmd
# 階段搬到正確位置並改好擁有者。不要在 write_files 裡指定 owner: hermes。
# ---------------------------------------------------------------------------

hostname: @@HOSTNAME@@
fqdn: @@HOSTNAME@@
prefer_fqdn_over_hostname: false
manage_etc_hosts: true

users:
  - name: @@VM_USER@@
    shell: /bin/bash
    lock_passwd: true
    # VM 邊界就是爆炸半徑，這裡放心給無密碼 sudo：
    # 這正是容器裡要靠 Dockerfile 硬塞 sudoers 才能勉強做到的事。
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: [users, sudo]
    ssh_authorized_keys:
@@SSH_AUTHORIZED_KEYS@@

ssh_pwauth: false
disable_root: true

package_update: true
# 刻意不做 package_upgrade：它會在 qemu-guest-agent 裝好之前先升級整個系統，
# 主機端因此要等好幾分鐘才拿得到 VM 的 IP（橋接網路只能靠 guest agent 問）。
# 系統套件由 provision.sh 的 apt-get update + install 處理就夠了。
package_upgrade: false

packages:
  # qemu-guest-agent 讓主機端可以用 `virsh domifaddr --source agent` 取得 VM 的
  # LAN IP。橋接網路沒有 libvirt DHCP，沒有它就只能自己掃 ARP。
  - qemu-guest-agent

write_files:
  - path: /root/hermes-provision/hermes.env
    encoding: b64
    content: @@ENV_B64@@
    permissions: '0600'
    owner: root:root

  - path: /root/hermes-provision/provision.sh
    encoding: b64
    content: @@PROVISION_B64@@
    permissions: '0755'
    owner: root:root

  - path: /root/hermes-provision/hermes-dashboard.service
    encoding: b64
    content: @@DASHBOARD_UNIT_B64@@
    permissions: '0644'
    owner: root:root

  - path: /root/hermes-provision/provision.env
    permissions: '0644'
    owner: root:root
    content: |
      # 這份檔案會被 provision.sh 用 `.` 載入，所以值一定要加引號 ——
      # 沒引號的 `FOO=--a --b` 會被 bash 讀成「賦值 --a，然後執行指令 --b」，
      # 在 set -e 底下會讓 provision.sh 直接結束。
      HERMES_USER="@@VM_USER@@"
      HERMES_INSTALL_ARGS="@@HERMES_INSTALL_ARGS@@"

runcmd:
  - [ bash, -lc, "/root/hermes-provision/provision.sh 2>&1 | tee -a /var/log/hermes-provision.log" ]

final_message: "Hermes VM 已就緒（cloud-init $UPTIME 秒）。安裝紀錄：/var/log/hermes-provision.log"
