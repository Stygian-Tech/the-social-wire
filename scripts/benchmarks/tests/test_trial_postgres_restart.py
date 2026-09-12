"""Synthetic receipt tests plus an opt-in, network-isolated owned Docker fixture."""
import copy
import hashlib
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import Mock, patch

from test_postgres_memory_trial import configuration, probe, m as trial

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import trial_restart_evidence as evidence
import trial_postgres_supervisor as supervisor


def receipt_fixture():
    config = configuration()
    config["restart"] = {"mode": evidence.MODE, "supervisor_sha256": "d" * 64}
    first, previous, current = probe(0), probe(1770), probe(1800, phase="recovery")
    for sample in (first, previous, current):
        sample.update(kernel_identity={"cgroup_device": 1, "cgroup_inode": 2, "boot_id": str(uuid.UUID(int=1)),
            "pid_namespace_inode": 3, "supervisor_start_ticks": 4, "supervisor_sha256": "d" * 64},
            provider_instance_id=str(uuid.UUID(int=2)), provider_service_instance_id=str(uuid.UUID(int=3)),
            postmaster_process=[10, 100], container_epoch=[str(uuid.UUID(int=9)), 2, str(uuid.UUID(int=1))])
    current["db"]["postmaster_started"] = "new-postmaster"
    current["postmaster_process"] = [20, 200]
    before = {**copy.deepcopy(previous), "time": 1771, "postmaster_started": "1", "database": config["target"]["database"], "system_identifier": "123"}
    after = {**copy.deepcopy(current), "time": 1790, "postmaster_started": "new-postmaster", "database": config["target"]["database"], "system_identifier": "123"}
    receipt = {"mode": evidence.MODE, "evidence_kind": evidence.KIND, "nonce": "f" * 32,
        "previous_container_epoch": previous["container_epoch"], "termination_reason": "operator_restart", "oom_killed": False,
        "child_exit_code": 0, "subtree_retired": True, "requested_at": 1772, "exited_at": 1780, "before": before, "after": after}
    current["restart_receipt"] = receipt
    return config, first, previous, current, receipt


