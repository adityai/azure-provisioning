#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/main.bicep"
MOCK_MODE=false
PARAMETERS_FILE=""

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--mock] [--parameters-file FILE]

Interactively deploy an App Service and private networking resources defined
in main.bicep to the selected Azure resource group.
If JSON files exist at the repository root, each is deployed as a parameter
file instead of prompting.

Options:
  --mock                 Compile and preview deployments without Azure deployment calls.
  --parameters-file FILE Deploy one Bicep parameters JSON file without prompts.
  -h, --help
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --mock)
      MOCK_MODE=true
      ;;
    --parameters-file)
      (($# >= 2)) || fail '--parameters-file requires a path.'
      PARAMETERS_FILE="$2"
      shift
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

prompt_value() {
  local label="$1"
  local default_value="$2"
  local value
  printf '%s [%s]: ' "$label" "$default_value"
  IFS= read -r value || value=''
  REPLY="${value:-$default_value}"
  printf '\nINPUT %s=%s\n' "$label" "$REPLY"
}

valid_general_name() {
  local name="$1"
  local max_length="$2"
  [[ ${#name} -ge 1 && ${#name} -le max_length && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

prompt_resource_name() {
  local label="$1"
  local default_value="$2"
  local max_length="$3"
  local name
  while true; do
    prompt_value "$label" "$default_value"
    name="$REPLY"
    if valid_general_name "$name" "$max_length"; then
      REPLY="$name"
      return
    fi
    printf 'Invalid name. Use 1-%s letters, numbers, dots, underscores, or hyphens; start with a letter or number.\n' "$max_length" >&2
  done
}

prompt_web_app_name() {
  local name
  while true; do
    prompt_value "$operating_system web app name (globally unique)" 'app-mcp-test-01'
    name="$REPLY"
    if ((${#name} >= 2 && ${#name} <= 60)) && [[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      REPLY="$name"
      return
    fi
    printf 'Invalid app name. Use 2-60 lowercase letters, numbers, or hyphens; do not start or end with a hyphen.\n' >&2
  done
}

prompt_plan_name() {
  local name
  while true; do
    prompt_value 'App Service plan name' 'asp-appservice-01'
    name="$REPLY"
    if ((${#name} >= 1 && ${#name} <= 40)) && [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
      REPLY="$name"
      return
    fi
    printf 'Invalid plan name. Use 1-40 letters, numbers, or hyphens; start with a letter or number.\n' >&2
  done
}

prompt_region() {
  while true; do
    prompt_value 'Azure region' 'eastus'
    if [[ "$REPLY" =~ ^[a-z0-9-]+$ ]]; then
      return
    fi
    printf 'Enter a region such as eastus or centralus.\n' >&2
  done
}

prompt_operating_system() {
  while true; do
    prompt_value 'App Service operating system (Linux or Windows)' 'Linux'
    case "$REPLY" in
      Linux|Windows) return ;;
      *) printf 'Choose Linux or Windows.\n' >&2 ;;
    esac
  done
}

prompt_nonempty_value() {
  local label="$1"
  local default_value="$2"
  while true; do
    prompt_value "$label" "$default_value"
    if [[ -n "$REPLY" ]]; then
      return
    fi
    printf 'A value is required.\n' >&2
  done
}

prompt_sku_token() {
  local label="$1"
  local default_value="$2"
  while true; do
    prompt_value "$label" "$default_value"
    if [[ "$REPLY" =~ ^[A-Za-z0-9._-]+$ ]]; then
      return
    fi
    printf 'Use letters, numbers, dots, underscores, or hyphens only.\n' >&2
  done
}

prompt_sku_capacity() {
  while true; do
    prompt_value 'App Service plan instance capacity' '1'
    if [[ "$REPLY" =~ ^[1-9][0-9]*$ ]]; then
      return
    fi
    printf 'Capacity must be a positive integer.\n' >&2
  done
}

if [[ -z "$PARAMETERS_FILE" ]]; then
  shopt -s nullglob
  parameter_files=("$REPO_ROOT"/*.json)
  shopt -u nullglob

  if ((${#parameter_files[@]} > 0)); then
    failures=0
    printf 'Found %s root-level JSON file(s); using each as a deployment parameter file.\n' "${#parameter_files[@]}"
    for parameter_file in "${parameter_files[@]}"; do
      printf '\n=== Processing %s ===\n' "$parameter_file"
      child_args=(--parameters-file "$parameter_file")
      [[ "$MOCK_MODE" == true ]] && child_args+=(--mock)
      if "$SCRIPT_DIR/deploy.sh" "${child_args[@]}"; then
        printf 'Completed parameter file: %s\n' "$parameter_file"
      else
        status=$?
        printf 'Deployment failed for %s (exit %s); continuing with remaining files.\n' \
          "$parameter_file" "$status" >&2
        failures=$((failures + 1))
      fi
    done
    if ((failures > 0)); then
      fail "$failures of ${#parameter_files[@]} JSON deployment(s) failed."
    fi
    exit 0
  fi
fi

if [[ -n "$PARAMETERS_FILE" ]]; then
  [[ -f "$PARAMETERS_FILE" ]] || fail "Parameter file not found: $PARAMETERS_FILE"
  command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required to read Bicep parameter JSON files.'
  parsed_parameters="$(python3 - "$PARAMETERS_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    document = json.loads(path.read_text())
    values = document["parameters"]
except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
    print(f"Invalid Bicep parameter JSON {path}: {error}", file=sys.stderr)
    raise SystemExit(1)

names = [
    "location",
    "vnetName",
    "integrationSubnetName",
    "privateEndpointSubnetName",
    "planName",
    "operatingSystem",
    "webAppName",
    "runtimeStack",
    "privateDnsZoneName",
    "vnetLinkName",
    "privateEndpointName",
    "privateDnsZoneGroupName",
    "skuName",
    "skuTier",
    "skuSize",
    "skuFamily",
    "skuCapacity",
]
try:
    resolved = {name: values[name]["value"] for name in names}
except (KeyError, TypeError) as error:
    print(f"Parameter file {path} is missing a required parameter or value: {error}", file=sys.stderr)
    raise SystemExit(1)

metadata = document.get("metadata") or {}
if not isinstance(metadata, dict):
    print(f"Parameter file {path}: metadata must be a JSON object.", file=sys.stderr)
    raise SystemExit(1)
group_name = metadata.get("resourceGroupName", path.stem)
if not isinstance(group_name, str) or not group_name:
    print(f"Parameter file {path} must have a non-empty metadata.resourceGroupName.", file=sys.stderr)
    raise SystemExit(1)
if any(not isinstance(resolved[name], str) or not resolved[name] for name in names[:-1]):
    print(f"Parameter file {path} has an empty or non-string required parameter.", file=sys.stderr)
    raise SystemExit(1)
if resolved["operatingSystem"] not in ("Linux", "Windows"):
    print(f"Parameter file {path}: operatingSystem must be Linux or Windows.", file=sys.stderr)
    raise SystemExit(1)
if resolved["privateDnsZoneName"] != "privatelink.azurewebsites.net":
    print(f"Parameter file {path}: privateDnsZoneName must be privatelink.azurewebsites.net.", file=sys.stderr)
    raise SystemExit(1)
if type(resolved["skuCapacity"]) is not int or resolved["skuCapacity"] < 1:
    print(f"Parameter file {path}: skuCapacity must be a positive integer.", file=sys.stderr)
    raise SystemExit(1)

print(group_name)
for name in names:
    print(resolved[name])
PY
)" || fail "Could not load deployment inputs from $PARAMETERS_FILE."
  parameter_values=()
  while IFS= read -r parameter_value; do
    parameter_values+=("$parameter_value")
  done <<< "$parsed_parameters"
  ((${#parameter_values[@]} == 18)) || fail "Unexpected parameter count in $PARAMETERS_FILE."
  resource_group_name="${parameter_values[0]}"
  location="${parameter_values[1]}"
  vnet_name="${parameter_values[2]}"
  integration_subnet_name="${parameter_values[3]}"
  private_endpoint_subnet_name="${parameter_values[4]}"
  plan_name="${parameter_values[5]}"
  operating_system="${parameter_values[6]}"
  web_app_name="${parameter_values[7]}"
  runtime_stack="${parameter_values[8]}"
  private_dns_zone_name="${parameter_values[9]}"
  vnet_link_name="${parameter_values[10]}"
  private_endpoint_name="${parameter_values[11]}"
  private_dns_zone_group_name="${parameter_values[12]}"
  sku_name="${parameter_values[13]}"
  sku_tier="${parameter_values[14]}"
  sku_size="${parameter_values[15]}"
  sku_family="${parameter_values[16]}"
  sku_capacity="${parameter_values[17]}"
  deployment_parameters=("--parameters" "@$PARAMETERS_FILE")
else
  prompt_resource_name 'Resource group name' 'rg-appservice-01' 90
  resource_group_name="$REPLY"
fi

[[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] ||
  fail "Invalid resource group name: $resource_group_name"
LOG_FILE="$PWD/${resource_group_name}.log"
: > "$LOG_FILE" || fail "Could not create deployment log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf 'App Service deployment log\n'
printf 'Started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Log file: %s\n' "$LOG_FILE"
if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'INPUT Parameter file=%s\n' "$PARAMETERS_FILE"
  printf 'INPUT Resource group name=%s\n' "$resource_group_name"
  printf 'INPUT Azure region=%s\n' "$location"
  printf 'INPUT Virtual network name=%s\n' "$vnet_name"
  printf 'INPUT VNet integration subnet name=%s\n' "$integration_subnet_name"
  printf 'INPUT Private endpoint subnet name=%s\n' "$private_endpoint_subnet_name"
  printf 'INPUT App Service plan name=%s\n' "$plan_name"
  printf 'INPUT App Service operating system=%s\n' "$operating_system"
  printf 'INPUT Web app name=%s\n' "$web_app_name"
  printf 'INPUT App Service runtime stack=%s\n' "$runtime_stack"
  printf 'INPUT Private DNS zone name=%s\n' "$private_dns_zone_name"
  printf 'INPUT Private DNS VNet link name=%s\n' "$vnet_link_name"
  printf 'INPUT Private endpoint name=%s\n' "$private_endpoint_name"
  printf 'INPUT Private DNS zone group name=%s\n' "$private_dns_zone_group_name"
  printf 'INPUT App Service plan SKU name=%s\n' "$sku_name"
  printf 'INPUT App Service plan SKU tier=%s\n' "$sku_tier"
  printf 'INPUT App Service plan SKU size=%s\n' "$sku_size"
  printf 'INPUT App Service plan SKU family=%s\n' "$sku_family"
  printf 'INPUT App Service plan instance capacity=%s\n' "$sku_capacity"
else
  printf 'INPUT Resource group name=%s\n' "$resource_group_name"
  prompt_region
  location="$REPLY"
  prompt_resource_name 'Virtual network name' 'vnet-appservice-01' 64
  vnet_name="$REPLY"
  prompt_resource_name 'VNet integration subnet name' 'snet-appservice-integration' 80
  integration_subnet_name="$REPLY"
  prompt_resource_name 'Private endpoint subnet name' 'snet-appservice-private-endpoint' 80
  private_endpoint_subnet_name="$REPLY"
  prompt_plan_name
  plan_name="$REPLY"
  prompt_operating_system
  operating_system="$REPLY"
  prompt_web_app_name
  web_app_name="$REPLY"
  if [[ "$operating_system" == Linux ]]; then
    runtime_default='NODE|20-lts'
  else
    runtime_default='DOTNET|8.0'
  fi
  prompt_nonempty_value 'App Service runtime stack (for example NODE|20-lts or DOTNET|8.0)' "$runtime_default"
  runtime_stack="$REPLY"
  prompt_value 'Private DNS zone name (required by App Service private endpoints)' 'privatelink.azurewebsites.net'
  private_dns_zone_name="$REPLY"
  [[ "$private_dns_zone_name" == 'privatelink.azurewebsites.net' ]] || fail 'The private DNS zone must be privatelink.azurewebsites.net.'
  prompt_resource_name 'Private DNS VNet link name' 'link-appservice-vnet' 80
  vnet_link_name="$REPLY"
  prompt_resource_name 'Private endpoint name' 'pep-appservice-01' 80
  private_endpoint_name="$REPLY"
  prompt_resource_name 'Private DNS zone group name' 'default' 80
  private_dns_zone_group_name="$REPLY"
  prompt_sku_token 'App Service plan SKU name' 'S1'
  sku_name="$REPLY"
  prompt_sku_token 'App Service plan SKU tier' 'Standard'
  sku_tier="$REPLY"
  prompt_sku_token 'App Service plan SKU size' "$sku_name"
  sku_size="$REPLY"
  prompt_sku_token 'App Service plan SKU family' "${sku_name:0:1}"
  sku_family="$REPLY"
  prompt_sku_capacity
  sku_capacity="$REPLY"

  deployment_parameters=(
    "--parameters"
    "location=$location"
    "operatingSystem=$operating_system"
    "runtimeStack=$runtime_stack"
    "vnetName=$vnet_name"
    "integrationSubnetName=$integration_subnet_name"
    "privateEndpointSubnetName=$private_endpoint_subnet_name"
    "planName=$plan_name"
    "webAppName=$web_app_name"
    "privateDnsZoneName=$private_dns_zone_name"
    "vnetLinkName=$vnet_link_name"
    "privateEndpointName=$private_endpoint_name"
    "privateDnsZoneGroupName=$private_dns_zone_group_name"
    "skuName=$sku_name"
    "skuTier=$sku_tier"
    "skuSize=$sku_size"
    "skuFamily=$sku_family"
    "skuCapacity=$sku_capacity"
  )
fi

run_bicep_build() {
  printf '\nCOMMAND: az bicep build --file %s --stdout\n' "$TEMPLATE_FILE"
  if az bicep build --file "$TEMPLATE_FILE" --stdout >>"$LOG_FILE" 2>&1; then
    printf 'Bicep compilation succeeded; full compiler output is recorded above in this log.\n'
  else
    local status=$?
    printf 'Bicep compilation failed with exit code %s. See compiler output in this log.\n' "$status"
    return "$status"
  fi
}

if [[ "$MOCK_MODE" == true ]]; then
  if command -v az >/dev/null 2>&1; then
    run_bicep_build || fail 'Bicep compilation failed; mock deployment stopped.'
  else
    printf '\nBicep compilation skipped: Azure CLI/Bicep compiler is unavailable in this environment.\n'
  fi
  printf '\nMOCK MODE: no Azure deployment commands were run and no resources were created.\n'
  printf '\nResolved deployment inputs:\n'
  printf 'Resource group: %s (%s)\n' "$resource_group_name" "$location"
  printf 'Plan: %s (SKU %s, tier %s, size %s, family %s, capacity %s; %s)\n' \
    "$plan_name" "$sku_name" "$sku_tier" "$sku_size" "$sku_family" "$sku_capacity" "$operating_system"
  printf 'Web app: %s (public network access disabled)\n' "$web_app_name"
  printf 'Runtime stack: %s\n' "$runtime_stack"
  printf 'VNet: %s; integration subnet: %s; private endpoint subnet: %s\n' \
    "$vnet_name" "$integration_subnet_name" "$private_endpoint_subnet_name"
  printf 'Private endpoint: %s; DNS zone: %s; VNet link: %s; zone group: %s\n' \
    "$private_endpoint_name" "$private_dns_zone_name" "$vnet_link_name" "$private_dns_zone_group_name"
  printf 'Would deploy: az deployment group create --resource-group %q --template-file %q' \
    "$resource_group_name" "$TEMPLATE_FILE"
  printf ' %q' "${deployment_parameters[@]}"
  printf '\n'
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required. Install it and sign in with az login.'
[[ -f "$TEMPLATE_FILE" ]] || fail "Bicep template not found: $TEMPLATE_FILE"
run_bicep_build || fail 'Bicep compilation failed; deployment stopped.'
printf '\nCOMMAND: az account show --query '\''[name, id]'\'' --output tsv\n'
subscription_details="$(az account show --query '[name, id]' --output tsv)" ||
  fail 'Azure CLI is not signed in or the active account is unavailable. Run az login.'
[[ -n "$subscription_details" ]] || fail 'Could not determine the active Azure subscription.'

printf '\nActive Azure subscription (name, ID): %s\n' "$subscription_details"
printf '\nResolved deployment inputs:\n'
printf 'Resource group: %s (%s)\n' "$resource_group_name" "$location"
printf 'Plan: %s (SKU %s, tier %s, size %s, family %s, capacity %s; %s); web app: %s\n' \
  "$plan_name" "$sku_name" "$sku_tier" "$sku_size" "$sku_family" "$sku_capacity" "$operating_system" "$web_app_name"
printf 'Runtime stack: %s\n' "$runtime_stack"
printf 'VNet: %s; integration subnet: %s; private endpoint subnet: %s\n' \
  "$vnet_name" "$integration_subnet_name" "$private_endpoint_subnet_name"
printf 'Private endpoint: %s; private DNS zone: %s; VNet link: %s; zone group: %s\n' \
  "$private_endpoint_name" "$private_dns_zone_name" "$vnet_link_name" "$private_dns_zone_group_name"
if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'JSON parameter file supplied; proceeding without interactive prompts.\n'
else
  printf 'Proceed with deployment? [y/N]: '
  IFS= read -r confirmation || confirmation=''
  [[ "$confirmation" == 'y' || "$confirmation" == 'Y' ]] || {
    printf 'Deployment cancelled. No resources were created.\n'
    exit 0
  }
fi

printf '\nCOMMAND: az group create --name %s --location %s --output jsonc\n' "$resource_group_name" "$location"
az group create \
  --name "$resource_group_name" \
  --location "$location" \
  --output jsonc

printf '\nCOMMAND: az deployment group create --resource-group %q --template-file %q' \
  "$resource_group_name" "$TEMPLATE_FILE"
printf ' %q' "${deployment_parameters[@]}"
printf ' --output jsonc\n'
az deployment group create \
  --resource-group "$resource_group_name" \
  --template-file "$TEMPLATE_FILE" \
  "${deployment_parameters[@]}" \
  --output jsonc

printf '\nDeployment finished. Verify private DNS and HTTPS from an intended private client.\n'
printf 'The web app is private-only (public network access disabled) from initial provisioning.\n'
