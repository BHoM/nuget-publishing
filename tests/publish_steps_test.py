"""Tests for the inline shell of two steps of publish-nuget.yml's publish job.

Each step is read from the workflow and run under bash. The Push step runs with stub dotnet and curl
first on PATH, so nothing reaches the network; the stub dotnet records every NuGet.Config or global.json
it could read from its working folder upwards that carries the planted marker. The step that refuses a
re-run from an earlier day runs with a planted attempt number and planned day.
"""
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASH = shutil.which("bash")
VERSION = "10.1.0-alpha.1.0"

STUB_DOTNET = """#!/usr/bin/env bash
d="$PWD"
while :; do
  for n in NuGet.Config nuget.config NuGet.config global.json; do
    if [ -f "$d/$n" ] && grep -q PLANTED "$d/$n"; then echo "SAW $d/$n" >> "$STUB_LOG"; fi
  done
  p=$(dirname "$d"); [ "$p" = "$d" ] && break; d="$p"
done
echo "DOTNET $*" >> "$STUB_LOG"
for a in "$@"; do case "$a" in *.nupkg) [ -f "$a" ] || { echo "MISSING $a" >> "$STUB_LOG"; exit 1; } ;; esac; done
"""

STUB_CURL = """#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && echo '{"versions":[]}' > "$out"
printf 404
"""


RERUN_STEP = "Refuse a re-run from an earlier day"


def publish_steps():
    with open(os.path.join(ROOT, ".github", "workflows", "publish-nuget.yml"), encoding="utf-8") as f:
        return yaml.safe_load(f)["jobs"]["publish"]["steps"]


def publish_step(name):
    steps = [s for s in publish_steps() if s.get("name") == name]
    assert len(steps) == 1, f"publish job has no single step named {name}"
    return steps[0]["run"]


def push_step():
    return publish_step("Push")


@unittest.skipUnless(BASH, "needs bash")
class RerunStepTests(unittest.TestCase):
    TODAY = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")

    def run_step(self, attempt, planned_on):
        env = dict(os.environ)
        env.pop("GITHUB_RUN_ATTEMPT", None)
        if attempt is not None:
            env["GITHUB_RUN_ATTEMPT"] = attempt
        env["PLANNED_ON"] = planned_on
        return subprocess.run([BASH, "--noprofile", "--norc", "-c", publish_step(RERUN_STEP)], env=env,
                              capture_output=True, text=True)

    def test_step_is_the_first_of_the_publish_job(self):
        self.assertEqual(publish_steps()[0].get("name"), RERUN_STEP)

    def test_first_attempt_runs_even_when_approved_on_a_later_day(self):
        for planned_on in (self.TODAY, "2001-01-01"):
            with self.subTest(planned_on=planned_on):
                proc = self.run_step("1", planned_on)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_rerun_on_the_day_it_was_planned_runs(self):
        proc = self.run_step("2", self.TODAY)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_rerun_on_a_later_day_is_refused(self):
        for attempt, planned_on in (("2", "2001-01-01"), ("3", "2001-01-01"), ("2", ""), (None, self.TODAY)):
            with self.subTest(attempt=attempt, planned_on=planned_on):
                proc = self.run_step(attempt, planned_on)
                self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)


@unittest.skipUnless(BASH and shutil.which("jq") and shutil.which("sha256sum", path=os.path.dirname(BASH) + os.pathsep + os.environ.get("PATH", "")),
                     "needs bash, jq and sha256sum")
class PushStepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="push-step-test-")
        self.runner_temp = os.path.join(self.tmp, "runner-temp")
        self.stubs = os.path.join(self.tmp, "stubs")
        self.workspace = os.path.join(self.tmp, "workspace")
        release = os.path.join(self.runner_temp, "release")
        pkg_dir = os.path.join(release, VERSION, "packages")
        for d in (pkg_dir, self.stubs, self.workspace):
            os.makedirs(d)
        data = b"not really a package"
        rel = f"{VERSION}/packages/BHoM.{VERSION}.nupkg"
        with open(os.path.join(release, rel), "wb") as f:
            f.write(data)
        for planted in (os.path.join(release, "NuGet.Config"), os.path.join(release, "global.json"),
                        os.path.join(release, VERSION, "nuget.config")):
            with open(planted, "w", encoding="utf-8", newline="\n") as f:
                f.write("PLANTED\n")
        for name, text in (("dotnet", STUB_DOTNET), ("curl", STUB_CURL)):
            path = os.path.join(self.stubs, name)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            os.chmod(path, 0o755)
        self.log = os.path.join(self.tmp, "stub.log")
        open(self.log, "w").close()
        self.to_publish = json.dumps([{"version": VERSION, "id": "BHoM", "file": rel, "sha256": hashlib.sha256(data).hexdigest()}])

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_step(self, rehearsal):
        env = dict(os.environ)
        env.update({
            "PATH": self.stubs + os.pathsep + env.get("PATH", ""),
            "RUNNER_TEMP": self.runner_temp.replace("\\", "/"),
            "GITHUB_OUTPUT": os.path.join(self.tmp, "output.txt").replace("\\", "/"),
            "STUB_LOG": self.log.replace("\\", "/"),
            "TO_PUBLISH": self.to_publish,
            "REHEARSAL": rehearsal,
            "NUGET_API_KEY": "not-a-key",
        })
        proc = subprocess.run([BASH, "--noprofile", "--norc", "-c", push_step()], cwd=self.workspace, env=env,
                              capture_output=True, text=True)
        with open(self.log, encoding="utf-8") as f:
            log = f.read().splitlines()
        return proc, log

    def assert_pushed_from_outside_the_artifact(self, rehearsal):
        proc, log = self.run_step(rehearsal)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len([line for line in log if line.startswith("DOTNET nuget push")]), 1, "\n".join(log))
        self.assertEqual([line for line in log if line.startswith(("SAW", "MISSING"))], [], "\n".join(log))

    def test_publish_push_does_not_read_config_from_the_artifact(self):
        self.assert_pushed_from_outside_the_artifact("false")

    def test_rehearsal_push_does_not_read_config_from_the_artifact(self):
        self.assert_pushed_from_outside_the_artifact("true")

    def test_rehearsal_value_other_than_true_or_false_pushes_nothing(self):
        for value in ("", "True", "yes"):
            with self.subTest(rehearsal=value):
                open(self.log, "w").close()
                proc, log = self.run_step(value)
                self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual([line for line in log if line.startswith("DOTNET")], [], "\n".join(log))