class RestartEvidenceTests(unittest.TestCase):
    def test_explicit_round_accepts_one_clean_process_restart(self):
        config, first, previous, current, _ = receipt_fixture()
        state = trial.Round(config)
        state.expect_restart({"nonce": "f" * 32, "previous_container_epoch": previous["container_epoch"],
            "previous_postmaster_started": previous["db"]["postmaster_started"], "recorded_at": 1770.5,
            "target": config["target"], "snapshot_sha256": config["snapshot_sha256"]})
        state.accept(first)
        for t in range(30, 1771, 30):
            sample = copy.deepcopy(previous); sample["time"] = t
            sample["load"].update(interval_start=t-30, interval_end=t)
            state.accept(sample)
        state.accept(current)
        self.assertEqual(state.restart_count, 1)
        self.assertEqual(state.observed_seconds, 1770)

    def test_saved_samples_require_separately_recorded_request(self):
        config, first, previous, current, receipt = receipt_fixture()
        samples = []
        for t in range(0, 3631, 30):
            value = copy.deepcopy(first if t < 1800 else current)
            value.pop("restart_receipt", None)
            value["time"] = t
            value["load"].update(interval_start=t-30, interval_end=t,
                phase="burst" if 900 <= t <= 1230 else "recovery" if 1800 <= t <= 2430 else "mixed")
            if t == 1800: value["restart_receipt"] = receipt
            samples.append(value)
        request = {"nonce": "f" * 32, "previous_container_epoch": previous["container_epoch"],
            "previous_postmaster_started": previous["db"]["postmaster_started"], "recorded_at": 1770.5,
            "target": config["target"], "snapshot_sha256": config["snapshot_sha256"]}
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw)
            (path / "config").write_text(json.dumps(config))
            (path / "samples").write_text("".join(json.dumps(value)+"\n" for value in samples))
            (path / "request").write_text(json.dumps(request))
            argv = ["trial", "validate", str(path / "config"), "--samples", str(path / "samples"), "--restart-request", str(path / "request")]
            with patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()) as output:
                trial.main()
            self.assertEqual(json.loads(output.getvalue())["observed_seconds"], 3600)
            request["nonce"] = "0" * 32
            (path / "request").write_text(json.dumps(request))
            with patch.object(sys, "argv", argv), self.assertRaises(trial.Error): trial.main()
            with patch.object(sys, "argv", argv[:-2]), self.assertRaises(trial.Error): trial.main()

    def test_invalid_identity_nonce_oom_and_timestamps_fail_closed(self):
        cases = [
            lambda r: r.update(nonce="0" * 32),
            lambda r: r.update(child_exit_code=1),
            lambda r: r.update(child_exit_code=False),
            lambda r: r.update(subtree_retired=False),
            lambda r: r.update(exited_at=1801),
            lambda r: r["after"].update(container_epoch=[2]),
            lambda r: r["after"]["kernel_identity"].update(supervisor_start_ticks=900),
            lambda r: r["after"].update(provider_instance_id=str(uuid.UUID(int=5))),
            lambda r: r["after"]["restore"].update(restore_epoch="other"),
            lambda r: r["before"]["memory_events"].update(oom=1),
            lambda r: r["after"]["memory_events"].pop("oom_kill"),
            lambda r: r["after"]["memory_events"].update(oom_group_kill=0),
            lambda r: r["after"].update(postmaster_process=[10,100]),
            lambda r: r["after"].update(system_identifier="other"),
        ]
        for mutate in cases:
            config, _, previous, current, receipt = receipt_fixture()
            mutate(receipt)
            with self.subTest(mutate=mutate), self.assertRaises((ValueError, KeyError)):
                evidence.validate_receipt(config, receipt, previous, current, "f" * 32)

    def test_container_loss_cannot_use_retained_kernel_receipt(self):
        config, first, previous, current, _ = receipt_fixture()
        state = trial.Round(config); state.first = first; state.last = previous; state.restart_nonce = "f" * 32
        current["container_epoch"] = [2]
        with self.assertRaises(trial.Error): state.accept(current)
        config.pop("restart")
        state = trial.Round(config); state.first = first; state.last = previous
        with self.assertRaises(trial.Error): state.accept(current)

    def test_supervisor_rejects_stale_request_without_signalling(self):
        config, _, _, _, receipt = receipt_fixture()
        instance = supervisor.Supervisor(config); instance.child = Mock(); instance.child.poll.return_value = None
        with patch.object(supervisor, "observe", return_value=receipt["before"]):
            with self.assertRaises(ValueError):
                instance.restart({"nonce": "a" * 32, "previous_container_epoch": [999], "previous_postmaster_started": "1"})
        instance.child.send_signal.assert_not_called()
        self.assertFalse(instance.used)

    def test_pid1_reports_failed_final_subtree_exit(self):
        for child_code in (0, 1):
            instance = Mock(); instance.run.side_effect = supervisor.SupervisorTermination()
            instance.child.poll.return_value = child_code
            instance.child.wait.return_value = child_code
            with patch.object(supervisor, "config_from_environment", return_value={}), patch.object(supervisor, "Supervisor", return_value=instance), patch.object(supervisor.signal, "signal"):
                self.assertEqual(supervisor.main(), child_code)
            instance.child.send_signal.assert_not_called()

    def test_hung_child_does_not_launch_replacement(self):
        config, _, _, _, receipt = receipt_fixture()
        instance = supervisor.Supervisor(config); instance.child = Mock()
        instance.child.poll.return_value = None
        instance.child.wait.side_effect = subprocess.TimeoutExpired("owned-fixture", .1)
        request = {"nonce": "f" * 32, "previous_container_epoch": receipt["before"]["container_epoch"],
            "previous_postmaster_started": receipt["before"]["postmaster_started"],
            "provider_instance_id": receipt["before"]["provider_instance_id"],
            "provider_service_instance_id": receipt["before"]["provider_service_instance_id"]}
        with patch.object(supervisor, "observe", return_value=receipt["before"]), patch.object(instance, "launch") as launch:
            with self.assertRaises(ValueError): instance.restart(request)
            launch.assert_not_called()
        self.assertTrue(instance.used)
        instance.child.send_signal.assert_called_once_with(supervisor.signal.SIGTERM)


