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

Deploy a private Standard Key Vault with RBAC authorization, purge protection,
soft delete, VNet, private endpoint, and private DNS resources.
JSON files in input/keyvault are auto-discovered and processed independently.

Options:
  --mock                 Validate and preview without Azure deployment calls.
  --use-defaults         Accept displayed example values in interactive mode.
  --interactive          Prompt instead of discovering input/keyvault JSON files.
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
  parameter_files=("$REPO_ROOT"/input/keyvault/*.json)
  shopt -u nullglob
  if ((${#parameter_files[@]} > 0)); then
    failures=0
    printf 'Found %s input/keyvault JSON file(s); using each as a deployment parameter file.\n' "${#parameter_files[@]}"
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
  location vnetName privateEndpointSubnetName vaultName privateDnsZoneName
  vnetLinkName privateEndpointName privateDnsZoneGroupName softDeleteRetentionInDays
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
    "location", "vnetName", "privateEndpointSubnetName", "vaultName",
    "privateDnsZoneName", "vnetLinkName", "privateEndpointName",
    "privateDnsZoneGroupName", "softDeleteRetentionInDays",
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
if any(not isinstance(resolved[name], str) or not resolved[name] for name in names[:-1]):
    print("All required string parameter values must be non-empty strings.", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(resolved["softDeleteRetentionInDays"], int) or isinstance(resolved["softDeleteRetentionInDays"], bool) or not 7 <= resolved["softDeleteRetentionInDays"] <= 90:
    print("softDeleteRetentionInDays must be an integer from 7 to 90.", file=sys.stderr)
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
if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{1,22}[A-Za-z0-9])", resolved["vaultName"]) or "--" in resolved["vaultName"]:
    print("vaultName must be 3-24 letters, numbers, or single hyphens, and start/end with a letter or number.", file=sys.stderr)
    raise SystemExit(1)
if resolved["privateDnsZoneName"] != "privatelink.vaultcore.azure.net":
    print("privateDnsZoneName must be privatelink.vaultcore.azure.net.", file=sys.stderr)
    raise SystemExit(1)
print(group)
for name in names:
    print(resolved[name])
PY
)" || fail "Could not load valid deployment inputs from $PARAMETERS_FILE."
  parameter_values=()
  while IFS= read -r parameter_value; do parameter_values+=("$parameter_value"); done <<< "$parsed_parameters"
  ((${#parameter_values[@]} == 10)) || fail 'Unexpected parameter count in parameter file.'
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
  prompt_value 'Resource group name' 'rg-weather-keyvault-01'
  resource_group_name="$REPLY"
  prompt_value 'Azure region' 'eastus'
  location="$REPLY"
  [[ "$location" =~ ^[a-z0-9-]{1,63}$ ]] || fail 'Invalid Azure region.'
  prompt_name 'Virtual network name' 'vnet-weather-keyvault-01' 64
  vnetName="$REPLY"
  prompt_name 'Private endpoint subnet name' 'snet-keyvault-private-endpoint' 80
  privateEndpointSubnetName="$REPLY"
  while true; do
    prompt_value 'Key Vault name (globally unique)' 'kv-weather-keyvault-01'
    vaultName="$REPLY"
    if [[ "$vaultName" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{1,22}[A-Za-z0-9])$ && "$vaultName" != *--* ]]; then break; fi
    printf 'Use 3-24 letters, numbers, and single hyphens; start/end with a letter or number.\n' >&2
  done
  prompt_value 'Private DNS zone name' 'privatelink.vaultcore.azure.net'
  privateDnsZoneName="$REPLY"
  [[ "$privateDnsZoneName" == privatelink.vaultcore.azure.net ]] || fail 'The Key Vault private DNS zone must be privatelink.vaultcore.azure.net.'
  prompt_name 'Private DNS VNet link name' 'link-keyvault-vnet' 80
  vnetLinkName="$REPLY"
  prompt_name 'Private endpoint name' 'pep-keyvault-01' 80
  privateEndpointName="$REPLY"
  prompt_name 'Private DNS zone group name' 'default' 80
  privateDnsZoneGroupName="$REPLY"
  while true; do
    prompt_value 'Soft-delete retention in days (7-90)' '90'
    softDeleteRetentionInDays="$REPLY"
    [[ "$softDeleteRetentionInDays" =~ ^[0-9]{1,2}$ ]] &&
      ((10#$softDeleteRetentionInDays >= 7 && 10#$softDeleteRetentionInDays <= 90)) && break
    printf 'Retention must be a whole number from 7 to 90.\n' >&2
  done
  [[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail 'Invalid resource group name.'
  deployment_parameters=(
    --parameters "location=$location" "vnetName=$vnetName"
    "privateEndpointSubnetName=$privateEndpointSubnetName" "vaultName=$vaultName"
    "privateDnsZoneName=$privateDnsZoneName" "vnetLinkName=$vnetLinkName"
    "privateEndpointName=$privateEndpointName" "privateDnsZoneGroupName=$privateDnsZoneGroupName"
    "softDeleteRetentionInDays=$softDeleteRetentionInDays"
  )
fi

[[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail 'Invalid resource group name.'
LOG_FILE="$PWD/${resource_group_name}.log"
touch "$LOG_FILE" || fail "Could not create deployment log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== Key Vault deployment run =====\nStarted: %s\nLog file: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_FILE"
if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'INPUT Parameter file=%s\nINPUT Resource group name=%s\n' "$PARAMETERS_FILE" "$resource_group_name"
  for name in "${parameter_names[@]}"; do printf 'INPUT %s=%s\n' "$name" "${!name}"; done
fi
printf '\nResolved configuration:\nResource group: %s (%s)\nVault: %s (Standard, RBAC authorization)\nPrivate endpoint: %s\nPrivate DNS zone: %s\nSoft-delete retention: %s days; purge protection enabled\nPublic access: Disabled\n' \
  "$resource_group_name" "$location" "$vaultName" "$privateEndpointName" "$privateDnsZoneName" "$softDeleteRetentionInDays"

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
