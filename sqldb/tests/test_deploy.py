import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "deploy.sh"
CLEANUP = ROOT / "cleanup.sh"
TEMPLATE = ROOT / "main.bicep"
PARAMETERS = ROOT.parent / "input" / "sqldb" / "rg-weather-sqldb-01.json"
BASH = Path("/bin/bash")
SAFE_PATH = "/bin:/usr/bin"


class SqlDatabaseDeploymentTests(unittest.TestCase):
    @staticmethod
    def create_project(temp_path: Path) -> tuple[Path, Path]:
        project_dir = temp_path / "sqldb"
        project_dir.mkdir()
        script = project_dir / "deploy.sh"
        script.write_bytes(SCRIPT.read_bytes())
        script.chmod(0o755)
        (project_dir / "main.bicep").write_bytes(TEMPLATE.read_bytes())
        input_dir = temp_path / "input" / "sqldb"
        input_dir.mkdir(parents=True)
        return script, input_dir

    def test_discovered_parameters_run_mock_without_password_or_azure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, input_dir = self.create_project(temp_path)
            (input_dir / PARAMETERS.name).write_bytes(PARAMETERS.read_bytes())
            result = subprocess.run(
                [str(BASH), str(script), "--mock"],
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                cwd=temp_path,
                check=False,
            )

            self.assertEqual(result.returncode, 0, f"{result.stdout}\n{result.stderr}")
            self.assertIn("Found 1 input/sqldb JSON file(s)", result.stdout)
            self.assertIn("MOCK MODE: no Azure deployment commands were run", result.stdout)
            self.assertIn("SQL server: weather-sql-weather-01.database.windows.net", result.stdout)
            self.assertNotIn("SQL administrator password:", result.stdout)
            log = (temp_path / "rg-weather-sqldb-01.log").read_text()
            self.assertIn("[REDACTED", log)

    def test_mock_cleanup_and_help_do_not_require_azure_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, _ = self.create_project(temp_path)
            cleanup = temp_path / "sqldb" / "cleanup.sh"
            cleanup.write_bytes(CLEANUP.read_bytes())
            cleanup.chmod(0o755)
            env = {**os.environ, "PATH": SAFE_PATH}

            help_result = subprocess.run(
                [str(BASH), str(script), "--help"],
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            cleanup_result = subprocess.run(
                [str(BASH), str(cleanup), "--mock"],
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )

            self.assertEqual(help_result.returncode, 0)
            self.assertIn("--parameters-file", help_result.stdout)
            self.assertEqual(cleanup_result.returncode, 0, cleanup_result.stderr)
            self.assertIn("no Azure CLI commands were run", cleanup_result.stdout)

    def test_password_is_sent_through_protected_temp_file_and_not_logged(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, _ = self.create_project(temp_path)
            calls_file = temp_path / "az-calls.txt"
            fake_az = temp_path / "az"
            fake_az.write_text(
                "#!/bin/bash\n"
                "printf '%s\\n' \"$*\" >> \"$AZ_MOCK_LOG\"\n"
                "if [[ \"$1 $2\" == 'account show' ]]; then printf 'Test subscription\\tfake-id\\n'; fi\n"
                "if [[ \"$1 $2 $3\" == 'deployment group create' ]]; then\n"
                "  for arg in \"$@\"; do\n"
                "    if [[ \"$arg\" == @* ]]; then\n"
                "      if grep -q 'Weather1!Pass' \"${arg#@}\"; then printf 'TEMP_PASSWORD_PRESENT\\n' >> \"$AZ_MOCK_LOG\"; fi\n"
                "      printf 'TEMP_PARAMETER_PATH=%s\\n' \"${arg#@}\" >> \"$AZ_MOCK_LOG\"\n"
                "    fi\n"
                "  done\n"
                "fi\n"
            )
            fake_az.chmod(0o755)
            secret = "Weather1!Pass"
            result = subprocess.run(
                [str(BASH), str(script), "--parameters-file", str(PARAMETERS)],
                input=f"{secret}\n{secret}\n",
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

            self.assertEqual(result.returncode, 0, f"{result.stdout}\n{result.stderr}")
            self.assertNotIn(secret, result.stdout)
            log = (temp_path / "rg-weather-sqldb-01.log").read_text()
            self.assertNotIn(secret, log)
            calls = calls_file.read_text()
            self.assertIn("TEMP_PASSWORD_PRESENT", calls)
            temp_parameter_path = next(
                line.split("=", 1)[1]
                for line in calls.splitlines()
                if line.startswith("TEMP_PARAMETER_PATH=")
            )
            self.assertFalse(Path(temp_parameter_path).exists())

    def test_password_in_sample_parameter_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            script, input_dir = self.create_project(temp_path)
            document = json.loads(PARAMETERS.read_text())
            document["parameters"]["adminPassword"] = {"value": "DoNotStoreMe1!"}
            parameter_file = input_dir / "unsafe.json"
            parameter_file.write_text(json.dumps(document))
            result = subprocess.run(
                [str(BASH), str(script), "--mock", "--parameters-file", str(parameter_file)],
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": SAFE_PATH},
                cwd=temp_path,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("adminPassword must not be stored", result.stderr)

    def test_template_uses_secure_password_and_private_sql_dns(self) -> None:
        template = TEMPLATE.read_text()
        self.assertIn("@secure()", template)
        self.assertIn("publicNetworkAccess: 'Disabled'", template)
        self.assertIn("minimalTlsVersion: '1.2'", template)
        self.assertIn("privatelink.${environment().suffixes.sqlServerHostname}", template)
        self.assertIn("groupIds: [\n            'sqlServer'", template)
        self.assertNotIn("output adminPassword", template)


if __name__ == "__main__":
    unittest.main()
