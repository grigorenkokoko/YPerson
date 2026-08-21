#!/usr/bin/env bash
set -Eeuo pipefail

YPERSON_APP_STORE_ID="${YPERSON_APP_STORE_ID:-}"
YPERSON_APPLE_APPLICATION_IDENTIFIER="${YPERSON_APPLE_APPLICATION_IDENTIFIER:-Q7A52Z2TS2.com.yperson.app}"

required=(
  YC_FOLDER_ID YC_API_GATEWAY_ID YC_HTTP_CONTAINER_ID YC_RUNTIME_SA_ID YC_GATEWAY_SA_ID
  YC_HEALTH_URL YPERSON_CONFIG_VERSION YPERSON_PRIVACY_URL YPERSON_SUPPORT_URL
  YDB_ENDPOINT YDB_DATABASE YPERSON_OBJECT_BUCKET
  YPERSON_S3_LOCKBOX_SECRET_ID YPERSON_S3_LOCKBOX_VERSION_ID
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

for command in yc curl jq python3 cmp mktemp; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required deployment command is unavailable: ${command}" >&2
    exit 2
  fi
done

yc_cmd=(yc --folder-id "${YC_FOLDER_ID}" --token "${YC_IAM_TOKEN}")
temporary_directory="$(mktemp -d)"
rendered_gateway="${temporary_directory}/api-gateway.yaml"
deployment_started=false
smoke_owner_ready=false
smoke_peer_ready=false
smoke_owner_id=""
smoke_peer_id=""

previous_revision_id="$("${yc_cmd[@]}" serverless container revision list \
  --container-id "${YC_HTTP_CONTAINER_ID}" \
  --format json | jq -r 'map(select(.status == "ACTIVE")) | first | .id // empty')"

write_sync_request() {
  local output_path="$1"
  local operation="$2"
  local operation_id="$3"
  local installation_id="$4"
  SMOKE_OPERATION="${operation}" \
  SMOKE_OPERATION_ID="${operation_id}" \
  SMOKE_INSTALLATION_ID="${installation_id}" \
  python3 -c '
import json, os, sys

operation = os.environ["SMOKE_OPERATION"]
payload = {
    "contractVersion": 2,
    "operationID": os.environ["SMOKE_OPERATION_ID"],
    "installationID": os.environ["SMOKE_INSTALLATION_ID"],
    "operation": operation,
}
card = {
    "id": os.environ.get("SMOKE_CARD_ID", "smoke-card"),
    "name": "Deployment smoke",
    "role": "Verification",
    "company": "YPerson",
    "phone": "",
    "email": "",
    "tagline": "Disposable",
    "hasAudioGreeting": operation == "publishCard",
    "meetingPlace": None,
    "isBlocked": False,
}
if operation in {"prepareExchange", "publishCard"}:
    payload["card"] = card
if operation == "prepareExchange":
    payload["exchangeMethod"] = "manual"
elif operation == "claimExchange":
    payload["exchangeToken"] = os.environ["SMOKE_EXCHANGE_TOKEN"]
elif operation == "prepareAudioUpload":
    payload["audioSizeBytes"] = int(os.environ["SMOKE_AUDIO_SIZE"])
    payload["audioDurationMS"] = 1000
elif operation == "publishCard":
    payload["audioAssetID"] = os.environ["SMOKE_AUDIO_ASSET_ID"]
json.dump(payload, sys.stdout, separators=(",", ":"))
' >"${output_path}"
}

write_auth_config() {
  local output_path="$1"
  local bearer="$2"
  umask 077
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
    "${bearer}" >"${output_path}"
}

call_sync() {
  local auth_config="$1"
  local request_path="$2"
  local response_path="$3"
  curl --config "${auth_config}" --fail --silent --show-error \
    --request POST --max-time 30 --data-binary "@${request_path}" \
    --output "${response_path}" "${YC_HEALTH_URL%/health}/sync"
}

json_value() {
  local input_path="$1"
  local expression="$2"
  python3 -c '
import json, sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for component in sys.argv[2].split("."):
    value = value[component]
if not isinstance(value, str) or not value:
    raise SystemExit(1)
sys.stdout.write(value)
' "${input_path}" "${expression}"
}

delete_smoke_profile() {
  local auth_config="$1"
  local installation_id="$2"
  local suffix="$3"
  local request_path="${temporary_directory}/delete-${suffix}.json"
  local response_path="${temporary_directory}/delete-${suffix}-response.json"
  write_sync_request "${request_path}" deleteProfile "smoke-delete-${suffix}" "${installation_id}"
  call_sync "${auth_config}" "${request_path}" "${response_path}"
}

rollback_previous_revision() {
  if [[ -n "${previous_revision_id}" ]]; then
    "${yc_cmd[@]}" serverless container rollback \
      --id "${YC_HTTP_CONTAINER_ID}" \
      --revision-id "${previous_revision_id}"
  else
    echo "Deployment verification failed; no previous revision exists for rollback" >&2
  fi
}

finish() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "${smoke_owner_ready}" == true ]]; then
    delete_smoke_profile "${temporary_directory}/owner-auth" "${smoke_owner_id}" owner >/dev/null 2>&1
  fi
  if [[ "${smoke_peer_ready}" == true ]]; then
    delete_smoke_profile "${temporary_directory}/peer-auth" "${smoke_peer_id}" peer >/dev/null 2>&1
  fi
  if [[ ${status} -ne 0 && "${deployment_started}" == true ]]; then
    rollback_previous_revision
  fi
  rm -rf "${temporary_directory}"
  unset smoke_owner_secret smoke_peer_secret SMOKE_EXCHANGE_TOKEN SMOKE_AUDIO_ASSET_ID
  exit "${status}"
}
trap finish EXIT

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
  --environment "YPERSON_ENV=production,YPERSON_CONFIG_VERSION=${YPERSON_CONFIG_VERSION},YPERSON_PRIVACY_URL=${YPERSON_PRIVACY_URL},YPERSON_SUPPORT_URL=${YPERSON_SUPPORT_URL},YPERSON_APP_STORE_ID=${YPERSON_APP_STORE_ID},YPERSON_APPLE_APPLICATION_IDENTIFIER=${YPERSON_APPLE_APPLICATION_IDENTIFIER},YPERSON_ANALYTICS_KILL_SWITCH=false,GRACEFUL_SHUTDOWN_SECONDS=15,YDB_ENDPOINT=${YDB_ENDPOINT},YDB_DATABASE=${YDB_DATABASE},YDB_METADATA_CREDENTIALS=1,YPERSON_OBJECT_BUCKET=${YPERSON_OBJECT_BUCKET},YPERSON_SYNC_ENABLED=true" \
  --secret "environment-variable=YPERSON_S3_ACCESS_KEY_ID,id=${YPERSON_S3_LOCKBOX_SECRET_ID},version-id=${YPERSON_S3_LOCKBOX_VERSION_ID},key=access_key_id" \
  --secret "environment-variable=YPERSON_S3_SECRET_ACCESS_KEY,id=${YPERSON_S3_LOCKBOX_SECRET_ID},version-id=${YPERSON_S3_LOCKBOX_VERSION_ID},key=secret_access_key"
