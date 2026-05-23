# hermes-podman

以 Podman Compose 無根（rootless）方式執行 [NousResearch Hermes Agent](https://hub.docker.com/r/nousresearch/hermes-agent)。

## 服務

| 服務 | 容器名稱 | 連接埠 | 說明 |
|------|----------|--------|------|
| `hermes` | `hermes-gateway` | `8642` | API 閘道 |
| `dashboard` | `hermes-dashboard` | `9119` | 網頁管理介面 |

兩個服務均掛載 `~/.hermes` 至容器內的 `/opt/data`，作為持久化資料目錄。

## 環境需求

- [Podman](https://podman.io/)
- [podman-compose](https://github.com/containers/podman-compose)

## 快速開始

```bash
# 啟動所有服務
./podman-compose up -d

# 停止所有服務
./podman-compose down

# 重新啟動單一服務
./podman-compose restart hermes

# 查看日誌
./podman-compose logs -f hermes
./podman-compose logs -f dashboard

# 拉取最新映像檔
./podman-compose pull
```

> **注意**：請使用專案內的 `./podman-compose` 包裝腳本，而非系統的 `podman-compose`。
> 該腳本會自動帶入 `--in-pod 0` 參數，以確保 `userns_mode: keep-id` 正常運作。

## 資料目錄

所有執行期資料存放於主機的 `~/.hermes/`：

| 路徑 | 內容 |
|------|------|
| `~/.hermes/config.yaml` | 主要設定檔 |
| `~/.hermes/.env` | 機密資訊 / API 金鑰 |
| `~/.hermes/logs/` | 閘道與代理日誌 |
| `~/.hermes/skills/` | 已安裝的技能 |
| `~/.hermes/plugins/` | 已安裝的外掛 |

## 安全說明

- `userns_mode: keep-id`：容器以主機使用者身份（UID 1000）執行，無需 root 權限
- `user: "1000:1000"`：明確指定容器內的執行使用者
- Volume 掛載加上 `:Z` SELinux 標籤，適用於啟用 SELinux 的系統
- 容器不具備特權模式（無 `privileged: true`）
