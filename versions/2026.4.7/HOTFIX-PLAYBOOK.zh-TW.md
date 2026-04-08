# OpenClaw Hotfix 操作手冊（zh-TW）

最後更新：2026-04-08
Owner：Jacky Kit / https://jackykit.com
範圍：`/root/.openclaw` 部署
主要聯絡：`Jacky Kit / https://jackykit.com`

## 用途
這份文件是 OpenClaw hotfix 的單一真實來源。
每次 OpenClaw 升級後，請先讀這份文件，再執行 hotfix 與驗證流程。

## 目前基線
- OpenClaw 版本：`2026.4.7 (5050017)`
- 安裝方式：global npm package（`/usr/lib/node_modules/openclaw`）
- Gateway service：`openclaw-gateway.service`

## 套件內 Hotfix
以下修補位於 `/usr/lib/node_modules/openclaw/...`，升級後通常會被覆蓋，必須重新檢查。

### 1) Small-model audit severity downgrade
目的：
- 預設 audit 會把 small model + 無 sandbox + web tools 判為 `critical`
- 目前部署刻意接受這個風險姿態，因此降為 `info`

目標檔案：
- `/usr/lib/node_modules/openclaw/dist/audit*.js`

### 2) OpenAI streaming usage include
目的：
- 讓串流回應固定帶 usage 統計

目標檔案：
- `/usr/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/openai-completions.js`

### 3) cron.run timeout guard（15 分鐘）
目的：
- 避免手動 `cron run` 因預設 timeout 太短而過早失敗

目標檔案：
- 新版：`/usr/lib/node_modules/openclaw/dist/cron-cli-*.js`
- 舊版：`/usr/lib/node_modules/openclaw/dist/reply-*.js`

### 4) Closed-system audit downgrade
目的：
- 封閉系統、單一操作者、full-exec、小模型的部署，保留訊息但降為 `info`

降級項目：
- `models.weak_tier`
- `gateway.control_ui.insecure_auth`
- `config.insecure_or_dangerous_flags`
- `tools.exec.safe_bin_trusted_dirs_risky`
- `tools.exec.security_full_configured`
- `tools.exec.safe_bins_broad_behavior`

### 5) CLI gateway RPC config 相容性（版本感知）
目的：
- 舊版曾因 `callGatewayFromCli(...)` 未注入 config 而導致 `openclaw cron run` 出現 `gateway closed (1000 normal closure)`
- 新版不一定還用相同 bundle，因此檢查邏輯需要版本感知

### 6) web_search 供應商備援（Brave -> Tavily）
目的：
- 高頻研究排程下，Brave 常出現 `429 rate limit`
- 目前 runtime 預設單一 provider，不會自動切換

目標檔案：
- `/usr/lib/node_modules/openclaw/dist/runtime-BiQlOaAl.js`

必要邏輯：
- `runWebSearch(params)` 主供應商失敗後，自動改試其他可用 provider（先排除原 provider）
- 所有 provider 都失敗時，才回拋原錯誤
- 即使 `tools.web.search.provider` 有明確指定（例如 `tavily`），只要有多個 provider 可用，也必須允許 fallback：
  - 明確指定僅代表優先順序，不是「只能用單一供應商」。
- 加入每個 provider 的冷卻佇列，避免瞬間連發造成 429：
  - `resolveWebSearchCooldownMs()`
  - `enqueueWebSearchWithCooldown(providerId, execute)`
  - 主供應商與備援供應商都走同一套冷卻機制

環境需求：
- `TAVILY_API_KEY` 必須可讀取（本機放在 `/root/.openclaw/.env`）
- gateway/node service 需載入 `.env`：
  - `EnvironmentFile=-/root/.openclaw/.env`
- 冷卻參數：
  - `OPENCLAW_WEB_SEARCH_COOLDOWN_MS`（優先，限制在 1000-5000ms）
  - `OPENCLAW_WEB_SEARCH_COOLDOWN_SECONDS`（次要，限制在 1-5 秒）
  - 本機預設：`OPENCLAW_WEB_SEARCH_COOLDOWN_MS=2000`

## Service / Config Hotfix
以下位於 npm 套件樹之外，通常升級後會保留，但如果重新安裝 service 或 doctor 強制重建，仍需重查。

### 6) Gateway handshake/runtime patch（版本感知）
目的：
- 修正 handshake timeout 與 gateway CLI 入口穩定性

