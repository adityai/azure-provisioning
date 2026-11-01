# App Service deployment scripts

These files implement [the infrastructure plan](./infrastructure-plan.md) with a reusable Bicep template and an interactive Bash/Azure CLI wrapper. The same template can deploy Linux or Windows App Service apps, accepts a runtime stack and App Service plan SKU fields, and provisions regional VNet integration, a separate private-endpoint subnet, an App Service private endpoint, and the `privatelink.azurewebsites.net` private DNS zone and VNet link.

The app's public network access is disabled at creation. The deployment configures the selected runtime stack but does not upload or deploy application code. The private endpoint is expected to be approved automatically when the deploying identity has the required permissions; otherwise, approve its connection before testing.

## Requirements

- Bash
- Azure CLI with Bicep support
- Python 3 for the unit tests
- Azure permissions to create resource groups, networking resources, App Service plans/apps, private endpoints, and deployments

Sign in and select the intended subscription before deploying:

```bash
az login
az account set --subscription "<subscription-id>"
```

## Mock run

The mock mode validates the selected inputs, compiles the template when Azure CLI/Bicep is available, prints the deployments that would be used, and does not run Azure deployment commands:

```bash
./deploy.sh --mock
```

Without JSON files in `input/appservice/`, prompts require a value and do not silently accept defaults. Use `--use-defaults` to explicitly allow the displayed example defaults:

```bash
./deploy.sh --mock --use-defaults
```

You can choose Linux or Windows, provide the corresponding App Service runtime stack, and specify plan SKU name, tier, size, family, and instance capacity. The private DNS zone must remain `privatelink.azurewebsites.net`. The web app name must be globally unique. If JSON files exist in `input/appservice/`, mock mode uses each file as input without prompts and creates one log per resource group.

## Unit tests

From this directory, run:

```bash
python3 -m unittest discover -s tests -v
```

## Deploy

From this directory, run:

```bash
./deploy.sh
```

When no JSON files are present in `input/appservice/`, the wrapper prompts for the resource group, location, and the name of each resource. It also prompts for the app operating system and runtime, and for all App Service plan SKU fields: name, tier, size, family, and capacity. Prompts require a value and reject blank input. To explicitly accept the displayed example values, run `./deploy.sh --use-defaults`. The examples are Linux, `NODE|20-lts`, Standard S1, capacity 1; select values supported in the region and suited to your workload. For example, a Premium v3 plan commonly uses name/size `P1v3`, tier `PremiumV3`, and family `P`.

If one or more JSON files are present in `input/appservice/`, the script treats every JSON file there as a Bicep deployment parameters file. It does not prompt for values or use interactive defaults. Each file is deployed separately; its resource group name comes from `metadata.resourceGroupName`, or from the filename without `.json` when that metadata is absent. JSON-driven deployments proceed without an interactive confirmation, so review every parameter file before running the script. Invalid files are reported, and processing continues with the remaining files before returning a failure status.

The parameter JSON must use the standard ARM/Bicep deployment-parameters format and include all parameters declared by `main.bicep`: `location`, `vnetName`, `integrationSubnetName`, `privateEndpointSubnetName`, `planName`, `operatingSystem`, `webAppName`, `runtimeStack`, `privateDnsZoneName`, `vnetLinkName`, `privateEndpointName`, `privateDnsZoneGroupName`, `skuName`, `skuTier`, `skuSize`, `skuFamily`, and `skuCapacity`. The private DNS zone must be `privatelink.azurewebsites.net`. An example is [rg-weather-service-01.json](../input/appservice/rg-weather-service-01.json).

You can run one parameter file explicitly, even if other JSON files exist in `input/appservice/`:

```bash
./deploy.sh --parameters-file ../input/appservice/rg-weather-service-01.json
```

The resource group is created if it does not already exist. For each file, the script displays the active subscription and resolved inputs before running the Bicep deployment.

Every run writes a transcript to `<resource-group-name>.log` in the directory where you invoke the script. It records each entered value, the resolved configuration, the Bicep build command and full compiler output, plus the Azure CLI deployment commands and their output. Mock runs produce the same input/output log; if Azure CLI/Bicep is unavailable in mock mode, the log records that compilation was skipped.

The network address prefixes in `main.bicep` default to the illustrative ranges in the plan (`10.40.0.0/16`, `10.40.1.0/26`, and `10.40.2.0/27`). Check for overlap with all connected networks and adjust the Bicep parameters before deployment if needed. The integration subnet is delegated to `Microsoft.Web/serverFarms`; do not reuse it for the private endpoint.

After deployment, validate DNS and HTTPS from an intended private network. The template provisions the app as private-only, so access requires working VNet routing and DNS. Clients outside the linked VNet need private connectivity and DNS forwarding or an additional private DNS VNet link. The private DNS zone group creates app and SCM records for the private endpoint.

The SKU name and size prompts always include suggestions such as `B1`, `S1`, `P1v3`, `P0v3`, and `EP1`; size usually matches the SKU name. These are examples, not a guarantee of regional availability or a valid SKU combination. SKU fields are passed through to Azure rather than being restricted to a fixed list. Ensure that SKU name, tier, size, and family form a valid combination for the selected region, and verify quotas and workload needs before deploying.

## Delete and verify resources

To delete the resource group and verify that the resources it contained are gone, run:

```bash
./cleanup.sh
```

The script shows the active subscription, inventories resource IDs in the group, and requires you to type the resource group name to confirm. It requests group deletion, waits for Azure to report the group absent, then queries the subscription for each resource ID captured before deletion. If any captured IDs remain, it requests individual deletion and polls until they are absent or the timeout is reached. Azure CLI errors and resources that remain after the timeout are reported; rerun the script or investigate the listed IDs if verification fails.

To target a different group or subscription:

```bash
./cleanup.sh --resource-group rg-appservice-01 --subscription "<subscription-id>"
```

Use the no-Azure mock to inspect the intended flow:

```bash
./cleanup.sh --mock
```

This only verifies the resources inventoried before group deletion. It cannot find resources that were already orphaned before the script ran, resources for which the active identity lacks subscription-level list permissions, or billable soft-deleted data retained by an Azure service. Check the subscription's Cost Analysis and service-specific soft-delete/retention settings if charges continue after ARM resources are gone.
