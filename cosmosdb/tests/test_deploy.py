import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
INPUT = REPO / "input" / "cosmosdb" / "rg-weather-cosmosdb-01.json"
LOG = ROOT / "rg-weather-cosmosdb-01.log"


class CosmosDbDeploymentTests(unittest.TestCase):
    def tearDown(self):
        LOG.unlink(missing_ok=True)

    def run_script(self, *args, input_text=""):
        return subprocess.run(
            ["/bin/bash", str(ROOT / args[0]), *args[1:]],
            input=input_text,
            text=True,
            capture_output=True,
            cwd=ROOT,
            check=False,
        )

    def test_input_parameters_are_exact_and_credential_free(self):
        document = json.loads(INPUT.read_text())
        expected = {
            "location", "vnetName", "privateEndpointSubnetName", "accountName",
            "databaseName", "containerName", "partitionKeyPath",
            "privateDnsZoneName", "vnetLinkName", "privateEndpointName",
            "privateDnsZoneGroupName",
        }
        self.assertEqual(set(document["parameters"]), expected)
        serialized = INPUT.read_text().lower()
        for forbidden in ("accountkey", "password", "secretvalue", "connectionstring"):
            self.assertNotIn(forbidden, serialized)
        self.assertEqual(document["parameters"]["privateDnsZoneName"]["value"], "privatelink.documents.azure.com")

    def test_auto_discovery_runs_mock_with_per_group_log(self):
        result = self.run_script("deploy.sh", "--mock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Found 1 input/cosmosdb JSON file(s)", result.stdout)
        self.assertIn("Resource group: rg-weather-cosmosdb-01 (eastus)", result.stdout)
        self.assertIn("Partition key: /weatherStationId", result.stdout)
        self.assertIn("no Azure deployment commands were run", result.stdout)
        self.assertTrue(LOG.exists())
        log = LOG.read_text()
        self.assertIn("INPUT accountName=weathercosmosdb01", log)
        self.assertIn("privatelink.documents.azure.com", log)
        self.assertIn("Would deploy: az deployment group create", log)

    def test_interactive_mode_bypasses_json_and_uses_explicit_defaults(self):
        result = self.run_script(
            "deploy.sh", "--mock", "--interactive", "--use-defaults",
            input_text="\n" * 12,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Found 1 input/cosmosdb", result.stdout)
        self.assertIn("Account: weathercosmosdb01", result.stdout)
        self.assertTrue(LOG.exists())

    def test_wrong_private_dns_zone_fails_before_preview(self):
        answers = "\n".join(["", "", "", "", "", "", "", "", "wrong.example", ""])
        result = self.run_script("deploy.sh", "--mock", "--interactive", "--use-defaults", input_text=answers)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private DNS zone must be", result.stderr)
        self.assertNotIn("Would deploy:", result.stdout)

    def test_cleanup_mock_does_not_need_azure(self):
        result = self.run_script("cleanup.sh", "--mock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no Azure CLI commands were run", result.stdout)
        self.assertIn("rg-weather-cosmosdb-01", result.stdout)

    def test_bicep_has_private_keyless_serverless_configuration_and_no_key_outputs(self):
        template = (ROOT / "main.bicep").read_text()
        self.assertIn("Microsoft.DocumentDB/databaseAccounts@2026-03-15", template)
        self.assertIn("name: 'EnableServerless'", template)
        self.assertIn("publicNetworkAccess: 'Disabled'", template)
        self.assertIn("disableLocalAuth: true", template)
        self.assertIn("partitionKeyPath", template)
        self.assertIn("privatelink.documents.azure.com", template)
        outputs = template.splitlines()
        self.assertFalse(any(line.startswith("output ") and "key" in line.lower() for line in outputs))

    def test_shell_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(ROOT / "deploy.sh"), str(ROOT / "cleanup.sh")],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
