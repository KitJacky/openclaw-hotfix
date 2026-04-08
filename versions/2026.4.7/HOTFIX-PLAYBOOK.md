# OpenClaw Hotfix Playbook

Last updated: 2026-04-08
Owner: Jacky Kit / https://jackykit.com
Scope: `/root/.openclaw` deployment
Primary contact: `Jacky Kit / https://jackykit.com`

## Purpose
This file is the single source of truth for OpenClaw hotfixes that may be overwritten by future upgrades.
When OpenClaw is updated, read this file first, then run the post-update checklist.

## Current Baseline
- OpenClaw version (at last verification): `2026.4.7 (5050017)`
- Install type: global npm package (`/usr/lib/node_modules/openclaw`)
- Gateway service: `openclaw-gateway.service`

## Package Hotfixes
These patch files under `/usr/lib/node_modules/openclaw/...`.
They are likely to be overwritten by package upgrades and must be rechecked after every update.

### 1) Small-model audit severity downgrade
Reason:
- Default audit flags small-model + non-sandbox + web tools as `critical`.
- Current deployment intentionally allows this risk posture.

Patch target:
- `/usr/lib/node_modules/openclaw/dist/audit*.js`

Expected patched logic:
- `severity: "info"`
- Must NOT contain `severity: hasUnsafe ? "critical" : "info"`

### 2) OpenAI streaming usage include
Reason:
- Ensure usage stats are returned in stream responses.
- Force-enable for all streaming models, including compat profiles that default to `supportsUsageInStreaming: false`.

Patch target:
- `/usr/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/openai-completions.js`

Expected patched logic:
- `params.stream_options = { include_usage: true };`
- Must NOT contain gate: `if (compat.supportsUsageInStreaming !== false) { ... }`

### 3) cron.run tool timeout guard (15 minutes)
Reason:
- Prevent manual cron tool runs from failing early at short gateway timeout.

Patch target (depends on version):
- Newer builds (current): `/usr/lib/node_modules/openclaw/dist/cron-cli-*.js`
- Legacy builds: `/usr/lib/node_modules/openclaw/dist/reply-*.js`

Expected patched logic:
- Newer builds:
  - in `cron run` command handler, default timeout should be set to `900000` (15m) when user did not pass `--timeout`.
- Legacy builds:
  - `const runOpts = { ...gatewayOpts, timeoutMs: Math.max(gatewayOpts.timeoutMs ?? 0, 15 * 6e4) };`
  - `callGateway("cron.run", runOpts, ...)`

### 4) Closed-system audit downgrade
Reason:
- This host is intentionally loopback-only, single-operator, full-exec, small-model, closed-system.
- The following audit findings should remain visible, but only as `info`, not `warn`.

Patch target:
- `/usr/lib/node_modules/openclaw/dist/audit*.js`

Downgraded checks:
- `models.weak_tier`
- `gateway.control_ui.insecure_auth`
- `config.insecure_or_dangerous_flags`
- `tools.exec.safe_bin_trusted_dirs_risky`
- `tools.exec.security_full_configured`
- `tools.exec.safe_bins_broad_behavior`

### 5) CLI gateway RPC config injection (version-aware)
Reason:
- In `2026.3.13`, `openclaw cron run <job-id>` could fail with `gateway closed (1000 normal closure)`.
- Root cause at that time: `callGatewayFromCli(...)` did not inject loaded config into `callGateway(...)`.

Patch targets / expected logic:
- Legacy builds (2026.3.13-style):
  - patch `gateway-rpc-*.js` to inject:
    - `const config = opts.config ?? await readBestEffortConfig();`
    - pass `config` into `callGateway({ ... })`
- Newer builds (current, 2026.3.23-2):
  - do **not** force legacy injection patch.
  - verify `call-*.js` contains internal config load:
    - `const config = options.config ?? gatewayCallDeps.loadConfig();`

Verification:
- `openclaw cron status`
- `openclaw cron run 06371142-7986-420b-8fab-89355b42b71c`
- `openclaw cron run 8888`

Expected behavior after patch:
- no websocket `1000 normal closure` from `openclaw cron run ...`
- if a job is already active, CLI should return business result like:
  - `{"ok":true,"ran":false,"reason":"already-running"}`

### 6) web_search provider fallback (Brave -> Tavily)
Reason:
- `web_search` can hit Brave 429 throttling under high-frequency cron research.
- Upstream runtime selects one provider per call and does not auto-fallback.

