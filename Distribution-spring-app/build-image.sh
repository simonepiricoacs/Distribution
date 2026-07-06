#!/usr/bin/env bash
#
# build-image.sh — Build dell'immagine base "water-spring-container"
#
# Costruisce l'immagine Docker che fa da base ai container Water in runtime
# Spring/Spring Boot. L'immagine impacchetta il fat jar di Distribution-spring-app
# (WaterLauncher -> WaterSpringApplication) e l'entrypoint di provisioning dei
# moduli a runtime.
#
# Uso:
#   ./build-image.sh                 # builda il jar (yo water:build) e poi l'immagine
#   ./build-image.sh --skip-build    # usa il jar gia' presente in build/libs/
#   ./build-image.sh -t myrepo/water-spring-container:dev   # tag aggiuntivo/override
#   ./build-image.sh --version 3.1.0
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Path e default
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="water-spring-container"
VERSION="3.0.0"
SKIP_BUILD=false
EXTRA_TAGS=()

log()  { echo "[build-image][spring] $*"; }
err()  { echo "[build-image][spring][ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Parsing argomenti
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Uso: $(basename "$0") [opzioni]

Costruisce l'immagine Docker base '${IMAGE_NAME}' per i microservizi Water/Spring.

Opzioni:
  --skip-build           Non ricompila il jar: usa quello presente in build/libs/.
  --version <ver>        Versione usata per il tag immagine (default: ${VERSION}).
  -t, --tag <tag>        Tag aggiuntivo (ripetibile). Es: -t myrepo/water-spring-container:dev
  -h, --help             Mostra questo aiuto.

Tag prodotti di default: ${IMAGE_NAME}:<version> e ${IMAGE_NAME}:latest
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true; shift ;;
        --version)    VERSION="${2:?--version richiede un valore}"; shift 2 ;;
        -t|--tag)     EXTRA_TAGS+=("${2:?--tag richiede un valore}"); shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            err "Opzione sconosciuta: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisiti
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker non trovato nel PATH."

# ---------------------------------------------------------------------------
# 1. Build del fat jar (a meno di --skip-build)
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    log "Build del fat jar via 'yo water:build --projects Distribution'..."
    command -v yo >/dev/null 2>&1 || die "yo non trovato nel PATH (richiesto per la build; usa --skip-build per saltarla)."
    # La build del sottoprogetto Distribution produce build/libs/Distribution-spring-app-<ver>.jar
    ( cd "$SCRIPT_DIR/.." && yo water:build --projects Distribution )
else
    log "--skip-build: salto la compilazione del jar."
fi

# ---------------------------------------------------------------------------
# 2. Verifica presenza del jar
# ---------------------------------------------------------------------------
JAR_FILE="$(ls -1 "$SCRIPT_DIR"/build/libs/Distribution-spring-app-*.jar 2>/dev/null | head -n 1 || true)"
[ -n "$JAR_FILE" ] && [ -f "$JAR_FILE" ] \
    || die "Nessun jar trovato in build/libs/Distribution-spring-app-*.jar. Esegui senza --skip-build oppure 'yo water:build --projects Distribution'."
log "Jar individuato: $(basename "$JAR_FILE")"

# ---------------------------------------------------------------------------
# 3. Build dell'immagine Docker
# ---------------------------------------------------------------------------
TAG_ARGS=(-t "${IMAGE_NAME}:${VERSION}" -t "${IMAGE_NAME}:latest")
for t in "${EXTRA_TAGS[@]:-}"; do
    [ -n "$t" ] && TAG_ARGS+=(-t "$t")
done

log "Build immagine: ${IMAGE_NAME}:${VERSION} (+ latest${EXTRA_TAGS:+ + ${#EXTRA_TAGS[@]} tag extra})"
docker build "${TAG_ARGS[@]}" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

log "Completato. Immagini disponibili:"
docker images "${IMAGE_NAME}" --format '  {{.Repository}}:{{.Tag}}  ({{.Size}})'
