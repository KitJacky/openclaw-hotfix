#!/usr/bin/env bash
# Verify/re-apply OpenClaw post-update hotfixes.
# Usage:
#   bash openclaw-post-update-hotfix.sh --check
#   bash openclaw-post-update-hotfix.sh --apply

set -euo pipefail

MODE="${1:---check}"
OPENCLAW_ROOT="/usr/lib/node_modules/openclaw"
DIST_DIR="${OPENCLAW_ROOT}/dist"
OPENCLAW_CONFIG="/root/.openclaw/openclaw.json"
PROVIDER_FILE="${OPENCLAW_ROOT}/node_modules/@mariozechner/pi-ai/dist/providers/openai-completions.js"
WEB_SEARCH_RUNTIME_FILE=""
HOTFIX_VERSION="2026.04.17.1"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || { log "missing file: $f"; exit 1; }
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "missing command: $1"; exit 1; }
}

retry_quiet() {
  local attempts="$1"
  shift
  local i=1
  while (( i <= attempts )); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    ((i++))
  done
  return 1
}

list_audit_files() {
  ls -1 "${DIST_DIR}"/audit*.js 2>/dev/null || true
}

find_web_search_runtime_file() {
  rg -l 'async function runWebSearch\(params\)' "${DIST_DIR}"/runtime-*.js 2>/dev/null | head -n 1
}

resolve_web_search_runtime_file() {
  if [[ -n "${WEB_SEARCH_RUNTIME_FILE}" && -f "${WEB_SEARCH_RUNTIME_FILE}" ]]; then
    return 0
  fi
  WEB_SEARCH_RUNTIME_FILE="$(find_web_search_runtime_file)"
  [[ -n "${WEB_SEARCH_RUNTIME_FILE}" && -f "${WEB_SEARCH_RUNTIME_FILE}" ]] || {
    log "web_search runtime bundle not found"
    return 1
  }
}

find_reply_file() {
  ls -1t "${DIST_DIR}"/reply-*.js 2>/dev/null | head -n 1
}

find_cron_cli_file() {
  ls -1t "${DIST_DIR}"/cron-cli-*.js 2>/dev/null | head -n 1
}

find_gateway_cli_file() {
  ls -1t "${DIST_DIR}"/gateway-cli-*.js 2>/dev/null | head -n 1
}

find_client_file() {
  rg -l 'DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS|OPENCLAW_HANDSHAKE_TIMEOUT_MS' "${DIST_DIR}"/client-*.js 2>/dev/null | head -n 1
}

backup_file() {
  local f="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp "$f" "${f}.bak.hotfix-${ts}"
}

