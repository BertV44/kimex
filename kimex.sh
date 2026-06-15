#!/usr/bin/env bash
#
# kimex - Kasten Import Key Extractor
#
# Retrieves the "import keys" (receiveString) from Kasten K10 policies and
# exports them in a structured way (table, JSON, and one .key file per policy).
#
# Goals:
#   - Make it easy to create import policies on a receiving cluster.
#   - Escrow this sensitive data to allow a restore even without the original
#     K10 catalog.
#
# Target CRD: policies.config.kio.kasten.io (v1alpha1)
# Import key: spec.actions[].exportParameters.receiveString
#
# SECURITY WARNING: the receiveString is sensitive data (a migration key).
# Never commit the output (see the bundled .gitignore).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
# Full name of the K10 CRD that holds the policies.
readonly K10_POLICY_CRD="policies.config.kio.kasten.io"
# Default namespace (overridable via --namespace). NO hardcoding elsewhere.
readonly DEFAULT_NAMESPACE="kasten-io"

# ---------------------------------------------------------------------------
# Global variables (set by argument parsing)
# ---------------------------------------------------------------------------
NAMESPACE="$DEFAULT_NAMESPACE"
KUBECONFIG_PATH=""        # --kubeconfig
OUTPUT_FORMAT="table"     # --output table|json|csv
OUTPUT_DIR=""             # --output-dir
ALL_CONTEXTS="false"      # --all-contexts
CONTEXT_FILE=""           # --context-file (extra: contexts "file")
DRY_RUN="false"           # --dry-run
declare -a CONTEXTS=()    # --context (repeatable / comma-separated)

# Results accumulator: one compact JSON object per line.
declare -a RESULTS=()

# ---------------------------------------------------------------------------
# Colors (only if stderr is a terminal)
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RED="$(printf '\033[31m')"; C_YEL="$(printf '\033[33m')"
  C_GRN="$(printf '\033[32m')"; C_RST="$(printf '\033[0m')"
else
  C_RED=""; C_YEL=""; C_GRN=""; C_RST=""
fi

# ---------------------------------------------------------------------------
# Log helpers: everything goes to stderr to avoid polluting stdout (data).
# ---------------------------------------------------------------------------
info() { printf '%s[i]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${SCRIPT_NAME} - Kasten Import Key Extractor

Retrieves the receiveString (import keys) from K10 policies and exports them
as a table, JSON, and/or one .key file per policy.

USAGE:
  ${SCRIPT_NAME} [options]

OPTIONS:
  -n, --namespace <ns>     K10 namespace to inspect (default: ${DEFAULT_NAMESPACE}).
  -c, --context <ctx>      Kubeconfig context to use. Repeatable, or several
                           values separated by commas.
      --context-file <f>   File containing one context per line.
      --all-contexts       Iterate over ALL contexts in the kubeconfig.
      --kubeconfig <path>  Path to a specific kubeconfig.
  -o, --output <fmt>       Output format: table (default), json or csv.
  -d, --output-dir <dir>   Write one <ctx>__<ns>__<policy>.key file per policy,
                           containing only the receiveString.
      --dry-run            Show what would be done (contexts, namespace,
                           commands, .key files) WITHOUT contacting any cluster
                           or writing any file.
  -h, --help               Show this help.

EXAMPLES:
  # Single cluster, current context, table
  ${SCRIPT_NAME}

  # Custom namespace + JSON output
  ${SCRIPT_NAME} -n kasten-io -o json

  # A specific context + escrow keys to disk
  ${SCRIPT_NAME} -c prod-cluster -d ./keys

  # Multiple contexts
  ${SCRIPT_NAME} -c prod-a,prod-b -o json

  # All contexts in the kubeconfig
  ${SCRIPT_NAME} --all-contexts -d ./keys

  # CSV output (full receiveString, ideal for spreadsheets/automation)
  ${SCRIPT_NAME} -c prod-a -o csv > import-keys.csv

  # Dry-run: see the plan without contacting or writing anything
  ${SCRIPT_NAME} --all-contexts -d ./keys --dry-run

  # Dedicated kubeconfig
  ${SCRIPT_NAME} --kubeconfig /etc/k10/admin.conf -c staging

SECURITY:
  The receiveString is a sensitive migration key. Do not commit the output;
  a .gitignore covering the output-dir and *.key is provided.
EOF
}

