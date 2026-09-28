"""Failure-path checks using disposable CLI fixtures; no Docker daemon or network needed."""

import contextlib
import io
import json
import os
import subprocess
import tempfile
import textwrap
import time
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


class RegressionTests(unittest.TestCase):
	def setUp(self):
		self.temp = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.path = Path(self.temp.name)
		self.bin = self.path / "bin"
		self.bin.mkdir()
		self.env = {
			**os.environ,
			"PATH": f"{self.bin}:{os.environ['PATH']}",
			"CALLS": str(self.path / "calls.jsonl"),
			"STATE": str(self.path / "state.json"),
			"LOGS": str(self.path / "logs"),
			"IMAGE": "fixture",
			"BUILDER": "fixture-container-builder",
		}

	def tool(self, name, source):
		path = self.bin / name
		path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(source))
		path.chmod(0o755)

	def run_script(self, name, *args):
		return subprocess.run(
			["bash", str(ROOT / "scripts" / name), *args],
			env=self.env,
			capture_output=True,
			text=True,
			timeout=10,
		)

	def calls(self):
		return [json.loads(line) for line in (self.path / "calls.jsonl").read_text().splitlines()]

	def test_same_day_runs_and_retries_have_distinct_tags(self):
		self.tool("date", 'print("2026-09-28T12:00:00Z")')
		self.env["LINE"] = "version-16"
		build_tags = set()
		for run_id, attempt in (("100", "1"), ("100", "2"), ("101", "1")):
			self.env.update(GITHUB_RUN_ID=run_id, GITHUB_RUN_ATTEMPT=attempt)
			result = self.run_script("build-meta.sh")
			self.assertEqual(result.returncode, 0, result.stderr)
			tags = result.stdout.split("tags<<EOF\n", 1)[1].splitlines()[:-1]
			self.assertEqual(len(tags), 2)
			self.assertEqual(tags[0], "fixture:version-16")
			build_tags.add(tags[1])
		self.assertEqual(len(build_tags), 3)

	def test_tags_require_a_retry_identifier(self):
		self.env.update(LINE="version-16", GITHUB_RUN_ID="100")
		self.env.pop("GITHUB_RUN_ATTEMPT", None)
		result = self.run_script("build-meta.sh")
		self.assertNotEqual(result.returncode, 0)
		self.assertNotIn("tags<<EOF", result.stdout)

	def test_duplicate_lines_cannot_publish_the_same_run_tag_twice(self):
		self.tool("git", 'print("a" * 40 + "\\trefs/heads/version-16")')
		self.env.update(EVENT="push", LINES_INPUT="version-16 version-15 version-16")
		result = self.run_script("plan.sh")
		self.assertEqual(result.returncode, 0, result.stderr)
		outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
		rows = json.loads(outputs["matrix"])["include"]
		self.assertEqual([row["line"] for row in rows], ["version-16", "version-15"])
		self.assertEqual(outputs["count"], "2")

	def build_tools(self):
		self.tool("git", 'print("a" * 40 + "\\trefs/heads/version-16")')
		self.tool(
			"docker",
			"""
            import json, os, sys
            from pathlib import Path
            a = sys.argv[1:]
            with open(os.environ['CALLS'], 'a') as f:
                f.write(json.dumps(a) + '\\n')
            path = Path(os.environ['STATE'])
            state = json.loads(path.read_text()) if path.exists() else {
                'python': 'old', 'labels': {}, 'loads': 0,
            }
            if a[:2] == ['buildx', 'build']:
                # A container builder only replaces the engine's image when it exports to it.
                if '--load' in a:
                    state['python'] = 'new'
                    state['loads'] += 1
                    state['labels'] = dict(
                        a[i + 1].split('=', 1) for i, arg in enumerate(a) if arg == '--label'
                    )
                    path.write_text(json.dumps(state))
            elif a[:2] == ['run', '--rm']:
                if os.environ.get('METADATA_FAILURE') == '1':
                    print('metadata read failed', file=sys.stderr)
                    sys.exit(42)
                if os.environ.get('BAD_METADATA') == '1':
                    print('not JSON')
                elif os.environ.get('EMPTY_METADATA') == '1':
                    pass  # an empty info.json: cat and jq both succeed and print nothing
                else:
                    print(json.dumps({'versions': {'python': state['python']}, 'apps': {}, 'sites': {}}))
            elif a[:2] == ['image', 'inspect']:
                print('3000000000')
            else:
                sys.exit('unexpected docker command: ' + repr(a))
            """,
		)

	def test_custom_builder_replaces_old_image_with_current_labels(self):
		self.build_tools()
		result = self.run_script("build.sh", "version-16")
		self.assertEqual(result.returncode, 0, result.stderr)
		state = json.loads((self.path / "state.json").read_text())
		self.assertEqual(state["loads"], 2)
		self.assertEqual(state["labels"]["et.keffa.ci.python.version"], "new")

	def test_metadata_errors_stop_before_second_build(self):
		self.build_tools()
		for failure in ("METADATA_FAILURE", "BAD_METADATA", "EMPTY_METADATA"):
			with self.subTest(failure=failure):
				self.env[failure] = "1"
				(self.path / "calls.jsonl").write_text("")
				result = self.run_script("build.sh", "version-16")
				self.assertNotEqual(result.returncode, 0)
				builds = [a for a in self.calls() if a[:2] == ["buildx", "build"]]
				self.assertEqual(len(builds), 1)
				self.assertFalse(any(a[:2] == ["image", "inspect"] for a in self.calls()))
				del self.env[failure]

	def local_ci_tools(self):
		repo = self.path / "example"
		(repo / ".github/workflows").mkdir(parents=True)
		(repo / ".github/workflows/ci.yml").write_text(
			'env:\n  APP: example\n  DEPS: ""\n  SOFT_APPS: ""\n  SOFT_AXES: ""\n'
		)
		self.tool("git", "import pathlib, sys; pathlib.Path(sys.argv[-1]).mkdir(parents=True)")
		self.tool(
			"docker",
			"""
            import json, os, sys
            a = sys.argv[1:]
            with open(os.environ['CALLS'], 'a') as f:
                f.write(json.dumps(a) + '\\n')
            if 'find' in a:
                if os.environ.get('DISCOVERY_OUTPUT', '1') == '1':
                    print('example/test_sample.py')
                if os.environ.get('DISCOVERY_FAILURE') == '1':
                    print('find: example/private: Permission denied', file=sys.stderr)
                    sys.exit(1)
            elif a[0] == 'exec' and a[-2:] == ['cat', '/tmp/site']:
                print('frappe.localhost')
            elif a[0] == 'exec' and 'run-tests' in a[-1]:
                print('Ran 1 test\\nOK')
            """,
		)
		return str(repo)

	def test_failed_discovery_rejects_empty_and_partial_results(self):
		repo = self.local_ci_tools()
		self.env["DISCOVERY_FAILURE"] = "1"
		for output in ("0", "1"):
			with self.subTest(partial_output=output):
				self.env["DISCOVERY_OUTPUT"] = output
				(self.path / "calls.jsonl").write_text("")
				result = self.run_script("local-ci.sh", "fixture:version-16", repo)
				self.assertNotEqual(result.returncode, 0, result.stdout)
				self.assertIn("discover site tests", result.stdout)
				self.assertNotIn("PASSED", result.stdout)
				self.assertFalse(any(a[0] == "exec" and "run-tests" in a[-1] for a in self.calls()))
				log = next((self.path / "logs").glob("*.log")).read_text()
				self.assertIn("Permission denied", log)

	def test_successful_discovery_runs_tests_and_allows_no_tests(self):
		repo = self.local_ci_tools()
		for output, expected in (("1", "1 passed"), ("0", "0 passed")):
			with self.subTest(output=output):
				self.env["DISCOVERY_OUTPUT"] = output
				result = self.run_script("local-ci.sh", "fixture:version-16", repo)
				self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
				self.assertIn(expected, result.stdout)
				self.assertIn("PASSED", result.stdout)

	def runtime(self):
		helper = types.ModuleType("keffa_ci")
		path = ROOT / "rootfs/usr/local/bin/keffa-ci"
		exec(compile(path.read_text(), str(path), "exec"), helper.__dict__)
		self.tool("mariadb-admin", "import time; time.sleep(3)")
		self.enterContext(mock.patch.dict(os.environ, self.env))
		self.enterContext(mock.patch.object(helper, "port_open", return_value=True))
		return helper

	def test_unresponsive_database_probe_returns_false(self):
		helper = self.runtime()
		started = time.monotonic()
		self.assertFalse(helper.db_ready(timeout=0.1))
		self.assertLess(time.monotonic() - started, 1.5)

	def test_start_honors_remaining_deadline_during_probe(self):
		helper = self.runtime()
		helper.READY_TIMEOUT = 0.2
		self.enterContext(mock.patch.object(helper, "check_user"))
		self.enterContext(mock.patch.object(helper.os, "getuid", return_value=1001))
		self.enterContext(mock.patch.object(helper, "redis_ping", return_value=True))
		stderr = self.enterContext(contextlib.redirect_stderr(io.StringIO()))
		started = time.monotonic()
		with self.assertRaises(SystemExit) as error:
			helper.start()
		self.assertEqual(error.exception.code, 1)
		self.assertIn("services not ready", stderr.getvalue())
		self.assertLess(time.monotonic() - started, 1.5)

	def test_expired_deadline_skips_service_probes(self):
		helper = self.runtime()
		self.enterContext(mock.patch.object(helper.socket, "create_connection", side_effect=AssertionError))
		self.assertFalse(any(helper.status(deadline=time.monotonic() - 1).values()))


if __name__ == "__main__":
	unittest.main()
