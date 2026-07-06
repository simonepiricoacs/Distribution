#!/usr/bin/env bash
#
# Distribution-spring-app — container bootstrap
#
# Scarica a runtime i moduli Water indicati in WATER_MODULES dai repository Maven
# configurati (WATER_MAVEN_REPO_<n>_URL/USER/PASSWORD), li deposita in
# EXTRA_CLASSPATH_DIR (/extlib) e infine avvia il WaterLauncher.
#
# Le variabili d'ambiente del container sono ereditate automaticamente dal processo
# java (exec) -> forward automatico verso l'app Spring (application.properties usa ${VAR}).
#
set -euo pipefail

log() { echo "[bootstrap] $*"; }
err() { echo "[bootstrap][ERROR] $*" >&2; }

EXTRA_CLASSPATH_DIR="${EXTRA_CLASSPATH_DIR:-/extlib}"
BASE_CLASSPATH_DIR="${BASE_CLASSPATH_DIR:-/baselib}"
WATER_MODULES="${WATER_MODULES:-}"
WATER_BASE_MODULES="${WATER_BASE_MODULES:-}"
APP_JAR="${APP_JAR:-/app/app.jar}"
# Entry point of the (flat, Shadow) uber-jar. Launched via -cp (not -jar) so the base
# classpath dir can be appended to the SYSTEM classloader alongside the app jar.
APP_MAIN_CLASS="${APP_MAIN_CLASS:-it.water.distribution.spring.app.WaterLauncher}"

mkdir -p "$EXTRA_CLASSPATH_DIR" "$BASE_CLASSPATH_DIR"

# ---------------------------------------------------------------------------
# Avvio dell'applicazione (env già ereditate -> forward automatico)
# ---------------------------------------------------------------------------
# Keystore fallback (container-level, NOT baked into the jar):
# se WATER_KEYSTORE_FILE non è impostata, si usa il keystore demo generato nell'immagine
# (cartella default-certs). Il jar/sorgente resta fail-fast (#1): application.properties non
# definisce un default, è il container a fornirlo. MAI affidarsi a questo default in produzione.
DEFAULT_KEYSTORE_FILE="${DEFAULT_KEYSTORE_FILE:-/app/default-certs/server.keystore}"

apply_default_keystore() {
    if [ -z "${WATER_KEYSTORE_FILE:-}" ]; then
        if [ -f "$DEFAULT_KEYSTORE_FILE" ]; then
            export WATER_KEYSTORE_FILE="$DEFAULT_KEYSTORE_FILE"
            log "[keystore] WATER_KEYSTORE_FILE non impostata → uso i certificati demo del container (${WATER_KEYSTORE_FILE}). NON usare in produzione."
        else
            err "[keystore] WATER_KEYSTORE_FILE non impostata e nessun keystore demo in ${DEFAULT_KEYSTORE_FILE}."
        fi
    fi
}

start_app() {
    apply_default_keystore
    # Base classpath = app jar + every jar in BASE_CLASSPATH_DIR (wildcard expanded by the JVM,
    # NOT the shell — keep it quoted). These share the application classloader with Spring, so
    # JDBC drivers etc. dropped in BASE_CLASSPATH_DIR are visible at bean-creation time.
    local cp="${APP_JAR}:${BASE_CLASSPATH_DIR}/*"
    log "Avvio WaterLauncher: java ${JAVA_OPTS:-} -cp ${cp} ${APP_MAIN_CLASS}"
    # shellcheck disable=SC2086
    exec java ${JAVA_OPTS:-} -cp "$cp" "$APP_MAIN_CLASS" "$@"
}

# Nessun modulo da provisionare (né Water né base): si avvia direttamente.
# (extraLib baked / volumi montati su /extlib o /baselib continuano a funzionare)
if [ -z "${WATER_MODULES// /}" ] && [ -z "${WATER_BASE_MODULES// /}" ]; then
    log "WATER_MODULES e WATER_BASE_MODULES non impostate: nessun download. Uso eventuali jar già presenti in ${EXTRA_CLASSPATH_DIR} e ${BASE_CLASSPATH_DIR}."
    start_app "$@"
fi

# ---------------------------------------------------------------------------
# Raccolta dei repository configurati: WATER_MAVEN_REPO_<n>_URL/USER/PASSWORD
# Iterazione finché l'URL indicizzato è valorizzato.
# ---------------------------------------------------------------------------
REPO_URLS=()
REPO_USERS=()
REPO_PASSWORDS=()

idx=1
while true; do
    url_var="WATER_MAVEN_REPO_${idx}_URL"
    url_val="${!url_var:-}"
    [ -z "$url_val" ] && break

    user_var="WATER_MAVEN_REPO_${idx}_USER"
    pass_var="WATER_MAVEN_REPO_${idx}_PASSWORD"

    # rimuove eventuale slash finale dalla base URL
    url_val="${url_val%/}"

    REPO_URLS+=("$url_val")
    REPO_USERS+=("${!user_var:-}")
    REPO_PASSWORDS+=("${!pass_var:-}")
    log "Repository #${idx}: ${url_val} (auth: $([ -n "${!user_var:-}" ] && echo sì || echo no))"
    idx=$((idx + 1))
done

if [ "${#REPO_URLS[@]}" -eq 0 ]; then
    err "WATER_MODULES è impostata ma nessun repository configurato (WATER_MAVEN_REPO_1_URL...)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Scarica un singolo file (rel_path) provando i repository in ordine (primo 200 vince).
