#!/usr/bin/env bash
# =============================================================================
# RefCard05 - AWS-Infrastruktur fuer BusinessTrips (idempotent, mehrfach ausfuehrbar)
# Ausfuehren in der AWS CloudShell des Learner Labs (us-east-1):
#   git clone https://github.com/Panat-ZHH/refcard-05-fullstack-aws.git && cd refcard-05-fullstack-aws
#   ./infra/provision.sh
# Legt an: ECR (2x), S3-Bucket, Security Groups, RDS MariaDB + Secret, ALB + Target Groups,
#          ECS-Cluster + 2 Fargate-Services (Frontend/Backend). Gibt am Ende die GitHub-Variablen aus.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

log "Account $ACCOUNT_ID, Region $AWS_REGION, VPC $VPC_ID, Subnets: $SUBNETS"

# --- 1. ECR-Repositories ---------------------------------------------------------------
for repo in "$ECR_BACKEND" "$ECR_FRONTEND"; do
  log "ECR-Repository $repo"
  aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 >/dev/null
  # Aufraeumen: ungetaggte Images nach 1 Tag, von sha-Builds nur die letzten 20 behalten
  aws ecr put-lifecycle-policy --repository-name "$repo" --lifecycle-policy-text '{
    "rules": [
      {"rulePriority": 1, "description": "untagged nach 1 Tag loeschen",
       "selection": {"tagStatus": "untagged", "countType": "sinceImagePushed", "countUnit": "days", "countNumber": 1},
       "action": {"type": "expire"}},
      {"rulePriority": 2, "description": "nur die letzten 20 sha-Builds behalten",
       "selection": {"tagStatus": "tagged", "tagPrefixList": ["sha-"], "countType": "imageCountMoreThan", "countNumber": 20},
       "action": {"type": "expire"}}
    ]}' >/dev/null
  ok "$(aws ecr describe-repositories --repository-names "$repo" --query 'repositories[0].repositoryUri' --output text)"
done

# --- 2. S3-Bucket fuer Bilder ----------------------------------------------------------------
log "S3-Bucket $BUCKET"
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
# Ressourcen-Policy: nur TLS; nur LabRole (Backend) und voclabs (Lab-Benutzer/Console) duerfen zugreifen
sed -e "s/\${BUCKET}/$BUCKET/g" -e "s/\${ACCOUNT_ID}/$ACCOUNT_ID/g" policies/s3-bucket-policy.json > /tmp/bucket-policy.json
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/bucket-policy.json
ok "privat, verschluesselt (SSE-S3), versioniert, Bucket-Policy gesetzt"

# --- 3. Security Groups (ALB -> Tasks -> RDS) ------------------------------------------------
ensure_sg() { # name description
  local id; id="$(sg_id "$1" || true)"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" --query GroupId --output text)"
  fi
  echo "$id"
}
allow() { # sg port source(cidr|sg)
  if [[ "$3" == sg-* ]]; then
    aws ec2 authorize-security-group-ingress --group-id "$1" --protocol tcp --port "$2" --source-group "$3" >/dev/null 2>&1 || true
  else
    aws ec2 authorize-security-group-ingress --group-id "$1" --protocol tcp --port "$2" --cidr "$3" >/dev/null 2>&1 || true
  fi
}
log "Security Groups"
SG_ALB="$(ensure_sg "${PREFIX}-alb-sg" 'ALB: HTTP aus dem Internet')"
SG_FE="$(ensure_sg "${PREFIX}-frontend-sg" 'Frontend-Tasks: 8080 nur vom ALB')"
SG_BE="$(ensure_sg "${PREFIX}-backend-sg" 'Backend-Tasks: 8080 nur vom ALB')"
SG_DB="$(ensure_sg "${PREFIX}-rds-sg" 'RDS MariaDB: 3306 nur vom Backend')"
allow "$SG_ALB" 80 0.0.0.0/0
allow "$SG_FE" 8080 "$SG_ALB"
allow "$SG_BE" 8080 "$SG_ALB"
allow "$SG_DB" 3306 "$SG_BE"
ok "alb=$SG_ALB frontend=$SG_FE backend=$SG_BE rds=$SG_DB"

