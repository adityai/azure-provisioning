# Private Key Vault deployment

This folder contains a Bicep template and Bash/Azure CLI workflow for a Standard Key Vault with public network access disabled, Azure RBAC authorization, purge protection, soft delete, a private endpoint, and a linked `privatelink.vaultcore.azure.net` zone. The template creates no secrets and takes no secret values.

## Requirements

- Bash, Python 3, and Azure CLI with Bicep support
- Azure permissions to create resource groups, Key Vault, networking, private DNS, and deployments
- A selected Azure subscription and a supported Azure region

## Preview and deployment

From this directory:

```bash
./deploy.sh --mock
./deploy.sh
```

By default, every `*.json` file in `../input/keyvault/` is auto-discovered and processed independently without prompts. The included [weather example](../input/keyvault/rg-weather-keyvault-01.json) is a Bicep parameters JSON file. Resource group name comes from `metadata.resourceGroupName`, or from the file name if that metadata is absent. JSON files must contain exactly the template's parameters and must not contain credentials, secret values, or extra parameters.

To prompt instead of discovering JSON files, use `./deploy.sh --interactive`. Prompts require values; `--use-defaults` accepts the examples. To process one parameter file explicitly, use `./deploy.sh --parameters-file ../input/keyvault/rg-weather-keyvault-01.json`. Combine with `--mock` to preview. Live deployment builds Bicep, shows the active subscription and configuration, then requires typing the resource-group name to confirm.

Mock mode validates inputs and runs `az bicep build` if Azure CLI/Bicep is installed, otherwise it reports that compilation was skipped. It never runs deployment commands. Each run appends a transcript to `<resource-group>.log` in the current working directory. The transcript contains deployment inputs and command output, never secret values.

## Access, network, and lifecycle

The vault uses Azure RBAC rather than access policies. Assign the consuming identity the minimum required Key Vault **data-plane** role, such as Key Vault Secrets User for read-only secret access, at the narrowest suitable scope. No identity or role assignment is assumed by this template. Public access is disabled; clients require private routing and DNS through the linked VNet. Other client VNets need their own zone link or an appropriately managed DNS forwarding design.

Soft delete is enabled for 7–90 days (90 in the example), and purge protection is enabled. Purge protection cannot be disabled after creation; deleted vaults and objects can remain recoverable during retention. Add secret material only through a separately authorized, secure process after deployment.

## Tests and Bicep validation

```bash
python3 -m unittest discover -s tests -v
az bicep build --file main.bicep --stdout
```

## Cleanup

`./cleanup.sh --mock` prints the intended workflow. To delete resources, run `./cleanup.sh`; it inventories resource IDs before deletion, requires typing the group name, waits for deletion, and verifies/deletes surviving inventoried resources. Specify another group or subscription with `--resource-group NAME` or `--subscription ID`. Purge protection and soft-delete retention mean the vault or deleted objects may remain recoverable after the resource group is deleted.

No Azure deployment is performed by tests or documentation commands above.
