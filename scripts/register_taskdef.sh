#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <taskdef.json> [output.json]"
  echo "Reads env vars from the environment and injects them into containerDefinitions[0].environment, then registers the task definition."
  exit 1
fi

INPUT_JSON="$1"
OUTPUT_JSON="${2:-rev-new.json}"

# Read env vars (CI should set these from secrets)
DB_URL="${DATABASE_URL:-}"
SECRET_KEY="${SECRET_KEY_BASE:-}"
MASTER_KEY="${PWPUSH_MASTER_KEY:-}"
RETRIEVAL_DEFAULT="${RETRIEVAL_STEP_DEFAULT:-true}"

# Build jq args to set environment array
jq --arg db "$DB_URL" \
   --arg sk "$SECRET_KEY" \
   --arg mk "$MASTER_KEY" \
   --arg rs "$RETRIEVAL_DEFAULT" \
   '(.containerDefinitions[0].environment) = [
      {name: "DATABASE_URL", value: $db},
      {name: "SECRET_KEY_BASE", value: $sk},
      {name: "PWPUSH_MASTER_KEY", value: $mk},
      {name: "RETRIEVAL_STEP_DEFAULT", value: $rs}
   ]' "$INPUT_JSON" > "$OUTPUT_JSON"

echo "Prepared $OUTPUT_JSON"

# Optionally register the task definition if AWS CLI is available
if command -v aws >/dev/null 2>&1; then
  echo "Registering task definition with AWS ECS..."
  aws ecs register-task-definition --cli-input-json file://"$OUTPUT_JSON"
  echo "Registered task definition."
else
  echo "aws CLI not found — skip registering. Use the prepared $OUTPUT_JSON to register manually."
fi
