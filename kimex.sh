#!/usr/bin/env bash
#
# kimex - Kasten Import Key Extractor
#
# Récupère les "import keys" (receiveString) des policies Kasten K10 et les
# exporte de façon structurée (table, JSON, et un fichier .key par policy).
#
# Objectifs :
#   - Faciliter la création des import policies sur un cluster receveur.
#   - Séquestrer ces données sensibles pour permettre une restauration même
#     sans le catalog K10 d'origine.
#
# CRD ciblée : policies.config.kio.kasten.io (v1alpha1)
# Clé d'import : spec.actions[].exportParameters.receiveString
#
# AVERTISSEMENT SÉCURITÉ : le receiveString est une donnée sensible (clé de
# migration). Ne committez jamais les sorties (voir .gitignore fourni).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
# Nom complet de la CRD K10 contenant les policies.
readonly K10_POLICY_CRD="policies.config.kio.kasten.io"
# Namespace par défaut (paramétrable via --namespace). PAS de hardcoding ailleurs.
readonly DEFAULT_NAMESPACE="kasten-io"

# ---------------------------------------------------------------------------
# Variables globales (positionnées par le parsing des arguments)
# ---------------------------------------------------------------------------
NAMESPACE="$DEFAULT_NAMESPACE"
KUBECONFIG_PATH=""        # --kubeconfig
OUTPUT_FORMAT="table"     # --output table|json|csv
OUTPUT_DIR=""             # --output-dir
ALL_CONTEXTS="false"      # --all-contexts
CONTEXT_FILE=""           # --context-file (extra : "fichier" de contextes)
DRY_RUN="false"           # --dry-run
declare -a CONTEXTS=()    # --context (répétable / séparé par des virgules)

# Accumulateur de résultats : un objet JSON compact par ligne.
declare -a RESULTS=()

# ---------------------------------------------------------------------------
# Couleurs (uniquement si la sortie d'erreur est un terminal)
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RED="$(printf '\033[31m')"; C_YEL="$(printf '\033[33m')"
  C_GRN="$(printf '\033[32m')"; C_RST="$(printf '\033[0m')"
else
  C_RED=""; C_YEL=""; C_GRN=""; C_RST=""
fi

# ---------------------------------------------------------------------------
# Helpers de log : tout part sur stderr pour ne pas polluer stdout (données).
# ---------------------------------------------------------------------------
info() { printf '%s[i]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Aide
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${SCRIPT_NAME} - Kasten Import Key Extractor

Récupère les receiveString (import keys) des policies K10 et les exporte
en table, JSON, et/ou un fichier .key par policy.

USAGE :
  ${SCRIPT_NAME} [options]

OPTIONS :
  -n, --namespace <ns>     Namespace K10 à inspecter (défaut: ${DEFAULT_NAMESPACE}).
  -c, --context <ctx>      Contexte kubeconfig à utiliser. Répétable, ou
                           plusieurs valeurs séparées par des virgules.
      --context-file <f>   Fichier contenant un contexte par ligne.
      --all-contexts       Itère sur TOUS les contextes du kubeconfig.
      --kubeconfig <path>  Chemin d'un kubeconfig spécifique.
  -o, --output <fmt>       Format de sortie : table (défaut), json ou csv.
  -d, --output-dir <dir>   Écrit un fichier <ctx>__<ns>__<policy>.key par
                           policy, contenant uniquement le receiveString.
      --dry-run            Montre ce qui serait fait (contextes, namespace,
                           commandes, fichiers .key) SANS contacter de cluster
                           ni écrire de fichier.
  -h, --help               Affiche cette aide.

EXEMPLES :
  # Mono-cluster, contexte courant, table
  ${SCRIPT_NAME}

  # Namespace personnalisé + sortie JSON
  ${SCRIPT_NAME} -n kasten-io -o json

  # Un contexte précis + séquestre des clés sur disque
  ${SCRIPT_NAME} -c prod-cluster -d ./keys

  # Plusieurs contextes
  ${SCRIPT_NAME} -c prod-a,prod-b -o json

  # Tous les contextes du kubeconfig
  ${SCRIPT_NAME} --all-contexts -d ./keys

  # Sortie CSV (receiveString complet, idéal tableur/automatisation)
  ${SCRIPT_NAME} -c prod-a -o csv > import-keys.csv

  # Dry-run : voir le plan sans rien contacter ni écrire
  ${SCRIPT_NAME} --all-contexts -d ./keys --dry-run

  # Kubeconfig dédié
  ${SCRIPT_NAME} --kubeconfig /etc/k10/admin.conf -c recette

SÉCURITÉ :
  Le receiveString est une clé de migration sensible. Ne committez pas les
  sorties ; un .gitignore couvrant l'output-dir et *.key est fourni.
EOF
}

