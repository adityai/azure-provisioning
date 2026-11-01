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

Deploy a Linux Azure Function App on an Elastic Premium plan with private
ingress, regional VNet integration, and private Storage endpoints.
JSON files in input/functionapp are processed as parameter files by default.

Options:
  --mock                 Compile and preview without Azure deployment calls.
  --use-defaults         Accept displayed example defaults in interactive mode.
  --interactive          Prompt instead of discovering input/functionapp JSON files.
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
    --mock) MOCK_MODE=true ;;
    --parameters-file)
      (($# >= 2)) || fail '--parameters-file requires a path.'
      PARAMETERS_FILE="$2"
      shift
      ;;
    --use-defaults) USE_DEFAULTS=true ;;
    --interactive) INTERACTIVE_MODE=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

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

prompt_resource_name() {
  local label="$1"
  local default_value="$2"
  local max_length="$3"
  local name
  while true; do
    prompt_value "$label" "$default_value"
    name="$REPLY"
    if ((${#name} <= max_length)) && [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      REPLY="$name"
      return
    fi
    printf 'Invalid name. Use 1-%s letters, numbers, dots, underscores, or hyphens; start with a letter or number.\n' "$max_length" >&2
  done
}

prompt_region() {
  while true; do
    prompt_value 'Azure region' 'eastus'
    if [[ "$REPLY" =~ ^[a-z0-9-]+$ ]]; then return; fi
    printf 'Enter a region such as eastus or centralus.\n' >&2
  done
}

prompt_global_name() {
  local label="$1"
  local default_value="$2"
  local kind="$3"
  local name
  while true; do
    prompt_value "$label" "$default_value"
    name="$REPLY"
    if [[ "$kind" == function ]]; then
      if ((${#name} >= 2 && ${#name} <= 60)) && [[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        REPLY="$name"
        return
      fi
      printf 'Use 2-60 lowercase letters, numbers, or hyphens; do not start or end with a hyphen.\n' >&2
    elif ((${#name} >= 3 && ${#name} <= 24)) && [[ "$name" =~ ^[a-z0-9]+$ ]]; then
      REPLY="$name"
      return
    else
      printf 'Storage account names must be 3-24 lowercase letters and numbers.\n' >&2
    fi
  done
}

prompt_sku_token() {
  local label="$1"
  local default_value="$2"
  while true; do
    prompt_value "$label" "$default_value"
    if [[ "$REPLY" =~ ^[A-Za-z0-9._-]+$ ]]; then return; fi
    printf 'Use letters, numbers, dots, underscores, or hyphens only.\n' >&2
  done
}

prompt_capacity() {
  while true; do
    prompt_value 'Elastic Premium plan instance capacity' '1'
    if [[ "$REPLY" =~ ^[1-9][0-9]*$ ]]; then return; fi
    printf 'Capacity must be a positive integer.\n' >&2
  done
}

if [[ -z "$PARAMETERS_FILE" && "$INTERACTIVE_MODE" != true ]]; then
  shopt -s nullglob
  parameter_files=("$REPO_ROOT"/input/functionapp/*.json)
  shopt -u nullglob
  if ((${#parameter_files[@]} > 0)); then
    failures=0
    printf 'Found %s input/functionapp JSON file(s); using each as a deployment parameter file.\n' "${#parameter_files[@]}"
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
    ((failures == 0)) || fail "$failures of ${#parameter_files[@]} JSON deployment(s) failed."
    exit 0
  fi
fi

if [[ -n "$PARAMETERS_FILE" ]]; then
  [[ -f "$PARAMETERS_FILE" ]] || fail "Parameter file not found: $PARAMETERS_FILE"
  command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required to read Bicep parameter files.'
  parsed_parameters="$(python3 - "$PARAMETERS_FILE" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
names = [
    "location", "vnetName", "integrationSubnetName", "privateEndpointSubnetName",
    "planName", "storageAccountName", "functionAppName", "runtimeStack",
    "privateDnsZoneName", "vnetLinkName", "privateEndpointName",
    "privateDnsZoneGroupName", "skuName", "skuTier", "skuSize", "skuFamily",
    "skuCapacity",
]
try:
    document = json.loads(path.read_text())
    values = document["parameters"]
    resolved = {name: values[name]["value"] for name in names}
except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
    print(f"Invalid parameter file {path}: {error}", file=sys.stderr)
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
if resolved["runtimeStack"] not in ("Python|3.11", "Python|3.12"):
    print(f"Parameter file {path}: runtimeStack must be Python|3.11 or Python|3.12.", file=sys.stderr)
    raise SystemExit(1)
if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", resolved["functionAppName"]):
    print(f"Parameter file {path}: functionAppName must use lowercase letters, numbers, and internal hyphens.", file=sys.stderr)
    raise SystemExit(1)
if not re.fullmatch(r"[a-z0-9]{3,24}", resolved["storageAccountName"]):
    print(f"Parameter file {path}: storageAccountName must use 3-24 lowercase letters and numbers.", file=sys.stderr)
    raise SystemExit(1)
if resolved["privateDnsZoneName"] != "privatelink.azurewebsites.net":
    print(f"Parameter file {path}: privateDnsZoneName must be privatelink.azurewebsites.net.", file=sys.stderr)
    raise SystemExit(1)
if (resolved["skuName"], resolved["skuTier"], resolved["skuSize"], resolved["skuFamily"]) not in (
    ("EP1", "ElasticPremium", "EP1", "EP"),
    ("EP2", "ElasticPremium", "EP2", "EP"),
    ("EP3", "ElasticPremium", "EP3", "EP"),
):
    print(f"Parameter file {path}: choose a matching EP1, EP2, or EP3 Elastic Premium SKU.", file=sys.stderr)
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
  while IFS= read -r parameter_value; do parameter_values+=("$parameter_value"); done <<< "$parsed_parameters"
  ((${#parameter_values[@]} == 18)) || fail "Unexpected parameter count in $PARAMETERS_FILE."
  resource_group_name="${parameter_values[0]}"
  location="${parameter_values[1]}"
  vnet_name="${parameter_values[2]}"
  integration_subnet_name="${parameter_values[3]}"
  private_endpoint_subnet_name="${parameter_values[4]}"
  plan_name="${parameter_values[5]}"
  storage_account_name="${parameter_values[6]}"
  function_app_name="${parameter_values[7]}"
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
  prompt_resource_name 'Resource group name' 'rg-weather-function-01' 90
  resource_group_name="$REPLY"
fi

[[ "$resource_group_name" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail "Invalid resource group name: $resource_group_name"
LOG_FILE="$PWD/${resource_group_name}.log"
touch "$LOG_FILE" || fail "Could not create deployment log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== Function App deployment run =====\n'
printf 'Function App deployment log\nStarted: %s\nLog file: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_FILE"

if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'INPUT Parameter file=%s\n' "$PARAMETERS_FILE"
  printf 'INPUT Resource group name=%s\n' "$resource_group_name"
  printf 'INPUT Azure region=%s\n' "$location"
  printf 'INPUT Virtual network name=%s\n' "$vnet_name"
  printf 'INPUT VNet integration subnet name=%s\n' "$integration_subnet_name"
  printf 'INPUT Private endpoint subnet name=%s\n' "$private_endpoint_subnet_name"
  printf 'INPUT Function App plan name=%s\n' "$plan_name"
  printf 'INPUT Storage account name=%s\n' "$storage_account_name"
  printf 'INPUT Function App name=%s\n' "$function_app_name"
  printf 'INPUT Functions runtime stack=%s\n' "$runtime_stack"
  printf 'INPUT Private DNS zone name=%s\n' "$private_dns_zone_name"
  printf 'INPUT Private DNS VNet link name=%s\n' "$vnet_link_name"
  printf 'INPUT Function App private endpoint name=%s\n' "$private_endpoint_name"
  printf 'INPUT Private DNS zone group name=%s\n' "$private_dns_zone_group_name"
else
  printf 'INPUT Resource group name=%s\n' "$resource_group_name"
  prompt_region; location="$REPLY"
  prompt_resource_name 'Virtual network name' 'vnet-weather-function-01' 64; vnet_name="$REPLY"
  prompt_resource_name 'VNet integration subnet name' 'snet-function-integration' 80; integration_subnet_name="$REPLY"
  prompt_resource_name 'Private endpoint subnet name' 'snet-function-private-endpoint' 80; private_endpoint_subnet_name="$REPLY"
  prompt_resource_name 'Function App plan name' 'ep-function-01' 40; plan_name="$REPLY"
  prompt_global_name 'Storage account name (globally unique)' 'stweatherfunc01' storage; storage_account_name="$REPLY"
  prompt_global_name 'Function App name (globally unique)' 'func-weather-01' function; function_app_name="$REPLY"
  prompt_value 'Functions runtime stack (Python|3.11 or Python|3.12)' 'Python|3.12'
  runtime_stack="$REPLY"
  [[ "$runtime_stack" == 'Python|3.11' || "$runtime_stack" == 'Python|3.12' ]] || fail 'Runtime stack must be Python|3.11 or Python|3.12.'
  prompt_value 'Private DNS zone name (required)' 'privatelink.azurewebsites.net'
  private_dns_zone_name="$REPLY"
  [[ "$private_dns_zone_name" == 'privatelink.azurewebsites.net' ]] || fail 'The Function App private DNS zone must be privatelink.azurewebsites.net.'
  prompt_resource_name 'Private DNS VNet link name' 'link-function-vnet' 80; vnet_link_name="$REPLY"
  prompt_resource_name 'Function App private endpoint name' 'pep-function-01' 60; private_endpoint_name="$REPLY"
  prompt_resource_name 'Private DNS zone group name' 'default' 80; private_dns_zone_group_name="$REPLY"
  prompt_sku_token 'Elastic Premium SKU name (suggestions: EP1, EP2, EP3)' 'EP1'; sku_name="$REPLY"
  prompt_sku_token 'Elastic Premium SKU tier' 'ElasticPremium'; sku_tier="$REPLY"
  prompt_sku_token 'Elastic Premium SKU size (usually matches SKU name; examples: EP1, EP2, EP3)' "$sku_name"; sku_size="$REPLY"
  prompt_sku_token 'Elastic Premium SKU family' 'EP'; sku_family="$REPLY"
  prompt_capacity; sku_capacity="$REPLY"
  deployment_parameters=(
    --parameters "location=$location" "vnetName=$vnet_name"
    "integrationSubnetName=$integration_subnet_name"
    "privateEndpointSubnetName=$private_endpoint_subnet_name"
    "planName=$plan_name" "storageAccountName=$storage_account_name"
    "functionAppName=$function_app_name" "runtimeStack=$runtime_stack"
    "privateDnsZoneName=$private_dns_zone_name" "vnetLinkName=$vnet_link_name"
    "privateEndpointName=$private_endpoint_name"
    "privateDnsZoneGroupName=$private_dns_zone_group_name"
    "skuName=$sku_name" "skuTier=$sku_tier" "skuSize=$sku_size"
    "skuFamily=$sku_family" "skuCapacity=$sku_capacity"
  )
fi

case "$sku_name" in
  EP1|EP2|EP3) ;;
  *) fail 'Elastic Premium SKU name must be EP1, EP2, or EP3.' ;;
esac
[[ "$sku_tier" == ElasticPremium && "$sku_size" == "$sku_name" && "$sku_family" == EP ]] ||
  fail 'Use a matching Elastic Premium SKU name and size (EP1, EP2, or EP3), tier ElasticPremium, and family EP.'

run_bicep_build() {
  printf '\nCOMMAND: az bicep build --file %s --stdout\n' "$TEMPLATE_FILE"
  if az bicep build --file "$TEMPLATE_FILE" --stdout >>"$LOG_FILE" 2>&1; then
    printf 'Bicep compilation succeeded; full compiler output is recorded in this log.\n'
  else
    local status=$?
    printf 'Bicep compilation failed with exit code %s. See compiler output in this log.\n' "$status"
    return "$status"
  fi
}

show_resolved_inputs() {
  printf '\nResolved deployment inputs:\n'
  printf 'Resource group: %s (%s)\n' "$resource_group_name" "$location"
  printf 'Function App: %s (Linux, public network access disabled)\n' "$function_app_name"
  printf 'Runtime: Functions v4, %s\n' "$runtime_stack"
  printf 'Plan: %s (SKU %s, tier %s, size %s, family %s, capacity %s)\n' \
    "$plan_name" "$sku_name" "$sku_tier" "$sku_size" "$sku_family" "$sku_capacity"
  printf 'Storage: %s (public network access disabled; blob, file, queue, and table private endpoints)\n' "$storage_account_name"
  printf 'VNet: %s; integration subnet: %s; private endpoint subnet: %s\n' \
    "$vnet_name" "$integration_subnet_name" "$private_endpoint_subnet_name"
  printf 'Function private endpoint: %s; DNS zone: %s\n' "$private_endpoint_name" "$private_dns_zone_name"
}

if [[ "$MOCK_MODE" == true ]]; then
  if command -v az >/dev/null 2>&1; then
    run_bicep_build || fail 'Bicep compilation failed; mock deployment stopped.'
  else
    printf '\nBicep compilation skipped: Azure CLI/Bicep compiler is unavailable.\n'
  fi
  printf '\nMOCK MODE: no Azure deployment commands were run and no resources were created.\n'
  show_resolved_inputs
  printf 'Would deploy: az deployment group create --resource-group %q --template-file %q' "$resource_group_name" "$TEMPLATE_FILE"
  printf ' %q' "${deployment_parameters[@]}"
  printf '\n'
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required. Install it and sign in with az login.'
[[ -f "$TEMPLATE_FILE" ]] || fail "Bicep template not found: $TEMPLATE_FILE"
run_bicep_build || fail 'Bicep compilation failed; deployment stopped.'
printf '\nCOMMAND: az account show --query '\''[name, id]'\'' --output tsv\n'
subscription_details="$(az account show --query '[name, id]' --output tsv)" || fail 'Azure CLI is not signed in. Run az login.'
[[ -n "$subscription_details" ]] || fail 'Could not determine the active Azure subscription.'
printf '\nActive Azure subscription (name, ID): %s\n' "$subscription_details"
show_resolved_inputs
if [[ -n "$PARAMETERS_FILE" ]]; then
  printf 'JSON parameter file supplied; proceeding without interactive prompts.\n'
else
  printf '\nProceed with deployment? [y/N]: '
  IFS= read -r confirmation || confirmation=''
  [[ "$confirmation" == y || "$confirmation" == Y ]] || {
    printf 'Deployment cancelled. No resources were created.\n'
    exit 0
  }
fi

printf '\nCOMMAND: az group create --name %s --location %s --output jsonc\n' "$resource_group_name" "$location"
az group create --name "$resource_group_name" --location "$location" --output jsonc
printf '\nCOMMAND: az deployment group create --resource-group %q --template-file %q' "$resource_group_name" "$TEMPLATE_FILE"
printf ' %q' "${deployment_parameters[@]}"
printf ' --output jsonc\n'
az deployment group create --resource-group "$resource_group_name" --template-file "$TEMPLATE_FILE" \
  "${deployment_parameters[@]}" --output jsonc
printf '\nDeployment finished. Validate Function App and Storage DNS from the intended private network.\n'
