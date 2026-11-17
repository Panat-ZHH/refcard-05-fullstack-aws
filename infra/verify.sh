#!/usr/bin/env bash
# =============================================================================
# RefCard05 - Status aller Ressourcen + Nachweis Least Privilege (S3)
#   ./infra/verify.sh            Status von ECR, S3, RDS, ECS, ALB + HTTP-Checks
#   ./infra/verify.sh --iam      zusaetzlich Least-Privilege-Nachweis als einmaliger ECS-Task
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./config.sh

ALB_DNS="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)"

log "ECR-Images (neueste 5 je Repository)"
for repo in "$ECR_BACKEND" "$ECR_FRONTEND"; do
  echo "  $repo:"
  aws ecr describe-images --repository-name "$repo" --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].[imagePushedAt,join(`,`,imageTags||[`-`])]' --output text | sed 's/^/    /'
done

log "S3-Bucket $BUCKET"
aws s3 ls "s3://$BUCKET/" --recursive --human-readable | sed 's/^/    /'

log "RDS"
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,PubliclyAccessible,StorageEncrypted]' --output text | sed 's/^/    status engine version class public encrypted: /'

log "ECS-Services"
aws ecs describe-services --cluster "$CLUSTER" --services "$SVC_FRONTEND" "$SVC_BACKEND" \
  --query 'services[].[serviceName,status,desiredCount,runningCount,taskDefinition,deployments[0].rolloutState]' --output text | sed 's/^/    /'

log "ALB-Target-Health"
for tg in "$TG_FRONTEND" "$TG_BACKEND"; do
  arn="$(aws elbv2 describe-target-groups --names "$tg" --query 'TargetGroups[0].TargetGroupArn' --output text)"
  echo "    $tg: $(aws elbv2 describe-target-health --target-group-arn "$arn" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
done

log "HTTP-Checks gegen http://$ALB_DNS"
for path in /healthz /version.json /actuator/health/readiness /actuator/info /v1/trips /v1/images; do
  code="$(curl -s -o /tmp/out -w '%{http_code}' "http://$ALB_DNS$path")"
  printf '    %-28s %s  %s\n' "$path" "$code" "$(head -c 150 /tmp/out | tr -d '\n')"
done

if [ "${1:-}" = "--iam" ]; then
  log "Least-Privilege-Nachweis: ECS-Task mit LabRole nimmt Session Policy an und testet Rechte"
  POLICY="$(sed "s/\${BUCKET}/$BUCKET/g" policies/s3-least-privilege-policy.json | jq -c .)"
  SCRIPT='set -- $(aws sts assume-role --role-arn "$ROLE" --role-session-name least-privilege-check --policy "$POLICY" --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" --output text)
export AWS_ACCESS_KEY_ID=$1 AWS_SECRET_ACCESS_KEY=$2 AWS_SESSION_TOKEN=$3
echo "Identitaet: $(aws sts get-caller-identity --query Arn --output text)"
t(){ exp=$1; shift; if "$@" >/dev/null 2>&1; then r=ALLOWED; else r=DENIED; fi; [ $r = $exp ] && m=OK || m=FEHLER; echo "[$m] erwartet $exp, ist $r: $*"; }
t ALLOWED aws s3api list-objects-v2 --bucket "$BUCKET" --max-keys 1
t ALLOWED aws s3api head-object --bucket "$BUCKET" --key trips/1
t ALLOWED aws s3api put-object --bucket "$BUCKET" --key trips/least-privilege-check.txt
t DENIED  aws s3api put-object --bucket "$BUCKET" --key other/x.txt
t DENIED  aws s3api delete-object --bucket "$BUCKET" --key trips/least-privilege-check.txt
t DENIED  aws s3api list-buckets
t DENIED  aws ecr describe-repositories
t DENIED  aws rds describe-db-instances
t DENIED  aws secretsmanager list-secrets'
  aws logs create-log-group --log-group-name /ecs/${PREFIX}-iam-check 2>/dev/null || true
  aws ecs register-task-definition --family "${PREFIX}-iam-check" --requires-compatibilities FARGATE --network-mode awsvpc \
    --cpu 256 --memory 512 --execution-role-arn "$LAB_ROLE_ARN" --task-role-arn "$LAB_ROLE_ARN" \
    --container-definitions "$(jq -nc --arg s "$SCRIPT" --arg p "$POLICY" --arg r "$LAB_ROLE_ARN" --arg b "$BUCKET" --arg reg "$AWS_REGION" --arg g "/ecs/${PREFIX}-iam-check" '[{
      name:"iam-check", image:"public.ecr.aws/aws-cli/aws-cli:latest", essential:true,
      entryPoint:["sh","-c"], command:[$s],
      environment:[{name:"POLICY",value:$p},{name:"ROLE",value:$r},{name:"BUCKET",value:$b},{name:"AWS_REGION",value:$reg}],
      logConfiguration:{logDriver:"awslogs",options:{"awslogs-group":$g,"awslogs-region":$reg,"awslogs-stream-prefix":"check"}}}]')" >/dev/null
  TASK="$(aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE --task-definition "${PREFIX}-iam-check" \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS// /,}],securityGroups=[$(sg_id ${PREFIX}-backend-sg)],assignPublicIp=ENABLED}" \
    --query 'tasks[0].taskArn' --output text)"
  echo "    Task $TASK laeuft ..."
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK"
  sleep 5
  aws logs get-log-events --log-group-name "/ecs/${PREFIX}-iam-check" \
    --log-stream-name "check/iam-check/${TASK##*/}" --query 'events[].message' --output text | tr '\t' '\n' | sed 's/^/    /'
fi
