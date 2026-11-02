#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/main.bicep"
MOCK_MODE=false
PARAMETERS_FILE=""
USE_DEFAULTS=false
INTERACTIVE_MODE=false
TEMP_PARAMETERS_FILE=""

cleanup_temp_file() {
  if [[ -n "$TEMP_PARAMETERS_FILE" && -f "$TEMP_PARAMETERS_FILE" ]]; then
    rm -f -- "$TEMP_PARAMETERS_FILE"
  fi
}
trap cleanup_temp_file EXIT

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--mock] [--use-defaults] [--interactive] [--parameters-file FILE]

Deploy an Azure SQL logical server and database with private endpoint access.
JSON files in input/sqldb are discovered automatically.

Options:
  --mock                 Compile and preview without Azure deployment calls.
  --use-defaults         Accept displayed example defaults in interactive mode.
  --interactive          Prompt instead of discovering input/sqldb JSON files.
  --parameters-file FILE Deploy one Bicep parameters JSON file.
  -h, --help
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
      PARAMETERS_FILE="$2"; shift
      ;;
    --use-defaults) USE_DEFAULTS=true ;;
    --interactive) INTERACTIVE_MODE=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

prompt_value() {
  local label="$1" default_value="$2" value
  if [[ "$USE_DEFAULTS" == true ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
    IFS= read -r value || value=''
    REPLY="${value:-$default_value}"
  else
    while true; do
      printf '%s: ' "$label"
      IFS= read -r value || fail "No input received for required value: $label"
      if [[ -n "$value" ]]; then REPLY="$value"; break; fi
      printf 'A value is required; enter a value to continue.\n' >&2
    done
  fi
  printf '\nINPUT %s=%s\n' "$label" "$REPLY"
}

prompt_name() {
  local label="$1" default_value="$2" pattern="$3" max_len="$4" name
  while true; do
    prompt_value "$label" "$default_value"
    name="$REPLY"
    if ((${#name} <= max_len)) && [[ "$name" =~ $pattern ]]; then REPLY="$name"; return; fi
    printf 'Invalid name for %s.\n' "$label" >&2
  done
}

if [[ -z "$PARAMETERS_FILE" && "$INTERACTIVE_MODE" != true ]]; then
  shopt -s nullglob
  parameter_files=("$REPO_ROOT"/input/sqldb/*.json)
  shopt -u nullglob
  if ((${#parameter_files[@]} > 0)); then
    failures=0
    printf 'Found %s input/sqldb JSON file(s); using each as a deployment parameter file.\n' "${#parameter_files[@]}"
    for parameter_file in "${parameter_files[@]}"; do
      printf '\n=== Processing %s ===\n' "$parameter_file"
      child_args=(--parameters-file "$parameter_file")
      [[ "$MOCK_MODE" == true ]] && child_args+=(--mock)
      if "$SCRIPT_DIR/deploy.sh" "${child_args[@]}"; then
        printf 'Completed parameter file: %s\n' "$parameter_file"
      else
        status=$?
        printf 'Deployment failed for %s (exit %s); continuing with remaining files.\n' "$parameter_file" "$status" >&2
        failures=$((failures + 1))
      fi
    done
    ((failures == 0)) || fail "$failures of ${#parameter_files[@]} SQL deployments failed."
    exit 0
  fi
fi

if [[ -n "$PARAMETERS_FILE" ]]; then
  [[ -f "$PARAMETERS_FILE" ]] || fail "Parameter file not found: $PARAMETERS_FILE"
  command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required to read parameter JSON.'
  parsed_parameters="$(python3 - "$PARAMETERS_FILE" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
names = [
    "location", "serverName", "databaseName", "adminLogin", "vnetName",
    "privateEndpointSubnetName", "privateEndpointName", "privateDnsVnetLinkName",
    "databaseSkuName", "databaseSkuTier", "databaseSkuCapacity",
]
try:
    document = json.loads(path.read_text())
    values = document["parameters"]
    if "adminPassword" in values:
        raise ValueError("adminPassword must not be stored in a parameter file.")
    resolved = {name: values[name]["value"] for name in names}
except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
    print(f"Invalid parameter file {path}: {error}", file=sys.stderr)
    raise SystemExit(1)

metadata = document.get("metadata") or {}
if not isinstance(metadata, dict):
    print(f"Parameter file {path}: metadata must be a JSON object.", file=sys.stderr)
    raise SystemExit(1)
group_name = metadata.get("resourceGroupName", path.stem)
if not isinstance(group_name, str) or not group_name:
    print(f"Parameter file {path} must have non-empty metadata.resourceGroupName.", file=sys.stderr)
    raise SystemExit(1)
if any(not isinstance(resolved[name], str) or not resolved[name] for name in names[:-1]):
    print(f"Parameter file {path} contains an empty or non-string required parameter.", file=sys.stderr)
    raise SystemExit(1)
if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", resolved["serverName"]):
    print(f"Parameter file {path}: serverName must be 3-63 lowercase letters, numbers, and internal hyphens.", file=sys.stderr)
    raise SystemExit(1)
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,127}", resolved["adminLogin"]):
    print(f"Parameter file {path}: invalid SQL administrator login.", file=sys.stderr)
    raise SystemExit(1)
if type(resolved["databaseSkuCapacity"]) is not int or resolved["databaseSkuCapacity"] < 1:
    print(f"Parameter file {path}: databaseSkuCapacity must be a positive integer.", file=sys.stderr)
    raise SystemExit(1)
print(group_name)
for name in names:
    print(resolved[name])
PY
)" || fail "Could not load deployment inputs from $PARAMETERS_FILE."
  parameter_values=()
  while IFS= read -r value; do parameter_values+=("$value"); done <<< "$parsed_parameters"
  ((${#parameter_values[@]} == 12)) || fail "Unexpected parameter count in $PARAMETERS_FILE."
  resource_group_name="${parameter_values[0]}"
  location="${parameter_values[1]}"
  server_name="${parameter_values[2]}"
  database_name="${parameter_values[3]}"
  admin_login="${parameter_values[4]}"
  vnet_name="${parameter_values[5]}"
  private_endpoint_subnet_name="${parameter_values[6]}"
  private_endpoint_name="${parameter_values[7]}"
  private_dns_vnet_link_name="${parameter_values[8]}"
  database_sku_name="${parameter_values[9]}"
  database_sku_tier="${parameter_values[10]}"
  database_sku_capacity="${parameter_values[11]}"
  deployment_parameters=("--parameters" "@$PARAMETERS_FILE")
else
  prompt_name 'Resource group name' 'rg-weather-sqldb-01' '^[A-Za-z0-9][A-Za-z0-9._()-]*$' 90; resource_group_name="$REPLY"
  prompt_value 'Azure region' 'eastus'; location="$REPLY"
  [[ "$location" =~ ^[a-z0-9-]+$ ]] || fail 'Invalid Azure region.'
  prompt_name 'SQL server name (globally unique)' 'weather-sql-01' '^[a-z0-9][a-z0-9-]*[a-z0-9]$' 63; server_name="$REPLY"
  prompt_name 'SQL database name' 'weatherdb' '^[A-Za-z0-9_-]+$' 128; database_name="$REPLY"
  prompt_name 'SQL administrator login' 'sqladminweather' '^[A-Za-z][A-Za-z0-9_]*$' 128; admin_login="$REPLY"
  prompt_name 'Virtual network name' 'vnet-weather-sqldb-01' '^[A-Za-z0-9][A-Za-z0-9._-]*$' 64; vnet_name="$REPLY"
  prompt_name 'Private endpoint subnet name' 'snet-sqldb-private-endpoint' '^[A-Za-z0-9][A-Za-z0-9._-]*$' 80; private_endpoint_subnet_name="$REPLY"
  prompt_name 'SQL private endpoint name' 'pe-weather-sqldb-01' '^[A-Za-z0-9][A-Za-z0-9._-]*$' 80; private_endpoint_name="$REPLY"
  prompt_name 'Private DNS VNet link name' 'link-sqldb-vnet' '^[A-Za-z0-9][A-Za-z0-9._-]*$' 80; private_dns_vnet_link_name="$REPLY"
  prompt_value 'SQL Database SKU name' 'S0'; database_sku_name="$REPLY"
  prompt_value 'SQL Database SKU tier' 'Standard'; database_sku_tier="$REPLY"
  prompt_value 'SQL Database SKU capacity (DTUs)' '10'; database_sku_capacity="$REPLY"
  [[ "$database_sku_capacity" =~ ^[1-9][0-9]*$ ]] || fail 'Database SKU capacity must be a positive integer.'
  deployment_parameters=(
    --parameters "location=$location" "serverName=$server_name" "databaseName=$database_name"
    "adminLogin=$admin_login" "vnetName=$vnet_name"
    "privateEndpointSubnetName=$private_endpoint_subnet_name"
    "privateEndpointName=$private_endpoint_name"
    "privateDnsVnetLinkName=$private_dns_vnet_link_name"
    "databaseSkuName=$database_sku_name" "databaseSkuTier=$database_sku_tier"
    "databaseSkuCapacity=$database_sku_capacity"
  )
fi

[[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail 'Invalid resource group name.'
LOG_FILE="$PWD/${resource_group_name}.log"
touch "$LOG_FILE" || fail "Could not create deployment log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== SQL Database deployment run =====\nStarted: %s\nLog file: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_FILE"
printf 'INPUT Resource group name=%s\n' "$resource_group_name"
printf 'INPUT SQL server name=%s\n' "$server_name"
printf 'INPUT SQL database name=%s\n' "$database_name"
printf 'INPUT SQL administrator login=%s\n' "$admin_login"
printf 'INPUT SQL administrator password=[REDACTED; requested only for real deployment]\n'
printf 'INPUT Azure region=%s\n' "$location"
printf 'INPUT Virtual network name=%s\n' "$vnet_name"
printf 'INPUT Private endpoint subnet name=%s\n' "$private_endpoint_subnet_name"
printf 'INPUT SQL private endpoint name=%s\n' "$private_endpoint_name"
printf 'INPUT Private DNS VNet link name=%s\n' "$private_dns_vnet_link_name"
printf 'INPUT Database SKU=%s / %s / %s DTUs\n' "$database_sku_name" "$database_sku_tier" "$database_sku_capacity"
[[ -n "$PARAMETERS_FILE" ]] && printf 'INPUT Parameter file=%s\n' "$PARAMETERS_FILE"

run_bicep_build() {
  printf '\nCOMMAND: az bicep build --file %s --stdout\n' "$TEMPLATE_FILE"
  if az bicep build --file "$TEMPLATE_FILE" --stdout >>"$LOG_FILE" 2>&1; then
    printf 'Bicep compilation succeeded.\n'
  else
    local status=$?
    printf 'Bicep compilation failed with exit code %s; see log.\n' "$status"
    return "$status"
  fi
}

if [[ "$MOCK_MODE" == true ]]; then
  if command -v az >/dev/null 2>&1; then run_bicep_build || fail 'Bicep compilation failed.'; else
    printf 'Bicep compilation skipped: Azure CLI/Bicep unavailable.\n'
  fi
  printf '\nMOCK MODE: no Azure deployment commands were run and no resources were created.\n'
  printf 'Resource group: %s (%s)\nSQL server: %s.database.windows.net\nDatabase: %s\nPrivate endpoint: %s\n' \
    "$resource_group_name" "$location" "$server_name" "$database_name" "$private_endpoint_name"
  printf 'Would deploy using private DNS zone privatelink.database.windows.net and the configured database SKU.\n'
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required. Install it and sign in with az login.'
run_bicep_build || fail 'Bicep compilation failed; deployment stopped.'
printf '\nActive subscription: '
subscription_details="$(az account show --query '[name, id]' --output tsv)" || fail 'Azure CLI is not signed in; run az login.'
printf '%s\n' "$subscription_details"
if [[ -z "$PARAMETERS_FILE" ]]; then
  printf 'Proceed with deployment? [y/N]: '
  IFS= read -r confirmation || confirmation=''
  [[ "$confirmation" == y || "$confirmation" == Y ]] || {
    printf 'Deployment cancelled. No resources were created.\n'
    exit 0
  }
fi

printf 'SQL administrator password (hidden; 8-128 chars, uppercase, lowercase, number, and symbol): '
IFS= read -r -s admin_password || fail 'Could not read the SQL administrator password.'
printf '\nConfirm SQL administrator password: '
IFS= read -r -s admin_password_confirmation || fail 'Could not read the password confirmation.'
printf '\n'
[[ "$admin_password" == "$admin_password_confirmation" ]] || fail 'SQL administrator passwords do not match.'
[[ ${#admin_password} -ge 8 && ${#admin_password} -le 128 &&
  "$admin_password" =~ [A-Z] && "$admin_password" =~ [a-z] &&
  "$admin_password" =~ [0-9] && "$admin_password" =~ [^A-Za-z0-9] ]] ||
  fail 'Password must be 8-128 characters and include uppercase, lowercase, numeric, and symbol characters.'
unset admin_password_confirmation

TEMP_PARAMETERS_FILE="$(mktemp "${TMPDIR:-/tmp}/sqldb-parameters.XXXXXX")" ||
  fail 'Could not create protected temporary parameter file.'
chmod 600 "$TEMP_PARAMETERS_FILE"
python3 - "$PARAMETERS_FILE" "$TEMP_PARAMETERS_FILE" \
  "$location" "$server_name" "$database_name" "$admin_login" "$vnet_name" \
  "$private_endpoint_subnet_name" "$private_endpoint_name" "$private_dns_vnet_link_name" \
  "$database_sku_name" "$database_sku_tier" "$database_sku_capacity" \
  3<<<"$admin_password" <<'PY'
import json
import os
import pathlib
import sys

source = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
target = pathlib.Path(sys.argv[2])
if source:
    document = json.loads(source.read_text())
else:
    names = [
        "location", "serverName", "databaseName", "adminLogin", "vnetName",
        "privateEndpointSubnetName", "privateEndpointName", "privateDnsVnetLinkName",
        "databaseSkuName", "databaseSkuTier", "databaseSkuCapacity",
    ]
    values = sys.argv[3:]
    document = {
        "parameters": {
            name: {"value": value}
            for name, value in zip(names, values, strict=True)
        }
    }
    document["parameters"]["databaseSkuCapacity"]["value"] = int(document["parameters"]["databaseSkuCapacity"]["value"])
document.setdefault("parameters", {})["adminPassword"] = {"value": os.fdopen(3).read().rstrip("\n")}
target.write_text(json.dumps(document))
PY
unset admin_password

printf '\nCOMMAND: az group create --name %s --location %s --output jsonc\n' "$resource_group_name" "$location"
az group create --name "$resource_group_name" --location "$location" --output jsonc
printf '\nCOMMAND: az deployment group create --resource-group %s --template-file %s --parameters @<protected-temp-file> --output jsonc\n' \
  "$resource_group_name" "$TEMPLATE_FILE"
az deployment group create --resource-group "$resource_group_name" --template-file "$TEMPLATE_FILE" \
  --parameters "@$TEMP_PARAMETERS_FILE" --output jsonc
printf '\nDeployment finished. Verify private DNS and database connectivity from the linked VNet.\n'