Patch target:
- `/usr/lib/node_modules/openclaw/dist/runtime-BiQlOaAl.js`

Required patched logic:
- In `runWebSearch(params)`, wrap primary provider execution in `try/catch`.
- On primary failure, resolve runtime providers and retry with alternates (excluding primary).
- Keep original error if all fallback providers fail.
- Even when `tools.web.search.provider` is explicitly set (for example `tavily`), fallback should still be allowed when multiple providers are available.
  - Explicit provider is treated as priority order, not a hard single-provider lock.
- Add per-provider cooldown queue to reduce provider-side 429 bursts:
  - `resolveWebSearchCooldownMs()`
  - `enqueueWebSearchWithCooldown(providerId, execute)`
  - route both primary and fallback execution through cooldown queue.

Environment requirements:
- Tavily key must be available via:
  - `TAVILY_API_KEY` (env), or
  - `plugins.entries.tavily.config.webSearch.apiKey`
- This host uses:
  - `/root/.openclaw/.env` with `TAVILY_API_KEY=...`
  - `EnvironmentFile=-/root/.openclaw/.env` in gateway/node systemd user units
- Cooldown env knobs:
  - `OPENCLAW_WEB_SEARCH_COOLDOWN_MS` (preferred, clamped to 1000-5000ms)
  - `OPENCLAW_WEB_SEARCH_COOLDOWN_SECONDS` (fallback, clamped to 1-5s)
  - host default: `OPENCLAW_WEB_SEARCH_COOLDOWN_MS=2000`

Verification:
- `openclaw gateway call health --timeout 20000 --json`
- Trigger a web-search-heavy cron turn and confirm no hard-stop when Brave is rate-limited.
- `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --check`

## Service / Config Hotfixes
These live outside the npm package tree and usually survive package upgrades, but may be overwritten by service reinstall/doctor force actions.

### 6) Gateway websocket handshake/runtime patch (version-aware)
Reason:
- On this host, manual Gateway entrypoints can fail in two different ways:
  - `openclaw cron run <job-id>` fails with:
    - `gateway closed (1000 normal closure)`
    - or `gateway closed (1006 abnormal closure (no close frame))`
  - `openclaw gateway --help` or other gateway subcli loads can crash with:
    - `uv_interface_addresses returned Unknown system error 1`
- Server log confirmed the first issue was a real Gateway-side handshake failure:
  - `handshake timeout`
  - `closed before connect`
  - with `handshakeMs: 3000`

Targets:
- `/usr/lib/node_modules/openclaw/dist/gateway-cli-*.js`
- (`auth-profiles-*.js` workaround is legacy-only and not required on current build)
- Newer build note (2026.3.24):
  - handshake timeout logic moved into `method-scopes-*.js`
  - expected default after patch: `DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3`

Required patched logic:
- In `gateway-cli-*.js`:
  - `const DEFAULT_HANDSHAKE_TIMEOUT_MS = 15e3;`
  - timeout env key accepts either:
    - `OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS` (preferred)
    - `OPENCLAW_HANDSHAKE_TIMEOUT_MS` (current upstream key)
  - keep support for `OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS`
- `auth-profiles-*.js` `pickPrimaryLanIPv4()` patch is only required for older builds where that function exists and is crash-prone.

Why this form:
- The old `systemd drop-in` workaround using:
  - `VITEST=1`
  - `OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS=15000`
  worked as a temporary workaround, but the more stable fix is to patch the installed runtime so:
  - production env can override handshake timeout directly
  - gateway subcli no longer depends on a fragile `networkInterfaces()` syscall succeeding

Activation:
- `systemctl --user restart openclaw-gateway.service`

Verification:
- `openclaw gateway --help`
- `openclaw cron status`
- `openclaw cron run moltbook-auto-reply-runner`

Expected behavior after patch:
- `openclaw gateway --help` prints help normally
- `openclaw cron status` returns JSON
- `openclaw cron run <job-id>` enqueues instead of dying in websocket close during connect
- `jobs.json` should show the job `runningAtMs` after a successful manual enqueue

Residual note:
- As of 2026-03-17, `openclaw gateway call cron.run ...` may still hit a separate `1006` path.
- Treat `openclaw cron run ...` as the primary manual-entry health check on this host.

### 7) Three-Day Blog Analysis delivery suppression
Reason:
- In `2026.3.13`, the job itself ran, but delivery failed with:
  - `Unsupported channel: telegram`
- This should not mark the retrospective run as failed.

