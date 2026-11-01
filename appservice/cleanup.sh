#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="rg-appservice-01"
SUBSCRIPTION=""
POLL_INTERVAL_SECONDS=10
TIMEOUT_SECONDS=1800
MOCK_MODE=false

usage() {
  cat <<'EOF'
Usage: ./cleanup.sh [options]

Delete a resource group, wait for Azure to finish, then check whether the
resources that were in the group still exist in the subscription and delete
any leftovers individually.

Options:
  --resource-group NAME       Resource group to delete (default: rg-appservice-01)
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
      RESOURCE_GROUP="$2"
      shift
      ;;
    --subscription)
      (($# >= 2)) || fail '--subscription requires a value.'
      SUBSCRIPTION="$2"
      shift
      ;;
    --poll-interval-seconds)
      (($# >= 2)) || fail '--poll-interval-seconds requires a value.'
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail 'Poll interval must be a positive integer.'
      POLL_INTERVAL_SECONDS="$2"
      shift
      ;;
    --timeout-seconds)
      (($# >= 2)) || fail '--timeout-seconds requires a value.'
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail 'Timeout must be a positive integer.'
      TIMEOUT_SECONDS="$2"
      shift
      ;;
    --mock)
      MOCK_MODE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

[[ "$RESOURCE_GROUP" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]*$ ]] ||
  fail 'Invalid resource group name.'

if [[ "$MOCK_MODE" == true ]]; then
  printf 'MOCK MODE: no Azure CLI commands were run and no resources were deleted.\n'
  printf 'Would snapshot resources, delete resource group %s, poll until it is gone, then check and delete any remaining snapshot resource IDs.\n' "$RESOURCE_GROUP"
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required.'

if [[ -z "$SUBSCRIPTION" ]]; then
  SUBSCRIPTION="$(az account show --query id --output tsv)" ||
    fail 'Azure CLI is not signed in or the active subscription could not be read. Run az login.'
fi
[[ -n "$SUBSCRIPTION" ]] || fail 'Could not determine the Azure subscription.'

printf 'Subscription: %s\n' "$SUBSCRIPTION"
printf 'Resource group: %s\n' "$RESOURCE_GROUP"
printf 'This permanently deletes the resource group and its resources, then individually deletes any surviving resources found from the pre-delete inventory.\n'
printf 'To continue, type the resource group name exactly: '
IFS= read -r confirmation || confirmation=''
[[ "$confirmation" == "$RESOURCE_GROUP" ]] || {
  printf 'Cleanup cancelled. No resources were deleted.\n'
  exit 0
}

group_exists="$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")" ||
  fail "Could not check whether resource group '$RESOURCE_GROUP' exists."
if [[ "$group_exists" != true ]]; then
  printf "Resource group '%s' does not exist. No pre-delete inventory is available to check for leftovers.\n" "$RESOURCE_GROUP"
  exit 0
fi

resource_ids="$(az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --subscription "$SUBSCRIPTION" \
  --query '[].id' \
  --output tsv)" || fail "Could not inventory resources in '$RESOURCE_GROUP'; refusing to delete the group."

if [[ -n "$resource_ids" ]]; then
  printf 'Captured %s resource ID(s) before deletion.\n' "$(printf '%s\n' "$resource_ids" | wc -l | tr -d ' ')"
else
  printf 'No resources found in the resource group before deletion.\n'
fi

printf 'Requesting deletion of resource group %s...\n' "$RESOURCE_GROUP"
az group delete \
  --name "$RESOURCE_GROUP" \
  --subscription "$SUBSCRIPTION" \
  --yes \
  --no-wait

start_time="$(date +%s)"
while true; do
  group_exists="$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")" ||
    fail "Could not check resource group '$RESOURCE_GROUP' deletion status."
  [[ "$group_exists" == false ]] && break

  current_time="$(date +%s)"
  if ((current_time - start_time >= TIMEOUT_SECONDS)); then
    fail "Timed out waiting for resource group '$RESOURCE_GROUP' deletion. Rerun cleanup after checking Azure activity."
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done
printf "Resource group '%s' is absent. Checking the pre-delete resource IDs at subscription scope...\n" "$RESOURCE_GROUP"

if [[ -z "$resource_ids" ]]; then
  printf 'Cleanup verified: there were no pre-delete resources to check.\n'
  exit 0
fi

subscription_resource_ids="$(az resource list \
  --subscription "$SUBSCRIPTION" \
  --query '[].id' \
  --output tsv)" || fail 'Could not list subscription resources after group deletion; leftover verification is incomplete.'

leftover_ids=()
while IFS= read -r resource_id; do
  [[ -n "$resource_id" ]] || continue
  if grep -Fqx -- "$resource_id" <<<"$subscription_resource_ids"; then
    leftover_ids+=("$resource_id")
  fi
done <<<"$resource_ids"

if ((${#leftover_ids[@]} == 0)); then
  printf 'Cleanup verified: none of the pre-delete resource IDs remain in the subscription.\n'
  exit 0
fi

printf 'Found %s surviving resource(s); requesting individual deletion:\n' "${#leftover_ids[@]}"
delete_failures=0
for resource_id in "${leftover_ids[@]}"; do
  printf '  %s\n' "$resource_id"
  if ! az resource delete --ids "$resource_id" --subscription "$SUBSCRIPTION"; then
    printf 'Failed to request deletion for %s\n' "$resource_id" >&2
    delete_failures=$((delete_failures + 1))
  fi
done

if ((delete_failures > 0)); then
  printf 'At least one individual delete request failed; continuing verification until timeout or deletion completes.\n' >&2
fi

start_time="$(date +%s)"
while true; do
  subscription_resource_ids="$(az resource list \
    --subscription "$SUBSCRIPTION" \
    --query '[].id' \
    --output tsv)" || fail 'Could not verify individual resource deletion; verification is incomplete.'

  remaining_ids=()
  for resource_id in "${leftover_ids[@]}"; do
    if grep -Fqx -- "$resource_id" <<<"$subscription_resource_ids"; then
      remaining_ids+=("$resource_id")
    fi
  done

  if ((${#remaining_ids[@]} == 0)); then
    printf 'Cleanup verified: all pre-delete resource IDs are absent from the subscription.\n'
    exit 0
  fi

  current_time="$(date +%s)"
  if ((current_time - start_time >= TIMEOUT_SECONDS)); then
    printf 'Timed out waiting for %s resource(s) to disappear:\n' "${#remaining_ids[@]}" >&2
    printf '  %s\n' "${remaining_ids[@]}" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done
