#!/usr/bin/env bash
# Verify/re-apply OpenClaw post-update hotfixes.
# Usage:
#   bash openclaw-post-update-hotfix.sh --check
#   bash openclaw-post-update-hotfix.sh --apply

set -euo pipefail

MODE="${1:---check}"
OPENCLAW_ROOT="/usr/lib/node_modules/openclaw"
DIST_DIR="${OPENCLAW_ROOT}/dist"
PROVIDER_FILE="${OPENCLAW_ROOT}/node_modules/@mariozechner/pi-ai/dist/providers/openai-completions.js"
WEB_SEARCH_RUNTIME_FILE="${DIST_DIR}/runtime-BiQlOaAl.js"
HOTFIX_VERSION="2026.04.01.3"
HOTFIX_REPO_URL="https://github.com/jackykit0116/openclaw-hotfix.git"

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

find_reply_file() {
  ls -1t "${DIST_DIR}"/reply-*.js 2>/dev/null | head -n 1
}

find_cron_cli_file() {
  ls -1t "${DIST_DIR}"/cron-cli-*.js 2>/dev/null | head -n 1
}

check_cron_run_timeout_hotfix() {
  local cron_file
  cron_file="$(find_cron_cli_file)"
  if [[ -n "$cron_file" ]]; then
    # Newer builds set cron run default timeout in cron-cli directly.
    rg -q 'command\.getOptionValueSource\("timeout"\)\s*===\s*"default"\)\s*opts\.timeout\s*=\s*"900000"' "$cron_file"
    return $?
  fi

  # Legacy fallback: patched in reply bundle.
  local reply_file
  reply_file="$(find_reply_file)"
  [[ -n "$reply_file" ]] || { log "reply/cron-cli bundle not found"; return 1; }
  rg -q 'callGateway\("cron\.run", runOpts' "$reply_file"
}