#   fetch_from_repos <rel_path> <dest> <require_jar:true|false>
# Se require_jar=true, valida i magic bytes ZIP ("PK") e scarta i non-jar (es. HTML da
# un URL repository errato). Imposta la globale FETCH_REPO con il numero del repo vincente.
# Ritorna 0 al primo successo, 1 se nessun repo risolve.
# ---------------------------------------------------------------------------
fetch_from_repos() {
    local rel_path="$1"
    local dest="$2"
    local require_jar="${3:-false}"
    local i base user pass full_url
    for i in "${!REPO_URLS[@]}"; do
        base="${REPO_URLS[$i]}"
        user="${REPO_USERS[$i]}"
        pass="${REPO_PASSWORDS[$i]}"
        full_url="${base}/${rel_path}"
        if [ -n "$user" ]; then
            curl -fsSL -u "${user}:${pass}" -o "$dest" "$full_url" 2>/dev/null || continue
        else
            curl -fsSL -o "$dest" "$full_url" 2>/dev/null || continue
        fi
        # HTTP 200 non basta: un URL errato (es. la UI web di Nexus invece del repository
        # Maven) può restituire 200 con una pagina HTML, che verrebbe salvata come .jar e poi
        # rifiutata dalla JVM con un oscuro errore di classloading. Validiamo i magic bytes.
        if [ "$require_jar" = "true" ] && [ "$(head -c 2 "$dest" 2>/dev/null)" != "PK" ]; then
            err "  ✗ repo #$((i + 1)): '${rel_path}' scaricato ma NON è un jar valido (magic bytes ZIP assenti)."
            err "    Probabile URL repository errato (es. UI web invece del repository Maven). Scarto e continuo."
            rm -f "$dest"
            continue
        fi
        FETCH_REPO=$((i + 1))
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Scarica un singolo modulo (jar) con failover sui repository. download_module <coord> <dest_dir>
# Download "flat": niente risoluzione transitiva. Ogni jar va elencato esplicitamente in
# WATER_MODULES/WATER_BASE_MODULES (i jar *-service-spring sono attesi self-contained).
# ---------------------------------------------------------------------------
download_module() {
    local coord="$1"
    local dest_dir="$2"

    # Validazione formato: groupId:artifactId:version (esattamente 3 segmenti)
    local segments
    IFS=':' read -r -a segments <<< "$coord"
    if [ "${#segments[@]}" -ne 3 ]; then
        err "Coordinata non valida '${coord}': atteso formato groupId:artifactId:version."
        exit 1
    fi

    local group_id="${segments[0]}"
    local artifact_id="${segments[1]}"
    local version="${segments[2]}"

    if [ -z "$group_id" ] || [ -z "$artifact_id" ] || [ -z "$version" ]; then
        err "Coordinata non valida '${coord}': segmenti vuoti."
        exit 1
    fi

    # Solo versioni release: SNAPSHOT non supportato (richiederebbe maven-metadata.xml)
    case "$version" in
        *-SNAPSHOT)
            err "Versione SNAPSHOT non supportata per '${coord}'. Usa una versione release."
            exit 1
            ;;
    esac

    local group_path="${group_id//.//}"
    local rel_path="${group_path}/${artifact_id}/${version}/${artifact_id}-${version}.jar"
    local dest="${dest_dir}/${artifact_id}-${version}.jar"

    if ! fetch_from_repos "$rel_path" "$dest" true; then
        err "Modulo '${coord}' non risolvibile (o nessun jar valido) in nessun repository configurato."
        exit 1
    fi
    log "  ✓ '${coord}' scaricato da repo #${FETCH_REPO} -> ${dest}"
}

# ---------------------------------------------------------------------------
# Iterazione sui moduli richiesti (liste separate da virgola).
# provision_modules <lista-coordinate> <cartella-destinazione>
# Imposta la globale PROVISIONED_COUNT (non usa stdout, così resta libero per i log).
# ---------------------------------------------------------------------------
PROVISIONED_COUNT=0
provision_modules() {
    local list="$1"
    local dest_dir="$2"
    local raw coord
    PROVISIONED_COUNT=0
    IFS=',' read -r -a _mods <<< "$list"
    for raw in "${_mods[@]}"; do
        # trim spazi attorno alla coordinata
        coord="$(echo "$raw" | xargs)"
        [ -z "$coord" ] && continue
        log "Modulo richiesto: ${coord} -> ${dest_dir}"
        download_module "$coord" "$dest_dir"
        PROVISIONED_COUNT=$((PROVISIONED_COUNT + 1))
    done
}

# Moduli Water -> /extlib (classloader figlio isolato del WaterLauncher)
water_count=0
if [ -n "${WATER_MODULES// /}" ]; then
    log "Provisioning moduli Water in ${EXTRA_CLASSPATH_DIR}..."
    provision_modules "$WATER_MODULES" "$EXTRA_CLASSPATH_DIR"
    water_count="$PROVISIONED_COUNT"
fi

# Moduli base (es. driver JDBC) -> /baselib (classpath di sistema, condiviso con Spring)
base_count=0
if [ -n "${WATER_BASE_MODULES// /}" ]; then
    log "Provisioning moduli base in ${BASE_CLASSPATH_DIR}..."
    provision_modules "$WATER_BASE_MODULES" "$BASE_CLASSPATH_DIR"
    base_count="$PROVISIONED_COUNT"
fi

log "Provisioning completato: ${water_count} modulo/i Water, ${base_count} modulo/i base."
start_app "$@"
