# legacy-podman —— 舊的 Podman Compose 佈署

2026-08-19 之前本專案的佈署方式。保留備查，**不是**目前的佈署路徑。

改用 VM 的原因見專案根目錄的 `README.md`。

## 內容

| 檔案 | 說明 |
|---|---|
| `docker-compose.yml` | 四個服務：hermes-gateway、hermes-dashboard、task-broker、claude-code-worker |
| `podman-compose` | 包裝腳本，自動加 `--in-pod 0`（`keep-id` 需要） |
| `hermes/Dockerfile` | 在官方 image 上加 sudo + LINE adapter 修正 |
| `broker/` | 任務調度代理，唯一能 `podman exec` 進 worker 的閘道 |
| `worker/` | 預載 Claude Code 的重型任務 worker |
| `DEPLOY.md` | 原本的 bring-up 順序、授權階段、網路封鎖與隔離驗證 |

## 要跑起來的話

```bash
cd legacy-podman
./podman-compose up -d
```

注意 `docker-compose.yml` 內的路徑寫死為 `/home/icekimo/...`，且 `.env` 在上一層
（`../.env`），直接跑會找不到，需要調整 `env_file` 路徑。

## 這套架構在 VM 模式下還有用嗎

`task-broker` + `claude-code-worker` 的委派設計，目的是讓 Hermes 能安全地把重型
程式任務丟給隔離的 Claude Code 容器 —— 隔離邊界是容器。在 VM 模式下，VM 本身就是
邊界，agent 直接在 VM 內跑 Claude Code 即可，通常不需要再套一層 broker。
