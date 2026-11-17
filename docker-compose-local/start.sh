#!/usr/bin/env bash
# Startet das Gesamtsystem lokal mit Podman und wartet, bis Backend und Frontend "healthy" sind.
#   ./start.sh            bauen + starten
#   ./start.sh --no-build vorhandene Images verwenden (z. B. nach ./use-ecr-images.sh)
set -euo pipefail
cd "$(dirname "$0")"

# Compose-Werkzeug: bevorzugt podman-compose, sonst "podman compose" (Provider), sonst docker compose
if command -v podman-compose >/dev/null; then COMPOSE=(podman-compose)
elif podman compose version >/dev/null 2>&1; then COMPOSE=(podman compose)
else echo "podman-compose fehlt: pip install podman-compose" >&2; exit 1; fi

[ -f .env ] || { cp .env.example .env; echo ".env aus .env.example erstellt"; }
set -a; source .env; set +a

BUILD=(--build); [ "${1:-}" = "--no-build" ] && BUILD=()
"${COMPOSE[@]}" up -d "${BUILD[@]}"

wait_healthy() { # container-name-teil, timeout-sekunden
  local name="$1" deadline=$(( $(date +%s) + $2 )) state
  printf 'Warte auf %-10s' "$name"
  while :; do
    state="$(podman ps -a --filter "label=com.docker.compose.project=biztrips" --filter "name=$name" \
      --format '{{.Status}}' | head -1)"
    case "$state" in
      *"(healthy)"*) echo " healthy"; return 0 ;;
      *Exited*|*"(unhealthy)"*) echo " FEHLER: $state"; "${COMPOSE[@]}" logs --tail 50 "$name"; return 1 ;;
    esac
    [ "$(date +%s)" -gt "$deadline" ] && { echo " TIMEOUT ($state)"; return 1; }
    printf '.'; sleep 3
  done
}
wait_healthy mariadb 120
wait_healthy backend 300
wait_healthy frontend 60
podman ps --filter "label=com.docker.compose.project=biztrips" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

cat <<OUT

Frontend:  http://localhost:${FRONTEND_PORT:-3000}
Backend:   http://localhost:8080/v1/trips
Health:    http://localhost:8080/actuator/health
MinIO:     http://localhost:9001   (Login: S3_ACCESS_KEY / S3_SECRET_KEY aus .env)
Stoppen:   ${COMPOSE[*]} down      (Daten loeschen: ${COMPOSE[*]} down -v)
OUT