check_gateway_rpc_config_hotfix() {
  local rpc_files=() auth_profile_files=() call_files=()
  mapfile -t rpc_files < <(ls -1 "${DIST_DIR}"/gateway-rpc-*.js 2>/dev/null || true)
  if [[ ${#rpc_files[@]} -gt 0 ]]; then
    if rg -q 'const config = opts\.config \?\? await readBestEffortConfig\(\);' "${rpc_files[@]}" && rg -q 'config,' "${rpc_files[@]}"; then
      return 0
    fi
  fi

  mapfile -t call_files < <(ls -1 "${DIST_DIR}"/call-*.js 2>/dev/null || true)
  if [[ ${#call_files[@]} -gt 0 ]] && rg -q 'const config = options\.config \?\? gatewayCallDeps\.loadConfig\(\);' "${call_files[@]}"; then
    return 0
  fi

  mapfile -t auth_profile_files < <(ls -1 "${DIST_DIR}"/auth-profiles-*.js 2>/dev/null || true)
  if [[ ${#auth_profile_files[@]} -gt 0 ]]; then
    if retry_quiet 3 openclaw cron status --json && retry_quiet 3 openclaw gateway call health --timeout 20000 --json; then
      return 0
    fi
  fi

  log "gateway-rpc compatible call path not confirmed"
  return 1
}

check_gateway_handshake_runtime_hotfix() {
  local gateway_files=() method_files=()
  mapfile -t method_files < <(ls -1 "${DIST_DIR}"/method-scopes-*.js 2>/dev/null || true)
  if [[ ${#method_files[@]} -gt 0 ]]; then
    rg -q 'const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3;' "${method_files[@]}"       && rg -q 'OPENCLAW_HANDSHAKE_TIMEOUT_MS' "${method_files[@]}"       && rg -q 'OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS' "${method_files[@]}"
    return $?
  fi

  mapfile -t gateway_files < <(ls -1 "${DIST_DIR}"/gateway-cli-*.js 2>/dev/null || true)
  [[ ${#gateway_files[@]} -gt 0 ]] || { log "gateway-cli bundle not found"; return 1; }
  rg -q 'const DEFAULT_HANDSHAKE_TIMEOUT_MS = 15e3;' "${gateway_files[@]}"     && (rg -q 'OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS' "${gateway_files[@]}" || rg -q 'OPENCLAW_HANDSHAKE_TIMEOUT_MS' "${gateway_files[@]}")     && rg -q 'OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS' "${gateway_files[@]}"
}

check_web_search_provider_fallback_hotfix() {
  require_file "$WEB_SEARCH_RUNTIME_FILE"
  rg -q 'web_search primary provider failed' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -F -q 'const fallbackProviders = sortWebSearchProvidersForAutoDetect(resolveRuntimeWebSearchProviders({' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -q 'resolveWebSearchCooldownMs' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -q 'enqueueWebSearchWithCooldown' "$WEB_SEARCH_RUNTIME_FILE" \
    && rg -q 'OPENCLAW_WEB_SEARCH_COOLDOWN_MS' "$WEB_SEARCH_RUNTIME_FILE"
}


backup_file() {
  local f="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp "$f" "${f}.bak.hotfix-${ts}"
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

apply_gateway_handshake_runtime_hotfix() {
  local method_files=() gateway_files=()
  mapfile -t method_files < <(ls -1 "${DIST_DIR}"/method-scopes-*.js 2>/dev/null || true)
  if [[ ${#method_files[@]} -gt 0 ]]; then
    for f in "${method_files[@]}"; do
      backup_file "$f"
    done
    perl -0777 -i -pe 's/const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 1e4;/const DEFAULT_PREAUTH_HANDSHAKE_TIMEOUT_MS = 15e3;/g' "${method_files[@]}"
    return 0
  fi

  mapfile -t gateway_files < <(ls -1 "${DIST_DIR}"/gateway-cli-*.js 2>/dev/null || true)
  [[ ${#gateway_files[@]} -gt 0 ]] || { log "gateway-cli bundle not found"; return 1; }
  for f in "${gateway_files[@]}"; do
    backup_file "$f"
  done
  perl -0777 -i -pe 's/const DEFAULT_HANDSHAKE_TIMEOUT_MS = 1e4;/const DEFAULT_HANDSHAKE_TIMEOUT_MS = 15e3;/g; s/process\.env\.OPENCLAW_HANDSHAKE_TIMEOUT_MS \|\| process\.env\.VITEST && process\.env\.OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS/process.env.OPENCLAW_GATEWAY_HANDSHAKE_TIMEOUT_MS || process.env.OPENCLAW_HANDSHAKE_TIMEOUT_MS || process.env.VITEST && process.env.OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS/g' "${gateway_files[@]}"
}

apply_web_search_provider_fallback_hotfix() {
  require_file "$WEB_SEARCH_RUNTIME_FILE"
  backup_file "$WEB_SEARCH_RUNTIME_FILE"
  # Step 1: ensure provider fallback exists (legacy upstream -> fallback patch).
  perl -0777 -i -pe 's/async function runWebSearch\(params\) \{\n\tconst resolved = resolveWebSearchDefinition\(\{\n\t\t\.\.\.params,\n\t\tpreferRuntimeProviders: true\n\t\}\);\n\tif \(!resolved\) throw new Error\("web_search is disabled or no provider is available\."\);\n\treturn \{\n\t\tprovider: resolved\.provider\.id,\n\t\tresult: await resolved\.definition\.execute\(params\.args\)\n\t\};\n\}/async function runWebSearch(params) {\n\tconst resolved = resolveWebSearchDefinition({\n\t\t...params,\n\t\tpreferRuntimeProviders: true\n\t});\n\tif (!resolved) throw new Error(\"web_search is disabled or no provider is available.\");\n\ttry {\n\t\treturn {\n\t\t\tprovider: resolved.provider.id,\n\t\t\tresult: await resolved.definition.execute(params.args)\n\t\t};\n\t} catch (primaryError) {\n\t\tconst fallbackProviders = sortWebSearchProvidersForAutoDetect(resolveRuntimeWebSearchProviders({\n\t\t\tconfig: params?.config,\n\t\t\tbundledAllowlistCompat: true\n\t\t})).filter((entry) => entry.id !== resolved.provider.id);\n\t\tfor (const fallbackProvider of fallbackProviders) {\n\t\t\ttry {\n\t\t\t\tconst fallbackDefinition = fallbackProvider.createTool({\n\t\t\t\t\tconfig: params?.config,\n\t\t\t\t\tsearchConfig: resolveSearchConfig(params?.config),\n\t\t\t\t\truntimeMetadata: getActiveRuntimeWebToolsMetadata()?.search\n\t\t\t\t});\n\t\t\t\tif (!fallbackDefinition) continue;\n\t\t\t\tlogVerbose(`web_search primary provider failed (${resolved.provider.id}); falling back to \"${fallbackProvider.id}\"`);\n\t\t\t\treturn {\n\t\t\t\t\tprovider: fallbackProvider.id,\n\t\t\t\t\tresult: await fallbackDefinition.execute(params.args)\n\t\t\t\t};\n\t\t\t} catch {\n\t\t\t\tcontinue;\n\t\t\t}\n\t\t}\n\t\tthrow primaryError;\n\t}\n}/s' "$WEB_SEARCH_RUNTIME_FILE"
  # Step 2: add 1-5s per-provider cooldown helper if missing.
  if ! rg -q 'resolveWebSearchCooldownMs' "$WEB_SEARCH_RUNTIME_FILE"; then
    perl -0777 -i -pe 's#//\#region src/web-search/runtime\.ts\nfunction resolveSearchConfig\(cfg\) \{#//#region src/web-search/runtime.ts\nconst WEB_SEARCH_COOLDOWN_MS_MIN = 1e3;\nconst WEB_SEARCH_COOLDOWN_MS_MAX = 5e3;\nconst WEB_SEARCH_COOLDOWN_MS_DEFAULT = 2e3;\nconst webSearchProviderLastRequestAt = /* @__PURE__ */ new Map();\nconst webSearchProviderQueue = /* @__PURE__ */ new Map();\nfunction resolveWebSearchCooldownMs() {\n\tconst rawMs = Number.parseInt(process.env.OPENCLAW_WEB_SEARCH_COOLDOWN_MS ?? \"\", 10);\n\tif (Number.isFinite(rawMs) && rawMs >= WEB_SEARCH_COOLDOWN_MS_MIN) return Math.min(rawMs, WEB_SEARCH_COOLDOWN_MS_MAX);\n\tconst rawSec = Number.parseInt(process.env.OPENCLAW_WEB_SEARCH_COOLDOWN_SECONDS ?? \"\", 10);\n\tif (Number.isFinite(rawSec) && rawSec >= 1) return Math.min(rawSec * 1e3, WEB_SEARCH_COOLDOWN_MS_MAX);\n\treturn WEB_SEARCH_COOLDOWN_MS_DEFAULT;\n}\nasync function enqueueWebSearchWithCooldown(providerId, execute) {\n\tconst previous = webSearchProviderQueue.get(providerId) ?? Promise.resolve();\n\tconst run = previous.catch(() => void 0).then(async () => {\n\t\tconst cooldownMs = resolveWebSearchCooldownMs();\n\t\tconst now = Date.now();\n\t\tconst lastAt = webSearchProviderLastRequestAt.get(providerId) ?? 0;\n\t\tconst waitMs = lastAt + cooldownMs - now;\n\t\tif (waitMs > 0) await new Promise((resolve) => setTimeout(resolve, waitMs));\n\t\tconst result = await execute();\n\t\twebSearchProviderLastRequestAt.set(providerId, Date.now());\n\t\treturn result;\n\t});\n\twebSearchProviderQueue.set(providerId, run.then(() => void 0, () => void 0));\n\treturn run;\n}\nfunction resolveSearchConfig(cfg) {#s' "$WEB_SEARCH_RUNTIME_FILE"
  fi
  # Step 3: always route provider execution through cooldown queue.
  perl -0777 -i -pe 's/result: await resolved\.definition\.execute\(params\.args\)/result: await enqueueWebSearchWithCooldown(resolved.provider.id, () => resolved.definition.execute(params.args))/g; s/result: await fallbackDefinition\.execute\(params\.args\)/result: await enqueueWebSearchWithCooldown(fallbackProvider.id, () => fallbackDefinition.execute(params.args))/g' "$WEB_SEARCH_RUNTIME_FILE"
}

print_check_summary() {
  local small_status usage_status cron_status closed_audit_status gateway_rpc_status gateway_handshake_status web_search_fallback_status
  small_status="FAIL"
  usage_status="FAIL"
  cron_status="FAIL"
  closed_audit_status="FAIL"
  gateway_rpc_status="FAIL"
  gateway_handshake_status="FAIL"
  web_search_fallback_status="FAIL"

  check_small_model_hotfix && small_status="OK"
  check_include_usage_hotfix && usage_status="OK"
  check_cron_run_timeout_hotfix && cron_status="OK"
  check_closed_system_audit_hotfix && closed_audit_status="OK"
  check_gateway_rpc_config_hotfix && gateway_rpc_status="OK"
  check_gateway_handshake_runtime_hotfix && gateway_handshake_status="OK"
  check_web_search_provider_fallback_hotfix && web_search_fallback_status="OK"

  log "OpenClaw version: $(openclaw --version 2>/dev/null || echo unknown)"
  log "Hotfix version: ${HOTFIX_VERSION}"
  log "small-model severity hotfix: ${small_status}"
  log "closed-system audit hotfix: ${closed_audit_status}"
  log "include_usage hotfix: ${usage_status}"
  log "cron.run timeout hotfix: ${cron_status}"
  log "gateway-rpc config hotfix: ${gateway_rpc_status}"
  log "gateway handshake/runtime hotfix: ${gateway_handshake_status}"
  log "web_search fallback+cooldown hotfix: ${web_search_fallback_status}"

  [[ "$small_status" == "OK" && "$closed_audit_status" == "OK" && "$usage_status" == "OK" && "$cron_status" == "OK" && "$gateway_rpc_status" == "OK" && "$gateway_handshake_status" == "OK" && "$web_search_fallback_status" == "OK" ]]
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

      if ! check_gateway_handshake_runtime_hotfix; then
        log "re-applying gateway handshake/runtime hotfix"
        apply_gateway_handshake_runtime_hotfix
      fi
      if ! check_web_search_provider_fallback_hotfix; then
        log "re-applying web_search fallback+cooldown hotfix"
        apply_web_search_provider_fallback_hotfix
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
