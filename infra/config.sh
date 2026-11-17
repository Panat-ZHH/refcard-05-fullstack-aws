# Gemeinsame Konfiguration fuer provision.sh / verify.sh / teardown.sh
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export PREFIX="${PREFIX:-biztrips}"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

export CLUSTER="${PREFIX}-cluster"
export ECR_BACKEND="${PREFIX}-backend"
export ECR_FRONTEND="${PREFIX}-frontend"
export SVC_BACKEND="${PREFIX}-backend-service"
export SVC_FRONTEND="${PREFIX}-frontend-service"
export BUCKET="${PREFIX}-images-${ACCOUNT_ID}"
export DB_ID="${PREFIX}-db"
export DB_NAME="db_biztrips"
export DB_USER="biztrips_app"
export DB_SECRET_NAME="${PREFIX}/db"
export ALB_NAME="${PREFIX}-alb"
export TG_BACKEND="${PREFIX}-backend-tg"
export TG_FRONTEND="${PREFIX}-frontend-tg"
# Learner Lab: einzige verfuegbare Rolle (iam:CreateRole ist gesperrt)
export LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"

export VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
# zwei Default-Subnets in us-east-1a/b (ALB braucht >= 2 AZs)
export SUBNETS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  Name=availability-zone,Values=${AWS_REGION}a,${AWS_REGION}b --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')"

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m    ok: %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m    !! %s\033[0m\n' "$*"; }

sg_id() { aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values="$1" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v None; }
