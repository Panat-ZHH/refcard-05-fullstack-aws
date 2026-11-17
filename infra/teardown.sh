#!/usr/bin/env bash
# =============================================================================
# RefCard05 - ALLE Ressourcen wieder loeschen (Lab-Budget schonen). Nicht rueckgaengig zu machen!
#   ./infra/teardown.sh --yes
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./config.sh
[ "${1:-}" = "--yes" ] || { echo "Loescht ECS, ALB, RDS (ohne Snapshot), Secret, S3-Bucket inkl. Bilder und ECR-Images. Mit --yes bestaetigen."; exit 1; }

log "ECS-Services und Cluster"
for s in "$SVC_FRONTEND" "$SVC_BACKEND"; do
  aws ecs update-service --cluster "$CLUSTER" --service "$s" --desired-count 0 >/dev/null 2>&1
  aws ecs delete-service --cluster "$CLUSTER" --service "$s" --force >/dev/null 2>&1
done
aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1

log "ALB und Target Groups"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)"
[ -n "$ALB_ARN" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
for tg in "$TG_FRONTEND" "$TG_BACKEND"; do
  arn="$(aws elbv2 describe-target-groups --names "$tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  [ -n "$arn" ] && aws elbv2 delete-target-group --target-group-arn "$arn"
done

log "RDS und Secret"
aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 \
  && aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID"
aws secretsmanager delete-secret --secret-id "$DB_SECRET_NAME" --force-delete-without-recovery >/dev/null 2>&1

log "S3-Bucket (alle Versionen)"
python3 - "$BUCKET" <<'PY'
import boto3, sys
b = boto3.resource("s3").Bucket(sys.argv[1])
try:
    b.object_versions.delete(); b.delete(); print("    geloescht")
except Exception as e:
    print("    ", e)
PY

log "ECR-Repositories"
for r in "$ECR_BACKEND" "$ECR_FRONTEND"; do aws ecr delete-repository --repository-name "$r" --force >/dev/null 2>&1; done

log "Security Groups und Log-Gruppen"
sleep 30
for n in rds backend frontend alb; do id="$(sg_id ${PREFIX}-$n-sg)"; [ -n "$id" ] && aws ec2 delete-security-group --group-id "$id"; done
for g in backend frontend iam-check; do aws logs delete-log-group --log-group-name /ecs/${PREFIX}-$g 2>/dev/null; done
ok "fertig"
