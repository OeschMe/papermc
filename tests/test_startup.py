"""Hermetic startup contract tests: fake curl/java, real Bash/jq/flock, no server."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = b"verified fixture jar"
SHA = hashlib.sha256(PAYLOAD).hexdigest()


def build(number=100, channel="STABLE", checksum=SHA, url=None):
    return {"id": number, "channel": channel, "downloads": {"server:default": {
        "url": url or f"https://fill-data.papermc.io/v1/objects/{SHA}/paper.jar",
        "checksums": {"sha256": checksum}}}}


CURL = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
url=args[-1]
with open(os.environ['FAKE_REQUESTS'], 'a') as log:
    log.write(url+'\n')
fixtures=json.loads(pathlib.Path(os.environ['FAKE_FIXTURES']).read_text())
if '-o' in args:
    if fixtures.get('download_failure'):
        sys.exit(22)
    pathlib.Path(args[args.index('-o')+1]).write_bytes(fixtures.get('artifact', 'verified fixture jar').encode())
else:
    suffix=url.removeprefix('https://fill.papermc.io/v3/projects/paper')
    if suffix not in fixtures:
        sys.exit(22)
    print(json.dumps(fixtures[suffix]))
"""
JAVA = r"""#!/usr/bin/env python3
import json,os,pathlib,sys,time
pathlib.Path('java.json').write_text(json.dumps({'args':sys.argv[1:],'cwd':os.getcwd()}))
time.sleep(float(os.environ.get('FAKE_JAVA_SLEEP','0')))
"""


