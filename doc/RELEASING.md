# Releasing the Flutter SDK

A **maintainer** of this repository — `admin` or `maintain`, see [Who can release](#who-can-release)
— can cut a release. It takes two workflows rather than one, and that is forced by pub.dev rather
than chosen; [Why this is two workflows](#why-this-is-two-workflows) explains it.

Two things have to be set up before the first automated release, and neither is done yet. Read
[Before the first release](#before-the-first-release).

## Cut a release

1. **Move the entries out of `## [Unreleased]`** in `CHANGELOG.md` into a `## [0.1.1] — 2026-09-09`
   section, bump `version` in `pubspec.yaml` to match, and merge that to `main`.
2. **Actions → Release → Run workflow**, with `version` = `0.1.1` (no `v` prefix).

| Stage | What it does |
| --- | --- |
| `authorize` | The dispatcher is `admin` or `maintain` |
| `preflight` | Version format, `pubspec.yaml` agreement, changelog section, not already released |
| `verify` | The full `ci.yml` gate set — fixtures, hygiene, `dart format`, `flutter analyze`, tests, the example app |
| `package-check` | `flutter pub publish --dry-run` — whether the package can be published at all, which the tests say nothing about |
| `tag` | Creates tag `v0.1.1` on the dispatched commit |

3. **The tag push is what publishes.** What happens next depends on whether `RELEASE_PAT` is set:

   - **With it** — the workflow pushes the tag, **Publish** fires, and pub.dev and the GitHub
     release follow. One dispatch, nothing else to do.
   - **Without it** — the workflow stops and prints the two commands to push the tag yourself. Run
     them; that push triggers **Publish**. Two steps instead of one, and no long-lived credential.

**Rehearse with `dry_run`** — every gate including the publish dry-run, no tag.

## Why this is two workflows

Not a style choice. Two GitHub and pub.dev rules meet here and between them they rule out doing it
in one:

1. **pub.dev accepts an automated publish only from a run triggered by a tag push** matching the
   pattern configured on the package. The OIDC token carries the ref, and a run started any other
   way is rejected. `workflow_dispatch` is not accepted — [dart-lang/pub-dev#7177](https://github.com/dart-lang/pub-dev/issues/7177)
   asks for it and is still open. So a dispatch-triggered workflow cannot publish, however it is
   written.
2. **GitHub does not start workflow runs from `GITHUB_TOKEN` events.** A tag pushed by a workflow
   using the default token triggers nothing, so it cannot hand over to a tag-triggered workflow
   either.

Together: a fully automated release needs a token that is not `GITHUB_TOKEN` to push the tag. That
is what `RELEASE_PAT` is for, and it is optional because a maintainer pushing the tag from a laptop
does the same job with no stored credential.

`release.yml` decides a tag deserves to exist. `publish.yml` is what happens once one does.

## Before the first release

### 1. Publish `0.1.0` by hand

`tracive_sdk` is not on pub.dev. Automated publishing can only be configured for a package that
already exists — pub.dev's own words: *"you can only automate publishing of existing packages. To
create a new package, you must publish the first version using `dart pub publish`."* So the first
version goes out from a laptop:

```bash
flutter pub publish
```

### 2. Turn on automated publishing

pub.dev → the package → **Admin** → enable publishing from GitHub Actions, with:

| Field | Value |
| --- | --- |
| Repository | `pleistocent/tracive-sdk-flutter` |
| Tag pattern | `v{{version}}` |

The pattern has to match the trigger in `publish.yml` (`v[0-9]+.[0-9]+.[0-9]+`). If they disagree,
publishing fails at the very end with an OIDC error that does not mention tags.

Note that this needs the repository to be reachable from pub.dev's settings page — worth checking
early, because this repository is **private**.

### 3. Optional: `RELEASE_PAT`

A fine-grained personal access token with **Contents: read and write** on this repository, stored as
the `RELEASE_PAT` secret. Its only job is to push the tag as a person rather than as
`github-actions[bot]`, so that the push triggers `publish.yml`.

It is genuinely optional, and skipping it is a defensible choice: a long-lived token with write
access is a real thing to hold, and the alternative costs one `git push`.

There is **no pub.dev token anywhere**, with or without the PAT. Publishing authenticates with the
OIDC token GitHub mints for the run.

## Who can release

The `authorize` job runs first in `release.yml`, and `guard` does the same in `publish.yml`: both
fail unless the person who triggered the run is `admin` or `maintain` on this repository. The check
is in both because `publish.yml` can also be reached by pushing a tag directly, which needs only
write access — a rule on the dispatch path alone would be a rule on the polite path only.

The native way to express this would be a GitHub
[environment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
with required reviewers, which would also give an approve button. It is not available: environments
on a **private** repository need GitHub Pro or Team, and the `pleistocent` organisation is on Free.
If the plan changes, an environment is the better mechanism — it is enforced by GitHub rather than
by a step, and it survives someone editing the workflow.

## What the workflows will refuse to do

- **Release a version that is not `x.y.z`**, or one where `pubspec.yaml` disagrees. pub.dev checks
  this too, but only after the tag is public.
- **Release a version with no changelog section.** pub.dev renders `CHANGELOG.md` on the package
  page and scores the package partly on it.
- **Release a version that already has a tag, or is already on pub.dev.** A version can be
  retracted but not replaced, and a retracted version stays resolvable for anyone who pinned it.
- **Publish a package that fails `pub publish --dry-run`** — checked before the tag exists, not
  after.

## When something goes half-wrong

**The gates failed.** Nothing was tagged. Fix and dispatch again with the same version.

**The tag exists but `publish.yml` never ran.** Almost always the `GITHUB_TOKEN` rule above: the tag
was pushed by the workflow without a `RELEASE_PAT`. Delete it and push it again as yourself:

```bash
git push --delete origin v0.1.1
git push origin v0.1.1
```

**pub.dev rejected the publish.** The tag is public but nothing was published. Fix, then delete and
re-push the tag — the version number is still free, because pub.dev only reserves it on a
successful publish.

**pub.dev succeeded but the GitHub release did not.** The package is out, which is the half that
matters. `gh release create v0.1.1 --title v0.1.1 --notes-file <the changelog section> --verify-tag`.

**A broken version reached pub.dev.** `dart pub retract tracive_sdk 0.1.1` within 7 days stops new
resolutions picking it up; it does not remove it. Then ship a patch.