CHECK_STEP = "Check files against the validated list"
BETA = "10.1.0-beta.0"


@unittest.skipUnless(BASH and shutil.which("jq") and shutil.which("unzip", path=os.path.dirname(BASH) + os.pathsep + os.environ.get("PATH", "")),
                     "needs bash, jq, sha256sum and unzip")
class CheckStepTests(unittest.TestCase):
    """The step must stop on a listed version that plan did not choose, a beta in a run without approval,
    or a package whose own nuspec carries another version, whatever validate's list says."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="check-step-test-")
        self.release = os.path.join(self.tmp, "release")
        self.stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(self.release)
        os.makedirs(self.stubs)
        if os.name == "nt":
            # jq built for Windows ends its lines with CRLF; the runner's does not.
            path = os.path.join(self.stubs, "jq")
            real = shutil.which("jq").replace("\\", "/")
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(f"#!/usr/bin/env bash\nset -o pipefail\n\"{real}\" \"$@\" | tr -d '\\r'\n")
            os.chmod(path, 0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def package(self, version, nuspec_version=None, nuspec_name="BHoM.nuspec", extra=""):
        rel = f"{version}/packages/BHoM.{version}.nupkg"
        path = os.path.join(self.release, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        nuspec = (f'<?xml version="1.0" encoding="utf-8"?>\n<package><metadata>{extra}<id>BHoM</id>'
                  f'<version>{nuspec_version or version}</version></metadata></package>\n')
        with zipfile.ZipFile(path, "w") as z:
            z.writestr(nuspec_name, nuspec)
            z.writestr("lib/net472/BHoM.dll", "not really an assembly")
        with open(path, "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        return {"version": version, "id": "BHoM", "file": rel, "sha256": sha}

    def run_step(self, listed, events, approval):
        env = dict(os.environ)
        env.update({
            "PATH": self.stubs + os.pathsep + env.get("PATH", ""),
            "RUNNER_TEMP": self.tmp.replace("\\", "/"),
            "TO_PUBLISH": json.dumps(listed),
            "EVENTS": json.dumps([{"version": v} for v in events]),
            "APPROVAL": approval,
        })
        return subprocess.run([BASH, "--noprofile", "--norc", "-c", publish_step(CHECK_STEP)], env=env,
                              capture_output=True, text=True)

    def assert_passes(self, *args):
        proc = self.run_step(*args)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def assert_stops(self, message, *args):
        proc = self.run_step(*args)
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(message, proc.stdout)

    def test_planned_alpha_without_approval_passes(self):
        self.assert_passes([self.package(VERSION)], [VERSION], "false")

    def test_planned_beta_with_approval_passes(self):
        self.assert_passes([self.package(VERSION), self.package(BETA)], [VERSION, BETA], "true")

    def test_unplanned_version_stops(self):
        self.assert_stops("not one of this run's events", [self.package("10.1.0-alpha.2.0")], [VERSION], "false")

    def test_beta_in_a_run_without_approval_stops(self):
        self.assert_stops("not an alpha", [self.package(BETA)], [VERSION, BETA], "false")

    def test_nuspec_version_differs_from_the_list_stops(self):
        listed = self.package(VERSION, nuspec_version=BETA)
        self.assert_stops("does not have version", [listed], [VERSION, BETA], "true")

    def test_second_version_element_stops(self):
        listed = self.package(VERSION, extra=f"<!-- <version>{BETA}</version> -->")
        self.assert_stops("does not have version", [listed], [VERSION], "false")

    def test_nuspec_not_at_the_root_stops(self):
        listed = self.package(VERSION, nuspec_name="sub/BHoM.nuspec")
        self.assert_stops("does not have version", [listed], [VERSION], "false")


if __name__ == "__main__":
    unittest.main()
