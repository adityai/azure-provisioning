import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "deploy.sh"
CLEANUP_SCRIPT = ROOT / "cleanup.sh"
BASH = Path("/bin/bash")
SAFE_PATH = "/bin:/usr/bin"


class DeployScriptTests(unittest.TestCase):
    @staticmethod
    def copy_project(root: Path) -> Path:
        project_dir = root / "rg-appservice-01"
        project_dir.mkdir(exist_ok=True)
        (project_dir / "deploy.sh").write_bytes(SCRIPT.read_bytes())
        (project_dir / "main.bicep").write_bytes((ROOT / "main.bicep").read_bytes())
        (project_dir / "deploy.sh").chmod(0o755)
        return project_dir / "deploy.sh"

    def run_mock(
        self, answers: str, *, use_defaults: bool = True
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script = self.copy_project(temp_path)
            args = [str(BASH), str(script), "--mock"]
            if use_defaults:
                args.append("--use-defaults")
            result = subprocess.run(
                args,
                input=answers,
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                cwd=temp_path,
                check=False,
            )
            log_path = temp_path / "rg-appservice-01.log"
            log_content = log_path.read_text() if log_path.exists() else ""
            return result, log_content

    @staticmethod
    def default_answers() -> str:
        return "\n" * 18

    def test_mock_mode_uses_defaults_and_never_needs_azure_cli(self) -> None:
        result, log_content = self.run_mock(self.default_answers())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MOCK MODE: no Azure deployment commands were run", result.stdout)
        self.assertIn("Resource group: rg-appservice-01 (eastus)", result.stdout)
        self.assertIn("Plan: asp-appservice-01 (SKU S1, tier Standard, size S1, family S, capacity 1; Linux)", result.stdout)
        self.assertIn("Web app: app-mcp-test-01 (public network access disabled)", result.stdout)
        self.assertIn("Runtime stack: NODE|20-lts", result.stdout)
        self.assertIn("Private endpoint: pep-appservice-01", result.stdout)
        self.assertIn("privatelink.azurewebsites.net", result.stdout)
        self.assertIn("Would deploy: az deployment group create", result.stdout)
        self.assertIn("INPUT App Service operating system (Linux or Windows)=Linux", log_content)
        self.assertIn("INPUT App Service runtime stack (for example NODE|20-lts or DOTNET|8.0)=NODE|20-lts", log_content)
        self.assertIn(
            "INPUT App Service plan SKU name (suggestions: B1, S1, P1v3, P0v3, EP1)=S1",
            log_content,
        )
        self.assertIn("Bicep compilation skipped:", log_content)
        self.assertIn("no Azure deployment commands were run", log_content)

    def test_interactive_mock_requires_values_instead_of_silently_using_defaults(self) -> None:
        result, _ = self.run_mock("\n", use_defaults=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Resource group name:", result.stdout)
        self.assertNotIn("Resource group: rg-appservice-01", result.stdout)
        self.assertIn("A value is required", result.stderr)

    def test_mock_mode_accepts_resource_name_overrides_and_premium_sku(self) -> None:
        answers = "\n".join(
            [
                "rg-custom",
                "centralus",
                "vnet-custom",
                "snet-out",
                "snet-in",
                "asp-custom",
                "Windows",
                "my-private-app-987",
                "DOTNET|8.0",
                "privatelink.azurewebsites.net",
                "dns-link",
                "pep-custom",
                "zone-group",
                "P1v3",
                "PremiumV3",
                "P1v3",
                "P",
                "3",
                "",
            ]
        )
        result, _ = self.run_mock(answers)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Resource group: rg-custom (centralus)", result.stdout)
        self.assertIn("Plan: asp-custom (SKU P1v3, tier PremiumV3, size P1v3, family P, capacity 3; Windows)", result.stdout)
        self.assertIn("Web app: my-private-app-987", result.stdout)
        self.assertIn("Runtime stack: DOTNET|8.0", result.stdout)
        self.assertIn("Private endpoint: pep-custom", result.stdout)
        self.assertIn(
            "App Service plan SKU name (suggestions: B1, S1, P1v3, P0v3, EP1)",
            result.stdout,
        )
        self.assertIn(
            "App Service plan SKU size (usually matches SKU name; examples: B1, S1, P1v3, P0v3, EP1)",
            result.stdout,
        )

    def test_invalid_web_app_name_is_rejected_and_reprompted(self) -> None:
        answers = "\n".join(
            [
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "Not_Valid",
                "valid-app-123",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
            ]
        )
        result, _ = self.run_mock(answers)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Invalid app name.", result.stdout + result.stderr)
        self.assertIn("Web app: valid-app-123", result.stdout)

    def test_wrong_private_dns_zone_fails_before_deployment(self) -> None:
        answers = "\n".join(
            [
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "wrong.example.com",
                "",
            ]
        )
        result, _ = self.run_mock(answers)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("The private DNS zone must be privatelink.azurewebsites.net", result.stdout + result.stderr)
        self.assertNotIn("Would deploy:", result.stdout)

    def test_confirmed_deployment_path_uses_mock_azure_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script = self.copy_project(temp_path)
            calls_file = temp_path / "az-calls.txt"
            fake_az = temp_path / "az"
            fake_az.write_text(
                "#!/bin/bash\n"
                "printf '%s\\n' \"$*\" >> \"$AZ_MOCK_LOG\"\n"
                "if [[ \"$1 $2\" == 'bicep build' ]]; then printf '{\"mockBicep\":\"compiled\"}\\n'; fi\n"
                "if [[ \"$1 $2\" == 'account show' ]]; then printf 'Mock Subscription\\tfake-subscription-id\\n'; fi\n"
                "if [[ \"$1 $2 $3\" == 'group create --name' ]]; then printf '{\"mockGroup\":\"created\"}\\n'; fi\n"
                "if [[ \"$1 $2 $3\" == 'deployment group create' ]]; then printf '{\"mockDeployment\":\"succeeded\"}\\n'; fi\n"
            )
            fake_az.chmod(0o755)
            answers = "\n" * 18 + "y\n"
            log_path = temp_path / "rg-appservice-01.log"
            result = subprocess.run(
                [str(BASH), str(script), "--use-defaults"],
                input=answers,
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{SAFE_PATH}",
                    "AZ_MOCK_LOG": str(calls_file),
                },
                cwd=temp_path,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            calls = calls_file.read_text().splitlines()
            self.assertEqual(len(calls), 4, calls)
            self.assertTrue(calls[0].startswith("bicep build "))
            self.assertTrue(calls[1].startswith("account show "))
            self.assertIn("group create --name rg-appservice-01 --location eastus", calls[2])
            self.assertIn("deployment group create", calls[3])
            self.assertIn("location=eastus", calls[3])
            self.assertIn("privateDnsZoneName=privatelink.azurewebsites.net", calls[3])
            self.assertIn("operatingSystem=Linux", calls[3])
            self.assertIn("runtimeStack=NODE|20-lts", calls[3])
            self.assertIn("skuName=S1", calls[3])
            self.assertIn("skuTier=Standard", calls[3])
            self.assertIn("skuFamily=S", calls[3])
            self.assertIn("Mock Subscription", result.stdout)
            log_content = log_path.read_text()
            self.assertIn("INPUT Resource group name=rg-appservice-01", log_content)
            self.assertIn('{"mockBicep":"compiled"}', log_content)
            self.assertIn('{"mockGroup":"created"}', log_content)
            self.assertIn('{"mockDeployment":"succeeded"}', log_content)
            self.assertIn("INPUT App Service plan instance capacity=1", log_content)

    def test_deployment_decline_does_not_create_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            calls_file = temp_path / "az-calls.txt"
            script = self.copy_project(temp_path)
            fake_az = temp_path / "az"
            fake_az.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$AZ_MOCK_LOG\"\n"
                "if [ \"$1\" = account ] && [ \"$2\" = show ]; then\n"
                "  printf 'Mock Subscription\\tfake-subscription-id\\n'\n"
                "fi\n"
                "if [ \"$1\" = bicep ] && [ \"$2\" = build ]; then\n"
                "  printf '{\"mockBicep\":\"compiled\"}\\n'\n"
                "fi\n"
            )
            fake_az.chmod(0o755)
            answers = "\n" * 18 + "n\n"
            result = subprocess.run(
                [str(BASH), str(script), "--use-defaults"],
                input=answers,
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{SAFE_PATH}",
                    "AZ_MOCK_LOG": str(calls_file),
                },
                cwd=temp_path,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Deployment cancelled. No resources were created.", result.stdout)
            calls = calls_file.read_text().splitlines()
            self.assertEqual(len(calls), 2, calls)
            self.assertTrue(calls[0].startswith("bicep build "))
            self.assertTrue(calls[1].startswith("account show "))

    def test_help_does_not_require_azure_cli(self) -> None:
        result = subprocess.run(
            [str(BASH), str(SCRIPT), "--help"],
            text=True,
            capture_output=True,
            env={**os.environ, "PATH": SAFE_PATH},
            check=False,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("--mock", result.stdout)
        self.assertIn("--use-defaults", result.stdout)

    def test_root_json_files_run_independently_without_prompts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script = self.copy_project(temp_path)
            calls_file = temp_path / "az-calls.txt"
            fake_az = temp_path / "az"
            fake_az.write_text(
                "#!/bin/bash\n"
                "printf '%s\\n' \"$*\" >> \"$AZ_MOCK_LOG\"\n"
                "if [[ \"$1 $2\" == 'bicep build' ]]; then printf '{\"mockBicep\":\"compiled\"}\\n'; fi\n"
                "if [[ \"$1 $2\" == 'account show' ]]; then printf 'Mock Subscription\\tfake-subscription-id\\n'; fi\n"
                "if [[ \"$1 $2 $3\" == 'group create --name' ]]; then printf '{\"mockGroup\":\"created\"}\\n'; fi\n"
                "if [[ \"$1 $2 $3\" == 'deployment group create' ]]; then printf '{\"mockDeployment\":\"succeeded\"}\\n'; fi\n"
            )
            fake_az.chmod(0o755)
            for name in ("rg-one", "rg-two"):
                parameters = {
                    "location": "eastus",
                    "vnetName": f"vnet-{name}",
                    "integrationSubnetName": f"int-{name}",
                    "privateEndpointSubnetName": f"pe-{name}",
                    "planName": f"plan-{name}",
                    "operatingSystem": "Linux",
                    "webAppName": f"app-{name}",
                    "runtimeStack": "NODE|20-lts",
                    "privateDnsZoneName": "privatelink.azurewebsites.net",
                    "vnetLinkName": f"dns-{name}",
                    "privateEndpointName": f"endpoint-{name}",
                    "privateDnsZoneGroupName": "default",
                    "skuName": "S1",
                    "skuTier": "Standard",
                    "skuSize": "S1",
                    "skuFamily": "S",
                    "skuCapacity": 1,
                }
                document = {
                    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
                    "contentVersion": "1.0.0.0",
                    "metadata": {"resourceGroupName": name},
                    "parameters": {key: {"value": value} for key, value in parameters.items()},
                }
                (temp_path / f"{name}.json").write_text(json.dumps(document))

            result = subprocess.run(
                [str(BASH), str(script)],
                input="",
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{SAFE_PATH}",
                    "AZ_MOCK_LOG": str(calls_file),
                },
                cwd=temp_path,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Found 2 root-level JSON file(s)", result.stdout)
            self.assertNotIn("Resource group name [", result.stdout)
            calls = calls_file.read_text().splitlines()
            deployments = [call for call in calls if call.startswith("deployment group create")]
            self.assertEqual(len(deployments), 2, calls)
            self.assertTrue(any("rg-one" in call and f"@{temp_path}/rg-one.json" in call for call in deployments))
            self.assertTrue(any("rg-two" in call and f"@{temp_path}/rg-two.json" in call for call in deployments))
            for name in ("rg-one", "rg-two"):
                log = (temp_path / f"{name}.log").read_text()
                self.assertIn(f"INPUT Resource group name={name}", log)
                self.assertIn(f"INPUT Parameter file={temp_path / f'{name}.json'}", log)
                self.assertIn('{"mockDeployment":"succeeded"}', log)


class CleanupScriptTests(unittest.TestCase):
    def fake_azure_cli(self, temp_path: Path) -> tuple[Path, Path]:
        state_path = temp_path / "fake-state"
        calls_file = temp_path / "az-calls.txt"
        fake_az = temp_path / "az"
        fake_az.write_text(
            "#!/bin/bash\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$AZ_MOCK_LOG\"\n"
            "case \"$1 $2\" in\n"
            "  'account show') printf 'fake-subscription-id\\n' ;;\n"
            "  'group exists')\n"
            "    if [[ -f \"$AZ_MOCK_STATE/group-deleted\" ]]; then printf 'false\\n'; else printf 'true\\n'; fi\n"
            "    ;;\n"
            "  'group delete') touch \"$AZ_MOCK_STATE/group-deleted\" ;;\n"
            "  'resource list')\n"
            "    if [[ \"$*\" == *'--resource-group'* ]]; then\n"
            "      printf '/subscriptions/fake/resourceGroups/rg-appservice-01/providers/Test/items/example\\n'\n"
            "    elif [[ ! -f \"$AZ_MOCK_STATE/leftover-deleted\" ]]; then\n"
            "      printf '/subscriptions/fake/resourceGroups/rg-appservice-01/providers/Test/items/example\\n'\n"
            "    fi\n"
            "    ;;\n"
            "  'resource delete') touch \"$AZ_MOCK_STATE/leftover-deleted\" ;;\n"
            "  *) printf 'Unexpected Azure CLI call: %s\\n' \"$*\" >&2; exit 64 ;;\n"
            "esac\n"
        )
        fake_az.chmod(0o755)
        return fake_az, calls_file

    def test_mock_mode_never_calls_azure(self) -> None:
        result = subprocess.run(
            [str(BASH), str(CLEANUP_SCRIPT), "--mock"],
            text=True,
            capture_output=True,
            env={**os.environ, "PATH": SAFE_PATH},
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no Azure CLI commands were run", result.stdout)
        self.assertIn("Would snapshot resources", result.stdout)

    def test_cleanup_deletes_group_then_individually_deletes_survivor(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            fake_az, calls_file = self.fake_azure_cli(temp_path)
            (temp_path / "fake-state").mkdir()
            result = subprocess.run(
                [
                    str(BASH),
                    str(CLEANUP_SCRIPT),
                    "--poll-interval-seconds",
                    "1",
                    "--timeout-seconds",
                    "5",
                ],
                input="rg-appservice-01\n",
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{SAFE_PATH}",
                    "AZ_MOCK_LOG": str(calls_file),
                    "AZ_MOCK_STATE": str(temp_path / "fake-state"),
                },
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Found 1 surviving resource(s)", result.stdout)
            self.assertIn("all pre-delete resource IDs are absent", result.stdout)
            calls = calls_file.read_text().splitlines()
            group_delete_index = next(i for i, call in enumerate(calls) if call.startswith("group delete "))
            resource_delete_index = next(i for i, call in enumerate(calls) if call.startswith("resource delete "))
            self.assertLess(group_delete_index, resource_delete_index)
            self.assertIn("--no-wait", calls[group_delete_index])
            self.assertIn("--ids /subscriptions/fake/resourceGroups/rg-appservice-01/providers/Test/items/example", calls[resource_delete_index])
            self.assertTrue(fake_az.exists())

    def test_cleanup_decline_does_not_call_delete(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            self.fake_azure_cli(temp_path)
            (temp_path / "fake-state").mkdir()
            calls_file = temp_path / "az-calls.txt"
            result = subprocess.run(
                [str(BASH), str(CLEANUP_SCRIPT)],
                input="no\n",
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{SAFE_PATH}",
                    "AZ_MOCK_LOG": str(calls_file),
                    "AZ_MOCK_STATE": str(temp_path / "fake-state"),
                },
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Cleanup cancelled.", result.stdout)
            calls = calls_file.read_text().splitlines()
            self.assertTrue(all(not call.startswith("group delete ") for call in calls))
            self.assertTrue(all(not call.startswith("resource delete ") for call in calls))


if __name__ == "__main__":
    unittest.main()
