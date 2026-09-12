"""Read-only Railway identity and database-cgroup adapters. No restart mutations."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import stat
import subprocess
import sys
import time
import urllib.parse

SPEC = importlib.util.spec_from_file_location("memory_trial", Path(__file__).with_name("postgres_memory_trial.py"))
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)
Error = trial.Error
PROJECT = "19eba29f-9229-4f8d-8b3c-44cbb839d656"
# Canonical source identities remain protected even if a caller omits them from its config.
PROTECTED = {
    "6ab95993-4fe7-4585-8aa5-4aac3492632e",  # Development
    "523aeabb-2d5f-4f8c-892d-2aa69dfa8390",  # Production
    "d48899ea-8ae6-4b46-9d5e-691bec1b91aa",  # Postgres
    "48ef3379-26b8-4082-bf93-60d32c267856",  # canonical Postgres volume
    "4dd19dd6-c815-4c0b-9767-44b0b8444e07",  # Gateway
    "135b442b-1053-461c-94e2-a3fde5c5892c",  # App View
    "824da360-63c0-4c41-b8ea-766c98abf4b1",  # Coordinator
    "d339689a-52a5-4371-a091-8aeb52b4711c",  # Projection Pool
    "420a1a6a-0936-4436-af56-46e4d32884e5",  # Ingress Controller
    "ec75da0b-43f1-43dc-9575-bcebd25693ff",  # Redis
    "cdb4dd6e-3855-48dc-a69b-38e374e5d790",  # Redis Dev
}
UUID = re.compile(r"[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}")


def uuid(value):
    if not isinstance(value, str) or not UUID.fullmatch(value):
        raise Error("Provider identity must be a canonical UUID")
    return value


def private_path(raw):
    path = Path(raw)
    if (not path.is_absolute() or path.is_symlink() or not path.is_file()
            or path.stat().st_uid != os.getuid() or stat.S_IMODE(path.stat().st_mode) & 0o077):
        raise Error("SSH identity must be an existing owner-only regular file")
    return path


def validate_config(config):
    trial.validate_config(config)
    target, runner = config["target"], config["runner"]
    if target["project_id"] != PROJECT or runner["project_id"] != PROJECT or runner["environment_id"] != target["environment_id"]:
        raise Error("Provider adapters require the explicitly isolated Social Wire project environment")
    identities = [target["environment_id"], target["service_id"], target["volume_id"], runner["service_id"]]
    reads = config["read_targets"]
    if not 1 <= len(reads) <= 8:
        raise Error("Bound isolated read services to 1–8")
    identities += [item["service_id"] for item in reads.values()]
    if any(uuid(value) in PROTECTED | set(config["protected_source_ids"]) for value in identities):
        raise Error("Provider adapter refuses a canonical source identity")
    if target["service_id"] == runner["service_id"]:
        raise Error("Runner cannot share the database service")
    for item in reads.values():
        parsed = urllib.parse.urlsplit(item["origin"])
        if (parsed.scheme != "http" or not re.fullmatch(r"tsw92-[a-z0-9-]+\.railway\.internal", parsed.hostname or "")
                or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/")
                or item["service_id"] in {target["service_id"], runner["service_id"]}):
            raise Error("Read origins must belong to separate isolated private application services")
    provider = config["provider"]
    if provider.get("railway_token_file"):
        private_path(provider["railway_token_file"])
        if provider.get("railway_token_kind") not in {"project", "account"}:
            raise Error("Explicit Railway token kind must be project or account")
    private_path(provider["ssh_identity_file"])
    directory = provider["remote_probe_directory"]
    if not re.fullmatch(r"/[A-Za-z0-9_/-]+", directory) or ".." in Path(directory).parts:
        raise Error("Remote probe directory must be an explicit absolute path")
    hashes = provider["probe_sha256"]
    if set(hashes) != {"postgres_memory_trial.py", "postgres_replay.py"} or any(not re.fullmatch(r"[a-f0-9]{64}", value) for value in hashes.values()):
        raise Error("Both remote read-only probe modules require reviewed hashes")
    if provider["module_sha256"] != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise Error("Provider adapter module differs from its reviewed hash")
    for key in ("railway_binary", "ssh_binary"):
        path = Path(provider[key])
        if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
            raise Error("Provider tools must be explicitly installed absolute executable paths")
    return config


def owned_command(argv, payload, timeout=12, environment=None):
    """Bound stdin/stdout/time and retire only the CLI/SSH process group we own."""
    if len(payload) > 65536:
        raise Error("Provider adapter request exceeds its byte bound")
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True, env=environment)
    output = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            os.set_blocking(process.stdin.fileno(), False)
            os.set_blocking(process.stdout.fileno(), False)
            if payload:
                selector.register(process.stdin, selectors.EVENT_WRITE)
            else:
                process.stdin.close()
            selector.register(process.stdout, selectors.EVENT_READ)
            sent = 0
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Error("Provider adapter command timed out")
                for key, _ in selector.select(remaining):
                    if key.fileobj is process.stdin:
                        sent += os.write(process.stdin.fileno(), payload[sent:])
                        if sent == len(payload):
                            selector.unregister(process.stdin); process.stdin.close()
                    else:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            selector.unregister(process.stdout)
                        output.extend(chunk)
                        if len(output) > 2 * 1024 * 1024:
                            raise Error("Provider adapter evidence exceeds its byte bound")
        process.wait(timeout=max(.01, deadline - time.monotonic()))
        if process.returncode:
            raise Error("Provider adapter command failed")
        try:
            return json.loads(output)
        except (ValueError, UnicodeError):
            raise Error("Provider adapter returned invalid JSON evidence") from None
    finally:
        # Also retire descendants if their direct parent has already exited.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        for stream in (process.stdin, process.stdout):
            if stream is not None:
                stream.close()


class Provider:
    def __init__(self, config, command=owned_command):
        self.config, self.command = config, command

    def query(self, document, variables):
        # The intended CLI authentication path uses its existing session/environment.
        # Never extract credentials or request variables, logs or deployment metadata.
        provider = self.config["provider"]
        environment = {key: os.environ[key] for key in ("HOME", "PATH", "LANG") if key in os.environ}
        if provider.get("railway_token_file"):
            token = private_path(provider["railway_token_file"]).read_text().strip()
            if not token or len(token) > 4096 or any(character.isspace() for character in token):
                raise Error("Externally supplied Railway token is malformed")
            name = "RAILWAY_TOKEN" if provider["railway_token_kind"] == "project" else "RAILWAY_API_TOKEN"
            environment[name] = token
        result = self.command([provider["railway_binary"], "api", document,
                               "--variables", json.dumps(variables), "--compact"], b"", environment=environment)
        if not isinstance(result, dict) or result.get("errors") or not isinstance(result.get("data"), dict):
            raise Error("Provider identity query failed")
        return result["data"]

    def identity(self, include_reads=True):
        config = self.config
        roles = {"database": config["target"]["service_id"], "runner": config["runner"]["service_id"]}
        if include_reads:
            roles.update({"read" + str(i): value["service_id"] for i, value in enumerate(config["read_targets"].values())})
        variables = {"environment": config["target"]["environment_id"], **roles}
        arguments = ",".join("$" + key + ":String!" for key in variables)
        services = " ".join(key + ":serviceInstance(environmentId:$environment,serviceId:$" + key + "){id environmentId serviceId serviceName region activeDeployments{id projectId environmentId serviceId status instances{id status}}}" for key in roles)
        document = "query(" + arguments + "){environment(id:$environment){id name projectId deletedAt volumeInstances(first:100){pageInfo{hasNextPage} edges{node{volumeId serviceId environmentId mountPath region state}}}} privateNetworks(environmentId:$environment){publicId projectId environmentId deletedAt dnsName} " + services + "}"
        data = self.query(document, variables)
        environment = data["environment"]
        if (environment["id"] != variables["environment"] or environment["projectId"] != PROJECT
                or environment.get("deletedAt") is not None or not re.fullmatch(r"tsw92-[a-z0-9-]+", environment["name"])):
            raise Error("Provider environment is not explicitly isolated")
        volumes = environment["volumeInstances"]
        if volumes["pageInfo"]["hasNextPage"]:
            raise Error("Provider volume inventory is truncated")
        matches = [edge["node"] for edge in volumes["edges"] if edge["node"]["volumeId"] == config["target"]["volume_id"]]
        if len(matches) != 1:
            raise Error("Provider target volume mapping is absent or ambiguous")
        volume = matches[0]
        if (volume["serviceId"] != roles["database"] or volume["environmentId"] != variables["environment"]
                or volume["region"] != "sfo" or volume["state"] != "READY" or volume["mountPath"] != "/var/lib/postgresql/data"):
            raise Error("Provider target volume is not ready on the isolated database")
        for role, service_id in roles.items():
            service = data[role]
            if (service["serviceId"] != service_id or service["environmentId"] != variables["environment"]
                    or not service["serviceName"].startswith("tsw92-")):
                raise Error("Provider service mapping differs from the isolated target")
            deployments = service["activeDeployments"]
            if len(deployments) != 1:
                raise Error("Each trial service needs exactly one active deployment")
            deployment = deployments[0]
            if (deployment["status"] != "SUCCESS" or deployment["projectId"] != PROJECT
                    or deployment["environmentId"] != variables["environment"] or deployment["serviceId"] != service_id
                    or len(deployment["instances"]) != 1 or deployment["instances"][0]["status"] != "RUNNING"):
                raise Error("Provider deployment identity is not one stable running instance")
            uuid(service["id"]); uuid(deployment["id"]); uuid(deployment["instances"][0]["id"])
        networks = [n for n in data["privateNetworks"] if n.get("deletedAt") is None]
        if len(networks) != 1 or networks[0]["projectId"] != PROJECT or networks[0]["environmentId"] != variables["environment"]:
            raise Error("Provider private network is absent or ambiguous")
        variables["network"] = uuid(networks[0]["publicId"])
        endpoints = " ".join(key + ":privateNetworkEndpoint(environmentId:$environment,privateNetworkId:$network,serviceId:$" + key + "){serviceInstanceId dnsName newDnsName deletedAt}" for key in roles)
        network_data = self.query("query(" + arguments + ",$network:String!){" + endpoints + "}", variables)
        hosts = {"database": config["target"]["host"]}
        if include_reads:
            hosts.update({"read" + str(i): urllib.parse.urlsplit(value["origin"]).hostname for i, value in enumerate(config["read_targets"].values())})
        for role, host in hosts.items():
            endpoint = network_data[role]
            if (not endpoint or endpoint["serviceInstanceId"] != data[role]["id"] or endpoint.get("deletedAt") is not None
                    or endpoint.get("newDnsName") not in (None, endpoint["dnsName"])
                    or endpoint["dnsName"] + "." + networks[0]["dnsName"] + ".internal" != host):
                raise Error("Provider private origin does not map to the named isolated service")
        return data

    def probe(self, identity):
        config, provider = self.config, self.config["provider"]
        deployment = identity["database"]["activeDeployments"][0]
        instance = identity["database"]["id"]
        # An independent remote deadline bounds work even after an SSH disconnect.
        # Probe modules are pre-provisioned; this command writes no files and resets no counters.
        program = """import hashlib,importlib.util,json,os,pathlib,sys