check_small_model_hotfix() {
  local files=()
  mapfile -t files < <(list_audit_files)
  [[ ${#files[@]} -gt 0 ]] || { log "audit bundle not found"; return 1; }
  if rg -q 'severity:\s*hasUnsafe\s*\?\s*"critical"\s*:\s*"info"' "${files[@]}"; then
    return 1
  fi
  return 0
}

check_closed_system_audit_hotfix() {
  local files=()
  mapfile -t files < <(list_audit_files)
  [[ ${#files[@]} -gt 0 ]] || { log "audit bundle not found"; return 1; }

  rg -U -q 'checkId:\s*"models\.weak_tier",\n\s*severity:\s*"info"' "${files[@]}" \
    && rg -U -q 'checkId:\s*"gateway\.control_ui\.insecure_auth",\n\s*severity:\s*"info"' "${files[@]}" \
    && rg -U -q 'checkId:\s*"config\.insecure_or_dangerous_flags",\n\s*severity:\s*"info"' "${files[@]}" \
    && rg -U -q 'checkId:\s*"tools\.exec\.safe_bin_trusted_dirs_risky",\n\s*severity:\s*"info"' "${files[@]}" \
    && rg -U -q 'checkId:\s*"tools\.exec\.security_full_configured",\n\s*severity:\s*"info"' "${files[@]}" \
    && rg -U -q 'checkId:\s*"tools\.exec\.safe_bins_broad_behavior",\n\s*severity:\s*"info"' "${files[@]}"
}

check_include_usage_hotfix() {
  require_file "$PROVIDER_FILE"
  rg -q 'stream_options\s*=\s*\{\s*include_usage:\s*true\s*\}' "$PROVIDER_FILE" \
    && ! rg -q 'if \(compat\.supportsUsageInStreaming !== false\)' "$PROVIDER_FILE"
}

check_llm_idle_timeout_hotfix() {
  require_file "$OPENCLAW_CONFIG"
  python3 - "$OPENCLAW_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
value = (
    data.get("agents", {})
    .get("defaults", {})
    .get("llm", {})
    .get("idleTimeoutSeconds")
)
sys.exit(0 if isinstance(value, int) and value >= 900 else 1)
PY
}

check_thinking_default_hotfix() {
  require_file "$OPENCLAW_CONFIG"
  python3 - "$OPENCLAW_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
value = (
    data.get("agents", {})
    .get("defaults", {})
    .get("thinkingDefault")
)
sys.exit(0 if value == "low" else 1)
PY
}

check_cron_run_timeout_hotfix() {
  local cron_file
  cron_file="$(find_cron_cli_file)"
  if [[ -n "$cron_file" ]]; then
    rg -q 'command\.getOptionValueSource\("timeout"\)\s*===\s*"default"\)\s*opts\.timeout\s*=\s*"(600000|900000)"' "$cron_file"
    return $?
  fi

  local reply_file
  reply_file="$(find_reply_file)"
  [[ -n "$reply_file" ]] || { log "reply/cron-cli bundle not found"; return 1; }
  rg -q 'callGateway\("cron\.run", runOpts' "$reply_file"
}

check_gateway_rpc_config_hotfix() {
  local rpc_files=() call_files=()
  mapfile -t rpc_files < <(ls -1 "${DIST_DIR}"/gateway-rpc-*.js 2>/dev/null || true)
  if [[ ${#rpc_files[@]} -gt 0 ]]; then
    if rg -q 'const config = opts\.config \?\? await readBestEffortConfig\(\);' "${rpc_files[@]}" && rg -q 'config,' "${rpc_files[@]}"; then
      return 0
    fi
  fi

  mapfile -t call_files < <(ls -1 "${DIST_DIR}"/call-*.js 2>/dev/null || true)
  if [[ ${#call_files[@]} -gt 0 ]]; then
    if rg -q 'const config = options\.config \?\? gatewayCallDeps\.loadConfig\(\);' "${call_files[@]}"; then
      return 0
    fi
    if rg -q 'canSkipGatewayConfigLoad' "${call_files[@]}" \
      && rg -q 'loadGatewayConfig\(\)' "${call_files[@]}" \
      && rg -q 'const config = opts\.config \?\? \(canSkipConfigLoad \? \{\} : loadGatewayConfig\(\)\);' "${call_files[@]}"; then
      return 0
    fi
  fi

  if retry_quiet 3 openclaw cron status --json && retry_quiet 3 openclaw gateway call health --timeout 20000 --json; then
    return 0
  fi

  log "gateway-rpc compatible call path not confirmed"
  return 1
}

check_gateway_handshake_runtime_hotfix() {
  local client_file gateway_file
  client_file="$(find_client_file)"
  gateway_file="$(find_gateway_cli_file)"

  [[ -n "$client_file" ]] || { log "client bundle not found"; return 1; }
  [[ -n "$gateway_file" ]] || { log "gateway-cli bundle not found"; return 1; }

  rg -q 'const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3;' "$client_file" \
    && rg -q 'OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS \|\| env\.OPENCLAW_HANDSHAKE_TIMEOUT_MS' "$client_file" \
    && rg -q 'option\("--timeout <ms>", "Timeout in ms", "15000"\)' "$gateway_file"
}

check_web_search_provider_fallback_hotfix() {
  resolve_web_search_runtime_file || return 1
  require_file "$WEB_SEARCH_RUNTIME_FILE"
  rg -q 'resolveWebSearchCooldownMs' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -q 'enqueueWebSearchWithCooldown' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -q 'OPENCLAW_WEB_SEARCH_COOLDOWN_MS' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -q 'const allowFallback = candidates\.length > 1;' "$WEB_SEARCH_RUNTIME_FILE"
}

check_telegram_setup_entry_hotfix() {
  local setup_entry_file="${DIST_DIR}/extensions/telegram/setup-entry.js"
  [[ -f "$setup_entry_file" ]] || return 0
  if rg -q 'specifier:\s*"\./setup-plugin-api\.js"' "$setup_entry_file" \
    && rg -q 'specifier:\s*"\./secret-contract-api\.js"' "$setup_entry_file" \
    && rg -q 'exportName:\s*"telegramSetupPlugin"' "$setup_entry_file"; then
    return 0
  fi
  rg -q 'specifier:\s*"\./api\.js"' "$setup_entry_file" \
    && rg -q 'exportName:\s*"telegramSetupPlugin"' "$setup_entry_file"
}

apply_small_model_hotfix() {
  local files=()
  mapfile -t files < <(list_audit_files)
  [[ ${#files[@]} -gt 0 ]] || { log "audit bundle not found"; return 1; }
  for f in "${files[@]}"; do
    backup_file "$f"
  done
  perl -0777 -i -pe 's/severity:\s*hasUnsafe\s*\?\s*"critical"\s*:\s*"info"/severity: "info"/g' "${files[@]}"
}

apply_closed_system_audit_hotfix() {
  local files=()
  mapfile -t files < <(list_audit_files)
  [[ ${#files[@]} -gt 0 ]] || { log "audit bundle not found"; return 1; }
  for f in "${files[@]}"; do
    backup_file "$f"
  done
  perl -0777 -i -pe 's/(checkId:\s*"models\.weak_tier",\s*severity:\s*)"warn"/${1}"info"/g; s/(checkId:\s*"gateway\.control_ui\.insecure_auth",\s*severity:\s*)"warn"/${1}"info"/g; s/(checkId:\s*"config\.insecure_or_dangerous_flags",\s*severity:\s*)"warn"/${1}"info"/g; s/(checkId:\s*"tools\.exec\.safe_bin_trusted_dirs_risky",\s*severity:\s*)"warn"/${1}"info"/g; s/(checkId:\s*"tools\.exec\.security_full_configured",\s*severity:\s*)(openExecSurfacePaths\.length > 0 \? "critical" : "warn"|"warn")/${1}"info"/g; s/(checkId:\s*"tools\.exec\.safe_bins_broad_behavior",\s*severity:\s*)"warn"/${1}"info"/g' "${files[@]}"
}

apply_cron_run_timeout_hotfix() {
  local cron_file
  cron_file="$(find_cron_cli_file)"
  if [[ -n "$cron_file" ]]; then
    backup_file "$cron_file"
    perl -0777 -i -pe 's/command\.getOptionValueSource\("timeout"\)\s*===\s*"default"\)\s*opts\.timeout\s*=\s*"(?:600000|900000)"/command.getOptionValueSource("timeout") === "default") opts.timeout = "900000"/g' "$cron_file"
    return 0
  fi

  local reply_file
  reply_file="$(find_reply_file)"
  [[ -n "$reply_file" ]] || { log "reply bundle not found"; return 1; }
  backup_file "$reply_file"
  perl -0777 -i -pe 's/return jsonResult\(await callGateway\("cron\.run", gatewayOpts, \{\n\s*id,\n\s*mode: params\.runMode === "due" \|\| params\.runMode === "force" \? params\.runMode : "force"\n\s*\}\)\);/const runOpts = { ...gatewayOpts, timeoutMs: Math.max(gatewayOpts.timeoutMs ?? 0, 15 * 6e4) };\n\t\t\t\t\treturn jsonResult(await callGateway("cron.run", runOpts, {\n\t\t\t\t\t\tid,\n\t\t\t\t\t\tmode: params.runMode === "due" || params.runMode === "force" ? params.runMode : "force"\n\t\t\t\t\t}));/s' "$reply_file"
}

apply_include_usage_hotfix() {
  require_file "$PROVIDER_FILE"
  backup_file "$PROVIDER_FILE"
  perl -0777 -i -pe 's/\n\s*if \(compat\.supportsUsageInStreaming !== false\) \{\n\s*params\.stream_options = \{ include_usage: true \};\n\s*\}/\n    params.stream_options = { include_usage: true };/s' "$PROVIDER_FILE"
}

apply_llm_idle_timeout_hotfix() {
  require_file "$OPENCLAW_CONFIG"
  backup_file "$OPENCLAW_CONFIG"
  python3 - "$OPENCLAW_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
llm = defaults.setdefault("llm", {})
current = llm.get("idleTimeoutSeconds")

if not isinstance(current, int) or current < 900:
    llm["idleTimeoutSeconds"] = 900

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
}

apply_thinking_default_hotfix() {
  require_file "$OPENCLAW_CONFIG"
  backup_file "$OPENCLAW_CONFIG"
  python3 - "$OPENCLAW_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults["thinkingDefault"] = "low"
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
}

apply_gateway_handshake_runtime_hotfix() {
  local client_file gateway_file
  client_file="$(find_client_file)"
  gateway_file="$(find_gateway_cli_file)"
  [[ -n "$client_file" ]] || { log "client bundle not found"; return 1; }
  [[ -n "$gateway_file" ]] || { log "gateway-cli bundle not found"; return 1; }

  backup_file "$client_file"
  backup_file "$gateway_file"

  perl -0777 -i -pe 's/const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 1e4;/const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3;/g; s/env\.OPENCLAW_HANDSHAKE_TIMEOUT_MS \|\| env\.VITEST && env\.OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS/env.OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS || env.OPENCLAW_HANDSHAKE_TIMEOUT_MS || env.VITEST && env.OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS/g' "$client_file"
  perl -0777 -i -pe 's/option\("--timeout <ms>", "Timeout in ms", "10000"\)/option("--timeout <ms>", "Timeout in ms", "15000")/g' "$gateway_file"
}

apply_web_search_provider_fallback_hotfix() {
  resolve_web_search_runtime_file || return 1
  require_file "$WEB_SEARCH_RUNTIME_FILE"
  backup_file "$WEB_SEARCH_RUNTIME_FILE"

  if ! rg -q 'resolveWebSearchCooldownMs' "$WEB_SEARCH_RUNTIME_FILE"; then
    python3 - "$WEB_SEARCH_RUNTIME_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
needle = "async function runWebSearch(params) {"
insert = """const WEB_SEARCH_COOLDOWN_MS_MIN = 1e3;
const WEB_SEARCH_COOLDOWN_MS_MAX = 5e3;
const WEB_SEARCH_COOLDOWN_MS_DEFAULT = 2e3;
const webSearchProviderLastRequestAt = /* @__PURE__ */ new Map();
const webSearchProviderQueue = /* @__PURE__ */ new Map();
function resolveWebSearchCooldownMs() {
\tconst rawMs = Number.parseInt(process.env.OPENCLAW_WEB_SEARCH_COOLDOWN_MS ?? "", 10);
\tif (Number.isFinite(rawMs) && rawMs >= WEB_SEARCH_COOLDOWN_MS_MIN) return Math.min(rawMs, WEB_SEARCH_COOLDOWN_MS_MAX);
\tconst rawSec = Number.parseInt(process.env.OPENCLAW_WEB_SEARCH_COOLDOWN_SECONDS ?? "", 10);
\tif (Number.isFinite(rawSec) && rawSec >= 1) return Math.min(rawSec * 1e3, WEB_SEARCH_COOLDOWN_MS_MAX);
\treturn WEB_SEARCH_COOLDOWN_MS_DEFAULT;
}
async function enqueueWebSearchWithCooldown(providerId, execute) {
\tconst previous = webSearchProviderQueue.get(providerId) ?? Promise.resolve();
\tconst run = previous.catch(() => void 0).then(async () => {
\t\tconst cooldownMs = resolveWebSearchCooldownMs();
\t\tconst now = Date.now();
\t\tconst lastAt = webSearchProviderLastRequestAt.get(providerId) ?? 0;
\t\tconst waitMs = lastAt + cooldownMs - now;
\t\tif (waitMs > 0) await new Promise((resolve) => setTimeout(resolve, waitMs));
\t\tconst result = await execute();
\t\twebSearchProviderLastRequestAt.set(providerId, Date.now());
\t\treturn result;
\t});
\twebSearchProviderQueue.set(providerId, run.then(() => void 0, () => void 0));
\treturn run;
}
async function runWebSearch(params) {"""
if needle in text and "resolveWebSearchCooldownMs" not in text:
    text = text.replace(needle, insert, 1)
path.write_text(text)
PY
  fi

  perl -0777 -i -pe 's/const allowFallback = !hasExplicitWebSearchSelection\(\{\n\t\tsearch,\n\t\truntimeWebSearch,\n\t\tproviderId: params\.providerId,\n\t\tproviders: candidates\n\t\}\);/const allowFallback = candidates.length > 1;/s; s/result: await definition\.execute\(params\.args\)/result: await enqueueWebSearchWithCooldown(candidate.id, () => definition.execute(params.args))/g' "$WEB_SEARCH_RUNTIME_FILE"
}

apply_telegram_setup_entry_hotfix() {
  local setup_entry_file="${DIST_DIR}/extensions/telegram/setup-entry.js"
  [[ -f "$setup_entry_file" ]] || return 0
  if rg -q 'specifier:\s*"\./setup-plugin-api\.js"' "$setup_entry_file" \
    && rg -q 'specifier:\s*"\./secret-contract-api\.js"' "$setup_entry_file"; then
    return 0
  fi
  backup_file "$setup_entry_file"
  perl -0777 -i -pe 's/specifier:\s*"\.\/src\/channel\.setup\.js",\s*exportName:\s*"telegramSetupPlugin"/specifier: ".\/api.js",\n\t\texportName: "telegramSetupPlugin"/g; s/specifier:\s*"\.\/channel-plugin-api\.js",\s*exportName:\s*"telegramSetupPlugin"/specifier: ".\/api.js",\n\t\texportName: "telegramSetupPlugin"/g' "$setup_entry_file"
}

print_check_summary() {
  local small_status usage_status idle_timeout_status thinking_default_status cron_status closed_audit_status gateway_rpc_status gateway_handshake_status web_search_fallback_status telegram_setup_entry_status
  small_status="FAIL"
  usage_status="FAIL"
  idle_timeout_status="FAIL"
  thinking_default_status="FAIL"
  cron_status="FAIL"
  closed_audit_status="FAIL"
  gateway_rpc_status="FAIL"
  gateway_handshake_status="FAIL"
  web_search_fallback_status="FAIL"
  telegram_setup_entry_status="FAIL"

  check_small_model_hotfix && small_status="OK"
  check_include_usage_hotfix && usage_status="OK"
  check_llm_idle_timeout_hotfix && idle_timeout_status="OK"
  check_thinking_default_hotfix && thinking_default_status="OK"
  check_cron_run_timeout_hotfix && cron_status="OK"
  check_closed_system_audit_hotfix && closed_audit_status="OK"
  check_gateway_rpc_config_hotfix && gateway_rpc_status="OK"
  check_gateway_handshake_runtime_hotfix && gateway_handshake_status="OK"
  check_web_search_provider_fallback_hotfix && web_search_fallback_status="OK"
  check_telegram_setup_entry_hotfix && telegram_setup_entry_status="OK"

  log "OpenClaw version: $(openclaw --version 2>/dev/null || echo unknown)"
  log "Hotfix version: ${HOTFIX_VERSION}"
  log "small-model severity hotfix: ${small_status}"
  log "closed-system audit hotfix: ${closed_audit_status}"
  log "include_usage hotfix: ${usage_status}"
  log "LLM idle timeout hotfix: ${idle_timeout_status}"
  log "thinkingDefault hotfix: ${thinking_default_status}"
  log "cron.run timeout hotfix: ${cron_status}"
  log "gateway-rpc config hotfix: ${gateway_rpc_status}"
  log "gateway handshake/runtime hotfix: ${gateway_handshake_status}"
  log "web_search fallback+cooldown hotfix: ${web_search_fallback_status}"
  log "telegram setup-entry hotfix: ${telegram_setup_entry_status}"

  [[ "$small_status" == "OK" && "$closed_audit_status" == "OK" && "$usage_status" == "OK" && "$idle_timeout_status" == "OK" && "$thinking_default_status" == "OK" && "$cron_status" == "OK" && "$gateway_rpc_status" == "OK" && "$gateway_handshake_status" == "OK" && "$web_search_fallback_status" == "OK" && "$telegram_setup_entry_status" == "OK" ]]
}

main() {
  require_cmd rg
  require_cmd perl
  require_cmd openclaw

  case "$MODE" in
    --check)
      if print_check_summary; then
        log "all hotfix checks passed"
      else
        log "one or more hotfix checks failed"
        exit 2
      fi
      ;;
    --apply)
      if [[ "$(id -u)" -ne 0 ]]; then
        log "--apply requires root privileges"
        exit 1
      fi

      if ! check_small_model_hotfix; then
        log "re-applying small-model severity hotfix"
        apply_small_model_hotfix
      fi
      if ! check_closed_system_audit_hotfix; then
        log "re-applying closed-system audit hotfix"
        apply_closed_system_audit_hotfix
      fi
      if ! check_cron_run_timeout_hotfix; then
        log "re-applying cron.run timeout hotfix"
        apply_cron_run_timeout_hotfix
      fi
      if ! check_include_usage_hotfix; then
        log "re-applying include_usage hotfix"
        apply_include_usage_hotfix
      fi
      if ! check_llm_idle_timeout_hotfix; then
        log "re-applying LLM idle timeout hotfix"
        apply_llm_idle_timeout_hotfix
      fi
      if ! check_thinking_default_hotfix; then
        log "re-applying thinkingDefault hotfix"
        apply_thinking_default_hotfix
      fi
      if ! check_gateway_handshake_runtime_hotfix; then
        log "re-applying gateway handshake/runtime hotfix"
        apply_gateway_handshake_runtime_hotfix
      fi
      if ! check_web_search_provider_fallback_hotfix; then
        log "re-applying web_search fallback+cooldown hotfix"
        apply_web_search_provider_fallback_hotfix
      fi
      if ! check_telegram_setup_entry_hotfix; then
        log "re-applying telegram setup-entry hotfix"
        apply_telegram_setup_entry_hotfix
      fi

      print_check_summary
      log "apply complete"
      ;;
    *)
      echo "Usage: bash openclaw-post-update-hotfix.sh [--check|--apply]"
      exit 1
      ;;
  esac
}

main "$@"
