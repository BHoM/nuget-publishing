"""Checks the repository against the publishing policy.

Usage: python Test-Policy.py [--root DIR]

Prints one line per breach, tagged with its rule, and exits 1 if there is any. Rules:

  triggers      publish-nuget.yml and watch.yml run on schedule and workflow_dispatch only, pr-checks.yml
                on pull_request only; no pull_request_target anywhere; no other workflow file
  id-token      id-token: write only on job publish of publish-nuget.yml, never at workflow level
  environment   an environment only on that job, and it is the one expression that chooses nuget-org-auto
                for a run of alphas only and nuget-org, which requires approval, for anything else
  uses          every uses: is owner/repo@<40 hex>; no local or Docker actions
  downloads     every download-artifact has name: and a path: under ${{ runner.temp }} with no ..
  secrets       no secrets reference except secrets.GITHUB_TOKEN
  run           no ${{ inside any run: block
  public-names  config/repos.json names only BHoM/ repositories and exactly the 16 package IDs; every URL
                host in the repository is on the allow-list
  yaml          every workflow parses, with no key repeated in a mapping

GitHub reads workflow keys, context names and action names without regard to case, so the checks do too:
keys are lower-cased as they are read, which also makes `on` a key rather than YAML 1.1's boolean True,
and a key that appears twice in any spelling is refused rather than resolved to the last one.
"""
import argparse
import json
import os
import re
import sys

import yaml

WORKFLOWS = {
    "publish-nuget.yml": {"schedule", "workflow_dispatch"},
    "watch.yml": {"schedule", "workflow_dispatch"},
    "pr-checks.yml": {"pull_request"},
}
PACKAGE_IDS = {
    "BHoM", "BHoM.Engine", "BHoM.Adapter", "BHoM.Interop.Analytics", "BHoM.Interop.CSharp",
    "BHoM.Interop.Excel", "BHoM.Interop.File", "BHoM.Interop.LadybugTools",
    "BHoM.Interop.LifeCycleAssessment", "BHoM.Interop.Mongo", "BHoM.Interop.PowerPoint",
    "BHoM.Interop.Python", "BHoM.Interop.SQL", "BHoM.Interop.TriangleNet", "BHoM.Interop.Localisation",
    "BHoM.UI",
}
URL_HOSTS = {
    "github.com", "api.github.com", "api.nuget.org", "www.nuget.org", "fsf.org", "www.gnu.org", "bhom.xyz",
}
PUBLISH_ENVIRONMENT = "${{ needs.plan.outputs.approval == 'false' && 'nuget-org-auto' || 'nuget-org' }}"
PINNED_USES = re.compile(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}\Z")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
SECRETS_REF = re.compile(r"\bsecrets\b(?!\s*\.\s*GITHUB_TOKEN\b)", re.IGNORECASE)
URL = re.compile(r"https?://([A-Za-z0-9.-]+)", re.IGNORECASE)
SKIP_DIRS = {".git"}


class PolicyLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        if not isinstance(key_node, yaml.ScalarNode):
            raise yaml.constructor.ConstructorError(None, None, "a mapping key is not a scalar", key_node.start_mark)
        key = key_node.value.lower()
        if key in mapping:
            raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key_node.value!r}", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=True)
    return mapping


PolicyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def triggers_of(doc):
    # PolicyLoader keeps the key as the string "on". True covers a document read with a stock PyYAML
    # loader, which turns the key on into the boolean.
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return set(on)
    if isinstance(on, dict):
        return set(on.keys())
    return set()