# --- 4. RDS MariaDB + Secret -----------------------------------------------------------------
log "RDS MariaDB $DB_ID"
if ! aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  # Passwort wird nur hier erzeugt, direkt in Secrets Manager abgelegt und nirgends ausgegeben
  DB_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  SECRET_JSON="$(jq -n --arg u "$DB_USER" --arg p "$DB_PASSWORD" --arg d "$DB_NAME" \
    '{username:$u, password:$p, dbname:$d, port:"3306", host:"pending", engine:"mariadb"}')"
  if aws secretsmanager describe-secret --secret-id "$DB_SECRET_NAME" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$DB_SECRET_NAME" --secret-string "$SECRET_JSON" >/dev/null
  else
    aws secretsmanager create-secret --name "$DB_SECRET_NAME" \
      --description "RefCard05 BusinessTrips: RDS-Verbindungsdaten fuer das Backend" \
      --secret-string "$SECRET_JSON" >/dev/null
  fi
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --engine mariadb \
    --db-instance-class db.t3.micro \
    --allocated-storage 20 --storage-type gp3 --storage-encrypted \
    --db-name "$DB_NAME" \
    --master-username "$DB_USER" --master-user-password "$DB_PASSWORD" \
    --vpc-security-group-ids "$SG_DB" \
    --no-publicly-accessible --no-multi-az \
    --backup-retention-period 1 \
    --tags Key=project,Value=refcard05 >/dev/null
  unset DB_PASSWORD SECRET_JSON
  ok "Instanz wird erstellt (dauert ca. 5-10 Minuten) ..."
fi

# --- 5. ALB + Target Groups -----------------------------------------------------------------
log "Application Load Balancer $ALB_NAME"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
    --subnets $SUBNETS --security-groups "$SG_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"

ensure_tg() { # name healthpath
  local arn; arn="$(aws elbv2 describe-target-groups --names "$1" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    arn="$(aws elbv2 create-target-group --name "$1" --protocol HTTP --port 8080 --vpc-id "$VPC_ID" --target-type ip \
      --health-check-path "$2" --health-check-interval-seconds 15 --healthy-threshold-count 2 \
      --unhealthy-threshold-count 3 --matcher HttpCode=200 --query 'TargetGroups[0].TargetGroupArn' --output text)"
  fi
  # schnelleres Rolling Deployment: alte Tasks nach 30s statt 300s aus dem ALB nehmen
  aws elbv2 modify-target-group-attributes --target-group-arn "$arn" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
  echo "$arn"
}
TG_FE_ARN="$(ensure_tg "$TG_FRONTEND" /healthz)"
TG_BE_ARN="$(ensure_tg "$TG_BACKEND" /actuator/health/readiness)"

LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`].ListenerArn' --output text)"
if [ -z "$LISTENER_ARN" ]; then
  LISTENER_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_FE_ARN" --query 'Listeners[0].ListenerArn' --output text)"
fi
# API-Pfade -> Backend, alles andere -> Frontend (nginx)
if [ -z "$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query 'Rules[?Priority==`10`].RuleArn' --output text)" ]; then
  aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 10 \
    --conditions Field=path-pattern,Values='/v1/*','/actuator/*' \
    --actions Type=forward,TargetGroupArn="$TG_BE_ARN" >/dev/null
fi
ok "http://$ALB_DNS  (/v1/*, /actuator/* -> Backend, Rest -> Frontend)"

# --- 6. ECS-Cluster, Log-Gruppen, Services --------------------------------------------------
log "ECS-Cluster $CLUSTER"
if [ "$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)" != "ACTIVE" ]; then
  # Beim allerersten ECS-Cluster im Account legt AWS die Service-Linked-Role erst an -> kurz warten und erneut versuchen
  for attempt in 1 2 3 4 5; do
    aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null 2>/tmp/ecs-err && break
    grep -q "service linked role" /tmp/ecs-err || { cat /tmp/ecs-err; exit 1; }
    warn "ECS Service-Linked-Role noch nicht bereit, Versuch $attempt/5 ..."; sleep 15
  done
fi
# Container Insights: CPU/Memory/Task-Metriken in CloudWatch (Monitoring der Deployments)
aws ecs update-cluster-settings --cluster "$CLUSTER" --settings name=containerInsights,value=enabled >/dev/null 2>&1 \
  || warn "Container Insights im Lab nicht verfuegbar"

for g in /ecs/${PREFIX}-backend /ecs/${PREFIX}-frontend; do
  aws logs create-log-group --log-group-name "$g" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$g" --retention-in-days 14
done
ok "aktiv, Log-Gruppen mit 14 Tagen Retention"

# Platzhalter-Task-Definition, damit der Service existiert. desiredCount=0 -> es laeuft nichts,
# bis die Pipeline das erste echte Image deployt (setzt desired-count auf 1).
ensure_service() { # service family container tg sg grace
  local status; status="$(aws ecs describe-services --cluster "$CLUSTER" --services "$1" --query 'services[0].status' --output text 2>/dev/null || true)"
  if [ "$status" = "ACTIVE" ]; then ok "Service $1 existiert"; return; fi
  aws ecs register-task-definition --family "$2" --requires-compatibilities FARGATE --network-mode awsvpc \
    --cpu 256 --memory 512 --execution-role-arn "$LAB_ROLE_ARN" \
    --container-definitions "[{\"name\":\"$3\",\"image\":\"public.ecr.aws/docker/library/busybox:stable\",\"essential\":true,\"portMappings\":[{\"containerPort\":8080}]}]" >/dev/null
  aws ecs create-service --cluster "$CLUSTER" --service-name "$1" --task-definition "$2" \
    --desired-count 0 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS// /,}],securityGroups=[$5],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$4,containerName=$3,containerPort=8080" \
    --health-check-grace-period-seconds "$6" \
    --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}" \
    --propagate-tags SERVICE --tags key=project,value=refcard05 >/dev/null
  ok "Service $1 angelegt (Circuit Breaker mit Auto-Rollback)"
}
log "ECS-Services"
ensure_service "$SVC_FRONTEND" "${PREFIX}-frontend" "${PREFIX}-frontend" "$TG_FE_ARN" "$SG_FE" 30
ensure_service "$SVC_BACKEND" "${PREFIX}-backend" "${PREFIX}-backend" "$TG_BE_ARN" "$SG_BE" 180

# --- 7. RDS fertigstellen: Endpoint ins Secret schreiben --------------------------------------
log "Warte auf RDS (kann einige Minuten dauern) ..."
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].Endpoint.Address' --output text)"
CURRENT="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_NAME" --query SecretString --output text)"
if [ "$(echo "$CURRENT" | jq -r .host)" != "$DB_HOST" ]; then
  aws secretsmanager put-secret-value --secret-id "$DB_SECRET_NAME" \
    --secret-string "$(echo "$CURRENT" | jq --arg h "$DB_HOST" '.host=$h')" >/dev/null
fi
unset CURRENT
ok "RDS verfuegbar: $DB_HOST (Endpoint im Secret $DB_SECRET_NAME)"

DB_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$DB_SECRET_NAME" --query ARN --output text)"
cat <<OUT

=============================================================================
 Fertig. Diese Werte als GitHub *Repository-Variables* setzen (keine Geheimnisse):
   Backend-Repo:   DB_SECRET_ARN = $DB_SECRET_ARN
                   S3_BUCKET     = $BUCKET
                   APP_URL       = http://$ALB_DNS
   Frontend-Repo:  VITE_API_BASE_URL = http://$ALB_DNS/
                   APP_URL           = http://$ALB_DNS
 Und in BEIDEN Repos die Learner-Lab-Zugangsdaten als *Secrets*:
   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
=============================================================================
OUT
