"""Real runner/adapter subprocess composition; only external CLI/SSH are fixtures."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import test_railway_memory_adapters as fixtures

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("composition_runner", ROOT / "postgres_memory_trial_runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class ProviderCompositionTests(unittest.TestCase):
    def test_actual_runner_identity_reaches_adapter_but_credentials_do_not(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            config, identity, data, endpoints, sample = fixtures.AdapterTests().fixture(root)
            cli = root / "cli"
            cli.write_text(f"#!{sys.executable}\nimport json,sys\n"
                f"first={repr({'data': data})}\nsecond={repr({'data': endpoints})}\n"
                "print(json.dumps(first if 'privateNetworks(' in sys.argv[2] else second))\n")
            ssh = root / "ssh"
            ssh.write_text(f"#!{sys.executable}\nimport json\nprint(json.dumps({sample!r}))\n")
            for path in (cli, ssh): path.chmod(0o700)
            config["provider"].update(railway_binary=str(cli), ssh_binary=str(ssh))
            config["runner"]["token_file"] = str(root / "not-read-by-identity")
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config)); config_path.chmod(0o600)
            adapter = ROOT / "railway_memory_identity.py"
            spec = {"path": str(adapter), "sha256": hashlib.sha256(adapter.read_bytes()).hexdigest()}
            secrets = {"DATABASE_URL": "never-forward-database", "PGPASSWORD": "never-forward-password",
                "RAILWAY_API_TOKEN": "never-forward-api-token", "RAILWAY_TOKEN": "never-forward-project-token",
                "RAILWAY_VOLUME_ID": "not-the-runner-identity", "GATEWAY_APPVIEW_INTERNAL_SECRET": "never-forward-trust"}
            inherited = {key: os.environ[key] for key in ("PATH", "LANG", "HOME") if key in os.environ}
            cases = [("valid", identity)]
            for name in identity:
                cases.append(("missing " + name, {key: value for key, value in identity.items() if key != name}))
                cases.append(("wrong " + name, identity | {name: "00000099-0000-0000-0000-000000000000"}))
            for label, observed in cases:
                with self.subTest(label=label), patch.dict(os.environ, inherited | secrets | observed, clear=True):
                    environment = runner.adapter_environment(config_path, config)
                    self.assertFalse(set(secrets) & set(environment))
                    self.assertEqual({key: environment[key] for key in identity if key in environment}, observed)
                    children = runner.Children()
                    try:
                        if label == "valid":
                            result = runner.invoke(children, spec, environment, {}, 5)
                            self.assertEqual(result, {"target": config["target"],
                                "runner": {key: config["runner"][key] for key in ("project_id", "environment_id", "service_id")},
                                "read_targets": config["read_targets"], "snapshot_sha256": config["snapshot_sha256"]})
                        else:
                            with self.assertRaises(runner.Error): runner.invoke(children, spec, environment, {}, 5)
                    finally:
                        children.stop()


if __name__ == "__main__": unittest.main()
