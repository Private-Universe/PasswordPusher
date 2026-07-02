#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --db-url DB_URL [--image IMAGE_URI] [--cluster CLUSTER] [--service SERVICE] [--container CONTAINER_NAME] [--yes]

This script runs a one-off ECS Fargate task to perform the Rails database migration using an image you specify
(or the current service image if none provided). It will:
 - fetch the current service task definition and network configuration
 - optionally register a temporary task definition using --image
 - run a single task that executes: bundle exec rake db:migrate
 - (if a temporary task definition was registered) leave it registered but prints its ARN

IMPORTANT: Back up your database before running. This script will ask for confirmation unless --yes is given.

Options:
  --db-url DB_URL          Required. The DATABASE_URL to pass to the task.
  --image IMAGE_URI        Optional. If provided, a temporary task definition will be registered using this image.
  --cluster CLUSTER        ECS cluster name (default: PasswordPusherV3)
  --service SERVICE        ECS service name to reuse network config (default: passwordpusher)
  --container CONTAINER    Container name in the task definition (default: passwordpusherv2)
  --yes                    Skip confirmation prompt (use with caution)
EOF
}

# defaults
CLUSTER="PasswordPusherV3"
SERVICE="passwordpusher"
CONTAINER="passwordpusherv2"
IMAGE=""
ASSUME_YES=0
DB_URL=""

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --db-url) DB_URL="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --cluster) CLUSTER="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --container) CONTAINER="$2"; shift 2;;
    --yes) ASSUME_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [ -z "$DB_URL" ]; then
  echo "--db-url is required"
  usage
  exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "aws CLI required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

printf "\n*** REMINDER: BACK UP YOUR DATABASE BEFORE PROCEEDING ***\n\n"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -p "I have backed up the DB and want to continue (type 'yes' to continue): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Aborting. Backup your DB and re-run when ready."; exit 1
  fi
fi

# 1) fetch service details
echo "Fetching service details for $SERVICE on cluster $CLUSTER..."
SERVICE_JSON=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --output json) || { echo "Failed to describe service"; exit 1; }

TD_ARN=$(echo "$SERVICE_JSON" | jq -r '.services[0].taskDefinition')
if [ -z "$TD_ARN" ] || [ "$TD_ARN" = "null" ]; then
  echo "Could not find taskDefinition for service $SERVICE"; exit 1
fi

# get network configuration to run the task in same subnets/security groups
AWSPVCONF=$(echo "$SERVICE_JSON" | jq -r '.services[0].networkConfiguration.awsvpcConfiguration')
SUBNETS=$(echo "$AWSPVCONF" | jq -r '.subnets | join(",")')
SECURITY_GROUPS=$(echo "$AWSPVCONF" | jq -r '.securityGroups | join(",")')
ASSIGN_PUBLIC_IP=$(echo "$AWSPVCONF" | jq -r '.assignPublicIp')

if [ -z "$SUBNETS" ] || [ "$SUBNETS" = "null" ]; then
  echo "Service network subnets not found. You must provide subnets via modifying the script or ensure the service has awsvpcConfiguration."; exit 1
fi

echo "Using subnets: $SUBNETS"
[ "$SECURITY_GROUPS" != "null" ] && echo "Using security groups: $SECURITY_GROUPS"

# 2) fetch the task definition JSON
echo "Fetching task definition $TD_ARN..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$TD_ARN" --output json) || { echo "Failed to describe task definition"; exit 1; }

# prepare a temporary task definition if IMAGE provided
TASKDEF_TO_USE="$TD_ARN"
TEMP_TASKDEF_FILE=""
if [ -n "$IMAGE" ]; then
  echo "Registering temporary task definition with image: $IMAGE"
  # replace container image, remove runtime-only keys
  TMPFILE=$(mktemp /tmp/taskdef.XXXX.json)
  echo "$TD_JSON" | jq --arg img "$IMAGE" '.taskDefinition | .containerDefinitions[0].image = $img | del(.status,.revision,.registeredAt,.registeredBy,.taskDefinitionArn)' > "$TMPFILE"
  # register
  echo "Registering..."
  REG_OUT=$(aws ecs register-task-definition --cli-input-json file://"$TMPFILE") || { echo "Failed to register temporary task definition"; rm -f "$TMPFILE"; exit 1; }
  NEW_ARN=$(echo "$REG_OUT" | jq -r '.taskDefinition.taskDefinitionArn')
  echo "Registered temporary task definition: $NEW_ARN"
  TASKDEF_TO_USE="$NEW_ARN"
  TEMP_TASKDEF_FILE="$TMPFILE"
fi

# 3) build overrides: command and environment
# allow passing SECRET_KEY_BASE and other secrets via environment to this script
OV_ENV_JSON='[]'
add_env() {
  name="$1"; val="$2"
  [ -n "$val" ] || return
  OV_ENV_JSON=$(echo "$OV_ENV_JSON" | jq --arg n "$name" --arg v "$val" '. + [{name:$n, value:$v}]')
}
add_env "DATABASE_URL" "$DB_URL"
add_env "SECRET_KEY_BASE" "${SECRET_KEY_BASE:-}"
add_env "PWPUSH_MASTER_KEY" "${PWPUSH_MASTER_KEY:-}"
add_env "RETRIEVAL_STEP_DEFAULT" "${RETRIEVAL_STEP_DEFAULT:-}"
# do not enable persistence unless explicitly provided
add_env "PWP_PERSIST_ENV" "${PWP_PERSIST_ENV:-0}"

# overrides JSON
OVERRIDES=$(jq -n --arg cname "$CONTAINER" --argcmd "bundle exec rake db:migrate" --argjson env "$OV_ENV_JSON" '{containerOverrides:[{name:$cname, command:($cmd|split(" ")), environment:$env}] }')

echo "Running one-off task to execute migrations..."
RUN_OUT=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$TASKDEF_TO_USE" \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SECURITY_GROUPS}],assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
  --overrides "$OVERRIDES" --count 1 --output json) || { echo "Failed to run task"; [ -n "$TEMP_TASKDEF_FILE" ] && echo "Temporary taskdef at $TEMP_TASKDEF_FILE left registered."; exit 1; }

TASK_ARN=$(echo "$RUN_OUT" | jq -r '.tasks[0].taskArn')
if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "null" ]; then
  echo "Task did not start. Response:"; echo "$RUN_OUT"; [ -n "$TEMP_TASKDEF_FILE" ] && echo "Temporary taskdef at $TEMP_TASKDEF_FILE left registered."; exit 1
fi

echo "Started task: $TASK_ARN"

echo "You can monitor logs via CloudWatch Logs or watch the task status. Waiting for task to finish..."

# wait for task to stop
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"

# show last task status
TASK_DESC=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --output json)
EXIT_CODE=$(echo "$TASK_DESC" | jq -r '.tasks[0].containers[0].exitCode // 0')

echo "Task finished. container exitCode=$EXIT_CODE"

if [ -n "$TEMP_TASKDEF_FILE" ]; then
  echo "Temporary task definition registered at: $NEW_ARN"
  echo "You may deregister it manually if desired: aws ecs deregister-task-definition --task-definition $NEW_ARN"
fi

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Migration task failed. Check CloudWatch logs for details."; exit 2
else
  echo "Migration task completed successfully. You can now update your service to the newer image/revision."; exit 0
fi
