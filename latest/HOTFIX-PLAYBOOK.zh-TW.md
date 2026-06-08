# OpenClaw Hotfix 操作手冊（zh-TW）

最後更新：2026-05-26
Owner：Jacky Kit / https://jackykit.com
範圍：`/root/.openclaw` 部署
主要聯絡：`Jacky Kit / https://jackykit.com`

## 用途
這份文件是 OpenClaw hotfix 的單一真實來源。
每次 OpenClaw 升級後，請先讀這份文件，再執行 hotfix 與驗證流程。

## 目前基線
- OpenClaw 版本：`2026.5.22 (a374c3a)`
- 安裝方式：global npm package（`/usr/lib/node_modules/openclaw`）
- Gateway service：`openclaw-gateway.service`

## Release 影響備註
### 2026.5.22
- 透過 **`npm i -g openclaw@latest`** 將全域套件從 **`2026.5.7` 升到 `2026.5.22`**，接著 **`openclaw-post-update-hotfix.sh --apply`**／**`--check`**（皆通過）。
- **pi-ai npm scope 變更：** `include_usage` hotfix 的目標改為 **`@earendil-works/pi-ai`**（舊：`@mariozechner/pi-ai`）。主機腳本 [`workspace/scripts/openclaw-post-update-hotfix.sh`](/root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh) 會自動嘗試兩條路徑。
- **Hotfix 腳本收緊到 `2026.05.26.4`：** undici `client-h1` pause 處理由單純刪 assert 升級為語意化 guard（requeue bytes、finish 前 resume、paused 時跳過 readable）。先前 `2026.05.26.3` 的 web_search cooldown 接線仍保留。
- **Gateway 自行 restart 緩解：** 重複 crash 來自 bundled **`undici@8.3.0`** 的 `client-h1.js`（`assert(!this.paused)`），不是 systemd/health-monitor 主動重啟。觸發模式是 cron 並發（browser + web_search + exec）加上 event-loop delay。本機緩解：在 `undici/lib/dispatcher/client-h1.js` 做語意化 patch、將 `agents.defaults.maxConcurrent` 限到 `3`、deny standalone `tavily_search`。
- 已執行 **`openclaw doctor --non-interactive --fix`**；並重啟 systemd user **`openclaw-gateway.service`**／**`openclaw-node.service`**。Gateway **剛重啟後** `gateway health` 可能短暫出現 **WebSocket 1006**；待 log 顯示 **ready** 後再重試即可。
- 在 Agent／IDE 環境執行 `openclaw` 時，請讓 PATH 優先 **`/usr/bin` 的 Node 22**，避免 Cursor 內建的 **Node v20** 排到前面而觸發「需要 Node ≥22.12」並直接退出。
- 驗證快照（warm 後）：
  - `openclaw --version` → `OpenClaw 2026.5.22 (a374c3a)`
  - `openclaw-post-update-hotfix.sh --check` → 全過
  - `openclaw gateway health --timeout 120000 --json` → `ok: true`
  - `openclaw cron status --json` → `jobs: 22`
  - `openclaw cron run 8888 --timeout 120000` → 成功入閘（enqueued）
  - `openclaw security audit` → `0 critical · 1 warn · 6 info`（`brave` 未鎖版本；其余 closed-system downgrade 規則仍適用）

### 2026.5.7
- 本機已成功從前一個穩定基線 `2026.4.26` 升級到 `2026.5.7`，並重新套用 host hotfix；另外因為新版 web-search provider 佈局調整，還需要補裝外部 Brave plugin。
- `2026.5.7` 對本機最有價值的修正包括：Telegram polling watchdog 更準確、native commands 的 owner enforcement、更乾淨的 `/new` / reset 後 context 失效、`/new` / `sessions.reset` 會清掉 cached skills snapshot，以及 Tavily 憑證從 active runtime config 正確解析。
- 升級後本機必要補步：
  - 安裝 `@openclaw/brave-plugin`
  - 確認 `plugins.entries.brave.enabled=true`
  - restart gateway
  - 重新執行 `cron status`，直到 `tools.web.search.provider` warning 消失
