# Blob Storage deployment

Deploy a private-only StorageV2 account, a private blob container, a blob private endpoint, and the linked `privatelink.blob.<storage-suffix>` zone. The template derives the zone from the active Azure cloud's storage suffix. The script supports automatic JSON discovery, explicit parameter files, interactive prompts, per-resource-group logs, and mock mode. No deployment is performed by tests.

## Requirements

- Bash, Azure CLI with Bicep support, and Python 3
- An Azure identity authorized to create resource groups, storage, networking, private DNS, and deployments
- Private client routing and DNS configured for the VNet before accessing the account

Run `az login` and select the intended subscription before deployment. Review the globally unique storage account name and VNet address ranges before using the example.

## Deploy and mock

From this directory:

```bash
./deploy.sh --mock
./deploy.sh
```

By default, every `*.json` file in `input/blobstorage/` is deployed independently without prompts. Each JSON parameter file uses `metadata.resourceGroupName` or its filename stem as the resource-group name. To bypass discovery and answer prompts, use `--interactive`; blank answers are rejected unless `--use-defaults` is explicitly supplied. To select one parameter file directly:

```bash
./deploy.sh --parameters-file ../input/blobstorage/rg-weather-blobstorage-01.json
```

Mock mode validates inputs and attempts Bicep compilation when Azure CLI/Bicep is installed; it never creates Azure resources or runs deployment commands. Each input run records a transcript in `<resource-group-name>.log` in the current working directory. Parameter JSON files contain configuration only—never put credentials or access keys in them.

Storage account names must be globally unique and contain 3–24 lowercase letters or digits. Container names must be 3–63 lowercase letters/digits with only single hyphens between alphanumeric characters. Review address-space overlap before deploying.

## Tests

```bash
python3 -m unittest discover -s tests -v
bash -n deploy.sh cleanup.sh
```

## Cleanup

```bash
./cleanup.sh
./cleanup.sh --mock
```

Cleanup displays a pre-delete resource inventory and requires the exact resource-group name before deleting. It waits for the group deletion and checks captured resource IDs for survivors, deleting and verifying leftovers if necessary. Mock cleanup does not call Azure.

Private clients must resolve the account's standard `*.blob.core.windows.net` endpoint through private DNS and have network routing to the private endpoint. Use Microsoft Entra ID with least-privilege data roles where possible. If key-based access is required, manage keys securely outside this repository.