重點：
- `2026.3.24+` 起，handshake timeout 邏輯移到 `method-scopes-*.js`
- 預期修補後預設值：`DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3`

### 7) Three-Day Blog Analysis delivery suppression
目的：
- 避免 retrospective job 因 telegram delivery 問題而被誤判為失敗

目標設定：
- `jobs.json` 內 job id `3095001f-8aef-4792-ba82-043a8a1e5230`
- `delivery.mode = "none"`

### 8a) state dir 權限
目的：
- 避免 audit 對 `/root/.openclaw` 權限提出警告

要求：
- 目錄權限維持 `700`

### 8) loopback trusted proxies
目的：
- 移除 loopback 控制介面的 reverse-proxy trust warning

設定：
- `gateway.trustedProxies = ["127.0.0.1/32", "::1/128"]`

### 9) 本地 device auth scope 修復
目的：
- 修正本地 CLI 與 paired device metadata scope 漂移問題

必要 scope：
- `operator.admin`
- `operator.approvals`
- `operator.pairing`
- `operator.read`
- `operator.write`

### 10) Telegram bundle setup-entry 路徑修復（2026.4.7）
目的：
- `2026.4.7` 內建 `dist/extensions/telegram/setup-entry.js` 指向：
  - `./src/channel.setup.js`
- 但實際 bundle 沒有該檔，會導致 config 載入與 gateway 指令異常。

目標檔案：
- `/usr/lib/node_modules/openclaw/dist/extensions/telegram/setup-entry.js`

必要修補：
- `plugin.specifier = "./channel-plugin-api.js"`
- `plugin.exportName = "telegramSetupPlugin"`

驗證：
- `openclaw gateway call health --timeout 25000 --json`
- `openclaw cron status --json`
- `openclaw security audit`

## Hotfix 歸檔同步
每次 hotfix 與驗證完成後，請同步以下資產到：
- `https://github.com/jackykit0116/openclaw-hotfix.git`
- 本地備份鏡像：`/home/github/openclaw-hotfix`
- 單向發布目標：`https://github.com/KitJacky/openclaw-hotfix`

次要發布設定來源：
- `/home/github/.env`
- 必要鍵值：
  - `github_email`
  - `github_openclaw_hotfix_repo`
  - `github_primary_key`（`jackykit0116` 用，未提供時回退 `github_key`）
  - `github_secondary_classic_key`（`KitJacky` 用，建議優先，fine-grained 不通時使用）
  - `github_secondary_key`（`KitJacky` 用，未提供時回退 `github_key`）
  - 可選帳號覆蓋：`github_primary_user`、`github_secondary_user`

必要資產：
- `/root/.openclaw/workspace/HOTFIX-PLAYBOOK.md`
- `/root/.openclaw/workspace/HOTFIX-PLAYBOOK.zh-TW.md`
- `/root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh`

規則：
- 保留 `latest/`
- 保留 `versions/<openclaw-version>/`
- 在 `metadata/manifest.json` 記錄 `hotfix_version` 與 `updated_at`

同步指令：
- `bash /root/.openclaw/workspace/scripts/finalize-openclaw-hotfix-sync.sh`

預期收尾行為：
- commit/push 到 `jackykit0116/openclaw-hotfix`
- 使用 `rsync --delete` 同步到 `/home/github/openclaw-hotfix`
- 單向 push `main` 到 `KitJacky/openclaw-hotfix`

## 自動化腳本
主要 hotfix 腳本：
- `/root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh`

模式：
- 檢查：
  - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --check`
- 套用：
  - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --apply`

## 標準升級流程
1. 預覽：
   - `openclaw update --dry-run --json`
2. 升級：
   - `npm i -g openclaw@latest`
3. 重新套用 hotfix：
   - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --apply`
4. 確認 service override：
   - `systemctl --user show openclaw-gateway.service -p DropInPaths -p Environment`
5. 重啟：
   - `systemctl --user daemon-reload`
   - `systemctl --user restart openclaw-gateway.service`
   - `systemctl --user restart openclaw-node.service`
6. 最後驗證：
   - `openclaw --version`
   - `openclaw gateway call health`
   - `openclaw cron status`
   - `openclaw security audit`
7. 發布 hotfix 歸檔：
   - `bash /root/.openclaw/workspace/scripts/finalize-openclaw-hotfix-sync.sh`
