# Copilot instructions: azure-provisioning

This repo provisions Azure services with private networking using Bicep and Bash/Azure CLI scripts. Services: appservice, functionapp, blobstorage, fileshare, sqldb, cosmosdb, keyvault.

## Repository layout
- `<service>/` holds the infrastructure plan, `main.bicep`, `deploy.sh`, `cleanup.sh`, `tests/`, and service docs.
- `input/<service>/` holds Bicep parameter JSON files (ARM parameter format). `deploy.sh` treats EVERY `*.json` in the matching folder as a live deployment input.
- `.vscode/mcp.json` is git-ignored and local. Never commit tenant IDs, subscription IDs, or secrets.

## Safety rules (always apply)
1. Never create, modify, or delete Azure resources without my explicit confirmation in the current chat. Summarize the planned resources, subscription, resource group, and region first.
2. Run `--mock` first for any deploy or cleanup script. Mock mode makes no Azure deployment calls.
3. Before a live run of `deploy.sh`, list the files in `input/<service>/`. Prefer `--parameters-file <one file>` over auto-discovery.
4. Never put passwords or secrets in JSON files, scripts, logs, or commits. SQL admin passwords are prompted at runtime only.
5. For deletion, use the service's `cleanup.sh`. Do not use ad hoc delete commands unless I ask.
6. If the Azure MCP server cannot do something, say so and stop. Do not silently switch to another deployment path.

## Bicep conventions
- Keep public network access disabled, HTTPS-only, and use private endpoints with a private DNS zone, VNet link, and DNS zone group.
- Use separate subnets for private endpoints and for VNet integration.
- Parameterize names, region, SKUs, and address spaces. Avoid hardcoded values.
- Validate with `az bicep build` and, when authorized, `az deployment group what-if`.
- Call the Azure MCP best-practices tool before writing new Bicep when available.

## Scripts and tests
- Bash scripts should use `set -euo pipefail` and quote variables.
- After any change to Bicep or scripts, run the matching tests:
  `python3 -m unittest discover -s <service>/tests -v`
- Tests mock Azure CLI and create no resources.

## When adding a new service
Create `<service>/` (plan, `main.bicep`, `deploy.sh`, `cleanup.sh`, `tests/`, README) and `input/<service>/` with one sample parameter file, mirroring an existing service such as keyvault.

## Before finishing a change
Report which tests ran, which mock commands ran, and confirm that no live Azure operation was performed unless I approved it.
