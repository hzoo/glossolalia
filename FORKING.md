# Forking Glossolalia

Glossolalia should behave like an overlay on top of Ghostty, not a sibling codebase.

## Product Surface

Keep product identity declarative:

- macOS app metadata and updater endpoints live in `macos/Ghostty-Info.plist`
- Xcode build-time identity defaults live in `macos/GlossolaliaBrand.xcconfig`
- macOS runtime branding reads from `macos/Sources/Helpers/ProductBrand.swift`
- app icons live under `macos/Assets.xcassets`
- release/update plumbing should stay fork-owned and local-first

The intended cutover is:

1. keep local defaults safe in `macos/GlossolaliaBrand.xcconfig`
2. override shipping identity in `scripts/release-macos-local.sh`
3. when the brand is final, move those release overrides back into the xcconfig

## Branch Shape

Keep three lanes:

- `main`: clean mirror of `upstream/main`
- `glossolalia`: ship branch
- topic branches: one concern per branch, rebased onto `glossolalia`

Do not collapse the fork into one giant squash commit again. Keep this patch stack:

1. fork workflow and branding seam
2. config/protocol hooks
3. renderer hooks
4. audio engine
5. video engine
6. macOS glue
7. GTK glue
8. final macOS identity
9. local release and fork automation policy

This makes conflict repair local and agent-friendly.

For the exact agent-assisted rebase and verification procedure, see
`REBASE_PLAN.md`.

## Daily Workflow

This structure is meant to keep change easy, not bureaucratic.

Normal feature flow:

1. branch from `glossolalia`
2. make the change on a topic branch
3. keep commits scoped by concern
4. land the topic branch back onto `glossolalia`
5. delete the topic branch when done

Suggested branch names:

- human work: `feature/<name>` or `fix/<name>`
- agent work: `codex/<name>`

Rules:

- `glossolalia` is not a scratchpad. Keep experiments and half-finished ideas on topic branches.
- Messy WIP is allowed on topic branches. Clean history only before landing.
- Small hotfix directly on `glossolalia` is acceptable only if it is truly one concern, low risk, and faster than making a topic branch.
- If a feature grows across config, renderer, platform glue, and release logic, split it before landing.
- If only one platform is shipping, avoid touching the other platform unless the API shape requires it.
- Default landing path is topic branch -> clean commits -> `glossolalia`.
- Default salvage path for messy work is cherry-pick the good commits, not merge the whole branch.

Landing options:

- rebase the topic branch onto `glossolalia`, then fast-forward `glossolalia`
- or cherry-pick clean commits from the topic branch onto `glossolalia`

Prefer cherry-pick when the topic branch contains messy exploration you do not want in ship history.

## Non-Negotiables

- Do not use `glossolalia` as a long-running personal work branch.
- Do not force unrelated work into one commit to "keep history small".
- Do not let branch cleanup wait until the next upstream rebase.
- Do not widen edits in upstream churn zones when a hook or helper file would do.
- Do not postpone rebases until conflict context is cold.

## Rebase Loop

Use `scripts/fork-sync.sh` for local rebases:

```sh
./scripts/fork-sync.sh
```

That script:

- refuses tracked worktree changes
- fetches `upstream/main`
- creates a timestamped safety branch
- fast-forwards local `main` when safe
- rebases the local `glossolalia` branch onto it
- prints a `range-diff` against the pre-rebase stack

It does not depend on `origin/glossolalia` for the rebase target. The
only source of truth for rebasing is `upstream/main`.

Recommended local git config:

```sh
git config rerere.enabled true
git config rerere.autoupdate true
git config rebase.autoStash true
```

Human rule:

- keep making whatever changes you want on topic branches
- only make `glossolalia` pay the rebase cost for finished, scoped work

Practical cadence:

- rebase `glossolalia` after meaningful upstream Ghostty movement
- if actively building, do not let `glossolalia` drift for more than about a week
- if a topic branch lives too long, rebase it or cherry-pick the good commits out

## Release

macOS release is local and manual.

Use `scripts/release-macos-local.sh` from a clean `glossolalia` branch after
you finish the upstream rebase and conflict repair.

Before signing, install and smoke-test the branded app:

```sh
./scripts/build-macos-app.sh --install
```

Check normal terminal use, config reload, audio response, background media, and
the packaged app icon. Run `zig build test -Demit-macos-app=false` before a
public release; this expensive checkpoint may be human-run.

Because the curated stack is rebased, publish it after review with:

```sh
git fetch origin glossolalia
git push --force-with-lease origin glossolalia
```

The release script checks this exact relationship before publishing a tag or
GitHub release. Building and verification do not modify Git or GitHub.

Local prerequisites:

- Apple signing identity installed in login keychain
- `xcrun notarytool store-credentials` already set up with a local profile
- `gh auth status` succeeds for this repo

Before first public release:

- replace the source icon in `images/icons/glossolalia-source-2048.png` and the rendered files in `macos/Assets.xcassets/AppIconImage.imageset` and `macos/Assets.xcassets/GlossolaliaAppIcon.appiconset` if you want a different app icon
- confirm `com.henryzoo.glossolalia` is the bundle ID you want to keep
- set `CODESIGN_IDENTITY` and `NOTARY_PROFILE` in your shell

Release flow:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="glossolalia-notary"

./scripts/release-macos-local.sh preflight 0.1.0
./scripts/release-macos-local.sh prepare 0.1.0
./scripts/release-macos-local.sh verify 0.1.0
./scripts/release-macos-local.sh publish 0.1.0
```

`preflight` fails before compilation if the Developer ID identity or notary
profile is unavailable. `prepare` builds, signs, notarizes, staples, packages,
checksums, and verifies into `dist/releases/v0.1.0`. `verify` is safe to repeat.
`publish` pushes only the annotated tag and creates a draft GitHub release from
the verified artifacts; use `publish 0.1.0 --final` for immediate publication.

Updater feeds remain disabled until Glossolalia owns a separate Sparkle signing
key and appcast. GitHub DMG and ZIP releases do not depend on Sparkle.

## Pull Requests

Fork PRs should stay light:

- use topic branches against `glossolalia`
- keep commits scoped by concern
- expect manual review and local rebases for upstream conflict repair
- rely on `.github/workflows/fork-sanity.yml` only for lightweight hygiene, not product signoff

## Agent Rules

- Prefer new files over edits in upstream churn zones.
- If a feature touches `renderer/generic.zig`, `Config.zig`, app delegates, or release workflows, isolate the seam first.
- Rebrand through metadata/helpers, not scattered string replacement.
- If a rebase conflict crosses more than one concern, split the patch before continuing.