class Startup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="papermc-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data with spaces"
        self.data.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, content in (("curl", CURL), ("java", JAVA)):
            file = self.bin / name
            file.write_text(content)
            file.chmod(0o755)
        self.fixture_file = self.root / "fixtures.json"
        self.requests = self.root / "requests.log"
        self.fixtures = {"/versions/1.21.11/builds": [build()]}
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        EULA="true", MC_VERSION="1.21.11", PAPER_BUILD="100",
                        PAPER_CHANNEL="STABLE", PAPER_PROJECT="paper", PAPER_OFFLINE="false",
                        PAPER_DATA_DIR=str(self.data), JAVA_OPTS="", MC_RAM="", MC_RAM_MIN="",
                        FAKE_REQUESTS=str(self.requests), FAKE_FIXTURES=str(self.fixture_file))

    def run_server(self, ok=True, **env):
        self.fixture_file.write_text(json.dumps(self.fixtures))
        result = subprocess.run(["bash", str(ROOT/"paper.sh")], env=dict(self.env, **env),
                                capture_output=True, text=True, timeout=10, cwd=self.root)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def jar(self, build_id="100"):
        return self.data / f"paper-1.21.11-{build_id}.jar"

    def test_exact_pin_downloads_and_starts_with_correct_args(self):
        self.run_server(MC_RAM="4G", MC_RAM_MIN="1G", JAVA_OPTS="-Dtest=yes -XX:+UseG1GC")
        self.assertEqual(self.jar().read_bytes(), PAYLOAD)
        self.assertEqual((self.data/"eula.txt").read_text(), "eula=true\n")
        args=json.loads((self.data/"java.json").read_text())["args"]
        self.assertEqual(args, ["-server","-Xms1G","-Xmx4G","-Dtest=yes","-XX:+UseG1GC",
                                "-jar","paper-1.21.11-100.jar","--nogui"])

    def test_explicit_mc_latest_never_crosses_versions(self):
        self.fixtures["/versions/1.21.11/builds"]=[build(channel="EXPERIMENTAL")]
        self.run_server(ok=False, PAPER_BUILD="latest")
        self.assertEqual(self.requests.read_text().splitlines(),
                         ["https://fill.papermc.io/v3/projects/paper/versions/1.21.11/builds"])
        self.assertFalse((self.data/"java.json").exists())

    def test_exact_build_channel_mismatch_fails(self):
        self.fixtures["/versions/1.21.11/builds"]=[build(channel="EXPERIMENTAL")]
        self.run_server(ok=False)
        self.run_server(PAPER_CHANNEL="EXPERIMENTAL")

    def test_latest_build_is_numeric_not_response_order(self):
        self.fixtures["/versions/1.21.11/builds"]=[build(9), build(101), build(99)]
        self.run_server(PAPER_BUILD="latest")
        self.assertTrue(self.jar("101").exists())

    def test_latest_mc_selects_available_stable_without_relying_on_key_order(self):
        self.fixtures.update({"":{"versions":{"1.20":["1.20.6"],"26.3":["26.3","26.3-rc-1"]}},
                              "/versions/26.3-rc-1/builds": [build(10,"EXPERIMENTAL")],
                              "/versions/26.3/builds":[build(200)]})
        self.run_server(MC_VERSION="latest", PAPER_BUILD="latest")
        self.assertTrue((self.data/"paper-26.3-200.jar").exists())

    def test_failed_download_preserves_all_existing_jars(self):
        self.jar().write_bytes(b"old known jar")
        other=self.data/"unrelated.jar"
        other.write_bytes(b"keep me")
        self.fixtures["download_failure"]=True
        self.run_server(ok=False)
        self.assertEqual(self.jar().read_bytes(), b"old known jar")
        self.assertEqual(other.read_bytes(), b"keep me")
        self.assertEqual(list(self.data.glob('.paper-download.*')), [])

    def test_bad_checksum_preserves_existing_target(self):
        self.jar().write_bytes(b"old")
        self.fixtures["artifact"]="corrupt"
        self.run_server(ok=False)
        self.assertEqual(self.jar().read_bytes(), b"old")
        self.assertFalse((self.data/"java.json").exists())
        self.assertEqual(list(self.data.glob('.paper-download.*')), [])

    def test_missing_checksum_and_wrong_host_fail_before_download(self):
        for item in (build(checksum=""), build(url="https://example.invalid/server.jar")):
            self.fixtures["/versions/1.21.11/builds"]=[item]
            self.run_server(ok=False)
            self.assertFalse(self.jar().exists())

    def test_matching_cache_avoids_redownload_but_checks_api(self):
        self.run_server()
        self.requests.write_text("")
        self.run_server()
        self.assertEqual(len(self.requests.read_text().splitlines()),1)

    def test_offline_cache_needs_no_network_and_checks_hash_and_channel(self):
        self.run_server()
        self.requests.write_text("")
        self.run_server(PAPER_OFFLINE="true")
        self.assertEqual(self.requests.read_text(), "")
        self.run_server(ok=False, PAPER_OFFLINE="true", PAPER_CHANNEL="EXPERIMENTAL")
        self.jar().write_bytes(b"changed")
        self.run_server(ok=False, PAPER_OFFLINE="true")
        self.assertEqual(self.requests.read_text(), "")

    def test_offline_requires_exact_pins_and_known_metadata(self):
        self.run_server(ok=False, PAPER_OFFLINE="true")
        self.run_server(ok=False, PAPER_OFFLINE="true", PAPER_BUILD="latest")
        self.assertFalse(self.requests.exists())

    def test_bad_configuration_rejected_before_network(self):
        for values in ({"EULA":"false"}, {"MC_VERSION":"../other"}, {"PAPER_BUILD":"100;id"},
                       {"MC_RAM":"4G -agentlib:bad"}, {"PAPER_DATA_DIR":"relative"},
                       {"MC_VERSION":"latest","PAPER_BUILD":"100"},
                       {"PAPER_OFFLINE":"maybe"}, {"PAPER_UA":"bad\nheader"}):
            self.run_server(ok=False, **values)
        self.assertFalse(self.requests.exists())

    def test_symlink_target_is_not_overwritten(self):
        protected=self.root/"protected.jar"
        protected.write_bytes(b"protected")
        self.jar().symlink_to(protected)
        self.run_server(ok=False)
        self.assertEqual(protected.read_bytes(),b"protected")

    def test_bad_api_json_or_error_cannot_become_empty_success(self):
        for response in ({"ok":False,"message":"failure"}, {"unexpected":[]}, [None]):
            self.fixtures["/versions/1.21.11/builds"]=response
            self.run_server(ok=False)
            self.assertFalse((self.data/"java.json").exists())

    def test_wrapped_build_responses(self):
        for key in ("builds","data"):
            self.fixtures["/versions/1.21.11/builds"]={key:[build()]}
            self.run_server()

    def test_min_ram_is_ignored_without_max_ram(self):
        self.run_server(MC_RAM_MIN="1G")
        args=json.loads((self.data/"java.json").read_text())["args"]
        self.assertNotIn("-Xms1G",args)

    def test_java_options_are_not_shell_evaluated(self):
        self.run_server(JAVA_OPTS="$(touch BAD) *.jar")
        self.assertFalse((self.data/"BAD").exists())
        args=json.loads((self.data/"java.json").read_text())["args"]
        self.assertIn("*.jar",args)

    def test_data_lock_remains_held_by_running_java(self):
        self.fixture_file.write_text(json.dumps(self.fixtures))
        process=subprocess.Popen(["bash",str(ROOT/"paper.sh")],env=dict(self.env,FAKE_JAVA_SLEEP="20"),
                                 stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+8
            while not (self.data/"java.json").exists() and time.monotonic()<deadline:
                if process.poll() is not None:
                    self.fail(process.stderr.read())
                time.sleep(0.02)
            self.assertTrue((self.data/"java.json").exists())
            self.assertIn("Another server",self.run_server(ok=False).stderr)
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
