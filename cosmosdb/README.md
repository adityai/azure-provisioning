# Private Cosmos DB deployment

This folder contains a Bicep template and Bash/Azure CLI workflow for a private Azure Cosmos DB for NoSQL account with serverless SQL database/container resources. The template creates a VNet and dedicated private-endpoint subnet, disables public network access and key-based local authentication, creates a private endpoint, and links `privatelink.documents.azure.com` to the VNet.

## Requirements

- Bash, Python 3, and Azure CLI with Bicep support
- Azure permissions to create resource groups, Cosmos DB, networking, private DNS, and deployments
- A selected Azure subscription and a region that supports Cosmos DB serverless

## Preview and deployment

From this directory:

```bash
./deploy.sh --mock
./deploy.sh
```

By default, every `*.json` file in `../input/cosmosdb/` is auto-discovered and processed independently, without interactive prompts. The included [weather example](../input/cosmosdb/rg-weather-cosmosdb-01.json) is a Bicep parameters JSON file. Its resource group is read from `metadata.resourceGroupName`, or from the file name if that metadata is absent. JSON files must contain exactly the Bicep template's parameters and must not contain credentials or extra values.

To prompt instead of discovering JSON files, run `./deploy.sh --interactive`. Prompts require values; `--use-defaults` accepts the displayed examples. To deploy a specific file, use `./deploy.sh --parameters-file ../input/cosmosdb/rg-weather-cosmosdb-01.json`. Combine with `--mock` to preview. A live deployment builds the Bicep template, displays the active subscription and configuration, and requires typing the resource-group name to confirm.

Mock mode validates inputs and runs `az bicep build` if Azure CLI/Bicep is installed; otherwise it reports that compilation was skipped. It never runs deployment commands. Each run appends a transcript to `<resource-group>.log` in the current working directory. Inputs contain no keys or secret values.

## Access and network notes

The template disables local/key authentication as well as public access. Assign an appropriate Cosmos DB **data-plane RBAC** role (for example, Built-in Data Reader or Data Contributor) to the consuming Microsoft Entra identity at the narrowest appropriate scope. An Azure management-plane role alone does not grant data access. This deployment intentionally creates no identity or role assignment. Clients need private routing and DNS via the linked VNet; additional VNets need an additional private DNS link or a suitable DNS forwarding design.

The SQL container's partition-key path is configurable, with `/weatherStationId` as the example. Choose a partition key based on the application's access patterns and expected distribution. The database and container are serverless and do not request provisioned throughput. Confirm serverless availability, limits, and cost for the selected region and workload.

## Tests and Bicep validation

```bash
python3 -m unittest discover -s tests -v
az bicep build --file main.bicep --stdout
```

## Cleanup

`./cleanup.sh --mock` prints the intended workflow. To delete resources, run `./cleanup.sh`; it inventories resource IDs before deletion, requires typing the group name, waits for deletion, and verifies/deletes surviving inventoried resources. Specify another group or subscription with `--resource-group NAME` or `--subscription ID`.

No Azure deployment is performed by tests or documentation commands above.