- 升級後本機驗證結果：
  - `openclaw --version` -> `OpenClaw 2026.5.7 (eeef486)`
  - `openclaw-post-update-hotfix.sh --check` -> 全部 hotfix 通過
  - `openclaw gateway health --timeout 120000 --json` -> `ok: true`，warm 狀態約 `1.3-2.8s`
  - `openclaw cron status --json` -> 乾淨，`jobs: 22`，安裝 Brave plugin 後不再報 warning
  - `openclaw security audit` -> `0 critical · 0 warn · 6 info`

### 2026.4.26
- `openclaw update` 會先裝到驗證過的暫存 prefix，再切換到正式版本。這可降低新舊檔混雜、stale chunk 殘留的升級失敗風險，但 package hotfix 仍需重套，因為 bundle 檔名仍可能改變。
- 前景 gateway 啟動不再依賴舊的 CLI self-respawn 路徑，對低記憶體 Linux 主機更友善，也減少一類啟動卡死問題。
- 上游對 broken pipe / `EPIPE` 的 stream 收尾更寬容，正常完成回應後的輸出管線關閉，不再那麼容易把 gateway-side 流程拖垮。
- 在這台主機上，重啟後第一次 `gateway health` 比 `2026.4.14/15` 明顯更慢。`2026.4.26` 實測 cold-start 健康回應最慢約 `81s`。
- 進入 warm 狀態後，同一台主機的 `gateway health` 會再次明顯變快。這代表有 warm/cold path 差異，不應直接判定為隨機故障。

### 2026.4.15
- Anthropic 預設與 `opus` alias 更新到 Claude Opus 4.7；本機 local model 設定不受影響。
- bundled `google` plugin 新增 Gemini TTS，會增加 plugin/dependency surface，但本機暫不需要額外設定。
- 上游縮減 startup/skills/memory prompt budget，與本機 `thinkingDefault="low"`、`llm.idleTimeoutSeconds=900` 策略相容。
- npm 升級後會清理 stale packaged `dist` chunks；這有助避免舊 chunk import 問題，但也代表每次升級後必須重新檢查 package hotfix，因為檔名會改。
- Gateway/tools 加強 built-in tool 名稱碰撞防護；本機不需要繞過。

## 套件內 Hotfix
以下修補位於 `/usr/lib/node_modules/openclaw/...`，升級後通常會被覆蓋，必須重新檢查。

目前 `2026.5.22 (a374c3a)` 搭配 hotfix 腳本 `2026.05.26.4` 的狀態：
- Small-model audit severity：已修補（不再升為 `critical`，仍以 `info` 可見）。
- OpenAI streaming usage：已在 `@earendil-works/pi-ai` 修補；腳本仍支援舊 `@mariozechner/pi-ai` 路徑。
- LLM idle timeout / thinking default：設定有效（`models.providers.local.timeoutSeconds = 900`、`thinkingDefault = "low"`）。
- `cron.run` timeout：目前上游預設為 `600000`（10 分鐘），guard 接受；若舊版或日後 bundle 改動，腳本仍可重套本機 timeout guard。
- Closed-system audit downgrade：已修補（下列 `warn` / conditional critical 項目均降為 `info`）。
- Gateway RPC config path：目前 call path 相容，不需要強行套舊版 config injection。
- `web_search` fallback + cooldown：已修補；多 provider 可用時允許 fallback，且 provider execution 已經走 `enqueueWebSearchWithCooldown(candidate.id, ...)`。
- `web_search` provider 順序：已 patch 為 **Brave (10) → SearXNG (15) → Tavily (25) → DuckDuckGo (100)**（hotfix `2026.06.08.1`）。
- MiniMax fallback suppression：設定有效（`plugins.entries.minimax.enabled = false`）。
- Standalone Tavily tool exposure：已透過 config deny（`tools.deny` 包含 `tavily_search`）；Tavily quota exhaustion 與 Gateway 自行 restart 有關聯，只有在 quota 恢復且重新檢查 tool-surface policy 後才應再啟用。
- Undici client-h1 pause hotfix：已 patch `undici/lib/dispatcher/client-h1.js`，用語意化 pause 處理（`execute`/`onUpgrade` requeue、`finish` 前 `llhttp_resume`、paused 時跳過 `readMore`/`readable`），取代 upstream `assert(!this.paused)` 直接 crash。
- Gateway session concurrency：已透過 config 限流（`agents.defaults.maxConcurrent = 3`），降低 cron 期間 browser/web_search 並發 HTTP 壓力。
- Telegram `/new` 與 `/reset` 卡死緩解：設定有效（`agents.defaults.startupContext.enabled = false`）。
- Telegram setup-entry compatibility：目前上游 layout 有效（`setup-plugin-api.js` + `secret-contract-api.js`）。

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
- `/usr/lib/node_modules/openclaw/node_modules/@earendil-works/pi-ai/dist/providers/openai-completions.js`（目前套件，例如 `2026.5.22+`）
- 舊版路徑：`@mariozechner/pi-ai/...`（本機 hotfix 腳本會兩邊一起嘗試）

