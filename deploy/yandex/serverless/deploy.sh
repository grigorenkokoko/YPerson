#!/usr/bin/env bash
set -Eeuo pipefail

required=(
  YC_FOLDER_ID YC_HTTP_CONTAINER_ID YC_RUNTIME_SA_ID YC_HEALTH_URL
  YPERSON_CONFIG_VERSION YPERSON_PRIVACY_URL YPERSON_SUPPORT_URL
  IMAGE_URL GITHUB_SHA YC_IAM_TOKEN
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required deployment value: ${name}" >&2
    exit 2
  fi
done

if [[ ! "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]] || [[ "${IMAGE_URL}" != *":${GITHUB_SHA}" ]]; then
  echo "IMAGE_URL must use the full Git commit SHA tag" >&2
  exit 2
fi

for command in yc curl jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required deployment command is unavailable: ${command}" >&2
    exit 2
  fi
done

yc_cmd=(yc --folder-id "${YC_FOLDER_ID}" --token "${YC_IAM_TOKEN}")

previous_revision_id="$("${yc_cmd[@]}" serverless container revision list \
  --container-id "${YC_HTTP_CONTAINER_ID}" \
  --format json | jq -r 'map(select(.status == "ACTIVE")) | first | .id // empty')"

"${yc_cmd[@]}" serverless container revision deploy \
  --container-id "${YC_HTTP_CONTAINER_ID}" \
  --image "${IMAGE_URL}" \
  --runtime http \
  --memory 512MB \
  --cores 1 \
  --concurrency 4 \
  --execution-timeout 30s \
  --min-instances 0 \
  --service-account-id "${YC_RUNTIME_SA_ID}" \
  --environment "YPERSON_ENV=staging,YPERSON_CONFIG_VERSION=${YPERSON_CONFIG_VERSION},YPERSON_PRIVACY_URL=${YPERSON_PRIVACY_URL},YPERSON_SUPPORT_URL=${YPERSON_SUPPORT_URL},YPERSON_ANALYTICS_KILL_SWITCH=false,GRACEFUL_SHUTDOWN_SECONDS=15"

if ! curl --fail --silent --show-error \
  --retry 12 --retry-delay 5 --retry-all-errors \
  --max-time 10 "${YC_HEALTH_URL}"; then
  if [[ -n "${previous_revision_id}" ]]; then
    "${yc_cmd[@]}" serverless container rollback \
      --id "${YC_HTTP_CONTAINER_ID}" \
      --revision-id "${previous_revision_id}"
  else
    echo "Health check failed; no previous revision exists for bootstrap rollback" >&2
  fi
  exit 1
fi
