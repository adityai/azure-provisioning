# Azure Files deployment

Deploy a private-only StorageV2 account, an SMB file share with a configurable quota, a file private endpoint, and the linked `privatelink.file.<storage-suffix>` zone. The template derives the zone from the active Azure cloud's storage suffix. The script supports automatic JSON discovery, explicit parameter files, interactive prompts, per-resource-group logs, and mock mode. Tests do not deploy resources.

## Requirements

- Bash, Azure CLI with Bicep support, and Python 3
- An Azure identity authorized to create resource groups, storage, networking, private DNS, and deployments
- Client private routing, DNS, and SMB over TCP port 445 permitted before mounting the share

Run `az login` and select the intended subscription before deployment. Review the globally unique storage account name and VNet address ranges before using the example.

## Deploy and mock

From this directory:

```bash
./deploy.sh --mock
./deploy.sh
```

By default, every `*.json` file in `input/fileshare/` is deployed independently without prompts. Each JSON parameter file uses `metadata.resourceGroupName` or its filename stem as the resource-group name. To bypass discovery and answer prompts, use `--interactive`; blank answers are rejected unless `--use-defaults` is explicitly supplied. To select one parameter file directly:

```bash
./deploy.sh --parameters-file ../input/fileshare/rg-weather-fileshare-01.json
```

Mock mode validates inputs and attempts Bicep compilation when Azure CLI/Bicep is installed; it never creates Azure resources or runs deployment commands. Each input run records a transcript in `<resource-group-name>.log` in the current working directory. Parameter JSON files contain configuration only—never put credentials or access keys in them.

Storage account names must be globally unique and contain 3–24 lowercase letters or digits. File share names must be 3–63 lowercase letters/digits with only single hyphens between alphanumeric characters. Share quota is 1–5120 GiB. Review address-space overlap before deploying.

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

SMB clients must resolve the account's standard `*.file.core.windows.net` hostname through private DNS, have private routing to the endpoint, and permit SMB over TCP port 445. Use Microsoft Entra ID-based SMB authentication where configured; if account-key authentication is required, secure keys outside this repository.
