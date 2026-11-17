#!/usr/bin/env bash
#
# dev-deploy.sh — initialise et démarre la stack Databasus.
#
# Idempotent : relançable autant de fois que nécessaire. Il enchaîne
#   1. vérification de Docker / Docker Compose,
#   2. création de .env depuis .env.example s'il manque,
#   3. création du réseau Docker externe s'il manque,
#   4. validation du compose,
#   5. pull + up -d,
#   6. attente de l'état « healthy » et rappel des étapes suivantes.
#
# Usage :
#   ./dev-deploy.sh              # installation / mise à jour complète
#   ./dev-deploy.sh --no-pull    # ne retélécharge pas l'image
#   ./dev-deploy.sh --no-wait    # ne bloque pas sur le healthcheck
#   ./dev-deploy.sh --help

set -Eeuo pipefail

# Toujours travailler dans le dossier du dépôt, quel que soit l'appelant.
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

DO_PULL=1
DO_WAIT=1
WAIT_TIMEOUT=240 # secondes ; la doc amont annonce un démarrage jusqu'à ~2 min

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  # Affiche l'en-tête de commentaires du script (hors shebang).
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) DO_PULL=0 ;;
    --no-wait) DO_WAIT=0 ;;
    -h|--help) usage ;;
    *) fail "option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

# Lit une clé de .env sans sourcer le fichier : certaines valeurs contiennent
# des espaces ou des caractères que le shell interpréterait (SMTP_FROM, etc.).
env_value() {
  local key="$1" default="$2" line
  line="$(grep -E "^[[:space:]]*${key}=" .env 2>/dev/null | tail -n 1 || true)"
  if [ -z "$line" ]; then
    printf '%s' "$default"
  else
    printf '%s' "${line#*=}"
  fi
}

# --- 1. Prérequis -----------------------------------------------------------

command -v docker >/dev/null 2>&1 \
  || fail "Docker n'est pas installé (https://docs.docker.com/engine/install/)."

docker compose version >/dev/null 2>&1 \
  || fail "le plugin Docker Compose v2 est absent (commande « docker compose »)."

docker info >/dev/null 2>&1 \
  || fail "le démon Docker est injoignable. Démarrez-le, ou ajoutez votre utilisateur au groupe docker."

[ -f docker-compose.yml ] || fail "docker-compose.yml introuvable dans $PWD."

# --- 2. Fichier .env --------------------------------------------------------

if [ -f .env ]; then
  info ".env présent, conservé tel quel."
else
  [ -f .env.example ] || fail ".env et .env.example sont tous les deux absents."
  cp .env.example .env
  chmod 600 .env
  warn ".env créé depuis .env.example avec les valeurs par défaut."
  warn "Relisez-le (port, tag, nom du réseau) avant une mise en production."
fi

NETWORK="$(env_value DATABASUS_DB_NETWORK databases)"
PORT="$(env_value DATABASUS_PORT 4005)"
BIND="$(env_value DATABASUS_BIND_ADDRESS 0.0.0.0)"
CONTAINER="$(env_value DATABASUS_CONTAINER_NAME databasus)"

# --- 3. Réseau Docker externe ----------------------------------------------

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  info "réseau « $NETWORK » déjà présent."
else
  info "création du réseau « $NETWORK »…"
  docker network create "$NETWORK" >/dev/null
fi

# --- 4. Validation du compose ----------------------------------------------

info "validation de la configuration Compose…"
docker compose config -q

# --- 5. Démarrage -----------------------------------------------------------

if [ "$DO_PULL" -eq 1 ]; then
  info "récupération de l'image…"
  docker compose pull
fi

info "démarrage de la stack…"
docker compose up -d

# --- 6. Attente du healthcheck ---------------------------------------------

if [ "$DO_WAIT" -eq 1 ]; then
  info "attente de l'état « healthy » (jusqu'à ${WAIT_TIMEOUT}s)…"
  deadline=$((SECONDS + WAIT_TIMEOUT))
  status=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$CONTAINER" 2>/dev/null || echo absent)"
    case "$status" in
      healthy) break ;;
      none)    warn "aucun healthcheck sur le conteneur, attente abandonnée."; break ;;
    esac
    sleep 5
  done

  if [ "$status" != "healthy" ] && [ "$status" != "none" ]; then
    warn "état après ${WAIT_TIMEOUT}s : ${status:-inconnu}."
    warn "Journaux : docker compose logs -f"
    exit 1
  fi
fi

# --- 7. Suite des opérations -----------------------------------------------

if [ "$BIND" = "0.0.0.0" ]; then
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$host" ] || host="localhost"
else
  host="$BIND"
fi

docker compose ps
echo
info "Databasus est accessible sur http://${host}:${PORT}"
cat <<'NEXT'

Étapes suivantes (tout se passe dans l'interface) :
  1. créer le premier compte — il administre l'instance ;
  2. déclarer les destinations S3 (Backblaze B2, Cloudflare R2) : voir README §5 ;
  3. déclarer les bases à sauvegarder, leur planning et leur rétention : README §4.

Pensez à sauvegarder le volume de données : il contient la clé de chiffrement
des sauvegardes (README §7).
NEXT