@unittest.skipUnless(os.environ.get("TSW_RESTART_TEST_IMAGE"), "Requires an explicitly built trial-only local image")
class PostgresProcessRestartTests(unittest.TestCase):
    def test_guardian_retires_adopted_setsid_helper_and_leaves_sibling_alive(self):
        helper = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path('/run/detached.pid').write_text(str(os.getpid()));time.sleep(120)"
        child = "import subprocess,sys,time,signal;signal.signal(signal.SIGTERM,lambda *_:sys.exit(0));subprocess.Popen([sys.executable,'-c'," + repr(helper) + "],start_new_session=True);time.sleep(120)"
        guardian = "import sys;sys.path.insert(0,'/benchmark');import trial_postgres_supervisor as s;sys.exit(s.guardian([sys.executable,'-c'," + repr(child) + "]))"
        controller = """import os,signal,subprocess,sys,time
from pathlib import Path
sibling=subprocess.Popen(['sleep','120'])
owned=subprocess.Popen([sys.executable,'-c',%r])
try:
 deadline=time.monotonic()+5
 while not Path('/run/detached.pid').exists():
  assert time.monotonic()<deadline;time.sleep(.02)
 helper=int(Path('/run/detached.pid').read_text())
 owned.send_signal(signal.SIGTERM)
 assert owned.wait(timeout=10)==0
 assert sibling.poll() is None
 try: os.kill(helper,0)
 except ProcessLookupError: pass
 else: raise AssertionError('detached owned helper survived')
 print('PASS: detached helper retired; unrelated sibling alive')
finally:
 sibling.terminate();sibling.wait(timeout=3)
 if owned.poll() is None: owned.kill();owned.wait(timeout=3)
""" % guardian
        name = "tsw92-guardian-test-" + uuid.uuid4().hex[:12]
        try:
            result = subprocess.run(["docker", "run", "--name", name, "--network", "none", "--entrypoint", "python3",
                os.environ["TSW_RESTART_TEST_IMAGE"], "-c", controller], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr[-1000:])
            self.assertIn("detached helper retired", result.stdout)
        finally:
            subprocess.run(["docker", "rm", "-fv", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)

    def test_clean_restart_preserves_container_and_sentinels(self):
        self.run_postgres_case("unexpected")

    def test_pid1_term_during_partial_request_still_cleans_database(self):
        self.run_postgres_case("partial_control")

    def run_postgres_case(self, termination):
        name = "tsw92-process-restart-test-" + uuid.uuid4().hex[:12]
        def docker(*args, input=None, timeout=30):
            return subprocess.run(["docker", *args], input=input, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=timeout, check=True).stdout.strip()
        config = configuration(8_000_000_000)
        config["target"]["project_id"] = supervisor.provider.PROJECT
        config["restart"] = {"mode": evidence.MODE,
            "supervisor_sha256": hashlib.sha256((ROOT / "trial_postgres_supervisor.py").read_bytes()).hexdigest(),
            "evidence_sha256": hashlib.sha256((ROOT / "trial_restart_evidence.py").read_bytes()).hexdigest()}
        config["restart_grace_seconds"] = 30
        deployment = str(uuid.uuid4())
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / "config.json").write_text(json.dumps(config))
            (directory / "snapshot.json").write_text(json.dumps(probe()["restore"]))
            args = ["run", "-d", "--name", name, "--network", "none", "--memory", "8000000000",
                "--mount", f"type=bind,source={directory},target=/test,readonly", "-e", "TSW92_TRIAL_CONFIG=/run/config.json",
                "-e", "PGDATA=/var/lib/postgresql/data/pgdata", "-e", "POSTGRES_HOST_AUTH_METHOD=trust",
                "-e", "POSTGRES_DB=" + config["target"]["database"], "-e", "POSTGRES_USER=postgres",
                "-e", "RAILWAY_DEPLOYMENT_ID=" + deployment, "-e", "RAILWAY_VOLUME_MOUNT_PATH=/var/lib/postgresql/data"]
            for key, env in trial.IDENTITIES.items(): args += ["-e", env + "=" + config["target"][key]]
            args += ["--entrypoint", "sh", os.environ["TSW_RESTART_TEST_IMAGE"], "-c",
                "mkdir -p /var/lib/postgresql/data && cp /test/config.json /run/config.json && chmod 600 /run/config.json && cp /test/snapshot.json /var/lib/postgresql/data/memory-trial-snapshot.json && exec python3 /benchmark/trial_postgres_supervisor.py"]
            try:
                docker(*args)
                observe = "import sys,json;sys.path.insert(0,'/benchmark');import trial_postgres_supervisor as s;print(json.dumps(s.observe(json.load(open('/run/config.json')))))"
                for _ in range(120):
                    try:
                        before = json.loads(docker("exec", name, "python3", "-c", observe)); break
                    except subprocess.CalledProcessError:
                        if docker("inspect", name, "--format", "{{.State.Running}}") != "true":
                            output = subprocess.run(["docker", "logs", name], capture_output=True, text=True, timeout=5)
                            self.fail("Trial fixture exited: " + (output.stdout + output.stderr)[-1500:])
                        time.sleep(.25)
                else:
                    output = subprocess.run(["docker", "logs", name], capture_output=True, text=True, timeout=5)
                    self.fail("Trial fixture did not become ready: " + (output.stdout + output.stderr)[-1500:])
                def sql(text):
                    return docker("exec", name, "gosu", "postgres", "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-d", config["target"]["database"], "-c", text)
                sql("CREATE UNLOGGED TABLE restart_inbox(id int primary key); INSERT INTO restart_inbox SELECT generate_series(1,1000); CREATE TABLE restart_durable(id int primary key); INSERT INTO restart_durable VALUES(1)")
                sql("ALTER SYSTEM SET checkpoint_timeout='15min'")
                docker("exec", "-d", name, "gosu", "postgres", "psql", "-d", config["target"]["database"], "-c", "BEGIN; INSERT INTO restart_durable VALUES(2); SELECT pg_sleep(120); COMMIT")
                for _ in range(50):
                    if sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'") == "1": break
                    time.sleep(.05)
                self.assertEqual(sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'"), "1")
                # A sibling exec is outside the guardian and must survive subtree retirement.
                unrelated = int(docker("exec", "-d", name, "sh", "-c", "echo $$ >/run/unrelated.pid; exec sleep 120") or "0")
                unrelated = int(docker("exec", name, "cat", "/run/unrelated.pid"))
                for payload in (b"", b"{", b"not-json\n", b"[]\n"):
                    disconnect = "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect('/run/tsw92-postgres-restart/control.sock');s.sendall(sys.stdin.buffer.read());s.close()"
                    docker("exec", "-i", name, "python3", "-c", disconnect, input=payload.decode())
                    self.assertEqual(json.loads(docker("exec", name, "python3", "-c", observe))["postmaster_process"], before["postmaster_process"])
                request = {"nonce": uuid.uuid4().hex, "previous_container_epoch": before["container_epoch"],
                    "previous_postmaster_started": before["postmaster_started"],
                    "provider_instance_id": str(uuid.uuid4()), "provider_service_instance_id": str(uuid.uuid4())}
                client = "import socket,json,sys;s=socket.socket(socket.AF_UNIX);s.settimeout(30);s.connect('/run/tsw92-postgres-restart/control.sock');s.sendall(sys.stdin.buffer.read()+b'\\n');data=bytearray();\nwhile b'\\n' not in data:data.extend(s.recv(65536))\nprint(data.decode());s.close()"
                receipt = json.loads(docker("exec", "-i", name, "python3", "-c", client, input=json.dumps(request)))
                after = json.loads(docker("exec", name, "python3", "-c", observe))
                for sample in (before, after):
                    sample.update({key: request[key] for key in ("provider_instance_id", "provider_service_instance_id")})
                    sample["db"] = {"postmaster_started": sample["postmaster_started"]}
                evidence.validate_receipt(config, receipt, before, after, request["nonce"])
                self.assertEqual(sql("SELECT count(*) FROM restart_inbox"), "1000")
                self.assertEqual(sql("SELECT array_agg(id ORDER BY id) FROM restart_durable"), "{1}")
                self.assertEqual(sql("SHOW checkpoint_timeout"), "15min")
                docker("exec", name, "kill", "-0", str(unrelated))
                duplicate = json.loads(docker("exec", "-i", name, "python3", "-c", client, input=json.dumps(request)))
                self.assertIn("error", duplicate)
                self.assertEqual(json.loads(docker("exec", name, "python3", "-c", observe))["postmaster_process"], after["postmaster_process"])
                if termination == "unexpected":
                    # Real unrequested clean exit must fail PID1, without auto-restart.
                    docker("exec", name, "gosu", "postgres", "pg_ctl", "-D", "/var/lib/postgresql/data/pgdata", "-m", "fast", "-w", "stop")
                    self.assertEqual(docker("wait", name), "1")
                else:
                    partial = "import socket,time;from pathlib import Path;s=socket.socket(socket.AF_UNIX);s.connect('/run/tsw92-postgres-restart/control.sock');s.sendall(b'{');Path('/run/partial-open').touch();time.sleep(30)"
                    docker("exec", "-d", name, "python3", "-c", partial)
                    for _ in range(30):
                        try: docker("exec", name, "test", "-f", "/run/partial-open"); break
                        except subprocess.CalledProcessError: time.sleep(.02)
                    docker("stop", "--signal", "TERM", "--timeout", "10", name)
                    self.assertEqual(docker("inspect", name, "--format", "{{.State.ExitCode}}"), "0")
            finally:
                subprocess.run(["docker", "rm", "-fv", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