deployment_started=true

curl --fail --silent --show-error \
  --retry 12 --retry-delay 5 --retry-all-errors \
  --max-time 10 "${YC_HEALTH_URL}" >/dev/null

RENDERED_GATEWAY="${rendered_gateway}" python3 -c '
import os, pathlib

source = pathlib.Path("deploy/yandex/serverless/api-gateway.yaml").read_text()
source = source.replace("${YC_HTTP_CONTAINER_ID}", os.environ["YC_HTTP_CONTAINER_ID"])
source = source.replace("${YC_GATEWAY_SA_ID}", os.environ["YC_GATEWAY_SA_ID"])
if "${" in source:
    raise SystemExit("unresolved API Gateway placeholder")
pathlib.Path(os.environ["RENDERED_GATEWAY"]).write_text(source)
'
"${yc_cmd[@]}" serverless api-gateway update \
  --id "${YC_API_GATEWAY_ID}" \
  --spec "${rendered_gateway}"

smoke_owner_id="smoke-owner-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
smoke_peer_id="smoke-peer-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
smoke_owner_secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
smoke_peer_secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
write_auth_config "${temporary_directory}/owner-auth" "${smoke_owner_secret}"
write_auth_config "${temporary_directory}/peer-auth" "${smoke_peer_secret}"