Target:
- `/root/.openclaw/cron/jobs.json`

Required setting:
- Job id: `3095001f-8aef-4792-ba82-043a8a1e5230`
- `delivery.mode = "none"`

### 8a) State dir permissions
Reason:
- Newer audits warn when `/root/.openclaw` is world-readable/executable.

Target:
- `/root/.openclaw`

Required state:
- directory mode `700`

### 8) Loopback trusted proxies
Reason:
- `gateway.bind="loopback"` with local Control UI should not keep producing the reverse-proxy trust warning.

Target:
- `/root/.openclaw/openclaw.json`

Required setting:
- `gateway.trustedProxies = ["127.0.0.1/32", "::1/128"]`

### 9) Local device auth scope repair
Reason:
- Local CLI device auth can drift from paired-device metadata after upgrade/restart/doctor flows.
- Symptom on this host:
  - `openclaw status --json` shows `gateway.error = "missing scope: operator.read"`
  - gateway logs show:
    - `errorMessage=missing scope: operator.read`
- This breaks gateway-backed read commands even when the gateway service itself is healthy.

Targets:
- `/root/.openclaw/identity/device-auth.json`
- `/root/.openclaw/devices/paired.json`

Required local operator scopes:
- `operator.admin`
- `operator.approvals`
- `operator.pairing`
- `operator.read`
- `operator.write`

Notes:
- This is state repair, not package patching.
- Re-check after `openclaw doctor --fix`, gateway reinstall, device re-pair, or major version updates.
- If these files diverge again, align the operator token scopes with the paired device record and restart the gateway.

### 10) Telegram bundled setup-entry path repair (2026.4.7)
Reason:
- `2026.4.7` package ships `dist/extensions/telegram/setup-entry.js` with plugin specifier:
  - `./src/channel.setup.js`
- That file does not exist in bundle output, and can break config loading / gateway-backed commands.

Patch target:
- `/usr/lib/node_modules/openclaw/dist/extensions/telegram/setup-entry.js`

Required patched logic:
- `plugin.specifier = "./api.js"`
- `plugin.exportName = "telegramSetupPlugin"`

Verification:
- `openclaw gateway call health --timeout 25000 --json`
- `openclaw cron status --json`
- `openclaw security audit`

## Hotfix Archive Sync
After every successful hotfix + verification cycle, publish the current assets to:
- `https://github.com/jackykit0116/openclaw-hotfix.git`
- local backup mirror: `/home/github/openclaw-hotfix`
- one-way publish target: `https://github.com/KitJacky/openclaw-hotfix`

Secondary publish config source:
- `/home/github/.env`
- required keys:
  - `github_email`
  - `github_openclaw_hotfix_repo`
  - `github_primary_key` (for `jackykit0116`, optional fallback to `github_key`)
  - `github_secondary_classic_key` (for `KitJacky`, preferred when fine-grained PAT fails)
  - `github_secondary_key` (for `KitJacky`, optional fallback to `github_key`)
  - optional user overrides: `github_primary_user`, `github_secondary_user`

Required assets:
- `/root/.openclaw/workspace/HOTFIX-PLAYBOOK.md`
- `/root/.openclaw/workspace/HOTFIX-PLAYBOOK.zh-TW.md`
- `/root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh`

Archive rule:
- keep `latest/` as the newest verified snapshot
- keep `versions/<openclaw-version>/` for per-version reproducibility
- record `hotfix_version` and `updated_at` in `metadata/manifest.json`

Sync command:
- `bash /root/.openclaw/workspace/scripts/finalize-openclaw-hotfix-sync.sh`

Expected finalize behavior:
- commit/push snapshot to `jackykit0116/openclaw-hotfix`
- sync local mirror to `/home/github/openclaw-hotfix` (`rsync --delete`)
- push `main` one-way to `KitJacky/openclaw-hotfix`

## Automation Script
Use this script after every OpenClaw upgrade:
- `/root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh`

Modes:
- Check only:
  - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --check`
- Check + apply:
  - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --apply`

Notes:
- `--apply` must run as root.
- Script creates timestamped `.bak.hotfix-*` backups before patching files.
- Script is now version-aware for `2026.3.23-2` style bundles (`audit*.js`, `cron-cli-*.js`, `call-*.js` config load check).

## Standard Upgrade Workflow
1. Preview:
   - `openclaw update --dry-run --json`
2. Upgrade:
   - `npm i -g openclaw@latest`
