#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="rg-weather-sqldb-01"
SUBSCRIPTION=""
POLL_INTERVAL_SECONDS=10
TIMEOUT_SECONDS=1800
MOCK_MODE=false

usage() {
  cat <<'EOF'
Usage: ./cleanup.sh [options]

Delete the SQL Database resource group, wait for deletion, and verify/delete
any pre-inventoried resources that remain.

Options:
  --resource-group NAME       Resource group to delete (default: rg-weather-sqldb-01)
  --subscription ID           Subscription ID (default: active Azure subscription)
  --poll-interval-seconds N   Poll interval (default: 10)
  --timeout-seconds N         Wait timeout (default: 1800)
  --mock                      Print the cleanup plan without Azure CLI calls
  -h, --help                  Show this help
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --resource-group)
      (($# >= 2)) || fail '--resource-group requires a value.'
      RESOURCE_GROUP="$2"; shift
      ;;
    --subscription)
      (($# >= 2)) || fail '--subscription requires a value.'
      SUBSCRIPTION="$2"; shift
      ;;
    --poll-interval-seconds)
      (($# >= 2)) || fail '--poll-interval-seconds requires a value.'
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail 'Poll interval must be a positive integer.'
      POLL_INTERVAL_SECONDS="$2"; shift
      ;;
    --timeout-seconds)
      (($# >= 2)) || fail '--timeout-seconds requires a value.'
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail 'Timeout must be a positive integer.'
      TIMEOUT_SECONDS="$2"; shift
      ;;
    --mock) MOCK_MODE=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

[[ "$RESOURCE_GROUP" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]*$ ]] || fail 'Invalid resource group name.'
if [[ "$MOCK_MODE" == true ]]; then
  printf 'MOCK MODE: no Azure CLI commands were run and no resources were deleted.\n'
  printf 'Would snapshot resources, delete resource group %s, poll until it is gone, then verify and delete any remaining snapshot resource IDs.\n' "$RESOURCE_GROUP"
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required.'
if [[ -z "$SUBSCRIPTION" ]]; then
  SUBSCRIPTION="$(az account show --query id --output tsv)" || fail 'Azure CLI is not signed in; run az login.'
fi
[[ -n "$SUBSCRIPTION" ]] || fail 'Could not determine the Azure subscription.'

printf 'Subscription: %s\nResource group: %s\n' "$SUBSCRIPTION" "$RESOURCE_GROUP"
printf 'This permanently deletes the resource group and its resources.\nTo continue, type the resource group name exactly: '
IFS= read -r confirmation || confirmation=''
[[ "$confirmation" == "$RESOURCE_GROUP" ]] || {
  printf 'Cleanup cancelled. No resources were deleted.\n'
  exit 0
}

group_exists="$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")" ||
  fail "Could not check whether resource group '$RESOURCE_GROUP' exists."
[[ "$group_exists" == true ]] || {
  printf "Resource group '%s' does not exist.\n" "$RESOURCE_GROUP"
  exit 0
}
resource_ids="$(az resource list --resource-group "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --query '[].id' --output tsv)" ||
  fail "Could not inventory resources in '$RESOURCE_GROUP'; refusing to delete the group."
az group delete --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --yes --no-wait

start_time="$(date +%s)"
while true; do
  group_exists="$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")" ||
    fail "Could not check resource group '$RESOURCE_GROUP' deletion status."
  [[ "$group_exists" == false ]] && break
  (( $(date +%s) - start_time < TIMEOUT_SECONDS )) || fail "Timed out waiting for resource group '$RESOURCE_GROUP' deletion."
  sleep "$POLL_INTERVAL_SECONDS"
done

if [[ -z "$resource_ids" ]]; then
  printf 'Cleanup verified: there were no pre-delete resources to check.\n'
  exit 0
fi
subscription_resource_ids="$(az resource list --subscription "$SUBSCRIPTION" --query '[].id' --output tsv)" ||
  fail 'Could not list subscription resources after group deletion.'
leftover_ids=()
while IFS= read -r resource_id; do
  [[ -n "$resource_id" ]] || continue
  grep -Fqx -- "$resource_id" <<<"$subscription_resource_ids" && leftover_ids+=("$resource_id")
done <<<"$resource_ids"
for resource_id in "${leftover_ids[@]}"; do
  printf 'Deleting surviving resource: %s\n' "$resource_id"
  az resource delete --ids "$resource_id" --subscription "$SUBSCRIPTION" || fail "Failed to request deletion for $resource_id"
done

start_time="$(date +%s)"
while ((${#leftover_ids[@]} > 0)); do
  subscription_resource_ids="$(az resource list --subscription "$SUBSCRIPTION" --query '[].id' --output tsv)" ||
    fail 'Could not verify individual resource deletion.'
  remaining_ids=()
  for resource_id in "${leftover_ids[@]}"; do
    grep -Fqx -- "$resource_id" <<<"$subscription_resource_ids" && remaining_ids+=("$resource_id")
  done
  ((${#remaining_ids[@]} == 0)) && break
  (( $(date +%s) - start_time < TIMEOUT_SECONDS )) || {
    printf 'Timed out waiting for resources to disappear:\n%s\n' "${remaining_ids[*]}" >&2
    exit 1
  }
  sleep "$POLL_INTERVAL_SECONDS"
done
printf 'Cleanup verified: all pre-delete resource IDs are absent from the subscription.\n'
