# openclaw-hotfix

Versioned OpenClaw hotfix assets for reproducible post-update recovery.

## English
This repository tracks OpenClaw post-update hotfix snapshots.
This page only lists hotfix topics. Full details are in the latest playbooks:
- EN: [latest/HOTFIX-PLAYBOOK.md](latest/HOTFIX-PLAYBOOK.md)
- zh-TW: [latest/HOTFIX-PLAYBOOK.zh-TW.md](latest/HOTFIX-PLAYBOOK.zh-TW.md)

Hotfix topics:
- Small-model audit severity downgrade (closed-system posture)
- OpenAI streaming usage include (include_usage)
- cron.run timeout guard (15 minutes)
- Closed-system audit downgrade set
- CLI gateway RPC config compatibility
- Gateway handshake/runtime stability patch
- web_search provider fallback (Brave -> Tavily)
- web_search per-provider cooldown (1-5s) to reduce 429
- Local state/auth scope recovery notes
- Hotfix archival + one-way publish workflow

Project links:
- Cheese Cat 🐯 OpenClaw · Public Interface: https://cheesecat.net
- Jacky Kit: https://jackykit.com
- Donate: https://cheesecat.net/donate

## 繁體中文（zh-TW）
此倉庫用於保存 OpenClaw 升級後 hotfix 的版本快照。
此頁只列出 hotfix 主題，完整內容請見最新手冊：
- 英文版：[latest/HOTFIX-PLAYBOOK.md](latest/HOTFIX-PLAYBOOK.md)
- 繁中版：[latest/HOTFIX-PLAYBOOK.zh-TW.md](latest/HOTFIX-PLAYBOOK.zh-TW.md)

Hotfix 主題：
- Small-model audit 嚴重度調整（封閉系統姿態）
- OpenAI 串流 usage 強制帶回（include_usage）
- cron.run 15 分鐘 timeout 防護
- 封閉系統 audit 降級集合
- CLI gateway RPC 相容性修補
- Gateway handshake/runtime 穩定性修補
- web_search 供應商備援（Brave -> Tavily）
- web_search 供應商冷卻（1-5 秒）降低 429
- 本地 state/auth scope 修復與檢查
- Hotfix 歸檔與單向發布流程

Current snapshot:
- OpenClaw: 2026.4.7
- Hotfix: 2026.04.08.5
- Updated: 2026-04-08T07:59:39Z
- Owner / Contact: Jacky Kit - https://jackykit.com