### 3) cron.run timeout guard（10-15 分鐘）
目的：
- 避免手動 `cron run` 因預設 timeout 太短而過早失敗
- `2026.4.14+` 上游已把預設提升到 `600000`（10 分鐘），本機 hotfix 可再提升到 `900000`（15 分鐘）

目標檔案：
- 新版：`/usr/lib/node_modules/openclaw/dist/cron-cli-*.js`
- 舊版：`/usr/lib/node_modules/openclaw/dist/reply-*.js`

### 3A) LLM 閒置逾時保護（15 分鐘）
- 設定：
  - 舊路徑：`agents.defaults.llm.idleTimeoutSeconds = 900`
  - 新 provider 路徑：`models.providers.<providerId>.timeoutSeconds >= 900`
- 原因：自建本地模型在長上下文、慢 token、研究型 cron job 中，超過 300 秒不罕見。
- 原則：自治 job 預設用 `900`；除非你刻意要完全取消限制，否則不建議設 `0`。
- `2026.4.26` doctor 備註：
  - 上游已把 `agents.defaults.llm` 視為 legacy config。
  - 未來可能改由 `models.providers.<id>.timeoutSeconds` 承接相同逾時設定。
  - hotfix 檢查腳本必須接受兩種位置皆為有效。

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

### 6) web_search 供應商備援 + 冷卻（Brave → SearXNG → Tavily → DuckDuckGo）
目的：
- 高頻研究排程下，Brave 常出現 `429 rate limit`
- Tavily dev quota 可能出現 `432`
- 本機自建 SearXNG（`http://127.0.0.1:8321`）提供免 key、無 quota 上限的備援，應在 Tavily 之前
- `2026.4.14+` 上游已內建基本 provider fallback，但本機仍需要每個 provider 的冷卻佇列，否則高頻 cron 仍會撞 429
- 上游預設把 SearXNG 排最後（order 200）；本機 hotfix 覆寫 `autoDetectOrder` 以符合 free-first 策略

目標檔案：
- `/usr/lib/node_modules/openclaw/dist/runtime-*.js`（fallback + cooldown）
- `dist/searxng-search-provider-*.js`（`200 → 15`）
- `dist/tavily-search-provider-*.js` 與 `dist/extensions/tavily/web-search-contract-api.js`（`70 → 25`）
- Brave 維持 `10`；DuckDuckGo 維持 `100`

必要邏輯：
- 在多個 provider 可用時保持 fallback 能力；本機允許明確指定 provider 時仍可 fallback
- 加入每個 provider 的冷卻佇列，避免瞬間連發造成 429：
  - `resolveWebSearchCooldownMs()`
  - `enqueueWebSearchWithCooldown(providerId, execute)`
- provider 執行都走同一套冷卻機制
- Checker 必須確認實際存在 `await enqueueWebSearchWithCooldown(candidate.id, ...)`；只看到 helper 函式不代表 cooldown 已生效。