# ---------------------------------------------------------------------------
# Vérification des dépendances : (oc OU kubectl) + jq.
# ---------------------------------------------------------------------------
check_deps() {
  command -v jq >/dev/null 2>&1 || die "Dépendance manquante : 'jq' est requis."

  if ! command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    die "Dépendance manquante : 'oc' ou 'kubectl' est requis."
  fi
}

# ---------------------------------------------------------------------------
# Client de config (config get-contexts, etc.) : indépendant de la
# joignabilité d'un cluster. On privilégie oc s'il est présent, sinon kubectl.
# ---------------------------------------------------------------------------
config_cli() {
  if command -v oc >/dev/null 2>&1; then echo "oc"; else echo "kubectl"; fi
}

# Construit un tableau de commande "config" complet (binaire + kubeconfig).
# On inclut toujours le binaire pour ne JAMAIS exposer un tableau vide à
# l'expansion (bash 3.2 + set -u plante sur "${arr[@]}" quand arr est vide).
# Résultat dans la variable globale CFG_CMD.
build_config_cmd() {
  CFG_CMD=("$(config_cli)")
  [[ -n "$KUBECONFIG_PATH" ]] && CFG_CMD+=(--kubeconfig "$KUBECONFIG_PATH")
  return 0   # ne pas propager le statut du test ci-dessus (set -e)
}