p=json.load(sys.stdin); c=p['config']; root=pathlib.Path(c['provider']['remote_probe_directory'])
for name,wanted in c['provider']['probe_sha256'].items():
 if hashlib.sha256((root/name).read_bytes()).hexdigest()!=wanted: raise RuntimeError('probe mismatch')
spec=importlib.util.spec_from_file_location('trial',root/'postgres_memory_trial.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
if os.environ.get('RAILWAY_DEPLOYMENT_ID')!=p['deployment']: raise RuntimeError('deployment mismatch')
print(json.dumps(m.sample(c,m.replay.Postgres(c.get('psql','psql')))))
"""
        remote = "timeout --signal=TERM --kill-after=1s 10s env PYTHONDONTWRITEBYTECODE=1 python3 -c " + shlex.quote(program)
        args = [provider["ssh_binary"], "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=2",
                "-o", "ServerAliveCountMax=2", "-i", provider["ssh_identity_file"], instance + "@ssh.railway.com", remote]
        result = self.command(args, json.dumps({"config": config, "deployment": deployment["id"]}).encode())
        expected = {key: config["target"][key] for key in trial.IDENTITIES}
        if (result["identity"] != expected or result["container_epoch"][0] != deployment["id"]
                or result["db"]["database"] != config["target"]["database"]
                or result["restore"]["snapshot_sha256"] != config["snapshot_sha256"]):
            raise Error("Remote probe does not match provider identity or restored snapshot")
        return result


def execute(mode, config, environment=os.environ, command=owned_command):
    if mode not in {"identity", "probe"}:
        raise Error("Restart has no verified provider termination/OOM evidence adapter")
    validate_config(config)
    if any(environment.get(trial.IDENTITIES[key]) != config["runner"][key] for key in ("project_id", "environment_id", "service_id")):
        raise Error("Execute adapters only inside the explicitly isolated runner")
    provider = Provider(config, command)
    identity = provider.identity(include_reads=mode == "identity")
    if environment.get("RAILWAY_DEPLOYMENT_ID") != identity["runner"]["activeDeployments"][0]["id"]:
        raise Error("Provider runner deployment differs from the executing container")
    probe = provider.probe(identity)
    if mode == "probe":
        return probe
    return {"target": config["target"], "runner": {key: config["runner"][key] for key in ("project_id", "environment_id", "service_id")},
            "read_targets": config["read_targets"], "snapshot_sha256": probe["restore"]["snapshot_sha256"]}


def main(mode):
    def stopped(_signal, _frame):
        raise Error("Provider adapter cancelled")
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    try:
        if json.loads(sys.stdin.buffer.read(65537)) != {}:
            raise Error("Read-only provider adapters accept only an empty request")
        config = json.loads(Path(os.environ["TSW92_TRIAL_CONFIG"]).read_text())
        print(json.dumps(execute(mode, config)))
    except BaseException:
        # Never print raw exceptions, provider errors, SQL, URLs or credentials.
        print("Read-only provider adapter failed; verify isolated identity, pinned probes and provider availability.", file=sys.stderr)
        return 1
    return 0
