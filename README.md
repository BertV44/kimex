# kimex — Kasten Import Key Extractor

`kimex` récupère les **import keys** (`receiveString`) des policies
[Kasten K10](https://docs.kasten.io/) et les exporte de façon structurée.

## Pourquoi ?

Lors d'une migration/restauration K10, les **import policies** du cluster
receveur ont besoin de la clé d'import (`receiveString`) générée par les
**export policies** du cluster source. Cette clé est noyée dans la CRD des
policies et n'est pas triviale à extraire.

`kimex` répond à deux besoins :

1. **Faciliter la création des import policies** sur un cluster receveur en
   exposant clairement `receiveString`, `profile` et `migrationToken`.
2. **Séquestrer ces données sensibles** afin de pouvoir restaurer même en
   l'absence du catalog K10 d'origine.

## Comment ça marche

- CRD ciblée : `policies.config.kio.kasten.io` (`v1alpha1`)
- Clé d'import : `spec.actions[].exportParameters.receiveString`
- Présente uniquement sur les actions d'export avec `exportData.enabled=true`
- Références associées conservées :
  - `exportParameters.profile` (`name` + `namespace`)
  - `exportParameters.migrationToken` (`name` + `namespace`)

Le parsing est fait via `... -o json | jq` (pas de `grep`/`sed` fragile sur
le YAML).

### Détection de l'environnement

- Si **OpenShift** est détecté (présence des API groups `route.openshift.io`
  ou `config.openshift.io`), `kimex` utilise **exclusivement `oc`**.
- Sinon, fallback sur `kubectl`.
- La détection se fait **par contexte** (chaque cluster peut différer).

## Prérequis

- `jq`
- `oc` **ou** `kubectl` (les deux idéalement en environnement mixte)

Les dépendances sont vérifiées au démarrage ; le script échoue proprement si
elles manquent.

## Installation

```bash
chmod +x kimex.sh
# optionnel : le mettre dans le PATH
sudo ln -s "$(pwd)/kimex.sh" /usr/local/bin/kimex
```

## Options

| Option | Description |
|--------|-------------|
| `-n, --namespace <ns>` | Namespace K10 (défaut : `kasten-io`). |
| `-c, --context <ctx>` | Contexte kubeconfig. Répétable ou séparé par des virgules. |
| `--context-file <f>` | Fichier avec un contexte par ligne (`#` = commentaire). |
| `--all-contexts` | Itère sur tous les contextes du kubeconfig. |
| `--kubeconfig <path>` | Kubeconfig spécifique. |
| `-o, --output <fmt>` | `table` (défaut), `json` ou `csv`. |
| `-d, --output-dir <dir>` | Écrit un fichier `.key` par policy (receiveString seul). |
| `--dry-run` | Affiche le plan (contextes, commandes, fichiers `.key`) sans contacter de cluster ni écrire de fichier. |
| `-h, --help` | Aide. |

## Exemples — mono-cluster

```bash
# Contexte courant, namespace par défaut, sortie table
./kimex.sh

# Namespace personnalisé en JSON
./kimex.sh -n kasten-io -o json

# Un contexte précis + séquestre des clés sur disque
./kimex.sh -c prod-cluster -d ./keys

# Kubeconfig dédié
./kimex.sh --kubeconfig /etc/k10/admin.conf -c recette -o json
```

## Exemples — multi-cluster

```bash
# Plusieurs contextes (virgules)
./kimex.sh -c prod-a,prod-b -o json

# Plusieurs contextes (option répétée)
./kimex.sh -c prod-a -c prod-b -d ./keys

# Liste de contextes depuis un fichier
cat > clusters.txt <<EOF
# clusters de production
prod-a
prod-b
EOF
./kimex.sh --context-file clusters.txt -d ./keys

# Tous les contextes du kubeconfig courant
./kimex.sh --all-contexts -o json
```

Chaque résultat est **tagué avec le contexte/cluster d'origine**. Un cluster
injoignable, un namespace absent ou un contexte invalide est journalisé puis
**ignoré** : les autres clusters continuent d'être traités.

## Formats de sortie

- **table** (défaut) : aperçu lisible. Le `receiveString` y est **tronqué**
  (valeur complète via `--output json`, `--output csv` ou `--output-dir`).
- **json** : tableau complet d'objets, idéal pour l'automatisation.
- **csv** : une ligne par policy avec `receiveString` **complet** (en-tête
  inclus, échappement géré). Idéal tableur / scripts :
  `./kimex.sh -c prod-a -o csv > import-keys.csv`
- **fichiers `.key`** (`--output-dir`) : un fichier par policy nommé
  `<contexte>__<namespace>__<policy>.key`, contenant **uniquement** le
  `receiveString` (copier-coller direct). Créés en `chmod 600`.

Exemple d'objet JSON :

```json
{
  "context": "prod-a",
  "policy": "mysql-export",
  "namespace": "kasten-io",
  "receiveString": "<clé de migration>",
  "profile": "azure-blob",
  "profileNs": "kasten-io",
  "migrationToken": "mysql-export-token",
  "migrationTokenNs": "kasten-io"
}
```

## ⚠️ Sécurité

Le `receiveString` est une **donnée sensible** (clé de migration). Quiconque
la possède peut importer vos données K10.

- **Ne committez jamais** les sorties de `kimex`.
- Le `.gitignore` fourni couvre `*.key` et les répertoires `--output-dir`
  usuels (`keys/`, `output/`, etc.).
- Les fichiers `.key` sont créés en `chmod 600`.
- Stockez les clés séquestrées dans un coffre (Vault, secret manager…),
  pas en clair dans un dépôt.

Vérifiez avant de pousser :

```bash
git status --ignored
```
