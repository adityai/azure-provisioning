import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASH = Path("/bin/bash")
SAMPLE_GROUP = "rg-weather-fileshare-01"
TEST_PATH = f"{Path(sys.executable).parent}:/bin:/usr/bin"


class FileShareDeploymentTests(unittest.TestCase):
    def run_deploy(self, *args: str, answers: str = "") -> subprocess.CompletedProcess[str]:
        log_path = ROOT / f"{SAMPLE_GROUP}.log"
        try:
            return subprocess.run(
                [str(BASH), str(ROOT / "deploy.sh"), *args],
                input=answers,
                text=True,
                capture_output=True,
                cwd=ROOT,
                env={**os.environ, "PATH": TEST_PATH},
                check=False,
            )
        finally:
            log_path.unlink(missing_ok=True)

    def test_discovered_json_runs_mock_without_azure_or_prompts(self) -> None:
        result = self.run_deploy("--mock")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Found 1 input/fileshare JSON file(s)", result.stdout)
        self.assertIn("MOCK MODE: no Azure deployment commands were run", result.stdout)
        self.assertIn("file share: weatherdata; quota: 100 GiB (SMB)", result.stdout)
        self.assertIn("privatelink.file.${environment().suffixes.storage}", (ROOT / "main.bicep").read_text())
        self.assertIn("TCP port 445", result.stdout)
        self.assertIn("Bicep compilation skipped:", result.stdout)
        self.assertNotIn("Resource group name:", result.stdout)

    def test_interactive_quota_validation_reprompts_and_honors_defaults(self) -> None:
        answers = "\n" * 4 + "0\n200\n" + "\n" * 5
        result = self.run_deploy("--mock", "--interactive", "--use-defaults", answers=answers)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Invalid value for File share quota", result.stdout + result.stderr)
        self.assertIn("file share: weatherdata; quota: 200 GiB (SMB)", result.stdout)

    def test_blank_required_value_fails_without_use_defaults(self) -> None:
        result = self.run_deploy("--mock", "--interactive", answers="\n")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A value is required", result.stderr)
        self.assertNotIn("MOCK MODE:", result.stdout)

    def test_sample_parameters_are_valid_json_and_contain_no_credentials(self) -> None:
        path = ROOT.parent / "input" / "fileshare" / "rg-weather-fileshare-01.json"
        document = json.loads(path.read_text())
        self.assertEqual(document["metadata"]["resourceGroupName"], SAMPLE_GROUP)
        self.assertEqual(document["parameters"]["shareQuota"]["value"], 100)
        self.assertNotIn("privateDnsZoneName", document["parameters"])
        serialized = json.dumps(document).lower()
        for marker in ("password", "secret", "accesskey", "accountkey", "sas"):
            self.assertNotIn(marker, serialized)

    def test_template_enforces_private_smb_share(self) -> None:
        template = (ROOT / "main.bicep").read_text()
        self.assertIn("kind: 'StorageV2'", template)
        self.assertIn("publicNetworkAccess: 'Disabled'", template)
        self.assertIn("defaultAction: 'Deny'", template)
        self.assertIn("enabledProtocols: 'SMB'", template)
        self.assertIn("shareQuota: shareQuota", template)
        self.assertIn("groupIds: [\n            'file'", template)

    def test_cleanup_mock_does_not_call_azure(self) -> None:
        result = subprocess.run(
            [str(BASH), str(ROOT / "cleanup.sh"), "--mock"],
            text=True,
            capture_output=True,
            cwd=ROOT,
            env={**os.environ, "PATH": TEST_PATH},
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no Azure CLI commands were run", result.stdout)
        self.assertIn("exact-name confirmation", result.stdout)


if __name__ == "__main__":
    unittest.main()
