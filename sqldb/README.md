# Azure SQL Database deployment

This directory contains a Bicep template and Bash scripts that deploy a SQL logical server and database with private endpoint networking and private DNS.

## Requirements

- Bash, Azure CLI with Bicep, and Python 3
- Permissions to create resource groups, SQL servers/databases, VNet/private endpoint resources, and private DNS
- A secure place to store the SQL administrator password for live deployments

Authenticate and select the intended subscription:

```bash
az login
az account set --subscription "<subscription-id>"
```

## Mock deployment

The sample parameter file is discovered automatically. Mock mode compiles the template when Azure CLI/Bicep is installed but makes no Azure changes and does not request the SQL password:

```bash
./sqldb/deploy.sh --mock
```

To prompt instead of discovering JSON files:

```bash
./sqldb/deploy.sh --mock --interactive
```

Interactive values are required unless `--use-defaults` is explicitly supplied.

## Live deployment and credentials

```bash
./sqldb/deploy.sh
```

Every `*.json` in `input/sqldb/` is deployed separately without an input confirmation; review those parameter files first. The SQL administrator password is not stored in the sample JSON. For a live deployment the script prompts for it using hidden input, confirms it, and requires 8-128 characters with uppercase, lowercase, a number, and a symbol. It uses a protected temporary parameters file and removes it when the script exits; the password is not logged. Do not put `adminPassword` in a JSON parameter file.

The example database is Standard S0 / 10 DTUs, intended only as a modest test baseline. Check service pricing, quota, and workload requirements before deployment. The template creates infrastructure, not schema or application identities.

## Cleanup and tests

```bash
./sqldb/cleanup.sh --mock
./sqldb/cleanup.sh --resource-group rg-weather-sqldb-01 --subscription "<subscription-id>"
python3 -m unittest discover -s sqldb/tests -v
```
