#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/main.bicep"
MOCK_MODE=false
PARAMETERS_FILE=""
USE_DEFAULTS=false
INTERACTIVE_MODE=false

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--mock] [--use-defaults] [--interactive] [--parameters-file FILE]

Deploy a private, serverless Cosmos DB for NoSQL account, SQL database/container,
VNet, private endpoint, and private DNS resources.
JSON files in input/cosmosdb are auto-discovered and processed independently.

Options:
  --mock                 Validate and preview without Azure deployment calls.
  --use-defaults         Accept displayed example values in interactive mode.
  --interactive          Prompt instead of discovering input/cosmosdb JSON files.
  --parameters-file FILE Deploy one Bicep parameters JSON file without prompts.
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
    --parameters-file)
      (($# >= 2)) || fail '--parameters-file requires a path.'
      PARAMETERS_FILE="$2"
      shift
      ;;
    --use-defaults) USE_DEFAULTS=true ;;
    --interactive) INTERACTIVE_MODE=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

if [[ -z "$PARAMETERS_FILE" && "$INTERACTIVE_MODE" != true ]]; then
  shopt -s nullglob
  parameter_files=("$REPO_ROOT"/input/cosmosdb/*.json)
  shopt -u nullglob
  if ((${#parameter_files[@]} > 0)); then
    failures=0
    printf 'Found %s input/cosmosdb JSON file(s); using each as a deployment parameter file.\n' "${#parameter_files[@]}"
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

parameter_names=(
  location vnetName privateEndpointSubnetName accountName databaseName containerName
  partitionKeyPath privateDnsZoneName vnetLinkName privateEndpointName privateDnsZoneGroupName
)
if [[ -n "$PARAMETERS_FILE" ]]; then
  [[ -f "$PARAMETERS_FILE" ]] || fail "Parameter file not found: $PARAMETERS_FILE"
  command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required to read JSON parameter files.'
  parsed_parameters="$(python3 - "$PARAMETERS_FILE" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
names = [
    "location", "vnetName", "privateEndpointSubnetName", "accountName",
    "databaseName", "containerName", "partitionKeyPath", "privateDnsZoneName",
    "vnetLinkName", "privateEndpointName", "privateDnsZoneGroupName",
]
try:
    document = json.loads(path.read_text())
    values = document["parameters"]
except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
    print(f"Invalid Bicep parameter JSON {path}: {error}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(values, dict) or set(values) != set(names):
    print(f"Parameter file must contain exactly these parameters (no credentials or extras): {', '.join(names)}", file=sys.stderr)
    raise SystemExit(1)
try:
    resolved = {name: values[name]["value"] for name in names}
except (KeyError, TypeError) as error:
    print(f"Parameter file {path} is missing a required value: {error}", file=sys.stderr)
    raise SystemExit(1)
metadata = document.get("metadata") or {}
if not isinstance(metadata, dict):
    print("metadata must be a JSON object.", file=sys.stderr)
    raise SystemExit(1)
group = metadata.get("resourceGroupName", path.stem)
if not isinstance(group, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._()-]{0,89}", group):
    print("resourceGroupName must be a valid 1-90 character resource group name.", file=sys.stderr)
    raise SystemExit(1)
if any(not isinstance(resolved[name], str) or not resolved[name] for name in names):
    print("All required parameter values must be non-empty strings.", file=sys.stderr)
    raise SystemExit(1)
if not re.fullmatch(r"[a-z0-9-]{1,63}", resolved["location"]):
    print("location must be an Azure region token such as eastus.", file=sys.stderr)
    raise SystemExit(1)
for name, maximum in (("vnetName", 64), ("privateEndpointSubnetName", 80),
                      ("vnetLinkName", 80), ("privateEndpointName", 80),
                      ("privateDnsZoneGroupName", 80)):
    if not re.fullmatch(rf"[A-Za-z0-9][A-Za-z0-9._-]{{0,{maximum - 1}}}", resolved[name]):
        print(f"{name} has an invalid resource name.", file=sys.stderr)
        raise SystemExit(1)
if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,42}[a-z0-9])", resolved["accountName"]) or "--" in resolved["accountName"]:
    print("accountName must be 3-44 lowercase letters, numbers, or single hyphens, and start/end with a letter or number.", file=sys.stderr)
    raise SystemExit(1)
for name in ("databaseName", "containerName"):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,254}", resolved[name]):
        print(f"{name} must be 1-255 letters, numbers, underscores, or hyphens and start with a letter or number.", file=sys.stderr)
        raise SystemExit(1)
if not re.fullmatch(r"/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*", resolved["partitionKeyPath"]):
    print("partitionKeyPath must be a slash-prefixed JSON property path such as /weatherStationId.", file=sys.stderr)
    raise SystemExit(1)
if resolved["privateDnsZoneName"] != "privatelink.documents.azure.com":
    print("privateDnsZoneName must be privatelink.documents.azure.com.", file=sys.stderr)
    raise SystemExit(1)
print(group)
for name in names:
    print(resolved[name])
PY
)" || fail "Could not load valid deployment inputs from $PARAMETERS_FILE."
  parameter_values=()
  while IFS= read -r parameter_value; do parameter_values+=("$parameter_value"); done <<< "$parsed_parameters"
  ((${#parameter_values[@]} == 12)) || fail 'Unexpected parameter count in parameter file.'
  resource_group_name="${parameter_values[0]}"
  for index in "${!parameter_names[@]}"; do
    printf -v "${parameter_names[$index]}" '%s' "${parameter_values[$((index + 1))]}"
  done
  deployment_parameters=(--parameters "@$PARAMETERS_FILE")
else
  prompt_value() {
    local label="$1" default="$2" value
    if [[ "$USE_DEFAULTS" == true ]]; then
      printf '%s [%s]: ' "$label" "$default"
      IFS= read -r value || value=''
      REPLY="${value:-$default}"
    else
      while true; do
        printf '%s: ' "$label"
        IFS= read -r value || fail "No input received for required value: $label"
        [[ -n "$value" ]] && { REPLY="$value"; break; }
        printf 'A value is required.\n' >&2
      done
    fi
    printf '\nINPUT %s=%s\n' "$label" "$REPLY"
  }
  prompt_name() {
    local label="$1" default="$2" max="$3"
    while true; do
      prompt_value "$label" "$default"
      if ((${#REPLY} <= max)) && [[ "$REPLY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then return; fi
      printf 'Invalid name; use at most %s letters, numbers, dots, underscores, or hyphens.\n' "$max" >&2
    done
  }
  prompt_cosmos_id() {
    local label="$1" default="$2"
    while true; do
      prompt_value "$label" "$default"
      if ((${#REPLY} <= 255)) && [[ "$REPLY" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then return; fi
      printf 'Use 1-255 letters, numbers, underscores, or hyphens; start with a letter or number.\n' >&2
    done
  }
  prompt_value 'Resource group name' 'rg-weather-cosmosdb-01'
  resource_group_name="$REPLY"
  prompt_value 'Azure region' 'eastus'
  location="$REPLY"
  [[ "$location" =~ ^[a-z0-9-]{1,63}$ ]] || fail 'Invalid Azure region.'
  prompt_name 'Virtual network name' 'vnet-weather-cosmosdb-01' 64
  vnetName="$REPLY"
  prompt_name 'Private endpoint subnet name' 'snet-cosmosdb-private-endpoint' 80
  privateEndpointSubnetName="$REPLY"
  while true; do
    prompt_value 'Cosmos DB account name (globally unique)' 'weathercosmosdb01'
    accountName="$REPLY"
    if [[ "$accountName" =~ ^[a-z0-9]([a-z0-9-]{1,42}[a-z0-9])$ && "$accountName" != *--* ]]; then break; fi
    printf 'Use 3-44 lowercase letters, numbers, and single hyphens; start/end with a letter or number.\n' >&2
  done
  prompt_cosmos_id 'SQL database name' 'weather'
  databaseName="$REPLY"
  prompt_cosmos_id 'Container name' 'observations'
  containerName="$REPLY"
  while true; do
    prompt_value 'Container partition key path' '/weatherStationId'
    partitionKeyPath="$REPLY"
    [[ "$partitionKeyPath" =~ ^(/[A-Za-z0-9_-]+)+$ ]] && break
    printf 'Use a slash-prefixed property path such as /weatherStationId.\n' >&2
  done
  prompt_value 'Private DNS zone name' 'privatelink.documents.azure.com'
  privateDnsZoneName="$REPLY"
  [[ "$privateDnsZoneName" == privatelink.documents.azure.com ]] || fail 'The Cosmos DB private DNS zone must be privatelink.documents.azure.com.'
  prompt_name 'Private DNS VNet link name' 'link-cosmosdb-vnet' 80
  vnetLinkName="$REPLY"
  prompt_name 'Private endpoint name' 'pep-cosmosdb-01' 80
  privateEndpointName="$REPLY"
  prompt_name 'Private DNS zone group name' 'default' 80
  privateDnsZoneGroupName="$REPLY"
  [[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail 'Invalid resource group name.'
  deployment_parameters=(
    --parameters "location=$location" "vnetName=$vnetName"
    "privateEndpointSubnetName=$privateEndpointSubnetName" "accountName=$accountName"
    "databaseName=$databaseName" "containerName=$containerName"
    "partitionKeyPath=$partitionKeyPath" "privateDnsZoneName=$privateDnsZoneName"
    "vnetLinkName=$vnetLinkName" "privateEndpointName=$privateEndpointName"
    "privateDnsZoneGroupName=$privateDnsZoneGroupName"
  )
fi

[[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail 'Invalid resource group name.'
LOG_FILE="$PWD/${resource_group_name}.log"
touch "$LOG_FILE" || fail "Could not create deployment log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== Cosmos DB deployment run =====\nStarted: %s\nLog file: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_FILE"
if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'INPUT Parameter file=%s\nINPUT Resource group name=%s\n' "$PARAMETERS_FILE" "$resource_group_name"
  for name in "${parameter_names[@]}"; do printf 'INPUT %s=%s\n' "$name" "${!name}"; done
fi
printf '\nResolved configuration:\nResource group: %s (%s)\nAccount: %s\nSQL database/container: %s/%s\nPartition key: %s\nPrivate endpoint: %s\nPrivate DNS zone: %s\nPublic access: Disabled\nLocal/key authentication: Disabled\n' \
  "$resource_group_name" "$location" "$accountName" "$databaseName" "$containerName" "$partitionKeyPath" "$privateEndpointName" "$privateDnsZoneName"

if [[ "$MOCK_MODE" == true ]]; then
  if command -v az >/dev/null 2>&1; then
    printf 'COMMAND: az bicep build --file %s --stdout\n' "$TEMPLATE_FILE"
    az bicep build --file "$TEMPLATE_FILE" --stdout
  else
    printf 'Bicep compilation skipped: Azure CLI/Bicep compiler is unavailable.\n'
  fi
  printf 'MOCK MODE: no Azure deployment commands were run and no resources were created.\n'
  printf 'Would deploy: az deployment group create --resource-group %s --template-file %s [parameters]\n' "$resource_group_name" "$TEMPLATE_FILE"
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required.'
printf '\nCOMMAND: az bicep build --file %s --stdout\n' "$TEMPLATE_FILE"
az bicep build --file "$TEMPLATE_FILE" --stdout
subscription="$(az account show --query id --output tsv)" || fail 'Azure CLI is not signed in; run az login.'
[[ -n "$subscription" ]] || fail 'Could not determine the active subscription.'
printf 'Subscription: %s\n' "$subscription"
printf 'This creates billable Azure resources. Type the resource group name to confirm: '
IFS= read -r confirmation || confirmation=''
[[ "$confirmation" == "$resource_group_name" ]] || { printf 'Deployment cancelled. No resources were created.\n'; exit 0; }
printf '\nCOMMAND: az group create --name %s --location %s\n' "$resource_group_name" "$location"
az group create --name "$resource_group_name" --location "$location" --output json
printf '\nCOMMAND: az deployment group create --resource-group %s --template-file %s [parameters]\n' "$resource_group_name" "$TEMPLATE_FILE"
az deployment group create --resource-group "$resource_group_name" --template-file "$TEMPLATE_FILE" "${deployment_parameters[@]}" --output json
printf 'Deployment completed for %s.\n' "$resource_group_name"