# ---------------------------------------------------------------------------
# Dependency check: (oc OR kubectl) + jq.
# ---------------------------------------------------------------------------
check_deps() {
  command -v jq >/dev/null 2>&1 || die "Missing dependency: 'jq' is required."

  if ! command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    die "Missing dependency: 'oc' or 'kubectl' is required."
  fi
}

# ---------------------------------------------------------------------------
# Config client (config get-contexts, etc.): independent of cluster
# reachability. We prefer oc if present, otherwise kubectl.
# ---------------------------------------------------------------------------
config_cli() {
  if command -v oc >/dev/null 2>&1; then echo "oc"; else echo "kubectl"; fi
}

# Builds a complete "config" command array (binary + kubeconfig).
# We always include the binary so we NEVER expose an empty array to expansion
# (bash 3.2 + set -u crashes on "${arr[@]}" when arr is empty).
# Result goes into the global variable CFG_CMD.
build_config_cmd() {
  CFG_CMD=("$(config_cli)")
  [[ -n "$KUBECONFIG_PATH" ]] && CFG_CMD+=(--kubeconfig "$KUBECONFIG_PATH")
  return 0   # do not propagate the status of the test above (set -e)
}

# ---------------------------------------------------------------------------
# Environment detection for ONE given context.
#
# Returns (via echo) the binary to use: "oc" or "kubectl".
# Detects OpenShift via the presence of the route.openshift.io or
# config.openshift.io API groups. If OpenShift is detected -> oc exclusively.
# Otherwise -> kubectl (fallback). Returns 1 if the cluster is unreachable.
#
# $1 = context (may be empty = current context)
# ---------------------------------------------------------------------------
detect_cli() {
  local ctx="$1"

  # Probe client: we use oc if present (able to talk to any k8s cluster),
  # otherwise kubectl.
  local probe; probe="$(config_cli)"

  # Connection arguments (kubeconfig + context if provided).
  local -a conn=("$probe")
  [[ -n "$KUBECONFIG_PATH" ]] && conn+=(--kubeconfig "$KUBECONFIG_PATH")
  [[ -n "$ctx" ]] && conn+=(--context "$ctx")

  # Query the API resources. Doubles as a reachability / context-validity
  # check: a failure here => we skip this cluster.
  local api_out
  if ! api_out="$("${conn[@]}" api-resources 2>/dev/null)"; then
    return 1
  fi

  # OpenShift if one of the characteristic API groups is present.
  if grep -qE 'route\.openshift\.io|config\.openshift\.io' <<<"$api_out"; then
    if command -v oc >/dev/null 2>&1; then
      echo "oc"
    else
      # OpenShift detected but 'oc' unavailable: warn and fall back to
      # kubectl (better than failing outright).
      warn "OpenShift detected but 'oc' is unavailable: falling back to kubectl."
      echo "kubectl"
    fi
    return 0
  fi

  # Not OpenShift: kubectl if available, otherwise oc (always capable).
  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl"
  else
    echo "oc"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Enumerates the contexts to process and fills the global CONTEXTS array.
# Priority: --all-contexts > --context / --context-file > current context.
# ---------------------------------------------------------------------------
resolve_contexts() {
  # --context-file: add each non-empty / non-commented line.
  if [[ -n "$CONTEXT_FILE" ]]; then
    [[ -r "$CONTEXT_FILE" ]] || die "Unreadable context file: $CONTEXT_FILE"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"                       # strip comments
      line="$(echo "$line" | tr -d '[:space:]')" # strip whitespace
      [[ -n "$line" ]] && CONTEXTS+=("$line")
    done < "$CONTEXT_FILE"
  fi

  # --all-contexts: list the whole kubeconfig (mutually exclusive with --context).
  if [[ "$ALL_CONTEXTS" == "true" ]]; then
    if (( ${#CONTEXTS[@]} > 0 )); then
      die "--all-contexts is mutually exclusive with --context / --context-file."
    fi
    build_config_cmd
    local names
    if ! names="$("${CFG_CMD[@]}" config get-contexts -o name 2>/dev/null)"; then
      die "Unable to list the kubeconfig contexts."
    fi
    [[ -n "$names" ]] || die "No context found in the kubeconfig."
    local n
    while IFS= read -r n; do
      [[ -n "$n" ]] && CONTEXTS+=("$n")
    done <<<"$names"
  fi

  # No context specified: use the current context (empty string).
  if (( ${#CONTEXTS[@]} == 0 )); then
    CONTEXTS=("")
  fi
}

# ---------------------------------------------------------------------------
# Processes ONE context: detects the CLI, checks the namespace, fetches the
# policies, extracts the receiveString values and pushes them into RESULTS.
#
# $1 = context (may be empty = current context)
# Never fails the whole script: it logs and returns.
# ---------------------------------------------------------------------------
process_context() {
  local ctx="$1"
  local ctx_label="${ctx:-<current context>}"

  info "Cluster: ${ctx_label} (namespace: ${NAMESPACE})"

  # Determine the right client (oc/kubectl); fails if the cluster is unreachable.
  local cli
  if ! cli="$(detect_cli "$ctx")"; then
    err "  Unreachable cluster or invalid context: ${ctx_label} — skipped."
    return 0
  fi

  # Build the reusable base command (always >= 1 element).
  local -a kube=("$cli")
  [[ -n "$KUBECONFIG_PATH" ]] && kube+=(--kubeconfig "$KUBECONFIG_PATH")
  [[ -n "$ctx" ]] && kube+=(--context "$ctx")

  # Check that the namespace exists.
  if ! "${kube[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    err "  Missing namespace: ${NAMESPACE} on ${ctx_label} — skipped."
    return 0
  fi

  # Fetch the policies as JSON. If the CRD is absent or access is denied,
  # 'get' fails: we log and move on.
  local json
  if ! json="$("${kube[@]}" get "$K10_POLICY_CRD" -n "$NAMESPACE" -o json 2>/dev/null)"; then
    err "  Unable to list ${K10_POLICY_CRD} (CRD missing or access denied) on ${ctx_label} — skipped."
    return 0
  fi

  # Extraction via jq: for each policy, iterate over the export actions that
  # have a non-empty receiveString. Each object is tagged with its source
  # context. exportData.enabled=true is the existence condition for the
  # receiveString; we filter on the key actually being present.
  local extracted
  extracted="$(
    jq -c --arg ctx "$ctx_label" '
      .items[]? as $p
      | $p.spec.actions[]?
      | select(.action == "export")
      | .exportParameters as $ep
      | select($ep != null)
      | select($ep.receiveString != null and ($ep.receiveString | length) > 0)
      | {
          context:        $ctx,
          policy:         $p.metadata.name,
          namespace:      $p.metadata.namespace,
          receiveString:  $ep.receiveString,
          profile:        ($ep.profile.name        // ""),
          profileNs:      ($ep.profile.namespace    // ""),
          migrationToken: ($ep.migrationToken.name  // ""),
          migrationTokenNs: ($ep.migrationToken.namespace // "")
        }
    ' <<<"$json"
  )"

  # No export policy with a key: warn but keep going.
  if [[ -z "$extracted" ]]; then
    warn "  No export policy with a receiveString on ${ctx_label}."
    return 0
  fi

  # Push each object (one JSON line = one record).
  local count=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    RESULTS+=("$line")
    count=$((count + 1))
  done <<<"$extracted"

  info "  ${count} import key(s) found."
}

# ---------------------------------------------------------------------------
# Builds a single JSON array from RESULTS.
# ---------------------------------------------------------------------------
results_as_array() {
  if (( ${#RESULTS[@]} == 0 )); then
    echo "[]"
    return
  fi
  printf '%s\n' "${RESULTS[@]}" | jq -s '.'
}

# ---------------------------------------------------------------------------
# Table output (readable). The receiveString is truncated as it can be very
# long; the full value is in the JSON and the .key files.
# ---------------------------------------------------------------------------
render_table() {
  local arr; arr="$(results_as_array)"

  # Header + rows, tab-separated, then aligned via column -t.
  {
    printf 'CONTEXT\tPOLICY\tNAMESPACE\tPROFILE\tMIGRATION_TOKEN\tRECEIVE_STRING\n'
    jq -r '
      .[] |
      [ .context,
        .policy,
        .namespace,
        (if .profile == "" then "-" else .profile end),
        (if .migrationToken == "" then "-" else .migrationToken end),
        ( .receiveString
          | if length > 40 then (.[0:37] + "...") else . end )
      ] | @tsv
    ' <<<"$arr"
  } | column -t -s $'\t'

  echo
  info "receiveString truncated in the table. Full value: --output json or --output-dir."
}

# ---------------------------------------------------------------------------
# CSV output. Unlike the table, the receiveString is FULL (format intended for
# spreadsheets / automation). jq @csv handles escaping (quotes, commas)
# correctly.
# ---------------------------------------------------------------------------
render_csv() {
  local arr; arr="$(results_as_array)"

  # CSV header.
  printf 'context,policy,namespace,profile,profile_namespace,migration_token,migration_token_namespace,receive_string\n'

  jq -r '
    .[] |
    [ .context,
      .policy,
      .namespace,
      .profile,
      .profileNs,
      .migrationToken,
      .migrationTokenNs,
      .receiveString
    ] | @csv
  ' <<<"$arr"
}

# ---------------------------------------------------------------------------
# Writes one .key file per policy into OUTPUT_DIR (receiveString only).
# ---------------------------------------------------------------------------
write_key_files() {
  [[ -n "$OUTPUT_DIR" ]] || return 0

  mkdir -p "$OUTPUT_DIR" || die "Unable to create directory: $OUTPUT_DIR"

  local arr; arr="$(results_as_array)"
  local total; total="$(jq 'length' <<<"$arr")"
  (( total > 0 )) || { warn "No key to write into ${OUTPUT_DIR}."; return 0; }

  # Iterate by index to fetch each field cleanly.
  local i fname recv ctx policy ns
  for (( i = 0; i < total; i++ )); do
    ctx="$(jq -r ".[$i].context"       <<<"$arr")"
    policy="$(jq -r ".[$i].policy"      <<<"$arr")"
    ns="$(jq -r ".[$i].namespace"       <<<"$arr")"
    recv="$(jq -r ".[$i].receiveString" <<<"$arr")"

    # Filename: <ctx>__<ns>__<policy>.key ; unsafe characters are replaced
    # with '_' to stay filesystem-compatible.
    fname="$(printf '%s__%s__%s.key' "$ctx" "$ns" "$policy" \
             | tr -c 'A-Za-z0-9._-' '_')"

    # Write ONLY the receiveString (direct copy/paste).
    printf '%s' "$recv" > "${OUTPUT_DIR}/${fname}"
    # Restrictive permissions: sensitive data.
    chmod 600 "${OUTPUT_DIR}/${fname}" 2>/dev/null || true
  done

  info "${total} .key file(s) written to ${OUTPUT_DIR} (chmod 600)."
  warn "These files contain migration keys. DO NOT commit them."
}

# ---------------------------------------------------------------------------
# Main output (stdout) according to the requested format.
# ---------------------------------------------------------------------------
render_output() {
  case "$OUTPUT_FORMAT" in
    json)  results_as_array ;;
    table) render_table ;;
    csv)   render_csv ;;
    *)     die "Unknown output format: $OUTPUT_FORMAT (expected: table|json|csv)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        NAMESPACE="$2"; shift 2 ;;
      -c|--context)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        # Supports comma-separated values.
        IFS=',' read -r -a _split <<<"$2"
        local v
        for v in "${_split[@]}"; do
          [[ -n "$v" ]] && CONTEXTS+=("$v")
        done
        shift 2 ;;
      --context-file)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        CONTEXT_FILE="$2"; shift 2 ;;
      --all-contexts)
        ALL_CONTEXTS="true"; shift ;;
      --dry-run)
        DRY_RUN="true"; shift ;;
      --kubeconfig)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        KUBECONFIG_PATH="$2"; shift 2 ;;
      -o|--output)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        OUTPUT_FORMAT="$2"; shift 2 ;;
      -d|--output-dir)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        OUTPUT_DIR="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      --) shift; break ;;
      -*) die "Unknown option: $1 (see --help)." ;;
      *)  die "Unexpected argument: $1 (see --help)." ;;
    esac
  done

  # Validate the output format as early as possible.
  case "$OUTPUT_FORMAT" in
    table|json|csv) ;;
    *) die "Invalid format: $OUTPUT_FORMAT (expected: table|json|csv)." ;;
  esac
}