環境需求：
- `TAVILY_API_KEY` 必須可讀取（本機放在 `/root/.openclaw/.env`）
- `SEARXNG_BASE_URL=http://127.0.0.1:8321`（Docker：`/root/.openclaw/searxng/`，**勿用 8888**，該 port 已被 SSH tunnel 占用）
- gateway/node service 需載入 `.env`：
  - `EnvironmentFile=-/root/.openclaw/.env`
- 冷卻參數：
  - `OPENCLAW_WEB_SEARCH_COOLDOWN_MS`（優先，限制在 1000-5000ms）
- `OPENCLAW_WEB_SEARCH_COOLDOWN_SECONDS`（次要，限制在 1-5 秒）
- 本機預設：`OPENCLAW_WEB_SEARCH_COOLDOWN_MS=2000`

重要 config 規則：
- **不要**設定 `tools.web.search.provider = "brave"`（或任何單一 id）— 會禁用 fallback（`onlyPluginIds`）
- 順序**無法**在 `openclaw.json` 設定，必須靠 hotfix patch `autoDetectOrder`

本機 fallback 順序：
1. Brave（API 免費額度）
2. SearXNG（自建，port 8321）
3. Tavily（dev 額度）
4. DuckDuckGo（VPS 上常 bot challenge，最後備援）

### 6A) 關閉本機未配置的 MiniMax web_search 備援
目的：
- `2026.4.26` 會把更多 bundled provider/plugin 候選暴露給 runtime，但其中有些在本機其實不可用。
- 本機實測 `web_search` 備援曾多次把 `missing_minimax_api_key` 當成 tool result 寫回自治 session。
- 這類結果不是硬失敗，而是一般工具輸出，容易污染本地模型上下文，導致後續推理偏離現實能力。

目標：
- `/root/.openclaw/openclaw.json`

必要設定：
- `plugins.entries.minimax.enabled = false`

本機策略：
- 本機 `web_search` 主路徑為 Brave；備援順序為 SearXNG → Tavily → DuckDuckGo（見 §6 hotfix order patch）。
- 除非之後真的配置 MiniMax 憑證，否則 `minimax` 必須保持停用。
- 不要把沒有真實憑證與路由策略的 provider/plugin surface 暴露給 LLM。

驗證：
- `openclaw plugins list --json | rg '"id": "minimax"|\"enabled\": false'`
- `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --check`
- 確認新的自治 session 不再收到 `missing_minimax_api_key` 類型的 tool result。

### 6B) 本機 Telegram `/new` 與 `/reset` 卡死緩解
目的：
- 在本機上，Telegram `/status` 可能仍正常，但 bare `/new` 與 `/reset` 看起來像完全沒反應。
- 這兩個指令在上游不是即時回 ACK，而是會直接進入完整 agent 啟動回合。
- 配合此 workspace 的 startup 檔案與預設 runtime startup-context prelude，首輪 reset 路徑容易過重，最後讓 `agent:main:telegram:slash:*` 這類 session 長時間卡在 `processing`。

目標：
- `/root/.openclaw/openclaw.json`

必要設定：
- `agents.defaults.startupContext.enabled = false`

本機策略：
- 保持一般 Telegram 對話回覆邏輯不變。
- 只移除 bare `/new` 與 `/reset` 額外載入的 runtime daily-memory prelude。
- 若 slash session 已卡死，先刪除 session store 內陳舊的 `agent:*:telegram:slash:<ownerId>` 映射，再重啟 `openclaw-gateway.service`。

驗證：
- `openclaw doctor` 仍可能顯示 Telegram pairing warnings；這不代表 `/new` 或 `/reset` 已被上游取消。
- 重新測試後，gateway log 不應再持續對 owner slash session 報 `stuck session`。
- `/status` 應持續正常，而 `/new` / `/reset` 應建立新的 slash session，而不是反覆沿用壞掉的舊 session。

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

本機 `2026.4.26` 實測備註：
- 重啟後第一次 `openclaw gateway health` 在本機最慢可到約 `81s`
- 升級後驗證建議優先使用：
  - `openclaw gateway health --timeout 90000 --json`
- 進入 warm 狀態後，health 檢查可再次明顯變快；不要把 cold-start path 直接視為硬故障

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