3. Re-apply package hotfixes:
   - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --apply`
4. Ensure service override still exists:
   - `systemctl --user show openclaw-gateway.service -p DropInPaths -p Environment`
5. Restart:
   - `systemctl --user daemon-reload`
   - `systemctl --user restart openclaw-gateway.service`
   - `systemctl --user restart openclaw-node.service`
6. Final check:
   - `openclaw --version`
   - `systemctl --user is-active openclaw-gateway.service`
   - `openclaw gateway --help`
   - `openclaw cron status`
   - `openclaw cron run moltbook-blog-record --timeout 900000`
   - `openclaw security audit`

## 2026-03-24 Validation Snapshot
- Upgrade path verified:
  - `2026.3.13 (61d171a) -> 2026.3.23-2 (7ffe7e4)`
- On 2026-03-27, post-2026.3.23-2 baseline was tightened:
  - `/root/.openclaw` mode set to `700`
  - systemd service version strings aligned to `2026.3.23-2`
  - closed-system audit downgrade extended to `tools.exec.security_full_configured`
  - `openclaw security audit` => `0 critical · 0 warn · 7 info`
- Hotfix script verification after update:
  - `--apply` succeeded
  - `--check` returned all `OK`
- Runtime verification after re-apply:
  - `openclaw gateway --help` works
  - `openclaw cron status` returns JSON
  - `openclaw cron run 8888` enqueues normally
- Audit baseline after re-apply:
  - `0 critical · 1 warn · 6 info`

## Known Operational Notes
- `openclaw update --yes` may return `skipped` for package installs if package manager auto-detect fails.
  Use `npm i -g openclaw@latest` directly.
- On 2026-03-17, `openclaw update --yes` completed via npm package flow and upgraded:
  - `2026.3.12 -> 2026.3.13`
- On 2026-03-17, package hotfixes were successfully re-applied after upgrade:
  - small-model severity: OK
  - closed-system audit downgrade: OK
  - include_usage: OK
  - cron.run timeout guard: OK
- On 2026-03-17, additional CLI/gateway hotfix identified:
  - `openclaw gateway call cron.run --params '{"id":"8888","mode":"force"}' --json` succeeded
  - `openclaw cron run 8888` failed before patch with `gateway closed (1000 normal closure)`
  - root cause was missing `config` injection inside `callGatewayFromCli(...)`
  - patching `gateway-rpc-*.js` fixed `openclaw cron run ...`
- On 2026-03-17, local auth state drift was also observed:
  - paired device metadata included `operator.read` and `operator.write`
  - `/root/.openclaw/identity/device-auth.json` operator token scopes were missing both
  - after scope repair, `openclaw cron status` recovered
- On 2026-03-17, closed-system audit baseline became:
  - `0 critical · 0 warn · 6 info`
  - reverse-proxy warning removed by `gateway.trustedProxies = ["127.0.0.1/32", "::1/128"]`
- Doctor warning currently seen:
  - Telegram `groupPolicy=allowlist` with empty allow-list.
  - This is not part of hotfix failure, but should be handled in channel policy config.
- Gateway runtime baseline on 2026-03-16:
  - `openclaw-gateway.service` must be running.
  - `openclaw-node.service` must also be running and enabled.
  - Symptom if node host is missing:
    - `openclaw gateway status` may still look healthy.
    - but execution RPCs such as `openclaw cron run ...` fail with:
      - `gateway closed (1000 normal closure)`
  - Recovery sequence that worked:
    1. `openclaw gateway install --force`
    2. `openclaw gateway restart`
    3. `systemctl --user start openclaw-node.service`
    4. `systemctl --user enable openclaw-node.service`
    5. Verify with:
       - `openclaw gateway status --json`
       - `openclaw cron run <job-id> --timeout ...`
  - Note:
    - `openclaw gateway health` still returned `gateway closed (1000 normal closure)` even after runtime recovery.
    - Treat `cron run` as the stronger usability check on this host.
- Idle watchdog baseline on 2026-03-16:
  - `/root/.openclaw/workspace/scripts/check_idle.py` must read:
    - `/root/.openclaw/agents/main/sessions/sessions.json`
  - Do not depend on `openclaw sessions ... --json` for idle detection.
  - Reason:
    - gateway/CLI hiccups can yield empty output and trigger:
      - `Error checking idle: Expecting value: line 1 column 1 (char 0)`
    - idle status is local state and should not require gateway RPC.
- Website publish pipeline baseline on 2026-03-16:
  - `/root/.openclaw/workspace/scripts/validate_build.sh` is expected to do both steps:
    - local build validation
    - `/root/sync-website.sh` only after build success
  - Lightweight website validation layer added on 2026-03-17:
    - prefer `/root/.openclaw/workspace/scripts/validate_website_changes.sh --check-only` first
    - blog-only changes should be screened by `/root/.openclaw/workspace/scripts/validate_blog_entry.sh`
    - reserve `/root/.openclaw/workspace/scripts/validate_build.sh` for structural website changes or explicit publish/release moments
    - `/root/.openclaw/workspace/scripts/evolve_website.sh` should use the same path:
      - collect/sync content
      - lightweight validation
      - explicit publish build only when actually releasing
  - Current fallback behavior:
    - prefer `bun`
    - fallback to `npm` if `bun` is not installed
  - Verified good run on 2026-03-16:
    - Astro build succeeded
    - `561` pages built
    - sync completed to `/home/website`
  - Operational rule:
    - if a cron/job changes website content and validation passes, deploy path is `validate_build.sh -> /root/sync-website.sh`
    - do not call `/root/sync-website.sh` before a successful build
  - Build health check rule added on 2026-03-16:
    - `validate_build.sh` now captures the Astro build log to:
      - `/root/.openclaw/workspace/logs/website-build-latest.log`
    - and captures website sync log to:
      - `/root/.openclaw/workspace/logs/website-sync-latest.log`
    - Then runs:
      - `/root/.openclaw/workspace/scripts/build_health_check.sh`
    - Health check policy:
      - fail on known critical regressions such as duplicate content ids/slugs or hard build-regression signatures
      - report non-blocking warning classes such as tracked KaTeX/Shiki-style warnings
    - Context control policy:
      - build stdout must remain summary-only
      - inspect log files only when a fix is required
    - Verified good run on 2026-03-16:
      - build succeeded
      - health check passed with no tracked warnings
      - sync completed after health check
  - Website rendering tolerance rules added on 2026-03-16:
    - Goal: absorb inconsistent markdown generated by OpenClaw jobs at the website layer, not by relying on prompt hygiene.
    - File:
      - `/root/.openclaw/workspace/website/astro.config.mjs`
    - KaTeX rule:
      - `rehypeKatex` runs with `{ strict: 'ignore', throwOnError: false }`
      - Reason: legacy/generated posts may contain Unicode text inside math mode; build should not warn/fail on this.
    - Shiki alias rule:
      - `python3 -> python`
      - `cron -> plaintext`
      - `ignore -> plaintext`
      - Reason: generated code fences often use non-standard language ids; website layer should normalize them.
    - Verification status on 2026-03-16:
      - duplicate content id/slug warnings removed after content-path cleanup + Astro cache reset
      - KaTeX Unicode math warnings removed
      - Shiki `python3` / `cron` / `ignore` warnings removed
    - Remaining policy:
      - prefer fixing recurring generator patterns when practical
      - but website build must remain tolerant to historical content variance
- Moltbook auto-post failure pattern seen on 2026-03-14 to 2026-03-16:
  - Symptom: `moltbook-auto-post-runner` times out repeatedly at `420s`, no new post created.
  - Root cause 1: `fetch_rss_candidates()` used `printf ... | python3 <<'PY'`, so the heredoc consumed `stdin` and RSS XML never reached the parser correctly.
  - Root cause 2: RSS parser double-encoded text fields, causing `jq` failures such as `Cannot index string with string "total_score"`.
  - Fix applied in `/root/.openclaw/workspace/skills/moltbook/auto-post-moltbook.sh`:
    - Parse RSS from a temp file, not from a broken heredoc pipe.
    - Emit clean JSON objects with the real feed source name.
    - Enforce a long-form post structure: `Thesis`, `What changed`, `Scientific core`, `Philosophical tension`, `Practical takeaway`, `Why builders should care`, `Source trace`.
  - Job guard applied in `/root/.openclaw/cron/jobs.json`:
    - `moltbook-auto-post-runner.payload.timeoutSeconds = 900`
    - Message now instructs agent to execute exactly and avoid exploratory debugging unless the command fails.
- Website content warning currently seen during Astro build:
  - Build succeeds, but Astro reports duplicate content IDs/slugs in `src/content/blog`.
  - Current confirmed duplicates on 2026-03-16:
    - `2026-02-27-conversational-ux-architecture-agentic-systems`
    - `2026-03-01-openclaw-zero-trust-agent-security-architecture-zh-tw`
    - `openclaw-vector-memory-enterprise-2026-zh-tw`
  - Risk:
    - content loader collisions
    - later entry may shadow earlier entry
    - routing and RSS consistency can drift
  - This is not a build blocker, but it is a publishing-quality issue and should be cleaned before adding more posts on the same themes.

## Files Managed by Us (Persistent)
These usually survive OpenClaw package upgrades:
- `/root/.openclaw/openclaw.json`
- `/root/.openclaw/cron/jobs.json`
- `/root/.openclaw/workspace/scripts/*.sh`
- `/root/.config/systemd/user/openclaw-gateway.service.d/*.conf`

## Files Likely Overwritten by Upgrades
These are package internals and must be rechecked every upgrade:
- `/usr/lib/node_modules/openclaw/dist/*.js`
- `/usr/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/openai-completions.js`

## Incident Quick Triage
If behavior regresses after upgrade:
1. Run hotfix check:
   - `bash /root/.openclaw/workspace/scripts/openclaw-post-update-hotfix.sh --check`
2. If failed, run apply mode.
3. Confirm gateway drop-in override still exists:
   - `systemctl --user show openclaw-gateway.service -p DropInPaths -p Environment`
4. Restart gateway/node.
5. Re-test one cron run manually:
   - `openclaw cron run <job-id> --timeout 240000`

## 2026-03-17: Gateway RPC Handshake Timeout Hotfix
- Symptom:
  - `openclaw gateway call health` fails with:
    - `gateway closed (1000 normal closure)`
  - `openclaw cron run <job-id>` fails the same way.
  - `openclaw cron status`, `cron runs`, and `gateway health --json` may still work.
- What this means:
  - Jobs and `cron/jobs.json` may be healthy.
  - The failure can sit in the generic Gateway RPC CLI path, not in the job definition itself.
- Verified non-root-causes on 2026-03-17:
  - `gateway.auth.token` missing was not the cause.
  - adding explicit `--token` did not fix `cron run`.
  - temporary patching of `/usr/lib/node_modules/openclaw/dist/gateway-rpc-*.js` was not required for the final fix.
- Updated effective hotfix on 2026-03-17:
  - Patch installed runtime files instead of relying only on a service drop-in.
  - Runtime changes:
    - `gateway-cli-*.js`
      - increase default handshake timeout from `3e3` to `15e3`
      - allow env override via `OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS`
    - `auth-profiles-*.js`
      - wrap `os.networkInterfaces()` inside `pickPrimaryLanIPv4()` with `try/catch`
  - Then run:
    - `systemctl --user restart openclaw-gateway.service`
- Result verified on 2026-03-17:
  - `openclaw gateway --help` returned normally
  - `openclaw cron status` returned JSON
  - `openclaw cron run moltbook-auto-reply-runner` returned:
    - `{"ok":true,"enqueued":true,"runId":"manual:moltbook-auto-reply-runner:1773745502033:1"}`
  - `/root/.openclaw/cron/jobs.json` showed:
    - `runningAtMs: 1773745502062`
- Remaining caveat:
  - `openclaw gateway call cron.run ...` still showed:
    - `gateway closed (1006 abnormal closure (no close frame))`
  - So this hotfix restores the main manual cron entrypoint, but does not fully clear every gateway client path.
- Operational note:
  - This is a service-level hotfix for the installed Gateway package.
  - Re-check after any OpenClaw upgrade or service reinstall.

## 2026-03-17: Three-Day Blog Analysis Delivery Regression
- Symptom after upgrade/runtime changes:
  - job run completed analysis work
  - final status still became `error`
  - error:
    - `Unsupported channel: telegram`
- Root cause:
  - delivery/announce path is not a reliable success criterion for this retrospective job
- Fix:
  - in `/root/.openclaw/cron/jobs.json`
  - job id `3095001f-8aef-4792-ba82-043a8a1e5230`
  - set:
    - `delivery.mode = "none"`
- Reason:
  - preserve retrospective execution result even when outbound announce channel is unsupported

- On 2026-03-27, upgrade to `2026.3.24 (cff6dc9)` completed successfully:
  - hotfixes re-applied
  - `method-scopes-*.js` handshake timeout patched to `15e3`
  - `openclaw-post-update-hotfix.sh --check` returned all OK
  - `openclaw security audit` => `0 critical · 0 warn · 7 info`
