import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "deploy.sh"
CLEANUP_SCRIPT = ROOT / "cleanup.sh"
TEMPLATE = ROOT / "main.bicep"
PARAMETERS = ROOT.parent / "input" / "functionapp" / "rg-weather-function-01.json"
BASH = Path("/bin/bash")
SAFE_PATH = "/bin:/usr/bin"


class FunctionAppDeploymentTests(unittest.TestCase):
    @staticmethod
    def create_project(temp_path: Path) -> tuple[Path, Path]:
        project_dir = temp_path / "functionapp"
        project_dir.mkdir()
        script = project_dir / "deploy.sh"
        script.write_bytes(SCRIPT.read_bytes())
        script.chmod(0o755)
        (project_dir / "main.bicep").write_bytes(TEMPLATE.read_bytes())
        input_dir = temp_path / "input" / "functionapp"
        input_dir.mkdir(parents=True)
        return script, input_dir

    def test_discovered_parameter_file_runs_in_mock_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, input_dir = self.create_project(temp_path)
            parameter_file = input_dir / "rg-weather-function-01.json"
            parameter_file.write_bytes(PARAMETERS.read_bytes())
            result = subprocess.run(
                [str(BASH), str(script), "--mock"],
                input="",
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                cwd=temp_path,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Found 1 input/functionapp JSON file(s)", result.stdout)
            self.assertIn("MOCK MODE: no Azure deployment commands were run", result.stdout)
            self.assertIn("Function App: func-weather-01 (Linux, public network access disabled)", result.stdout)
            self.assertIn("Runtime: Functions v4, Python|3.12", result.stdout)
            self.assertIn("EP1, tier ElasticPremium", result.stdout)
            self.assertIn("Storage: stweatherfunc01 (public network access disabled", result.stdout)
            self.assertIn(f"@{parameter_file}", result.stdout)
            log = (temp_path / "rg-weather-function-01.log").read_text()
            self.assertIn(f"INPUT Parameter file={parameter_file}", log)
            self.assertIn("INPUT Storage account name=stweatherfunc01", log)

    def test_interactive_mode_requires_values_when_defaults_not_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, _ = self.create_project(temp_path)
            result = subprocess.run(
                [str(BASH), str(script), "--mock", "--interactive"],
                input="\n",
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                cwd=temp_path,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Resource group name:", result.stdout)
            self.assertIn("A value is required", result.stderr)

    def test_invalid_runtime_in_parameter_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, input_dir = self.create_project(temp_path)
            document = json.loads(PARAMETERS.read_text())
            document["parameters"]["runtimeStack"]["value"] = "Node|20"
            parameter_file = input_dir / "invalid.json"
            parameter_file.write_text(json.dumps(document))
            result = subprocess.run(
                [str(BASH), str(script), "--parameters-file", str(parameter_file), "--mock"],
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                cwd=temp_path,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtimeStack must be Python|3.11 or Python|3.12", result.stderr)

    def test_help_and_cleanup_mock_do_not_need_azure_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, _ = self.create_project(temp_path)
            cleanup = temp_path / "functionapp" / "cleanup.sh"
            cleanup.write_bytes(CLEANUP_SCRIPT.read_bytes())
            cleanup.chmod(0o755)

            help_result = subprocess.run(
                [str(BASH), str(script), "--help"],
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                check=False,
            )
            cleanup_result = subprocess.run(
                [str(BASH), str(cleanup), "--mock"],
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                check=False,
            )

            self.assertEqual(help_result.returncode, 0)
            self.assertIn("--parameters-file", help_result.stdout)
            self.assertEqual(cleanup_result.returncode, 0, cleanup_result.stderr)
            self.assertIn("no Azure CLI commands were run", cleanup_result.stdout)

    def test_template_includes_private_function_and_storage_endpoints(self) -> None:
        template = TEMPLATE.read_text()

        self.assertIn("publicNetworkAccess: 'Disabled'", template)
        self.assertIn("FUNCTIONS_EXTENSION_VERSION", template)
        self.assertIn("WEBSITE_CONTENTOVERVNET", template)
        self.assertIn("storagePrivateEndpoints", template)
        self.assertIn("privateDnsZoneName", template)
        self.assertIn("Microsoft.OperationalInsights/workspaces", template)
        self.assertIn("Microsoft.Insights/components", template)
        self.assertIn("APPLICATIONINSIGHTS_CONNECTION_STRING", template)
        self.assertIn("Microsoft.KeyVault/vaults", template)
        self.assertIn("keyVaultPrivateEndpoint", template)
        for service in ("blob", "file", "queue", "table"):
            self.assertIn(f"suffix: '{service}'", template)


if __name__ == "__main__":
    unittest.main()
