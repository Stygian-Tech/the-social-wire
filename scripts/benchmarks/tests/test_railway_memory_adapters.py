"""Deterministic provider fixtures and owned local subprocesses; no Railway mutations."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from test_postgres_memory_trial import configuration, probe

SPEC = importlib.util.spec_from_file_location("provider_adapters", Path(__file__).resolve().parents[1] / "railway_memory_adapters.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def uid(number):
    return f"{number:08x}-0000-0000-0000-000000000000"


class AdapterTests(unittest.TestCase):
    def fixture(self, root):
        config = configuration()
        config["target"].update(project_id=m.PROJECT, environment_id=uid(1), service_id=uid(2), volume_id=uid(3), host="tsw92-postgres.railway.internal")
        config["runner"] = {"project_id": m.PROJECT, "environment_id": uid(1), "service_id": uid(4)}
        config["read_targets"] = {"gateway": {"service_id": uid(5), "origin": "http://tsw92-gateway.railway.internal:8080"}}
        key = root / "key"; key.write_text("test-only-not-a-key"); key.chmod(0o600)
        config["provider"] = {"ssh_identity_file": str(key), "railway_binary": sys.executable, "ssh_binary": sys.executable,
            "module_sha256": hashlib.sha256(Path(m.__file__).read_bytes()).hexdigest(),
            "remote_probe_directory": "/benchmark", "probe_sha256": {"postgres_memory_trial.py": "a" * 64, "postgres_replay.py": "b" * 64}}
        env = {m.trial.IDENTITIES[key]: config["runner"][key] for key in ("project_id", "environment_id", "service_id")}
        env["RAILWAY_DEPLOYMENT_ID"] = uid(24)
        data = {"environment": {"id": uid(1), "name": "tsw92-memory-dev", "projectId": m.PROJECT, "deletedAt": None,
            "volumeInstances": {"pageInfo": {"hasNextPage": False}, "edges": [{"node": {
            "volumeId": uid(3), "serviceId": uid(2), "environmentId": uid(1), "mountPath": "/var/lib/postgresql/data", "region": "sfo", "state": "READY"}}]}},
            "privateNetworks": [{"publicId": uid(9), "projectId": m.PROJECT, "environmentId": uid(1), "deletedAt": None, "dnsName": "railway"}]}
        endpoints = {}
        for name, number, dns in (("database", 2, "tsw92-postgres"), ("runner", 4, "tsw92-runner"), ("read0", 5, "tsw92-gateway")):
            data[name] = {"id": uid(number + 10), "serviceId": uid(number), "environmentId": uid(1), "serviceName": dns, "region": "sfo",
                          "activeDeployments": [{"id": uid(number + 20), "projectId": m.PROJECT, "environmentId": uid(1), "serviceId": uid(number), "status": "SUCCESS",
                                                  "instances": [{"id": uid(number + 30), "status": "RUNNING"}]}]}
            endpoints[name] = {"serviceInstanceId": uid(number + 10), "dnsName": dns, "newDnsName": dns, "deletedAt": None}
        sample = probe()
        sample["identity"] = {key: config["target"][key] for key in m.trial.IDENTITIES}
        sample["container_epoch"][0] = uid(22)
        sample["db"]["database"] = config["target"]["database"]
        return config, env, data, endpoints, sample

    def test_identity_uses_fresh_provider_mapping_and_remote_attestation(self):
        with tempfile.TemporaryDirectory() as raw:
            config, env, data, endpoints, sample = self.fixture(Path(raw))
            calls = []
            def command(args, payload, **_):
                calls.append((args, payload))
                return [{"data": data}, {"data": endpoints}, sample][len(calls) - 1]
            result = m.execute("identity", config, env, command)
            self.assertEqual(result, {"target": config["target"], "runner": config["runner"], "read_targets": config["read_targets"], "snapshot_sha256": config["snapshot_sha256"]})
            self.assertEqual(len(calls), 3)
            self.assertTrue(all("mutation" not in call[0][2].lower() for call in calls[:2]))
            ssh = calls[2][0]
            self.assertIn(uid(12) + "@ssh.railway.com", ssh)  # service-instance ID, not deployment-instance ID
            self.assertIn("StrictHostKeyChecking=yes", ssh)
            self.assertIn("--kill-after=1s 10s", ssh[-1])
            self.assertIn("PYTHONDONTWRITEBYTECODE=1", ssh[-1])
            self.assertNotIn("test-only-not-a-key", str(calls))
            self.assertEqual(json.loads(calls[2][1])["deployment"], uid(22))

    def test_probe_returns_unmodified_cgroup_and_database_sample(self):
        with tempfile.TemporaryDirectory() as raw:
            config, env, data, endpoints, sample = self.fixture(Path(raw))
            with patch.object(m.Provider, "identity", return_value=data) as identity, patch.object(m.Provider, "probe", return_value=sample):
                self.assertIs(m.execute("probe", config, env), sample)
                identity.assert_called_once_with(include_reads=False)

    def test_canonical_sources_cannot_be_unprotected_by_omitting_ids(self):
        with tempfile.TemporaryDirectory() as raw:
            config, env, *_ = self.fixture(Path(raw))
            for value in m.PROTECTED:
                invalid = copy.deepcopy(config); invalid["target"]["service_id"] = value
                with self.subTest(value=value), self.assertRaises(m.Error): m.validate_config(invalid)
            for field in ("environment_id", "service_id", "volume_id"):
                invalid = copy.deepcopy(config); invalid["target"][field] = "not-a-uuid"
                with self.assertRaises(m.Error): m.validate_config(invalid)
            with self.assertRaises(m.Error): m.execute("identity", config, {}, lambda *_: self.fail("Must refuse before API access"))
            with self.assertRaises(m.Error): m.execute("restart", config, env, lambda *_: self.fail("No restart command exists"))

    def test_changed_module_or_public_read_origin_and_unsafe_key_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            config, _, *_ = self.fixture(Path(raw))
            for change in (lambda c: c["provider"].update(module_sha256="0" * 64),
                           lambda c: c["read_targets"]["gateway"].update(origin="https://api.thesocialwire.app"),
                           lambda c: c["provider"].update(remote_probe_directory="/benchmark/../other")):
                invalid = copy.deepcopy(config); change(invalid)
                with self.assertRaises(m.Error): m.validate_config(invalid)
            key = Path(config["provider"]["ssh_identity_file"]); key.chmod(0o644)
            with self.assertRaises(m.Error): m.validate_config(config)

    def test_provider_volume_service_network_and_deployment_mismatch_fail(self):
        mutations = [lambda d, e: d["environment"].update(name="dev"),
                     lambda d, e: d["environment"]["volumeInstances"]["pageInfo"].update(hasNextPage=True),
                     lambda d, e: d["environment"]["volumeInstances"]["edges"][0]["node"].update(serviceId=uid(99)),
                     lambda d, e: d["database"]["activeDeployments"][0].update(status="CRASHED"),
                     lambda d, e: d["database"]["activeDeployments"][0]["instances"].append({"id": uid(88), "status": "RUNNING"}),
                     lambda d, e: e["database"].update(dnsName="postgres"),
                     lambda d, e: e["read0"].update(serviceInstanceId=uid(99)),
                     lambda d, e: e["database"].update(newDnsName="moving-host")]
        with tempfile.TemporaryDirectory() as raw:
            for mutate in mutations:
                config, _, data, endpoints, _ = self.fixture(Path(raw)); mutate(data, endpoints)
                answers = iter([{"data": data}, {"data": endpoints}])
                with self.assertRaises(m.Error): m.Provider(config, lambda *_, **__: next(answers)).identity()

    def test_remote_epoch_database_or_snapshot_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            for change in (lambda s: s["container_epoch"].__setitem__(0, uid(99)),
                           lambda s: s["db"].update(database="railway"),
                           lambda s: s["restore"].update(snapshot_sha256="f" * 64)):
                config, _, identity, _, sample = self.fixture(Path(raw)); change(sample)
                with self.assertRaises(m.Error): m.Provider(config, lambda *_: sample).probe(identity)

    def test_command_invalid_json_oversize_timeout_and_cancellation_retire_owned_child(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)"])
        real_popen = subprocess.Popen
        created = []
        def start(*args, **kwargs):
            process = real_popen(*args, **kwargs); created.append(process); return process
        try:
            with patch.object(m.subprocess, "Popen", side_effect=start):
                for code, timeout in (("print('private invalid provider output')", 2),
                                      ("print('x'*3000000)", 2), ("import time;time.sleep(30)", .05)):
                    with self.assertRaises(m.Error): m.owned_command([sys.executable, "-c", code], b"", timeout)
                    self.assertIsNotNone(created[-1].poll())
                with patch.object(m.selectors, "DefaultSelector", side_effect=KeyboardInterrupt):
                    with self.assertRaises(KeyboardInterrupt):
                        m.owned_command([sys.executable, "-c", "print('{}',flush=True);import time;time.sleep(30)"], b"", 2)
                self.assertIsNotNone(created[-1].poll())
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate(); unrelated.wait()

    def test_external_project_token_only_reaches_cli_environment(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); config, *_ = self.fixture(root)
            token = root / "railway-token"; token.write_text("fixture-private-token"); token.chmod(0o600)
            config["provider"].update(railway_token_file=str(token), railway_token_kind="project")
            captured = []
            def command(argv, payload, **kwargs):
                captured.append((argv, payload, kwargs)); return {"data": {"identity": "fixture"}}
            m.validate_config(config)
            with patch.dict(os.environ, {"DATABASE_URL": "never-forward", "RAILWAY_API_TOKEN": "never-forward"}):
                m.Provider(config, command).query("query{identity}", {})
            argv, payload, options = captured[0]
            self.assertNotIn("fixture-private-token", str(argv) + str(payload))
            self.assertEqual(options["environment"]["RAILWAY_TOKEN"], "fixture-private-token")
            self.assertNotIn("DATABASE_URL", options["environment"])
            self.assertNotIn("RAILWAY_API_TOKEN", options["environment"])

    def test_command_roundtrip_does_not_require_credentials_in_argv(self):
        self.assertEqual(m.owned_command([sys.executable, "-c", "import json,sys;print(json.dumps(json.load(sys.stdin)))"], b'{"value":1}'), {"value": 1})


if __name__ == "__main__": unittest.main()
