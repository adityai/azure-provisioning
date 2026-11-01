# Azure App Service private networking deployment

This repository contains a reusable Bicep template and Bash/Azure CLI scripts for deploying an Azure App Service with regional VNet integration and private inbound connectivity. The template supports Linux and Windows apps, a user-specified runtime stack and App Service plan SKU, a separate private-endpoint subnet, and the `privatelink.azurewebsites.net` private DNS zone.

The web app is configured with HTTPS-only access and public network access disabled. The deployment provisions infrastructure, but does not publish application code. Start with the [infrastructure plan](rg-appservice-01/infrastructure-plan.md) and [deployment guide](rg-appservice-01/README.md).

## Repository contents

- [main.bicep](rg-appservice-01/main.bicep) — reusable App Service and private networking template.
- [deploy.sh](rg-appservice-01/deploy.sh) — prompts for configuration, or consumes JSON parameter files from the repository root.
- [cleanup.sh](rg-appservice-01/cleanup.sh) — deletes a resource group, checks pre-delete resource IDs for survivors, and attempts individual cleanup.
- [tests](rg-appservice-01/tests/test_deploy.py) — unit and mock Azure CLI tests.
- `rg-*.json` — Bicep deployment parameter examples. Every root-level JSON file is treated as a deployment input by `deploy.sh`.

## Prerequisites

- Bash
- Azure CLI (`az`)
- Bicep CLI (`az bicep install`)
- Python 3 (tests and parsing deployment parameter files)
- VS Code (optional, for the Azure MCP server configuration)

Install Bicep if needed:

```bash
az bicep install
```

Sign in and select the intended subscription before deploying:

```bash
az login
az account set --subscription "<subscription-id>"
```

## Configure Azure MCP in VS Code

Create `.vscode/mcp.json` in the repository root. Set `AZURE_TENANT_ID` to your Entra tenant ID:

```json
{
  "servers": {
    "Azure MCP server": {
      "command": "npx",
      "args": ["-y", "@azure/mcp@latest", "server", "start"],
      "env": {
        "AZURE_TENANT_ID": "<your-tenant-id>",
        "AZURE_TOKEN_CREDENTIALS": "AzureCliCredential"
      }
    }
  }
}
```

Authenticate with Azure CLI as above, then start or reload the MCP server through VS Code. The `.vscode` directory is git-ignored; keep local configuration out of commits.

### Ask GitHub Copilot in VS Code

Open the repository in VS Code, choose GitHub Copilot Chat in **Agent** mode, and make sure the Azure MCP server is connected. The prompts below are examples; replace the resource group, subscription, and other values for your environment.

#### Mock deployment (no Azure resources)

To run the repository's mock script and validate the parameter files without deploying:

```text
Run a mock App Service deployment for every root-level JSON parameter file.
Use ./rg-appservice-01/deploy.sh --mock. Do not call Azure deployment or
resource-creation tools. Show me the result and the generated
<resource-group-name>.log files.
```

For an interactive mock when no root-level JSON files are present:

```text
Run ./rg-appservice-01/deploy.sh --mock interactively. Ask me for each input
instead of accepting defaults. Do not make any Azure changes.
```

The local mock compiles Bicep when Azure CLI/Bicep is installed; it does not provision resources. **Do not ask Copilot to use Azure MCP resource-creation tools for a mock**—those tools can make real Azure changes.

#### Real deployment using Azure MCP

For a real deployment, ask Copilot to use the connected Azure MCP server and make the provisioning intent explicit:

```text
Deploy the App Service architecture from rg-appservice-01/main.bicep using
the connected Azure MCP server, not a local mock. Target subscription
<subscription-id> and resource group <resource-group-name> in <region>.
Use parameter file <path-to-parameters-json> (or ask me for each required
parameter if no file is supplied). First inspect and summarize every planned
resource and input, validate the Bicep/template and target subscription, and
show me the changes. Do not create or modify anything until I explicitly
confirm. After confirmation, deploy and report the operation result and
resource IDs.
```

