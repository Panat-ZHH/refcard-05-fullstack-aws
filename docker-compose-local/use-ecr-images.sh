#!/usr/bin/env bash
# Zieht ein Release aus Amazon ECR und startet es lokal (statt lokal zu bauen).
#   ./use-ecr-images.sh 1.0.0          (benoetigt AWS-CLI mit Learner-Lab-Credentials)
# Hinweis: das Frontend-Image aus ECR enthaelt die ALB-URL als Backend-Adresse (VITE_API_BASE_URL wird
# beim Build eingebettet) - fuer reine lokale Entwicklung deshalb ./start.sh (lokal bauen) verwenden.
set -euo pipefail
cd "$(dirname "$0")"
TAG="${1:-latest}"
REGION="${AWS_REGION:-us-east-1}"
REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$REGION.amazonaws.com"
aws ecr get-login-password --region "$REGION" | podman login --username AWS --password-stdin "$REGISTRY"
for svc in backend frontend; do
  podman pull "$REGISTRY/biztrips-$svc:$TAG"
  podman tag "$REGISTRY/biztrips-$svc:$TAG" "localhost/biztrips-$svc:local"
done
./start.sh --no-build
