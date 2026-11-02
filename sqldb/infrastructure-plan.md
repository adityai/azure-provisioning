# Private Azure SQL Database infrastructure plan

**Status:** Design and deployment artifacts; no Azure resources have been created.

## Goal and architecture

Provision an Azure SQL logical server and a sample Standard S0 database with public network access disabled. A private endpoint in a dedicated subnet connects to the SQL server using the `sqlServer` private-link subresource. A linked `privatelink.database.windows.net` private DNS zone supports private resolution from the VNet.

The template creates the VNet, a dedicated private-endpoint subnet, SQL server, database, private endpoint, and DNS resources. It does not create database schemas, users, or application code.

## Security

- Public SQL access is disabled and the server enforces TLS 1.2 or newer.
- The SQL administrator password is a secure Bicep parameter, omitted from the checked-in sample JSON. The deployment script prompts for it with hidden input only for live deployments, checks complexity, and places it in a mode-0600 temporary parameter file that is removed on exit. The secret is not printed or written to the deployment log.
- Use a unique password stored in an approved secret manager. SQL credentials do not replace application identity; prefer Microsoft Entra authentication/managed identity for application access where configured.
- The VNet ranges are examples; check for overlap before deployment.

## Sizing and cost

The example uses a Standard S0 (10 DTU) database for a small test workload. This is not a production sizing recommendation. Private endpoints, SQL compute/storage, and DNS incur charges. Validate region availability, quota, workload sizing, retention, backups, and recovery requirements before a live deployment.

## Validation

From a client connected to the VNet, confirm `<server>.database.windows.net` resolves through the private DNS zone to the endpoint address, then test TLS SQL connectivity. Public network access must remain disabled. Deploy database schema and application access configuration separately.
