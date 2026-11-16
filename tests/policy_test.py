"""Tests for scripts/Test-Policy.py.

Each test copies the repository to a temporary folder, plants one breach by editing a real workflow or
file, and checks that the policy fails with that rule's message and no other. The unedited copy must pass.
"""
import importlib.util
import os
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("test_policy_script", os.path.join(ROOT, "scripts", "Test-Policy.py"))
policy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(policy)


def rules(errors):
    return sorted({e.split("]")[0].lstrip("[") for e in errors})


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="policy-test-")
        self.root = os.path.join(self.tmp, "repo")
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns(".git", "__pycache__"))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def edit(self, rel, old, new):
        path = os.path.join(self.root, rel)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        self.assertIn(old, text, f"planting failed: text not found in {rel}")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text.replace(old, new, 1))

    def write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    def assert_only(self, rule):
        errors = policy.run(self.root)
        self.assertTrue(errors, "the planted breach was not reported")
        self.assertEqual(rules(errors), [rule], "\n".join(errors))
        return errors

    def test_real_workflows_pass(self):
        self.assertEqual(policy.run(self.root), [])

    def test_triggers_extra_trigger(self):
        self.edit(".github/workflows/publish-nuget.yml", "  workflow_dispatch:\n    inputs:", "  push:\n  workflow_dispatch:\n    inputs:")
        self.assert_only("triggers")

    def test_triggers_pull_request_target(self):
        self.edit(".github/workflows/pr-checks.yml", "  pull_request:\n", "  pull_request_target:\n")
        errors = self.assert_only("triggers")
        self.assertTrue(any("pull_request_target" in e for e in errors))

    def test_triggers_fourth_workflow(self):
        with open(os.path.join(self.root, ".github/workflows/watch.yml"), encoding="utf-8") as f:
            self.write(".github/workflows/extra.yml", f.read())
        self.assert_only("triggers")

    def test_id_token_on_another_job(self):
        self.edit(".github/workflows/publish-nuget.yml", "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n",
                  "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n      id-token: write\n")
        self.assert_only("id-token")

    def test_id_token_at_workflow_level(self):
        self.edit(".github/workflows/watch.yml", "permissions:\n  contents: read\n\njobs:", "permissions:\n  contents: read\n  id-token: write\n\njobs:")
        self.assert_only("id-token")

    def test_id_token_through_write_all(self):
        self.edit(".github/workflows/watch.yml", "permissions:\n  contents: read\n\njobs:", "permissions: write-all\n\njobs:")
        self.assert_only("id-token")

    def test_environment_on_another_job(self):
        self.edit(".github/workflows/publish-nuget.yml", "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n",
                  "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    environment: nuget-org\n")
        self.assert_only("environment")

    PUBLISH_ENVIRONMENT = "    environment: ${{ needs.plan.outputs.approval == 'false' && 'nuget-org-auto' || 'nuget-org' }}\n"

    def test_environment_always_without_approval(self):
        self.edit(".github/workflows/publish-nuget.yml", self.PUBLISH_ENVIRONMENT, "    environment: nuget-org-auto\n")
        self.assert_only("environment")

    def test_environment_expression_inverted(self):
        self.edit(".github/workflows/publish-nuget.yml", self.PUBLISH_ENVIRONMENT,
                  "    environment: ${{ needs.plan.outputs.approval == 'true' && 'nuget-org' || 'nuget-org-auto' }}\n")
        self.assert_only("environment")

    def test_environment_renamed(self):
        self.edit(".github/workflows/publish-nuget.yml", self.PUBLISH_ENVIRONMENT,
                  "    environment: ${{ needs.plan.outputs.approval == 'false' && 'nuget-org-auto' || 'nuget-org-test' }}\n")
        self.assert_only("environment")

    def test_environment_missing(self):
        self.edit(".github/workflows/publish-nuget.yml", self.PUBLISH_ENVIRONMENT, "")
        self.assert_only("environment")

    def test_uses_tag_not_sha(self):
        self.edit(".github/workflows/watch.yml", "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd", "actions/checkout@v6")
        self.assert_only("uses")

    def test_uses_local_action(self):
        self.edit(".github/workflows/watch.yml", "      - name: Check calendar.json\n", "      - uses: ./local-action\n      - name: Check calendar.json\n")
        self.assert_only("uses")

    def test_uses_docker(self):
        self.edit(".github/workflows/watch.yml", "      - name: Check calendar.json\n", "      - uses: docker://alpine:3\n      - name: Check calendar.json\n")
        self.assert_only("uses")

    def test_downloads_path_escapes_temp(self):
        self.edit(".github/workflows/publish-nuget.yml", "          name: release\n          path: ${{ runner.temp }}/release\n\n      - name: Check packages",
                  "          name: release\n          path: ${{ runner.temp }}/../release\n\n      - name: Check packages")
        self.assert_only("downloads")

    def test_downloads_without_name(self):
        self.edit(".github/workflows/publish-nuget.yml", "          name: release\n          path: ${{ runner.temp }}/release\n\n      - name: Check packages",
                  "          path: ${{ runner.temp }}/release\n\n      - name: Check packages")
        self.assert_only("downloads")

    def test_secrets_other_than_github_token(self):
        self.edit(".github/workflows/watch.yml", "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n", "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n          APP_KEY: ${{ secrets.NUGET_KEY }}\n")
        self.assert_only("secrets")

    def test_secrets_whole_context(self):
        self.edit(".github/workflows/watch.yml", "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n", "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n          ALL: ${{ toJSON(secrets) }}\n")
        self.assert_only("secrets")

    def test_run_with_expression(self):
        self.edit(".github/workflows/watch.yml", "        run: ./scripts/Test-Calendar.ps1\n", "        run: ./scripts/Test-Calendar.ps1 -Path ${{ github.event.inputs.path }}\n")
        self.assert_only("run")

    # YAML tricks. GitHub reads workflow keys case-insensitively and resolves anchors.

    VALIDATE_PERMS = "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n"

    def test_trick_anchor_alias(self):
        self.edit(".github/workflows/publish-nuget.yml", "  plan:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n",
                  "  plan:\n    runs-on: ubuntu-24.04\n    permissions: &perms\n      contents: read\n      id-token: write\n")
        self.edit(".github/workflows/publish-nuget.yml", self.VALIDATE_PERMS,
                  "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    permissions: *perms\n")
        errors = self.assert_only("id-token")
        self.assertTrue(any("job validate" in e for e in errors), "\n".join(errors))

    def test_trick_quoted_key(self):
        self.edit(".github/workflows/publish-nuget.yml", self.VALIDATE_PERMS, self.VALIDATE_PERMS + '      "id-token": write\n')
        self.assert_only("id-token")

    def test_trick_duplicate_key(self):
        self.edit(".github/workflows/publish-nuget.yml", self.VALIDATE_PERMS,
                  "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    permissions:\n      id-token: write\n    permissions:\n      contents: read\n")
        errors = self.assert_only("yaml")
        self.assertTrue(any("duplicate" in e for e in errors))

    def test_trick_on_twice_quoted_and_plain(self):
        self.edit(".github/workflows/pr-checks.yml", "on:\n  pull_request:\n    branches: [main]\n",
                  '"on":\n  pull_request:\n    branches: [main]\non:\n  push:\n')
        self.assert_only("yaml")

    def test_trick_job_key_case(self):
        self.edit(".github/workflows/publish-nuget.yml", self.VALIDATE_PERMS,
                  "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    Permissions:\n      contents: read\n      id-token: write\n")
        self.assert_only("id-token")

    def test_trick_permission_value_case(self):
        self.edit(".github/workflows/publish-nuget.yml", self.VALIDATE_PERMS, self.VALIDATE_PERMS + "      id-token: Write\n")
        self.assert_only("id-token")

    def test_trick_environment_key_case(self):
        self.edit(".github/workflows/publish-nuget.yml", "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n",
                  "  validate:\n    needs: [plan, build]\n    runs-on: ubuntu-24.04\n    Environment: nuget-org\n")
        self.assert_only("environment")

    def test_trick_step_uses_key_case(self):
        self.edit(".github/workflows/watch.yml", "      - name: Check calendar.json\n", "      - Uses: actions/checkout@v6\n      - name: Check calendar.json\n")
        self.assert_only("uses")

    def test_trick_secrets_context_case(self):
        self.edit(".github/workflows/watch.yml", "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n", "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n          APP_KEY: ${{ SECRETS.NUGET_KEY }}\n")
        self.assert_only("secrets")

    def test_trick_download_action_name_case(self):
        self.edit(".github/workflows/publish-nuget.yml",
                  "        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2\n        with:\n          name: release\n          path: ${{ runner.temp }}/release\n\n      - name: Check packages",
                  "        uses: Actions/Download-Artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2\n        with:\n          name: release\n          path: ${{ runner.temp }}/../release\n\n      - name: Check packages")
        self.assert_only("downloads")

    def test_trick_reusable_workflow_call(self):
        self.edit(".github/workflows/watch.yml", "jobs:\n", "jobs:\n  extra:\n    uses: BHoM/nuget-publishing/.github/workflows/watch.yml@" + "0" * 40 + "\n")
        self.assert_only("uses")

    def test_public_names_non_bhom_repository(self):
        self.edit("config/repos.json", '"repo": "BHoM/BHoM_UI"', '"repo": "SomeOtherOrg/BHoM_UI"')
        self.assert_only("public-names")

    def test_public_names_extra_package(self):
        self.edit("config/repos.json", '{ "repo": "BHoM/BHoM_UI", "config": "", "packageId": "BHoM.UI" }',
                  '{ "repo": "BHoM/BHoM_UI", "config": "", "packageId": "BHoM.UI" },\n    { "repo": "BHoM/Extra_Toolkit", "config": "", "packageId": "BHoM.Interop.Extra" }')
        self.assert_only("public-names")

    def test_public_names_url_host(self):
        self.write("docs/notes.md", "See " + "https://" + "feed.example.invalid/v3/index.json for the feed.\n")
        errors = self.assert_only("public-names")
        self.assertTrue(any("feed.example.invalid" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
