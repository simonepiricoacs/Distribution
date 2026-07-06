#!/usr/bin/env bash
#
# build-image.sh — Build dell'immagine base "water-osgi-container"
#
# Costruisce l'immagine Docker che fa da base ai container Water in runtime
# OSGi (Apache Karaf). L'immagine impacchetta la distribuzione Karaf prodotta da
# questo modulo Maven (packaging karaf-assembly) e l'entrypoint che genera a
# runtime la feature dei moduli dinamici (env MODULES).
#
# Il Dockerfile sorgente (src/main/default/Dockerfile-microservices) e
# l'entrypoint (src/main/default/entrypoint.sh) assumono un build-context
# differente dal layout reale del modulo:
#   - COPY ./target/karaf-microservices-<ver>.tar.gz   ma Maven produce
#     target/water-karaf-distribution-<ver>.tar.gz
#   - COPY entrypoint.sh                               ma il file e' in src/main/default/
# Per non modificare i sorgenti, lo script prepara una STAGING DIR coerente con
# le COPY del Dockerfile e builda da li'.
#
# Uso:
#   ./build-image.sh                 # mvn install + build immagine
#   ./build-image.sh --skip-build    # usa il tar.gz gia' presente in target/
#   ./build-image.sh -t myrepo/water-osgi-container:dev
#   ./build-image.sh --version 3.1.0
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Path e default
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="water-osgi-container"
VERSION="3.0.0"
SKIP_BUILD=false
EXTRA_TAGS=()

DOCKERFILE_SRC="$SCRIPT_DIR/src/main/default/Dockerfile-microservices"
ENTRYPOINT_SRC="$SCRIPT_DIR/src/main/default/entrypoint.sh"

log()  { echo "[build-image][osgi] $*"; }
err()  { echo "[build-image][osgi][ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Parsing argomenti
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Uso: $(basename "$0") [opzioni]

Costruisce l'immagine Docker base '${IMAGE_NAME}' per i microservizi Water/OSGi (Karaf).

Opzioni:
  --skip-build           Non ricompila la distribuzione: usa il tar.gz in target/.
  --version <ver>        Versione usata per il tag immagine e il tar (default: ${VERSION}).
  -t, --tag <tag>        Tag aggiuntivo (ripetibile). Es: -t myrepo/water-osgi-container:dev
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
[ -f "$DOCKERFILE_SRC" ]  || die "Dockerfile sorgente non trovato: $DOCKERFILE_SRC"
[ -f "$ENTRYPOINT_SRC" ]  || die "entrypoint sorgente non trovato: $ENTRYPOINT_SRC"

# ---------------------------------------------------------------------------
# 1. Build della distribuzione Karaf (a meno di --skip-build)
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    command -v mvn >/dev/null 2>&1 || die "mvn non trovato nel PATH (richiesto per la build; usa --skip-build per saltarla)."
    log "Build della distribuzione Karaf via 'mvn clean install'..."
    mvn -f "$SCRIPT_DIR/pom.xml" clean install -DskipTests
else
    log "--skip-build: salto la compilazione della distribuzione."
fi

# ---------------------------------------------------------------------------
# 2. Individuazione del tar.gz prodotto da Maven
# ---------------------------------------------------------------------------
TAR_FILE="$(ls -1 "$SCRIPT_DIR"/target/water-karaf-distribution-*.tar.gz 2>/dev/null | head -n 1 || true)"
[ -n "$TAR_FILE" ] && [ -f "$TAR_FILE" ] \
    || die "Nessun tar.gz trovato in target/water-karaf-distribution-*.tar.gz. Esegui senza --skip-build oppure 'mvn clean install'."
log "Distribuzione individuata: $(basename "$TAR_FILE")"

# ---------------------------------------------------------------------------
# 3. Preparazione della staging dir coerente con le COPY del Dockerfile
#    staging/
#      Dockerfile
#      entrypoint.sh
#      target/karaf-microservices-<ver>.tar.gz
# ---------------------------------------------------------------------------
STAGING_DIR="$SCRIPT_DIR/target/docker-build"
trap 'rm -rf "$STAGING_DIR"' EXIT

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/target"

cp "$DOCKERFILE_SRC" "$STAGING_DIR/Dockerfile"
cp "$ENTRYPOINT_SRC" "$STAGING_DIR/entrypoint.sh"
cp "$TAR_FILE"       "$STAGING_DIR/target/karaf-microservices-${VERSION}.tar.gz"
log "Staging dir pronta: $STAGING_DIR"

# ---------------------------------------------------------------------------
# 4. Build dell'immagine Docker
# ---------------------------------------------------------------------------
TAG_ARGS=(-t "${IMAGE_NAME}:${VERSION}" -t "${IMAGE_NAME}:latest")
for t in "${EXTRA_TAGS[@]:-}"; do
    [ -n "$t" ] && TAG_ARGS+=(-t "$t")
done

log "Build immagine: ${IMAGE_NAME}:${VERSION} (+ latest${EXTRA_TAGS:+ + ${#EXTRA_TAGS[@]} tag extra})"
docker build \
    --build-arg "KARAF_MICROSERVICES_VERSION=${VERSION}" \
    "${TAG_ARGS[@]}" \
    -f "$STAGING_DIR/Dockerfile" \
    "$STAGING_DIR"

log "Completato. Immagini disponibili:"
docker images "${IMAGE_NAME}" --format '  {{.Repository}}:{{.Tag}}  ({{.Size}})'