write_sync_request "${temporary_directory}/owner-refresh.json" refresh \
  smoke-owner-bootstrap "${smoke_owner_id}"
call_sync "${temporary_directory}/owner-auth" \
  "${temporary_directory}/owner-refresh.json" "${temporary_directory}/owner-refresh-response.json"
smoke_owner_ready=true

write_sync_request "${temporary_directory}/peer-refresh.json" refresh \
  smoke-peer-bootstrap "${smoke_peer_id}"
call_sync "${temporary_directory}/peer-auth" \
  "${temporary_directory}/peer-refresh.json" "${temporary_directory}/peer-refresh-response.json"
smoke_peer_ready=true

SMOKE_CARD_ID="smoke-card-${GITHUB_SHA:0:12}" \
  write_sync_request "${temporary_directory}/prepare-exchange.json" prepareExchange \
    smoke-prepare-exchange "${smoke_owner_id}"
call_sync "${temporary_directory}/owner-auth" \
  "${temporary_directory}/prepare-exchange.json" "${temporary_directory}/prepare-exchange-response.json"
SMOKE_EXCHANGE_TOKEN="$(json_value "${temporary_directory}/prepare-exchange-response.json" exchangeToken)"
export SMOKE_EXCHANGE_TOKEN
write_sync_request "${temporary_directory}/claim-exchange.json" claimExchange \
  smoke-claim-exchange "${smoke_peer_id}"
call_sync "${temporary_directory}/peer-auth" \
  "${temporary_directory}/claim-exchange.json" "${temporary_directory}/claim-exchange-response.json"

printf 'YPerson smoke audio' >"${temporary_directory}/audio.m4a"
SMOKE_AUDIO_SIZE=19
export SMOKE_AUDIO_SIZE
write_sync_request "${temporary_directory}/prepare-audio.json" prepareAudioUpload \
  smoke-prepare-audio "${smoke_owner_id}"
call_sync "${temporary_directory}/owner-auth" \
  "${temporary_directory}/prepare-audio.json" "${temporary_directory}/prepare-audio-response.json"
SMOKE_AUDIO_ASSET_ID="$(json_value "${temporary_directory}/prepare-audio-response.json" audioUpload.assetID)"
smoke_upload_url="$(json_value "${temporary_directory}/prepare-audio-response.json" audioUpload.uploadURL)"
export SMOKE_AUDIO_ASSET_ID
curl --fail --silent --show-error --request PUT --max-time 30 \
  --header 'Content-Type: audio/mp4' \
  --data-binary "@${temporary_directory}/audio.m4a" "${smoke_upload_url}" >/dev/null
unset smoke_upload_url

SMOKE_CARD_ID="smoke-card-${GITHUB_SHA:0:12}" \
  write_sync_request "${temporary_directory}/publish-card.json" publishCard \
    smoke-publish-card "${smoke_owner_id}"
call_sync "${temporary_directory}/owner-auth" \
  "${temporary_directory}/publish-card.json" "${temporary_directory}/publish-card-response.json"

write_sync_request "${temporary_directory}/peer-final-refresh.json" refresh \
  smoke-peer-refresh "${smoke_peer_id}"
call_sync "${temporary_directory}/peer-auth" \
  "${temporary_directory}/peer-final-refresh.json" "${temporary_directory}/peer-final-refresh-response.json"
smoke_download_url="$(python3 -c '
import json, sys

response = json.load(open(sys.argv[1], encoding="utf-8"))
owner = sys.argv[2]
matches = [person for person in response["people"] if person["installationID"] == owner]
if len(matches) != 1 or not matches[0].get("audio", {}).get("downloadURL"):
    raise SystemExit(1)
sys.stdout.write(matches[0]["audio"]["downloadURL"])
' "${temporary_directory}/peer-final-refresh-response.json" "${smoke_owner_id}")"
curl --fail --silent --show-error --max-time 30 \
  --output "${temporary_directory}/downloaded.m4a" "${smoke_download_url}"
unset smoke_download_url
cmp --silent "${temporary_directory}/audio.m4a" "${temporary_directory}/downloaded.m4a"

delete_smoke_profile "${temporary_directory}/owner-auth" "${smoke_owner_id}" owner
smoke_owner_ready=false
delete_smoke_profile "${temporary_directory}/peer-auth" "${smoke_peer_id}" peer
smoke_peer_ready=false
