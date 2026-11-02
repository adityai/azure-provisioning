#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP='rg-weather-keyvault-01'
SUBSCRIPTION=''
POLL_INTERVAL_SECONDS=10
TIMEOUT_SECONDS=1800
MOCK_MODE=false

usage() {
  cat <<'EOF'
Usage: ./cleanup.sh [options]

Inventory resources, confirm by typing the resource-group name, delete the
group, wait for deletion, and verify/delete any surviving inventoried IDs.

Options:
  --resource-group NAME       Resource group (default: rg-weather-keyvault-01)
  --subscription ID           Subscription (default: active Azure subscription)
  --poll-interval-seconds N   Poll interval (default: 10)
  --timeout-seconds N         Wait timeout (default: 1800)
  --mock                      Print the intended flow without Azure CLI calls.
  -h, --help                  Show this help.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --resource-group) (($# >= 2)) || fail '--resource-group requires a value.'; RESOURCE_GROUP="$2"; shift ;;
    --subscription) (($# >= 2)) || fail '--subscription requires a value.'; SUBSCRIPTION="$2"; shift ;;
    --poll-interval-seconds)
      (($# >= 2)) || fail '--poll-interval-seconds requires a value.'
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail 'Poll interval must be a positive integer.'
      POLL_INTERVAL_SECONDS="$2"; shift ;;
    --timeout-seconds)
      (($# >= 2)) || fail '--timeout-seconds requires a value.'
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail 'Timeout must be a positive integer.'
      TIMEOUT_SECONDS="$2"; shift ;;
    --mock) MOCK_MODE=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

[[ "$RESOURCE_GROUP" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail 'Invalid resource group name.'
if [[ "$MOCK_MODE" == true ]]; then
  printf 'MOCK MODE: no Azure CLI commands were run and no resources were deleted.\n'
  printf 'Would inventory resources, confirm by typing %s, delete the group, wait, and verify/delete inventoried resource IDs.\n' "$RESOURCE_GROUP"
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required.'
if [[ -z "$SUBSCRIPTION" ]]; then
  SUBSCRIPTION="$(az account show --query id --output tsv)" || fail 'Azure CLI is not signed in; run az login.'
fi
[[ -n "$SUBSCRIPTION" ]] || fail 'Could not determine the Azure subscription.'
printf 'Subscription: %s\nResource group: %s\n' "$SUBSCRIPTION" "$RESOURCE_GROUP"
printf 'This permanently deletes the group and its resources. Type the resource group name to continue: '
IFS= read -r confirmation || confirmation=''
[[ "$confirmation" == "$RESOURCE_GROUP" ]] || { printf 'Cleanup cancelled. No resources were deleted.\n'; exit 0; }

group_exists="$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")" || fail 'Could not check whether the resource group exists.'
if [[ "$group_exists" != true ]]; then
  printf "Resource group '%s' does not exist; no pre-delete inventory is available.\n" "$RESOURCE_GROUP"
  exit 0
fi
resource_ids="$(az resource list --resource-group "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --query '[].id' --output tsv)" ||
  fail 'Could not inventory resources; refusing to delete the group.'
if [[ -n "$resource_ids" ]]; then
  printf 'Captured %s resource ID(s) before deletion.\n' "$(printf '%s\n' "$resource_ids" | wc -l | tr -d ' ')"
else
  printf 'No resources found before deletion.\n'
fi
az group delete --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --yes --no-wait
start_time="$(date +%s)"
while true; do
  group_exists="$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")" || fail 'Could not check resource group deletion status.'
  [[ "$group_exists" == false ]] && break
  current_time="$(date +%s)"
  ((current_time - start_time < TIMEOUT_SECONDS)) || fail 'Timed out waiting for resource group deletion.'
  sleep "$POLL_INTERVAL_SECONDS"
done
printf "Resource group '%s' is absent; verifying the pre-delete inventory.\n" "$RESOURCE_GROUP"
if [[ -z "$resource_ids" ]]; then
  printf 'Cleanup verified: no pre-delete resources were found.\n'
  exit 0
fi
subscription_resource_ids="$(az resource list --subscription "$SUBSCRIPTION" --query '[].id' --output tsv)" ||
  fail 'Could not query subscription resources; leftover verification is incomplete.'
leftover_ids=()
while IFS= read -r resource_id; do
  [[ -n "$resource_id" ]] || continue
  if grep -Fqx -- "$resource_id" <<<"$subscription_resource_ids"; then
    leftover_ids+=("$resource_id")
  fi
done <<<"$resource_ids"
if ((${#leftover_ids[@]} == 0)); then
  printf 'Cleanup verified: none of the pre-delete resource IDs remain.\n'
  exit 0
fi
printf 'Found %s surviving resource(s); requesting individual deletion:\n' "${#leftover_ids[@]}"
delete_failures=0
for resource_id in "${leftover_ids[@]}"; do
  printf '  %s\n' "$resource_id"
  az resource delete --ids "$resource_id" --subscription "$SUBSCRIPTION" || delete_failures=$((delete_failures + 1))
done
((delete_failures == 0)) || printf 'Some individual deletion requests failed; verification will continue.\n' >&2
start_time="$(date +%s)"
while true; do
  subscription_resource_ids="$(az resource list --subscription "$SUBSCRIPTION" --query '[].id' --output tsv)" ||
    fail 'Could not verify individual resource deletion.'
  remaining_ids=()
  for resource_id in "${leftover_ids[@]}"; do
    if grep -Fqx -- "$resource_id" <<<"$subscription_resource_ids"; then
      remaining_ids+=("$resource_id")
    fi
  done
  if ((${#remaining_ids[@]} == 0)); then
    printf 'Cleanup verified: all pre-delete resource IDs are absent.\n'
    exit 0
  fi
  current_time="$(date +%s)"
  if ((current_time - start_time >= TIMEOUT_SECONDS)); then
    printf 'Timed out waiting for these resource IDs to disappear:\n%s\n' "${remaining_ids[*]}" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done
