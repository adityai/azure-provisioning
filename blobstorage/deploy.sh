#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/main.bicep"
RESOURCE_GROUP=""
PARAMETERS_FILE=""
MOCK_MODE=false
INTERACTIVE_MODE=false
USE_DEFAULTS=false

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--mock] [--interactive] [--use-defaults] [--parameters-file FILE]

Deploy a private-only StorageV2 blob account, container, private endpoint,
private DNS zone, VNet, and endpoint subnet.

Options:
  --mock                 Compile and preview without Azure deployment calls.
  --interactive          Prompt instead of discovering input/blobstorage JSON files.
  --use-defaults         Accept displayed defaults when a prompt is blank.
  --parameters-file FILE Deploy one Bicep parameter JSON file without prompts.
  -h, --help             Show this help.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --mock) MOCK_MODE=true ;;
    --interactive) INTERACTIVE_MODE=true ;;
    --use-defaults) USE_DEFAULTS=true ;;
    --parameters-file)
      (($# >= 2)) || fail '--parameters-file requires a path.'
      PARAMETERS_FILE="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

valid_resource_group() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._\(\)-]{0,89}$ ]]
}

valid_general_name() {
  [[ ${#1} -ge 1 && ${#1} -le 80 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

valid_storage_account() {
  [[ ${#1} -ge 3 && ${#1} -le 24 && "$1" =~ ^[a-z0-9]+$ ]]
}

valid_container() {
  [[ ${#1} -ge 3 && ${#1} -le 63 && "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local value
  if [[ "$USE_DEFAULTS" == true ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
    IFS= read -r value || value=''
    REPLY="${value:-$default_value}"
  else
    while true; do
      printf '%s: ' "$label"
      IFS= read -r value || fail "No input received for required value: $label"
      if [[ -n "$value" ]]; then
        REPLY="$value"
        break
      fi
      printf 'A value is required; enter a value to continue.\n' >&2
    done
  fi
  printf '\nINPUT %s=%s\n' "$label" "$REPLY"
}

prompt_checked() {
  local label="$1"
  local default_value="$2"
  local rule="$3"
  local maximum_length="${4:-}"
  while true; do
    prompt_value "$label" "$default_value"
    if [[ "$REPLY" =~ $rule ]] && { [[ -z "$maximum_length" ]] || ((${#REPLY} <= maximum_length)); }; then
      return
    fi
    printf 'Invalid value for %s.\n' "$label" >&2
  done
}

if [[ -z "$PARAMETERS_FILE" && "$INTERACTIVE_MODE" != true ]]; then
  shopt -s nullglob
  parameter_files=("$REPO_ROOT"/input/blobstorage/*.json)
  shopt -u nullglob
  if ((${#parameter_files[@]} > 0)); then
    failures=0
    printf 'Found %s input/blobstorage JSON file(s); using each as a deployment parameter file.\n' "${#parameter_files[@]}"
    for parameter_file in "${parameter_files[@]}"; do
      printf '\n=== Processing %s ===\n' "$parameter_file"
      child_args=(--parameters-file "$parameter_file")
      [[ "$MOCK_MODE" == true ]] && child_args+=(--mock)
      [[ "$USE_DEFAULTS" == true ]] && child_args+=(--use-defaults)
      if "$SCRIPT_DIR/deploy.sh" "${child_args[@]}"; then
        printf 'Completed parameter file: %s\n' "$parameter_file"
      else
        status=$?
        printf 'Failed parameter file %s (exit %s); continuing.\n' "$parameter_file" "$status" >&2
        failures=$((failures + 1))
      fi
    done
    ((failures == 0)) || fail "$failures of ${#parameter_files[@]} JSON deployment(s) failed."
    exit 0
  fi
fi

if [[ -n "$PARAMETERS_FILE" ]]; then
  [[ -f "$PARAMETERS_FILE" ]] || fail "Parameter file not found: $PARAMETERS_FILE"
  command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required to read Bicep parameter JSON files.'
  parsed_parameters="$(python3 - "$PARAMETERS_FILE" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
try:
    document = json.loads(path.read_text())
    values = document["parameters"]
except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
    print(f"Invalid Bicep parameter JSON {path}: {error}", file=sys.stderr)
    raise SystemExit(1)

names = [
    "storageAccountName",
    "containerName",
    "location",
    "vnetName",
    "privateEndpointSubnetName",
    "privateEndpointName",
    "vnetLinkName",
    "privateDnsZoneGroupName",
]
try:
    resolved = {name: values[name]["value"] for name in names}
except (KeyError, TypeError) as error:
    print(f"Parameter file {path} is missing a required parameter or value: {error}", file=sys.stderr)
    raise SystemExit(1)

metadata = document.get("metadata", {})
if not isinstance(metadata, dict):
    print(f"Parameter file {path}: metadata must be an object.", file=sys.stderr)
    raise SystemExit(1)
group_name = metadata.get("resourceGroupName", path.stem)
checks = [
    (isinstance(group_name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._()-]{0,89}", group_name), "invalid resource group name"),
    (isinstance(resolved["storageAccountName"], str) and re.fullmatch(r"[a-z0-9]{3,24}", resolved["storageAccountName"]), "storageAccountName must be 3-24 lowercase letters or digits"),
    (isinstance(resolved["containerName"], str) and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", resolved["containerName"]) and 3 <= len(resolved["containerName"]) <= 63, "containerName must be 3-63 lowercase letters, digits, or single hyphens"),
    (isinstance(resolved["location"], str) and re.fullmatch(r"[a-z0-9-]{1,60}", resolved["location"]), "location must be a valid Azure region token"),
]
for name in ("vnetName", "privateEndpointSubnetName", "privateEndpointName", "vnetLinkName", "privateDnsZoneGroupName"):
    maximum = 63 if name == "vnetName" else 79
    checks.append((isinstance(resolved[name], str) and re.fullmatch(rf"[A-Za-z0-9][A-Za-z0-9._-]{{0,{maximum}}}", resolved[name]), f"{name} must have a valid length and contain letters, numbers, dots, underscores, or hyphens"))
for valid, message in checks:
    if not valid:
        print(f"Parameter file {path}: {message}.", file=sys.stderr)
        raise SystemExit(1)
print(group_name)
for name in names:
    print(resolved[name])
PY
)" || fail "Could not load valid deployment inputs from $PARAMETERS_FILE."
  parameter_values=()
  while IFS= read -r value; do parameter_values+=("$value"); done <<< "$parsed_parameters"
  ((${#parameter_values[@]} == 9)) || fail "Unexpected parameter count in $PARAMETERS_FILE."
  RESOURCE_GROUP="${parameter_values[0]}"
  storage_account_name="${parameter_values[1]}"
  container_name="${parameter_values[2]}"
  location="${parameter_values[3]}"
  vnet_name="${parameter_values[4]}"
  private_endpoint_subnet_name="${parameter_values[5]}"
  private_endpoint_name="${parameter_values[6]}"
  vnet_link_name="${parameter_values[7]}"
  private_dns_zone_group_name="${parameter_values[8]}"
  deployment_parameters=("--parameters" "@$PARAMETERS_FILE")
else
  prompt_checked 'Resource group name' 'rg-weather-blobstorage-01' '^[A-Za-z0-9][A-Za-z0-9._()\-]{0,89}$'
  RESOURCE_GROUP="$REPLY"
fi

valid_resource_group "$RESOURCE_GROUP" || fail "Invalid resource group name: $RESOURCE_GROUP"
LOG_FILE="$PWD/${RESOURCE_GROUP}.log"
touch "$LOG_FILE" || fail "Could not create deployment log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== Blob Storage deployment run =====\n'
printf 'Started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Log file: %s\n' "$LOG_FILE"
printf 'INPUT Resource group name=%s\n' "$RESOURCE_GROUP"

if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'INPUT Parameter file=%s\n' "$PARAMETERS_FILE"
  printf 'INPUT Storage account name=%s\n' "$storage_account_name"
  printf 'INPUT Container name=%s\n' "$container_name"
  printf 'INPUT Azure region=%s\n' "$location"
  printf 'INPUT VNet name=%s\n' "$vnet_name"
  printf 'INPUT Private endpoint subnet name=%s\n' "$private_endpoint_subnet_name"
  printf 'INPUT Private endpoint name=%s\n' "$private_endpoint_name"
  printf 'INPUT Private DNS VNet link name=%s\n' "$vnet_link_name"
  printf 'INPUT Private DNS zone group name=%s\n' "$private_dns_zone_group_name"
else
  prompt_checked 'Azure region' 'eastus' '^[a-z0-9-]{1,60}$'
  location="$REPLY"
  prompt_checked 'Storage account name (globally unique, 3-24 lowercase letters or digits)' 'stweatherblob01' '^[a-z0-9]{3,24}$'
  storage_account_name="$REPLY"
  prompt_checked 'Private container name' 'weather-data' '^[a-z0-9]+(-[a-z0-9]+)*$' 63
  container_name="$REPLY"
  prompt_checked 'VNet name' 'vnet-weather-blobstorage-01' '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
  vnet_name="$REPLY"
  prompt_checked 'Private endpoint subnet name' 'snet-private-endpoint' '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
  private_endpoint_subnet_name="$REPLY"
  prompt_checked 'Private endpoint name' 'pep-weather-blob-01' '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
  private_endpoint_name="$REPLY"
  prompt_checked 'Private DNS VNet link name' 'link-blobstorage-vnet' '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
  vnet_link_name="$REPLY"
  prompt_checked 'Private DNS zone group name' 'default' '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
  private_dns_zone_group_name="$REPLY"
  deployment_parameters=(
    --parameters
    "storageAccountName=$storage_account_name"
    "containerName=$container_name"
    "location=$location"
    "vnetName=$vnet_name"
    "privateEndpointSubnetName=$private_endpoint_subnet_name"
    "privateEndpointName=$private_endpoint_name"
    "vnetLinkName=$vnet_link_name"
    "privateDnsZoneGroupName=$private_dns_zone_group_name"
  )
fi

valid_storage_account "$storage_account_name" || fail 'Storage account name must be 3-24 lowercase letters or digits.'
valid_container "$container_name" || fail 'Container name must be 3-63 lowercase letters, digits, or single hyphens.'
for resource_name in "$vnet_name" "$private_endpoint_subnet_name" "$private_endpoint_name" "$vnet_link_name" "$private_dns_zone_group_name"; do
  valid_general_name "$resource_name" || fail "Invalid Azure resource name: $resource_name"
done
((${#vnet_name} <= 64)) || fail 'VNet name must not exceed 64 characters.'

run_bicep_build() {
  printf '\nCOMMAND: az bicep build --file %s --stdout\n' "$TEMPLATE_FILE"
  if az bicep build --file "$TEMPLATE_FILE" --stdout >>"$LOG_FILE" 2>&1; then
    printf 'Bicep compilation succeeded; compiler output is in this log.\n'
  else
    local status=$?
    printf 'Bicep compilation failed with exit code %s.\n' "$status"
    return "$status"
  fi
}

if [[ "$MOCK_MODE" == true ]]; then
  if command -v az >/dev/null 2>&1; then
    run_bicep_build || fail 'Bicep compilation failed; mock deployment stopped.'
  else
    printf 'Bicep compilation skipped: Azure CLI/Bicep compiler is unavailable.\n'
  fi
  printf 'MOCK MODE: no Azure deployment commands were run and no resources were created.\n'
  printf 'Resource group: %s (%s)\n' "$RESOURCE_GROUP" "$location"
  printf 'Storage account: %s; container: %s\n' "$storage_account_name" "$container_name"
  printf 'VNet: %s; subnet: %s; private endpoint: %s\n' "$vnet_name" "$private_endpoint_subnet_name" "$private_endpoint_name"
  printf 'Private DNS zone: derived from the Azure cloud storage suffix; VNet link: %s; zone group: %s\n' "$vnet_link_name" "$private_dns_zone_group_name"
  printf 'Would deploy: az deployment group create --resource-group %q --template-file %q' "$RESOURCE_GROUP" "$TEMPLATE_FILE"
  printf ' %q' "${deployment_parameters[@]}"
  printf '\n'
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required. Install it and sign in with az login.'
run_bicep_build || fail 'Bicep compilation failed; deployment stopped.'
printf '\nCOMMAND: az account show --query '\''[name, id]'\'' --output tsv\n'
subscription_details="$(az account show --query '[name, id]' --output tsv)" ||
  fail 'Azure CLI is not signed in or the active account is unavailable. Run az login.'
printf 'Active Azure subscription (name, ID): %s\n' "$subscription_details"
printf 'Resolved: %s, %s, account %s, container %s, endpoint %s; private DNS zone is derived from the Azure cloud storage suffix.\n' \
  "$RESOURCE_GROUP" "$location" "$storage_account_name" "$container_name" "$private_endpoint_name"
if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'JSON parameter file supplied; proceeding without interactive prompts.\n'
else
  printf 'Proceed with deployment? [y/N]: '
  IFS= read -r confirmation || confirmation=''
  [[ "$confirmation" == y || "$confirmation" == Y ]] || {
    printf 'Deployment cancelled. No resources were created.\n'
    exit 0
  }
fi
az group create --name "$RESOURCE_GROUP" --location "$location" --output jsonc
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  "${deployment_parameters[@]}" \
  --output jsonc
printf 'Deployment finished. Verify private DNS and authorized blob access from an intended private client.\n'
