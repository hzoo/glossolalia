# Maintaining the Ghostty Fork

## Goal

Glossolalia is a curated patch stack on Ghostty, not a second terminal engine.

- `main` mirrors `upstream/main` exactly.
- `glossolalia` is the standalone macOS ship branch.
- Topic branches start from `glossolalia` and contain one concern.
- Upstream mechanics win during conflicts; reapply the smallest Glossolalia hook.

The practical target is a rebase an agent can repair one concern at a time, with
a human running the expensive product smoke test before release.

## Curated Stack

Keep these nine concerns in this order:

1. `chore(fork): add branding seam and local fork workflow`
2. `feat(glossolalia): add config and protocol hooks`
3. `feat(glossolalia): add renderer plumbing and shaders`
4. `feat(glossolalia): add audio engine`
5. `feat(glossolalia): add video engine`
6. `feat(glossolalia): add macOS integration`
7. `feat(glossolalia): add GTK integration`
8. `brand(macos): finalize Glossolalia app identity`
9. `chore(release): move macOS release local and trim upstream automation`

Nine is not a score to optimize. Do not merge config, renderer, audio, video, or
platform glue just to reduce the count. A smaller stack is only better when two
commits always conflict and verify as one concern.

## Integration Boundaries

Prefer fork-owned files and keep upstream edits as narrow dispatch hooks.

| Concern | Fork-owned implementation | Upstream hook surface |
| --- | --- | --- |
| Identity/release | `macos/GlossolaliaBrand.xcconfig`, `ProductBrand.swift`, `scripts/*macos*.sh`, icons | Xcode project and plist variable references |
| Config/protocol | Glossolalia config values and OSC/action declarations | `Config.zig`, bindings, terminal stream dispatch |
| Renderer | `src/renderer/glossolalia.zig`, Glossolalia shaders | `generic.zig`, `Thread.zig`, renderer message enum |
| Audio | `src/audio/Glossolalia.zig` | Config copied into renderer state |
| Video | `src/video/BackgroundVideo.zig` | `Surface.zig`, embedded C API, renderer frame messages |
| macOS | MIDI and media controller files | App/runtime callbacks and surface commands |
| GTK | Background media dialog files | GTK surface registration and dispatch |

The highest-risk files are `src/renderer/generic.zig`, `src/renderer/Thread.zig`,
`src/Surface.zig`, `src/config/Config.zig`, `Ghostty.App.swift`, `AppDelegate.swift`,
and `project.pbxproj`. New behavior should move out of those files before adding
another hook.

## Routine Rebase

One-time local setup:

```sh
git config rerere.enabled true
git config rerere.autoupdate true
git config rebase.autoStash true
```

Use the sync helper from a worktree with no tracked changes:

```sh
./scripts/fork-sync.sh glossolalia
```

The helper fetches `upstream/main`, creates a timestamped `codex/safety-*`
branch, fast-forwards local `main` when safe, rebases `glossolalia`, and prints a
`git range-diff`. Untracked local tooling does not block the rebase.

Equivalent manual sequence:

```sh
git fetch --prune upstream main
git switch glossolalia
old_base="$(git merge-base glossolalia upstream/main)"
git branch codex/safety-glossolalia-pre-upstream-YYYYMMDD
git rebase upstream/main
git range-diff \
  "$old_base..codex/safety-glossolalia-pre-upstream-YYYYMMDD" \
  upstream/main..glossolalia
```

After the range-diff and product smoke test are reviewed, publish the rewritten
stack with a lease instead of an unconditional force:

```sh
git fetch origin glossolalia
git push --force-with-lease origin glossolalia
```

Delete the safety branch only after that push succeeds. The local release
script deliberately refuses to build when the reviewed rebase has not been
published yet, avoiding a late failure after signing and notarization.

## Conflict Protocol

For every stopped commit:

1. Read the whole current upstream function, not only conflict markers.
2. Identify the one behavior the replayed commit owns.
3. Preserve upstream lifecycle, error handling, scheduling, and naming.
4. Reinsert the fork behavior through the narrowest existing hook.
5. Stage only that concern and continue the rebase.
6. If the repair introduces a second concern, abort and redesign or split it.
7. Review the final `range-diff`; explain every non-equivalent patch change.

Do not solve conflicts by taking the old fork file wholesale. Do not rename
internal `Ghostty` symbols. Do not move product behavior into release plumbing.

Known repair patterns from the July 2026 rebase:

- Dock icon: preserve upstream icon reset/rendering and retain only the dynamic
  bundle/defaults-suite lookup.
- Renderer thread: preserve upstream visibility and scrollback-compression
  scheduling; classify Glossolalia video messages as draw-only mailbox updates.
- Embedded C API: use upstream `main_c.String` ownership instead of a fork-local
  duplicate ABI type.
- macOS app state: preserve upstream instance-based config-path lifecycle and
  insert only MIDI synchronization and the background-media callback.
- Read-only terminal stream: ignore only the fork's background-video action;
  keep upstream handling for every existing terminal action.
- GitHub automation: retain only `.github/workflows/fork-sanity.yml`.

`rerere` should handle repeated textual resolutions, but the agent must still
check that upstream semantics have not changed around the recorded resolution.

## Verification

Run after every rebase:

```sh
git diff --check upstream/main..glossolalia
bash -n scripts/fork-sync.sh
bash -n scripts/build-macos-app.sh
bash -n scripts/release-macos-local.sh
```

Run the macOS build whenever a conflict touched Zig/C headers, renderer code,
Swift app glue, the Xcode project, or release identity:

```sh
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -target Ghostty \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build
```

The full Zig suite is expensive. Run it before a release and after core/config/
renderer/audio/video conflict repair, but it can remain a human-run checkpoint:

```sh
zig build test -Demit-macos-app=false
```

Before release, install and smoke-test the actual branded app:

```sh
./scripts/build-macos-app.sh --install
```

Verify launch, a normal shell, config reload, default microphone response, an
explicit loopback/custom audio device, background media start/stop, and the app
icon. The release script is not a substitute for this product smoke test.

## Cadence

- Rebase before starting a substantial feature.
- Rebase at least weekly while actively developing.
- Rebase before every standalone release.
- If inactive, do not let the fork drift for more than a month without at least
  fetching and reviewing the upstream delta.

Frequent small rebases keep conflict context current and make `rerere` useful.

## Standalone Release

Release only from a clean, smoke-tested `glossolalia` branch:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="glossolalia-notary"
./scripts/release-macos-local.sh preflight 0.1.0
./scripts/release-macos-local.sh prepare 0.1.0
./scripts/release-macos-local.sh publish 0.1.0
```

`prepare` has no Git or GitHub side effects. `publish` re-verifies the artifacts,
requires `origin/glossolalia` to equal the release commit, and creates a draft
GitHub release by default. See `FORKING.md` for the full release checklist.
