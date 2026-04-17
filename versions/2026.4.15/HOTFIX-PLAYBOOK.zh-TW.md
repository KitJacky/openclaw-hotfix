# OpenClaw Hotfix 操作手冊（zh-TW）

最後更新：2026-04-17
Owner：Jacky Kit / https://jackykit.com
範圍：`/root/.openclaw` 部署
主要聯絡：`Jacky Kit / https://jackykit.com`

## 用途
這份文件是 OpenClaw hotfix 的單一真實來源。
每次 OpenClaw 升級後，請先讀這份文件，再執行 hotfix 與驗證流程。

## 目前基線
- OpenClaw 版本：`2026.4.15 (041266a)`
- 安裝方式：global npm package（`/usr/lib/node_modules/openclaw`）
- Gateway service：`openclaw-gateway.service`

## Release 影響備註
### 2026.4.15
- Anthropic 預設與 `opus` alias 更新到 Claude Opus 4.7；本機 local model 設定不受影響。
- bundled `google` plugin 新增 Gemini TTS，會增加 plugin/dependency surface，但本機暫不需要額外設定。
- 上游縮減 startup/skills/memory prompt budget，與本機 `thinkingDefault="low"`、`llm.idleTimeoutSeconds=900` 策略相容。
- npm 升級後會清理 stale packaged `dist` chunks；這有助避免舊 chunk import 問題，但也代表每次升級後必須重新檢查 package hotfix，因為檔名會改。
- Gateway/tools 加強 built-in tool 名稱碰撞防護；本機不需要繞過。

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

### 3) cron.run timeout guard（10-15 分鐘）
目的：
- 避免手動 `cron run` 因預設 timeout 太短而過早失敗
- `2026.4.14+` 上游已把預設提升到 `600000`（10 分鐘），本機 hotfix 可再提升到 `900000`（15 分鐘）

目標檔案：
- 新版：`/usr/lib/node_modules/openclaw/dist/cron-cli-*.js`
- 舊版：`/usr/lib/node_modules/openclaw/dist/reply-*.js`

### 3A) LLM 閒置逾時保護（15 分鐘）
- 設定：`agents.defaults.llm.idleTimeoutSeconds = 900`
- 原因：自建本地模型在長上下文、慢 token、研究型 cron job 中，超過 300 秒不罕見。
- 原則：自治 job 預設用 `900`；除非你刻意要完全取消限制，否則不建議設 `0`。

### 3B) 預設 thinking 層級保護
- 設定：`agents.defaults.thinkingDefault = "low"`
- 原因：`medium` 更容易讓本地模型進入長篇自我解說、部分摘要重覆、研究迴圈失控。
- 原則：自治 cron 預設用 `low`。只有在某個明確工作流證明需要更深推理時，才個別提高。

### 4) Closed-system audit downgrade
目的：
- 封閉系統、單一操作者、full-exec、小模型的部署，保留訊息但降為 `info`

降級項目：
- `models.weak_tier`
- `models.small_params`
- `gateway.control_ui.insecure_auth`
- `config.insecure_or_dangerous_flags`
- `tools.exec.safe_bin_trusted_dirs_risky`
- `tools.exec.security_full_configured`
- `tools.exec.safe_bins_broad_behavior`

### 5) CLI gateway RPC config 相容性（版本感知）
目的：
- 舊版曾因 `callGatewayFromCli(...)` 未注入 config 而導致 `openclaw cron run` 出現 `gateway closed (1000 normal closure)`
- 新版不一定還用相同 bundle，因此檢查邏輯需要版本感知

### 6) web_search 供應商備援 + 冷卻（Brave -> Tavily）
目的：
- 高頻研究排程下，Brave 常出現 `429 rate limit`
- `2026.4.14+` 上游已內建基本 provider fallback，但本機仍需要每個 provider 的冷卻佇列，否則高頻 cron 仍會撞 429

目標檔案：
- `/usr/lib/node_modules/openclaw/dist/runtime-BiQlOaAl.js`

必要邏輯：
- 在多個 provider 可用時保持 fallback 能力；本機允許明確指定 provider 時仍可 fallback
- 加入每個 provider 的冷卻佇列，避免瞬間連發造成 429：
  - `resolveWebSearchCooldownMs()`
  - `enqueueWebSearchWithCooldown(providerId, execute)`
- provider 執行都走同一套冷卻機制

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
- `2026.4.14` / `2026.4.15` 的 handshake 常數位於 `client-*.js`
- 這版的可接受修補狀態是：
  - `const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3`
  - env precedence 支援 `OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS`
  - `gateway-cli-*.js` 內 `option("--timeout <ms>", "Timeout in ms", "15000")`

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

### 10) Telegram bundle setup-entry 相容性檢查（2026.4.7 / 2026.4.9）
目的：
- `2026.4.7` 內建 `dist/extensions/telegram/setup-entry.js` 指向：
  - `./src/channel.setup.js`
- 但實際 bundle 沒有該檔，會導致 config 載入與 gateway 指令異常。
- `2026.4.9` 已改成新的有效分拆路徑：
  - `./setup-plugin-api.js`
  - `./secret-contract-api.js`
- 因此 hotfix 腳本不能只接受舊修補結果，也要接受新版上游正確格式。

目標檔案：
- `/usr/lib/node_modules/openclaw/dist/extensions/telegram/setup-entry.js`

接受狀態：
- 舊版修補格式：
  - `plugin.specifier = "./api.js"`
  - `plugin.exportName = "telegramSetupPlugin"`
- `2026.4.9` 上游有效格式：
  - `plugin.specifier = "./setup-plugin-api.js"`
  - `plugin.exportName = "telegramSetupPlugin"`
  - `secrets.specifier = "./secret-contract-api.js"`

驗證：
- `openclaw gateway health --timeout 60000 --json`
- `openclaw cron status --json`
- `openclaw security audit`

本機 `2026.4.14` / `2026.4.15` 實測備註：
- `openclaw gateway call health --timeout 20000 --json` 即使 gateway 正常，也可能逾時。
- 實測健康回應時間大約 `42-44s`。
- 升級後驗證建議優先使用：
  - `openclaw gateway health --timeout 60000 --json`
- `openclaw gateway status --json` 可能顯示 `rpc.error="timeout"`，但同一輸出內 `health.healthy=true`，原因是它內部 RPC probe timeout 較短。

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
