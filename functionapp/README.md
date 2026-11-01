# Function App deployment

This directory contains a Bicep template and Bash scripts for deploying a Linux Azure Function App on Elastic Premium with private ingress, regional VNet integration, and private Storage service endpoints.

## Requirements

- Bash, Azure CLI with Bicep, and Python 3
- An Azure subscription and permissions to create resource groups, App Service plans, Function Apps, Storage accounts, private endpoints, private DNS zones, and VNet resources

Sign in and select the intended subscription:

```bash
az login
az account set --subscription "<subscription-id>"
```

## Mock deployment

The supplied parameter file is discovered automatically. This mock compiles the template when Azure CLI/Bicep is installed but does not deploy resources:

```bash
./functionapp/deploy.sh --mock
```

For interactive prompts rather than parameter-file discovery:

```bash
./functionapp/deploy.sh --mock --interactive
```

Prompts require values; `--use-defaults` explicitly accepts the displayed examples. The default hosting SKU is EP1 / ElasticPremium and the default runtime is Python 3.12. SKU suggestions are EP1, EP2, and EP3; confirm regional availability and capacity before deployment.

## Deploy

```bash
./functionapp/deploy.sh
```

Every `*.json` under `input/functionapp/` is treated as a Bicep parameter file and deployed separately without prompts or confirmation. Review those files before running a live deployment. To bypass discovery and prompt, pass `--interactive`; to deploy one specific file, use:

```bash
./functionapp/deploy.sh --parameters-file ./input/functionapp/rg-weather-function-01.json
```

Each run writes `<resource-group-name>.log` to the current directory. The infrastructure does not upload Function App code or define triggers.

## Cleanup

The cleanup script inventories resources before deletion, requires typing the resource group name, waits for deletion, and checks for surviving resource IDs:

```bash
./functionapp/cleanup.sh --mock
./functionapp/cleanup.sh --resource-group rg-weather-function-01 --subscription "<subscription-id>"
```

## Tests

```bash
python3 -m unittest discover -s functionapp/tests -v
```