# ---------------------------------------------------------------------------
# Détection de l'environnement pour UN contexte donné.
#
# Renvoie (via echo) le binaire à utiliser : "oc" ou "kubectl".
# Détecte OpenShift via la présence des API groups route.openshift.io ou
# config.openshift.io. Si OpenShift est détecté -> oc exclusivement.
# Sinon -> kubectl (fallback). Retourne 1 si le cluster est injoignable.
#
# $1 = contexte (peut être vide = contexte courant)
# ---------------------------------------------------------------------------
detect_cli() {
  local ctx="$1"

  # Client sonde : on utilise oc si présent (capable de parler à n'importe
  # quel cluster k8s), sinon kubectl.
  local probe; probe="$(config_cli)"

  # Arguments de connexion (kubeconfig + contexte si fourni).
  local -a conn=("$probe")
  [[ -n "$KUBECONFIG_PATH" ]] && conn+=(--kubeconfig "$KUBECONFIG_PATH")
  [[ -n "$ctx" ]] && conn+=(--context "$ctx")

  # Interroge les API resources. Sert aussi de test de joignabilité /
  # validité du contexte : un échec ici => on saute ce cluster.
  local api_out
  if ! api_out="$("${conn[@]}" api-resources 2>/dev/null)"; then
    return 1
  fi

  # OpenShift si l'un des API groups caractéristiques est présent.
  if grep -qE 'route\.openshift\.io|config\.openshift\.io' <<<"$api_out"; then
    if command -v oc >/dev/null 2>&1; then
      echo "oc"
    else
      # OpenShift détecté mais 'oc' indisponible : on prévient et on
      # retombe sur kubectl (mieux que d'échouer totalement).
      warn "OpenShift détecté mais 'oc' indisponible : fallback sur kubectl."
      echo "kubectl"
    fi
    return 0
  fi

  # Pas OpenShift : kubectl si dispo, sinon oc (toujours capable).
  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl"
  else
    echo "oc"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Énumère les contextes à traiter et remplit le tableau global CONTEXTS.
# Priorité : --all-contexts > --context / --context-file > contexte courant.
# ---------------------------------------------------------------------------
resolve_contexts() {
  # --context-file : on ajoute chaque ligne non vide / non commentée.
  if [[ -n "$CONTEXT_FILE" ]]; then
    [[ -r "$CONTEXT_FILE" ]] || die "Fichier de contextes illisible : $CONTEXT_FILE"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"                       # retire les commentaires
      line="$(echo "$line" | tr -d '[:space:]')" # retire les espaces
      [[ -n "$line" ]] && CONTEXTS+=("$line")
    done < "$CONTEXT_FILE"
  fi

  # --all-contexts : on liste tout le kubeconfig (incompatible avec --context).
  if [[ "$ALL_CONTEXTS" == "true" ]]; then
    if (( ${#CONTEXTS[@]} > 0 )); then
      die "--all-contexts est incompatible avec --context / --context-file."
    fi
    build_config_cmd
    local names
    if ! names="$("${CFG_CMD[@]}" config get-contexts -o name 2>/dev/null)"; then
      die "Impossible de lister les contextes du kubeconfig."
    fi
    [[ -n "$names" ]] || die "Aucun contexte trouvé dans le kubeconfig."
    local n
    while IFS= read -r n; do
      [[ -n "$n" ]] && CONTEXTS+=("$n")
    done <<<"$names"
  fi

  # Aucun contexte spécifié : on utilise le contexte courant (chaîne vide).
  if (( ${#CONTEXTS[@]} == 0 )); then
    CONTEXTS=("")
  fi
}

# ---------------------------------------------------------------------------
# Traite UN contexte : détecte le CLI, vérifie le namespace, récupère les
# policies, extrait les receiveString et les empile dans RESULTS.
#
# $1 = contexte (peut être vide = contexte courant)
# Ne fait jamais échouer le script global : journalise et retourne.
# ---------------------------------------------------------------------------
process_context() {
  local ctx="$1"
  local ctx_label="${ctx:-<contexte courant>}"

  info "Cluster : ${ctx_label} (namespace: ${NAMESPACE})"

  # Détermine le bon client (oc/kubectl) ; échoue si cluster injoignable.
  local cli
  if ! cli="$(detect_cli "$ctx")"; then
    err "  Cluster injoignable ou contexte invalide : ${ctx_label} — ignoré."
    return 0
  fi

  # Construit la commande de base réutilisable (toujours >= 1 élément).
  local -a kube=("$cli")
  [[ -n "$KUBECONFIG_PATH" ]] && kube+=(--kubeconfig "$KUBECONFIG_PATH")
  [[ -n "$ctx" ]] && kube+=(--context "$ctx")

  # Vérifie l'existence du namespace.
  if ! "${kube[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    err "  Namespace absent : ${NAMESPACE} sur ${ctx_label} — ignoré."
    return 0
  fi

  # Récupère les policies en JSON. Si la CRD est absente ou l'accès refusé,
  # 'get' échoue : on journalise et on continue.
  local json
  if ! json="$("${kube[@]}" get "$K10_POLICY_CRD" -n "$NAMESPACE" -o json 2>/dev/null)"; then
    err "  Impossible de lister ${K10_POLICY_CRD} (CRD absente ou accès refusé) sur ${ctx_label} — ignoré."
    return 0
  fi

  # Extraction via jq : pour chaque policy, on parcourt les actions d'export
  # disposant d'un receiveString non vide. On tague chaque objet avec le
  # contexte d'origine. exportData.enabled=true est la condition d'existence
  # du receiveString ; on filtre sur la présence effective de la clé.
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

  # Aucune policy d'export avec clé : on prévient mais on continue.
  if [[ -z "$extracted" ]]; then
    warn "  Aucune policy d'export avec receiveString sur ${ctx_label}."
    return 0
  fi

  # Empile chaque objet (une ligne JSON = un enregistrement).
  local count=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    RESULTS+=("$line")
    count=$((count + 1))
  done <<<"$extracted"

  info "  ${count} import key(s) trouvée(s)."
}

# ---------------------------------------------------------------------------
# Construit un tableau JSON unique à partir de RESULTS.
# ---------------------------------------------------------------------------
results_as_array() {
  if (( ${#RESULTS[@]} == 0 )); then
    echo "[]"
    return
  fi
  printf '%s\n' "${RESULTS[@]}" | jq -s '.'
}

# ---------------------------------------------------------------------------
# Sortie table (lisible). Le receiveString est tronqué car potentiellement
# très long ; la valeur complète est dans le JSON et les fichiers .key.
# ---------------------------------------------------------------------------
render_table() {
  local arr; arr="$(results_as_array)"

  # En-tête + lignes, tabulées, puis alignées via column -t.
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
  info "receiveString tronqué dans la table. Valeur complète : --output json ou --output-dir."
}

# ---------------------------------------------------------------------------
# Sortie CSV. Contrairement à la table, le receiveString est COMPLET (format
# destiné au tableur / à l'automatisation). jq @csv gère l'échappement
# (guillemets, virgules) correctement.
# ---------------------------------------------------------------------------
render_csv() {
  local arr; arr="$(results_as_array)"

  # En-tête CSV.
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
# Écrit un fichier .key par policy dans OUTPUT_DIR (receiveString uniquement).
# ---------------------------------------------------------------------------
write_key_files() {
  [[ -n "$OUTPUT_DIR" ]] || return 0

  mkdir -p "$OUTPUT_DIR" || die "Impossible de créer le répertoire : $OUTPUT_DIR"

  local arr; arr="$(results_as_array)"
  local total; total="$(jq 'length' <<<"$arr")"
  (( total > 0 )) || { warn "Aucune clé à écrire dans ${OUTPUT_DIR}."; return 0; }

  # On itère par index pour récupérer chaque champ proprement.
  local i fname recv ctx policy ns
  for (( i = 0; i < total; i++ )); do
    ctx="$(jq -r ".[$i].context"       <<<"$arr")"
    policy="$(jq -r ".[$i].policy"      <<<"$arr")"
    ns="$(jq -r ".[$i].namespace"       <<<"$arr")"
    recv="$(jq -r ".[$i].receiveString" <<<"$arr")"

    # Nom de fichier : <ctx>__<ns>__<policy>.key ; caractères dangereux
    # remplacés par '_' pour rester compatible avec le système de fichiers.
    fname="$(printf '%s__%s__%s.key' "$ctx" "$ns" "$policy" \
             | tr -c 'A-Za-z0-9._-' '_')"

    # On écrit UNIQUEMENT le receiveString (copier-coller direct).
    printf '%s' "$recv" > "${OUTPUT_DIR}/${fname}"
    # Permissions restrictives : donnée sensible.
    chmod 600 "${OUTPUT_DIR}/${fname}" 2>/dev/null || true
  done

  info "${total} fichier(s) .key écrit(s) dans ${OUTPUT_DIR} (chmod 600)."
  warn "Ces fichiers contiennent des clés de migration. NE PAS committer."
}

# ---------------------------------------------------------------------------
# Sortie principale (stdout) selon le format demandé.
# ---------------------------------------------------------------------------
render_output() {
  case "$OUTPUT_FORMAT" in
    json)  results_as_array ;;
    table) render_table ;;
    csv)   render_csv ;;
    *)     die "Format de sortie inconnu : $OUTPUT_FORMAT (attendu: table|json|csv)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Parsing des arguments.
# ---------------------------------------------------------------------------
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "Option $1 requiert une valeur."
        NAMESPACE="$2"; shift 2 ;;
      -c|--context)
        [[ $# -ge 2 ]] || die "Option $1 requiert une valeur."
        # Supporte les valeurs séparées par des virgules.
        IFS=',' read -r -a _split <<<"$2"
        local v
        for v in "${_split[@]}"; do
          [[ -n "$v" ]] && CONTEXTS+=("$v")
        done
        shift 2 ;;
      --context-file)
        [[ $# -ge 2 ]] || die "Option $1 requiert une valeur."
        CONTEXT_FILE="$2"; shift 2 ;;
      --all-contexts)
        ALL_CONTEXTS="true"; shift ;;
      --dry-run)
        DRY_RUN="true"; shift ;;
      --kubeconfig)
        [[ $# -ge 2 ]] || die "Option $1 requiert une valeur."
        KUBECONFIG_PATH="$2"; shift 2 ;;
      -o|--output)
        [[ $# -ge 2 ]] || die "Option $1 requiert une valeur."
        OUTPUT_FORMAT="$2"; shift 2 ;;
      -d|--output-dir)
        [[ $# -ge 2 ]] || die "Option $1 requiert une valeur."
        OUTPUT_DIR="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      --) shift; break ;;
      -*) die "Option inconnue : $1 (voir --help)." ;;
      *)  die "Argument inattendu : $1 (voir --help)." ;;
    esac
  done

  # Validation du format de sortie au plus tôt.
  case "$OUTPUT_FORMAT" in
    table|json|csv) ;;
    *) die "Format invalide : $OUTPUT_FORMAT (attendu: table|json|csv)." ;;
  esac
}

# ---------------------------------------------------------------------------
# Mode dry-run : affiche le plan (contextes, namespace, commandes, fichiers
# .key qui seraient produits) SANS contacter de cluster ni écrire de fichier.
# ---------------------------------------------------------------------------
print_dry_run() {
  # Le client réel dépend de la détection OpenShift par cluster (impossible
  # sans contacter le cluster), on affiche donc le client de sonde.
  local probe; probe="$(config_cli)"

  info "DRY-RUN : aucune connexion cluster, aucun fichier écrit."
  printf '\n'
  printf 'Plan :\n'
  printf '  Namespace        : %s\n' "$NAMESPACE"
  printf '  Format de sortie : %s\n' "$OUTPUT_FORMAT"
  printf '  Kubeconfig       : %s\n' "${KUBECONFIG_PATH:-<défaut>}"
  printf '  Output-dir       : %s\n' "${OUTPUT_DIR:-<aucun>}"
  printf '  Détection CLI    : OpenShift -> oc, sinon kubectl (par contexte)\n'
  printf '  Sonde de config  : %s\n' "$probe"
  printf '  Contextes (%d)   :\n' "${#CONTEXTS[@]}"

  local ctx ctx_label kc_flag=""
  [[ -n "$KUBECONFIG_PATH" ]] && kc_flag=" --kubeconfig $KUBECONFIG_PATH"
  for ctx in "${CONTEXTS[@]}"; do
    ctx_label="${ctx:-<contexte courant>}"
    local ctx_flag=""
    [[ -n "$ctx" ]] && ctx_flag=" --context $ctx"
    printf '    - %s\n' "$ctx_label"
    printf '        détection : <oc|kubectl>%s%s api-resources\n' "$kc_flag" "$ctx_flag"
    printf '        lecture   : <oc|kubectl>%s%s get %s -n %s -o json\n' \
      "$kc_flag" "$ctx_flag" "$K10_POLICY_CRD" "$NAMESPACE"
    if [[ -n "$OUTPUT_DIR" ]]; then
      printf '        écrirait  : %s/%s__%s__<policy>.key\n' \
        "$OUTPUT_DIR" "$ctx_label" "$NAMESPACE"
    fi
  done
  printf '\n'
}

# ---------------------------------------------------------------------------
# Point d'entrée.
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  check_deps
  resolve_contexts

  # Dry-run : on affiche le plan et on s'arrête là.
  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run
    exit 0
  fi

  info "Contextes à traiter : ${#CONTEXTS[@]}"

  # On parcourt tous les contextes ; un échec sur l'un n'interrompt pas
  # les autres (process_context journalise et retourne).
  local ctx
  for ctx in "${CONTEXTS[@]}"; do
    process_context "$ctx"
  done

  # Écriture des fichiers .key (si --output-dir) puis sortie principale.
  write_key_files

  if (( ${#RESULTS[@]} == 0 )); then
    warn "Aucune import key trouvée sur l'ensemble des clusters traités."
    # Sortie cohérente même vide (tableau vide en JSON).
    [[ "$OUTPUT_FORMAT" == "json" ]] && echo "[]"
    exit 0
  fi

  render_output
}

main "$@"
