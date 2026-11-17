#!/usr/bin/env bash
# Komfort-Skript: .env anlegen (falls noetig), alles bauen/starten und warten, bis alles gesund ist.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { cp .env.example .env; echo ".env aus .env.example erstellt"; }
docker compose up -d --build --wait --wait-timeout 300
docker compose ps
echo
echo "Frontend:  http://localhost:${FRONTEND_PORT:-3000}"
echo "Backend:   http://localhost:8080/v1/trips"
echo "Health:    http://localhost:8080/actuator/health"
echo "MinIO:     http://localhost:9001"