The Azure MCP server may expose different deployment capabilities depending on its version and connected tools. If it cannot deploy this Bicep template directly, ask Copilot to state that limitation and stop; do not silently substitute another deployment path. Real deployments create billable resources. The repository script's root-level JSON mode also deploys every root-level JSON file without prompting for values or confirmation, so review those files before using it.

## Run tests

From the repository root:

```bash
python3 -m unittest discover -s rg-appservice-01/tests -v
```

The tests mock Azure CLI and do not create Azure resources.

## Deployment input options

### Interactive prompts

If there are **no root-level JSON files**, the deploy script requires you to enter each value:

```bash
./rg-appservice-01/deploy.sh
```

Prompts do not show or silently use defaults; blank input is rejected. To explicitly accept the example defaults, pass `--use-defaults`:

```bash
./rg-appservice-01/deploy.sh --use-defaults
```

In this mode, each prompt displays an example in brackets. Press Enter to accept it, or type another value. The example defaults are:

| Input | Default |
|---|---|
| Resource group | `rg-appservice-01` |
| Region | `eastus` |
| VNet | `vnet-appservice-01` |
| VNet integration subnet | `snet-appservice-integration` |
| Private endpoint subnet | `snet-appservice-private-endpoint` |
| App Service plan | `asp-appservice-01` |
| Operating system | `Linux` |
| Web app name | `app-mcp-test-01` |
| Runtime stack | Linux: `NODE\|20-lts`; Windows: `DOTNET\|8.0` |
| Private DNS zone | `privatelink.azurewebsites.net` (required) |
| Private DNS VNet link | `link-appservice-vnet` |
| Private endpoint | `pep-appservice-01` |
| Private DNS zone group | `default` |
| SKU name / tier / size / family | `S1` / `Standard` / `S1` / `S` |
| SKU capacity | `1` |

You can override any displayed default at its prompt. The app name must be globally unique. SKU fields must be a valid combination available in the selected region. Review the resolved values and active subscription; interactive deployment requires an explicit confirmation.

### JSON parameter files

If one or more `*.json` files are present **at the repository root**, the script processes every one as a Bicep parameter file, without prompting or using interactive defaults:

```bash
./rg-appservice-01/deploy.sh
```

This is a live deployment unless `--mock` is specified. JSON-driven deployments do not require an interactive confirmation. Keep only intended deployment parameter files at the root before running the live command: unrelated JSON files will also be treated as deployment inputs. Each file must use ARM/Bicep parameters format and include all template parameters. Its resource group name is read from `metadata.resourceGroupName`, or falls back to the JSON filename without the `.json` extension.

To select one file explicitly (and ignore root-level auto-discovery):

```bash
./rg-appservice-01/deploy.sh --parameters-file ./rg-weather-service-01.json
```

An example parameter file is [rg-weather-service-01.json](rg-weather-service-01.json).

### Mock deployment

Use mock mode to validate input and compile Bicep when Azure CLI/Bicep is installed, without running Azure deployment commands:

```bash
./rg-appservice-01/deploy.sh --mock
```

With root-level JSON files, mock mode processes each file without prompting. Without root-level JSON files, it requires values at interactive prompts. Use `--use-defaults` only when you want to accept example values. For a single JSON file:

```bash
./rg-appservice-01/deploy.sh --mock --parameters-file ./rg-weather-service-01.json
```

To run an interactive mock using example defaults:

```bash
./rg-appservice-01/deploy.sh --mock --use-defaults
```

Mock runs write a log named `<resource-group-name>.log` in the current working directory. Real deployment logs include entered inputs, Bicep build output, and Azure CLI command output.

## Cleanup

To remove a resource group and check for resources that survived its deletion:

```bash
./rg-appservice-01/cleanup.sh --resource-group "<resource-group-name>" --subscription "<subscription-id>"
```

The cleanup script inventories resources before deletion, requires typing the resource group name to confirm, waits for group deletion, and checks whether those saved resource IDs remain. Any survivors are individually deleted and checked again. It cannot discover resources orphaned before the initial inventory or billable service-specific soft-deleted data. Use its mock option to preview the workflow without Azure calls:

```bash
./rg-appservice-01/cleanup.sh --mock --resource-group "<resource-group-name>"
```
