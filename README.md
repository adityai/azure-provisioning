# Azure private networking deployment templates

This repository contains reusable Bicep templates and Bash/Azure CLI scripts for deploying Azure services with private networking: App Service, Function App, Blob Storage, Azure Files, Azure SQL Database, Cosmos DB for NoSQL, and Key Vault.

The web app is configured with HTTPS-only access and public network access disabled. The deployment provisions infrastructure, but does not publish application code. Start with the [infrastructure plan](appservice/infrastructure-plan.md) and [deployment guide](appservice/README.md).

## Repository contents

- [main.bicep](appservice/main.bicep) — reusable App Service and private networking template.
- [deploy.sh](appservice/deploy.sh) — prompts for configuration, or consumes JSON parameter files from `input/appservice/`.
- [cleanup.sh](appservice/cleanup.sh) — deletes a resource group, checks pre-delete resource IDs for survivors, and attempts individual cleanup.
- [tests](appservice/tests/test_deploy.py) — unit and mock Azure CLI tests.
- [input/appservice/](input/appservice/) — Bicep deployment parameter files. Every JSON file in this directory is treated as a deployment input by `deploy.sh`.
- [functionapp/](functionapp/) — Linux Function App infrastructure plan, Bicep template, deployment/cleanup scripts, and tests for private networking.
- [input/functionapp/](input/functionapp/) — Function App Bicep deployment parameter files, auto-discovered by `functionapp/deploy.sh`.
- [blobstorage/](blobstorage/) and [input/blobstorage/](input/blobstorage/) — private Blob Storage account and container deployment.
- [fileshare/](fileshare/) and [input/fileshare/](input/fileshare/) — private Azure Files share deployment.
- [sqldb/](sqldb/) and [input/sqldb/](input/sqldb/) — private Azure SQL Database deployment.
- [cosmosdb/](cosmosdb/) and [input/cosmosdb/](input/cosmosdb/) — private Cosmos DB for NoSQL deployment.
- [keyvault/](keyvault/) and [input/keyvault/](input/keyvault/) — private, RBAC-enabled Key Vault deployment.
- [sqldb/](sqldb/) — the SQL deployment prompts for its administrator password only during live deployment; it is not stored in the sample JSON.

Each service directory contains an infrastructure plan, Bicep template, deployment and cleanup scripts, focused tests, and service-specific instructions. Each input directory contains a sample parameter file. Review parameter files before real deployments: the scripts automatically process every `*.json` in the matching input directory. Most services do not request confirmation in JSON mode; the SQL deployment additionally prompts securely for its administrator password. `--mock` validates and previews without Azure deployment calls; `--interactive` bypasses parameter-file discovery and prompts instead. Defaults are used only with `--use-defaults`.

Run a service's tests from the repository root, for example:

```bash
python3 -m unittest discover -s blobstorage/tests -v
python3 -m unittest discover -s fileshare/tests -v
python3 -m unittest discover -s sqldb/tests -v
python3 -m unittest discover -s cosmosdb/tests -v
python3 -m unittest discover -s keyvault/tests -v
```

## Function App deployment

The Function App template uses Linux Functions v4 on an Elastic Premium plan, a private endpoint for inbound traffic, and a private Storage account with Blob, File, Queue, and Table private endpoints.

Run a mock deployment (the parameter file is discovered automatically):

```bash
./functionapp/deploy.sh --mock
```

For interactive prompting instead of JSON discovery, use `--interactive`. Prompts require values; `--use-defaults` explicitly accepts the displayed examples. A live deployment processes every JSON file in `input/functionapp/` without prompting or confirmation, so review those files before deploying. See the [Function App deployment guide](functionapp/README.md) and [infrastructure plan](functionapp/infrastructure-plan.md).

Run its tests from the repository root:

```bash
python3 -m unittest discover -s functionapp/tests -v
```

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
Run a mock App Service deployment for every JSON parameter file in input/appservice/.
Use ./appservice/deploy.sh --mock. Do not call Azure deployment or
resource-creation tools. Show me the result and the generated
<resource-group-name>.log files.
```

For an interactive mock when no JSON files are present in input/appservice/:

```text
Run ./appservice/deploy.sh --mock --interactive. Ask me for each input
instead of accepting defaults. Do not make any Azure changes.
```

The local mock compiles Bicep when Azure CLI/Bicep is installed; it does not provision resources. **Do not ask Copilot to use Azure MCP resource-creation tools for a mock**—those tools can make real Azure changes.

#### Real deployment using Azure MCP

For a real deployment, ask Copilot to use the connected Azure MCP server and make the provisioning intent explicit:

```text
Deploy the App Service architecture from appservice/main.bicep using
the connected Azure MCP server, not a local mock. Target subscription
<subscription-id> and resource group <resource-group-name> in <region>.
Use parameter file <path-to-parameters-json> (or ask me for each required
parameter if no file is supplied). First inspect and summarize every planned
resource and input, validate the Bicep/template and target subscription, and
show me the changes. Do not create or modify anything until I explicitly
confirm. After confirmation, deploy and report the operation result and
resource IDs.
```

The Azure MCP server may expose different deployment capabilities depending on its version and connected tools. If it cannot deploy this Bicep template directly, ask Copilot to state that limitation and stop; do not silently substitute another deployment path. Real deployments create billable resources. The repository script deploys every JSON file in `input/appservice/` without prompting for values or confirmation, so review those files before using it.

## Run tests

From the repository root:

```bash
python3 -m unittest discover -s appservice/tests -v
```

The tests mock Azure CLI and do not create Azure resources.

## Deployment input options

### Interactive prompts

If there are **no JSON files in `input/appservice/`**, the deploy script requires you to enter each value:

```bash
./appservice/deploy.sh
```

Prompts do not show or silently use defaults; blank input is rejected. To explicitly accept the example defaults, pass `--use-defaults`. If JSON parameter files are present in `input/appservice/`, also pass `--interactive` to bypass their automatic processing:

```bash
./appservice/deploy.sh --interactive --use-defaults
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

If one or more `*.json` files are present in **`input/appservice/`**, the script processes every one as a Bicep parameter file, without prompting or using interactive defaults:

```bash
./appservice/deploy.sh
```

This is a live deployment unless `--mock` is specified. JSON-driven deployments do not require an interactive confirmation. Keep only intended deployment parameter files in `input/appservice/` before running the live command: every JSON file there is treated as a deployment input. Each file must use ARM/Bicep parameters format and include all template parameters. Its resource group name is read from `metadata.resourceGroupName`, or falls back to the JSON filename without the `.json` extension.

To select one file explicitly (and ignore automatic discovery):

```bash
./appservice/deploy.sh --parameters-file ./input/appservice/rg-weather-service-01.json
```

An example parameter file is [rg-weather-service-01.json](input/appservice/rg-weather-service-01.json).

### Mock deployment

Use mock mode to validate input and compile Bicep when Azure CLI/Bicep is installed, without running Azure deployment commands:

```bash
./appservice/deploy.sh --mock
```

With JSON files in `input/appservice/`, mock mode processes each file without prompting. Without parameter files, it requires values at interactive prompts. Use `--use-defaults` only when you want to accept example values. For a single JSON file:

```bash
./appservice/deploy.sh --mock --parameters-file ./input/appservice/rg-weather-service-01.json
```

To run an interactive mock using example defaults, bypassing any JSON files in `input/appservice/`:

```bash
./appservice/deploy.sh --mock --interactive --use-defaults
```

Mock runs write a log named `<resource-group-name>.log` in the current working directory. Real deployment logs include entered inputs, Bicep build output, and Azure CLI command output.

## Cleanup

To remove a resource group and check for resources that survived its deletion:

```bash
./appservice/cleanup.sh --resource-group "<resource-group-name>" --subscription "<subscription-id>"
```

The cleanup script inventories resources before deletion, requires typing the resource group name to confirm, waits for group deletion, and checks whether those saved resource IDs remain. Any survivors are individually deleted and checked again. It cannot discover resources orphaned before the initial inventory or billable service-specific soft-deleted data. Use its mock option to preview the workflow without Azure calls:

```bash
./appservice/cleanup.sh --mock --resource-group "<resource-group-name>"
```
