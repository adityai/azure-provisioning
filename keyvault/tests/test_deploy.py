import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
INPUT = REPO / "input" / "keyvault" / "rg-weather-keyvault-01.json"
LOG = ROOT / "rg-weather-keyvault-01.log"


class KeyVaultDeploymentTests(unittest.TestCase):
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

    def test_input_parameters_are_exact_and_secret_free(self):
        document = json.loads(INPUT.read_text())
        expected = {
            "location", "vnetName", "privateEndpointSubnetName", "vaultName",
            "privateDnsZoneName", "vnetLinkName", "privateEndpointName",
            "privateDnsZoneGroupName", "softDeleteRetentionInDays",
        }
        self.assertEqual(set(document["parameters"]), expected)
        serialized = INPUT.read_text().lower()
        for forbidden in ("password", "secretvalue", "secretstring", "connectionstring"):
            self.assertNotIn(forbidden, serialized)
        self.assertEqual(document["parameters"]["softDeleteRetentionInDays"]["value"], 90)

    def test_auto_discovery_runs_mock_with_per_group_log(self):
        result = self.run_script("deploy.sh", "--mock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Found 1 input/keyvault JSON file(s)", result.stdout)
        self.assertIn("Vault: kv-weather-keyvault-01 (Standard, RBAC authorization)", result.stdout)
        self.assertIn("Soft-delete retention: 90 days; purge protection enabled", result.stdout)
        self.assertIn("no Azure deployment commands were run", result.stdout)
        self.assertTrue(LOG.exists())
        log = LOG.read_text()
        self.assertIn("INPUT vaultName=kv-weather-keyvault-01", log)
        self.assertIn("privatelink.vaultcore.azure.net", log)
        self.assertIn("Would deploy: az deployment group create", log)

    def test_interactive_mode_bypasses_json_and_uses_explicit_defaults(self):
        result = self.run_script(
            "deploy.sh", "--mock", "--interactive", "--use-defaults",
            input_text="\n" * 9,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Found 1 input/keyvault", result.stdout)
        self.assertIn("Vault: kv-weather-keyvault-01", result.stdout)
        self.assertTrue(LOG.exists())

    def test_wrong_private_dns_zone_fails_before_preview(self):
        answers = "\n".join(["", "", "", "", "", "wrong.example", ""])
        result = self.run_script("deploy.sh", "--mock", "--interactive", "--use-defaults", input_text=answers)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private DNS zone must be", result.stderr)
        self.assertNotIn("Would deploy:", result.stdout)

    def test_cleanup_mock_does_not_need_azure(self):
        result = self.run_script("cleanup.sh", "--mock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no Azure CLI commands were run", result.stdout)
        self.assertIn("rg-weather-keyvault-01", result.stdout)

    def test_bicep_has_private_rbac_and_retention_safeguards(self):
        template = (ROOT / "main.bicep").read_text()
        self.assertIn("Microsoft.KeyVault/vaults@2026-05-15", template)
        self.assertIn("enableRbacAuthorization: true", template)
        self.assertIn("publicNetworkAccess: 'Disabled'", template)
        self.assertIn("enablePurgeProtection: true", template)
        self.assertIn("softDeleteRetentionInDays", template)
        self.assertIn("privatelink.vaultcore.azure.net", template)
        self.assertNotIn("Microsoft.KeyVault/vaults/secrets", template)
        self.assertNotIn("secretValue", template)

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