def strings(node, path=()):
    """Yields (path, string) for every string value in a parsed document."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from strings(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, path + (str(i),))
    elif isinstance(node, str):
        yield path, node


def has_key(node, key):
    if isinstance(node, dict):
        return key in node or any(has_key(v, key) for v in node.values())
    if isinstance(node, list):
        return any(has_key(v, key) for v in node)
    return False


def grants_id_token(perms):
    if isinstance(perms, str) and perms.lower() == "write-all":
        return True
    return isinstance(perms, dict) and str(perms.get("id-token", "")).lower() == "write"


def check_workflow(name, doc, errors):
    def err(rule, message):
        errors.append(f"[{rule}] {name}: {message}")

    if not isinstance(doc, dict):
        err("triggers", "is not a workflow mapping")
        return
    jobs = doc.get("jobs") or {}

    found = triggers_of(doc)
    if "pull_request_target" in found:
        err("triggers", "uses pull_request_target")
    if name not in WORKFLOWS:
        err("triggers", "is not one of the three workflows this repository may hold")
    elif found != WORKFLOWS[name]:
        err("triggers", f"triggers are {sorted(found)}, must be {sorted(WORKFLOWS[name])}")

    if grants_id_token(doc.get("permissions")):
        err("id-token", "grants id-token: write at workflow level")
    for job_id, job in jobs.items():
        job = job or {}
        allowed = name == "publish-nuget.yml" and job_id == "publish"
        if grants_id_token(job.get("permissions")) and not allowed:
            err("id-token", f"job {job_id} grants id-token: write")

        env = job.get("environment")
        env_name = env.get("name") if isinstance(env, dict) else env
        if allowed:
            if env_name != PUBLISH_ENVIRONMENT:
                err("environment", f"job publish has environment {env_name!r}, must be exactly {PUBLISH_ENVIRONMENT!r}")
        elif env is not None:
            err("environment", f"job {job_id} has environment {env_name!r}; only job publish of publish-nuget.yml may have one")

        if "uses" in job:
            err("uses", f"job {job_id} calls a reusable workflow ({job['uses']})")
        for i, step in enumerate(job.get("steps") or []):
            step = step or {}
            label = f"job {job_id} step {step.get('name') or step.get('id') or i + 1}"
            uses = step.get("uses")
            if uses is not None and not PINNED_USES.match(str(uses)):
                err("uses", f"{label} uses '{uses}', not owner/repo@<40 hex>")
            if uses is not None and str(uses).split("@")[0].lower() == "actions/download-artifact":
                w = step.get("with") or {}
                dl_path = str(w.get("path", ""))
                if not w.get("name"):
                    err("downloads", f"{label} downloads without a name")
                if not re.match(r"\A\$\{\{\s*runner\.temp\s*\}\}", dl_path) or ".." in dl_path:
                    err("downloads", f"{label} downloads to '{dl_path}', not a path under ${{{{ runner.temp }}}} without ..")
            run = step.get("run")
            if isinstance(run, str) and "${{" in run:
                err("run", f"{label} has ${{{{ inside run:")

    if has_key(doc, "secrets"):
        err("secrets", "has a secrets: key")
    for path, value in strings(doc):
        for expr in EXPRESSION.findall(value):
            if SECRETS_REF.search(expr):
                err("secrets", f"{'.'.join(path)} references secrets other than secrets.GITHUB_TOKEN: ${{{{{expr}}}}}")


def check_public_names(root, errors):
    def err(message):
        errors.append(f"[public-names] {message}")

    try:
        with open(os.path.join(root, "config", "repos.json"), encoding="utf-8-sig") as f:
            config = json.load(f)
        repos = config["repos"]
        names = [r["repo"] for r in repos]
        ids = [r["packageId"] for r in repos]
    except (OSError, ValueError, KeyError, TypeError) as e:
        err(f"config/repos.json cannot be read: {e}")
    else:
        for n in names:
            if not re.fullmatch(r"BHoM/[A-Za-z0-9_.-]+", n):
                err(f"config/repos.json names '{n}', not a BHoM/ repository")
        if len(ids) != len(set(ids)) or set(ids) != PACKAGE_IDS:
            extra = sorted(set(ids) - PACKAGE_IDS)
            missing = sorted(PACKAGE_IDS - set(ids))
            err(f"config/repos.json must list exactly the 16 package IDs once each; extra {extra}, missing {missing}")
        unknown_keys = sorted(set(config) - {"nugetOrgFlatContainer", "assets", "repos"})
        if unknown_keys:
            err(f"config/repos.json has keys {unknown_keys}; only nugetOrgFlatContainer, assets and repos are allowed")

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, "rb") as f:
                data = f.read()
            if b"\0" in data:
                continue
            text = data.decode("utf-8", errors="replace")
            for host in sorted({h.lower().rstrip(".") for h in URL.findall(text)}):
                if host not in URL_HOSTS:
                    err(f"{rel} has a URL on host {host}, which is not on the allow-list")


def run(root):
    errors = []
    wf_dir = os.path.join(root, ".github", "workflows")
    present = sorted(os.listdir(wf_dir)) if os.path.isdir(wf_dir) else []
    for name in sorted(set(present) | set(WORKFLOWS)):
        path = os.path.join(wf_dir, name)
        if not os.path.isfile(path):
            errors.append(f"[triggers] {name}: missing")
            continue
        try:
            with open(path, encoding="utf-8") as f:
                doc = yaml.load(f, Loader=PolicyLoader)
        except yaml.YAMLError as e:
            errors.append(f"[yaml] {name}: not valid YAML: {e}")
            continue
        check_workflow(name, doc, errors)
    check_public_names(root, errors)
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args(argv)
    errors = run(args.root)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for e in errors:
        print(f"::error title=Policy::{e}" if annotate else f"ERROR: {e}")
    if errors:
        print(f"Policy: {len(errors)} breach(es).")
        return 1
    print("Policy: all rules pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
