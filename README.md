# nuget-publishing

This repository publishes the 16 public BHoM NuGet packages to nuget.org on the dates listed in `calendar.json`. A scheduled GitHub Actions workflow builds every package from its repository's `develop` branch and pushes the set. An alpha is pushed without approval; a beta is pushed once a member of the release team has approved the run. It stores no nuget.org key: the publish job obtains a short-lived one through nuget.org Trusted Publishing.

## What happens on a release day

1. At 05:17 UTC every day, `publish-nuget.yml` starts, and `plan` selects the events dated today (UTC) that are not marked `skip`. With none, the run ends there.
2. `build` builds and packs the 16 from the commit each `develop` branch pointed at just before 05:00 UTC.
3. `validate` checks the 16 packages and leaves out any that nuget.org already holds.
4. `publish` pushes the packages to nuget.org. A run whose events are all alphas pushes at once, on the `nuget-org-auto` environment. A run with a beta in it waits for approval on the `nuget-org` environment first, and one approval covers an alpha due the same day.
5. `verify` waits up to 30 minutes for nuget.org to list all 16.
6. A failed or cancelled job opens an issue titled `publish-nuget.yml failed: <jobs>`.
7. At 12:37 UTC, `watch.yml` checks every event of the last 14 days and opens `NuGet <version> incomplete on nuget.org`, listing the missing packages, for any that is not complete.

A run that waits for approval cannot be approved by the person who started it, so a beta started by hand needs two people. Approval can be given on a later day, within the 7 days the built packages are kept. To approve a run:

1. Open the repository's Actions tab and select the waiting `Publish NuGet packages` run. Its summary lists the planned events, the pinned commits and the packages to be pushed.
2. Check that the run started today, and that its version is in `calendar.json` on `main` and is not marked `skip`.
3. Click "Review deployments", tick the environment, then click "Approve and deploy".

An administrator can make alphas wait for approval too, by adding required reviewers to the `nuget-org-auto` environment in the repository settings, and removing them to make alphas automatic again.

## The calendar

`calendar.json` is a list of events. Add, move or remove an event by pull request to `main`; the pull request checks validate the file. Only the four keys below are accepted. To cancel an event outright, delete it. When the last event is fewer than 42 days away, the watch opens an issue titled `Calendar runs out on <date>`.

```json
[
  { "date": "2027-01-15", "version": "10.1.0-alpha.1.0" },
  { "date": "2027-01-29", "version": "10.1.0-alpha.2.0", "skip": true },
  { "date": "2027-03-26", "version": "10.1.0-beta.0", "sprint": 6 }
]
```

| Key | Required | Meaning |
|---|---|---|
| `date` | yes | The UTC day to publish on, `yyyy-MM-dd`. |
| `version` | yes | `<major>.<minor>.0-alpha.<sprint>.<n>` or `<major>.<minor>.0-beta.<n>`, lower case, no leading zeros, used once only. |
| `sprint` | for a beta | The sprint number written into the release notes. An alpha takes it from its version. |
| `skip` | no | `true` means the workflow does not publish this event. The daily watch still checks it. |

## Publishing by hand

```
gh workflow run publish-nuget.yml --ref main -f version=10.1.0-alpha.1.0
```

- Use this when a scheduled run was missed, cancelled or failed.
- The version must be in `calendar.json`, dated today or earlier, not marked `skip`, and not already complete on nuget.org. On its own date, 05:00 UTC must have passed. Otherwise `plan` fails and says why.
- The run builds the same 05:00 UTC commits as the scheduled run would have, and a beta still waits for approval.
- Packages already on nuget.org with identical content are not pushed again, so a partly published version can be completed this way.

## Rehearsing

```
gh workflow run publish-nuget.yml --ref main -f version=10.1.0-alpha.1.0 -f rehearsal=true
```

- A rehearsal runs every job, including the nuget.org login and, for a beta, the approval, but pushes the packages to a folder on the runner instead of nuget.org.
- The version must be in the calendar and not marked `skip`. Its date does not matter: if it is in the future, the build uses the commits at the moment the run started.
- The last step of `publish` checks that the folder holds exactly the validated packages.
- `verify` checks that nuget.org lists none of the packages at that version, so a rehearsal of a version that is already published fails there.

## When something goes wrong

A run cannot be re-run on a later day, because it would use the calendar as it was then: "Re-run all jobs" is refused by `plan` on any day, and "Re-run failed jobs" is refused by `publish` once the day `plan` ran has passed. Start a new run by hand instead. Issues opened by the workflows are closed by hand.

| Symptom | What to do |
|---|---|
| Nobody approved, or the run is stuck waiting | Cancel the run, then publish by hand. |
| `build` failed at "Pin commits" | A repository's commit at 05:00 UTC could not be established with confidence. The step summary names the repository and the reason. Publish by hand once the cause has cleared. |
| `build` failed later | The `build-logs` artifact of the run holds each repository's log. A run by hand still builds the 05:00 UTC commits, so a fix merged later is not picked up. |
| `validate` reports a package "already on nuget.org with different content" | That version cannot be replaced. Add a new event with a new version. |
| `publish` failed part way | On the same day, use "Re-run failed jobs" on that run, or publish by hand. On a later day, publish by hand. |
| `plan` or `publish` says the run cannot be re-run | Publish by hand. |
| `verify` timed out | nuget.org had not listed every package within 30 minutes. The 12:37 UTC watch checks again. |
| No run starts at 05:17 UTC and the 12:37 UTC watch is silent too | GitHub disables scheduled workflows in a public repository after 60 days without repository activity, and a disabled workflow opens no issue. `gh workflow list --all` shows the state `disabled_inactivity`, and the workflow's page in the Actions tab shows an "Enable workflow" button. Click it, or run `gh workflow enable publish-nuget.yml` and `gh workflow enable watch.yml`, then publish by hand any event that was missed. |
| The workflow must stop publishing | Set `skip: true` on the affected events by pull request. |
| Issues mention nobody, or "Log in to nuget.org" failed | Check the repository variables `RELEASE_TEAM_MENTION` (the release team's mention) and `NUGET_USER` (the nuget.org profile name the Trusted Publishing policy was created under). |

## Folder layout

| Path | Content |
|---|---|
| `calendar.json` | The release events. |
| `config/`, `assets/` | `repos.json` lists the 16 repositories and their package IDs, which are listed again in `scripts/Test-Policy.py`. `assets/` holds the icon and default licence packed into every package. |
| `.github/workflows/` | `publish-nuget.yml` (the release), `watch.yml` (the daily check) and `pr-checks.yml` (the checks on every pull request). |
| `scripts/` | What the workflow jobs run, and the calendar and policy checks. The build script runs only on a hosted runner, because it deletes `C:\ProgramData\BHoM`. |
| `tests/` | Offline tests for the scripts and workflows, with their samples. |

## Running the tests

The tests need PowerShell and Python 3 with PyYAML, and none of them touches the network or publishes anything.

```
pwsh ./tests/Invoke-OfflineTests.ps1
python -m pip install --require-hashes --no-deps --only-binary :all: -r scripts/requirements-policy.txt
python -m unittest discover --start-directory tests --pattern "*_test.py"
python scripts/Test-Policy.py
pwsh ./scripts/Test-Calendar.ps1
```

On Windows PowerShell 5.1 replace `pwsh` with `powershell -File`; the push-step tests are skipped unless `bash`, `jq` and `sha256sum` are available; and `tests/PinnedCommit.Live.ps1`, which calls the GitHub API, is not one of these and is run by hand.