# ---------------------------------------------------------------------------
# Dry-run mode: print the plan (contexts, namespace, commands, .key files that
# would be produced) WITHOUT contacting any cluster or writing any file.
# ---------------------------------------------------------------------------
print_dry_run() {
  # The actual client depends on per-cluster OpenShift detection (impossible
  # without contacting the cluster), so we show the probe client instead.
  local probe; probe="$(config_cli)"

  info "DRY-RUN: no cluster connection, no file written."
  printf '\n'
  printf 'Plan:\n'
  printf '  Namespace        : %s\n' "$NAMESPACE"
  printf '  Output format    : %s\n' "$OUTPUT_FORMAT"
  printf '  Kubeconfig       : %s\n' "${KUBECONFIG_PATH:-<default>}"
  printf '  Output-dir       : %s\n' "${OUTPUT_DIR:-<none>}"
  printf '  CLI detection    : OpenShift -> oc, otherwise kubectl (per context)\n'
  printf '  Config probe     : %s\n' "$probe"
  printf '  Contexts (%d)    :\n' "${#CONTEXTS[@]}"

  local ctx ctx_label kc_flag=""
  [[ -n "$KUBECONFIG_PATH" ]] && kc_flag=" --kubeconfig $KUBECONFIG_PATH"
  for ctx in "${CONTEXTS[@]}"; do
    ctx_label="${ctx:-<current context>}"
    local ctx_flag=""
    [[ -n "$ctx" ]] && ctx_flag=" --context $ctx"
    printf '    - %s\n' "$ctx_label"
    printf '        detect : <oc|kubectl>%s%s api-resources\n' "$kc_flag" "$ctx_flag"
    printf '        read   : <oc|kubectl>%s%s get %s -n %s -o json\n' \
      "$kc_flag" "$ctx_flag" "$K10_POLICY_CRD" "$NAMESPACE"
    if [[ -n "$OUTPUT_DIR" ]]; then
      printf '        write  : %s/%s__%s__<policy>.key\n' \
        "$OUTPUT_DIR" "$ctx_label" "$NAMESPACE"
    fi
  done
  printf '\n'
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  check_deps
  resolve_contexts

  # Dry-run: print the plan and stop here.
  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run
    exit 0
  fi

  info "Contexts to process: ${#CONTEXTS[@]}"

  # Iterate over all contexts; a failure on one does not interrupt the others
  # (process_context logs and returns).
  local ctx
  for ctx in "${CONTEXTS[@]}"; do
    process_context "$ctx"
  done

  # Write the .key files (if --output-dir) then the main output.
  write_key_files

  if (( ${#RESULTS[@]} == 0 )); then
    warn "No import key found across all processed clusters."
    # Consistent output even when empty (empty array in JSON).
    [[ "$OUTPUT_FORMAT" == "json" ]] && echo "[]"
    exit 0
  fi

  render_output
}

main "$@"
