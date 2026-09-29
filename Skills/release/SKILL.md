---
name: release
description: Cut a ByteRipper release — set the version and build number, bring the README in line with what shipped, build the universal ad-hoc .dmg and check it, write the release notes, commit, tag, push and publish the GitHub release. Use when asked to make, cut or publish a release or a new version ("сделай релиз 0.8.5"). Invoke as /release <version>.
---

# Releasing ByteRipper

A release is one commit on `main` that sets the version and updates the README,
an annotated tag on it, and a GitHub release carrying one `.dmg`. The app's own
update check reads `/releases/latest` and compares its `tag_name` with the
running version (`ByteRipperApp/Updates/GitHubReleases.swift`), so the tag is
always `v<version>` and a release is never marked as a prerelease.

The mechanical parts are a script; the words — the notes and the README — are
the work.

```bash
python3 Skills/release/scripts/release.py bump <version>   # project.yml + README download line
python3 Skills/release/scripts/release.py build            # build/release/ByteRipper-<version>.dmg, checked
```

## Steps

### 1. Before anything

- On `main`, clean tree, up to date with `origin/main`. Releases are cut from
  `main`; nothing is branched.
- **Tests.** The full suite is the user's to run, not this skill's
  (`Scripts/run-tests.sh`, ~an hour, and it must not run beside another
  `xcodebuild test`). Ask whether the sweep is green on the commit being
  released; do not start it unasked.
- **Help.** Both checks clean:
  `python3 Skills/help-coverage/scripts/help_coverage.py` and
  `python3 Skills/help-names/scripts/help_names.py`. A release does not ship a
  stale translation.

### 2. Read what changed

```bash
git describe --tags --abbrev=0          # the last release, e.g. v0.8.4
git log --oneline <last-tag>..HEAD
```

Read the commits, not only their subjects, for anything user-visible: a new
command, a new panel or reading, a changed behaviour, a fix a user would have
met. Help-book and translation commits count as one line together unless they
add something a reader would notice (a new language, a new book).

### 3. Bump

```bash
python3 Skills/release/scripts/release.py bump <version>
```

Writes `MARKETING_VERSION`, increments `CURRENT_PROJECT_VERSION` by one, and
changes the README's download line. It refuses a version that is already set.

### 4. The README

The README is the page in front of the download, and it describes the app as
it is now — not a changelog. For each user-visible change from step 2, find
where the README already talks about that area (*On the bench*, *The tool
panel*, the feature sections further down) and bring it up to date there; add
a bullet only for something that has no home yet. Keep its voice: a bench's
questions, plain words, what the app does rather than how it is built.

### 5. Build and check the image

```bash
python3 Skills/release/scripts/release.py build
```

A universal (arm64 + x86_64) Release build, ad-hoc signed regardless of the
machine's `Signing.local.xcconfig` — a personal team never ships. Packed as a
compressed APFS image, volume `ByteRipper <version>`, holding `ByteRipper.app`
and a link to `/Applications`. The script then mounts the image and checks the
version, the build number, both architectures and the signature; it stops on
anything wrong. The `.dmg` lands in `build/release/` (git-ignored).

### 6. The release notes

Written to a file in the scratchpad, never committed. The shape the releases
have kept since 0.8:

- **Title:** `ByteRipper <version> — <what the release is about>`, a phrase,
  lower case after the dash (*a part of a dump, opened over it*).
- **Opening paragraph:** what the release is about, in two or three sentences.
- **`###` sections**, the larger themes first, each a short paragraph and then
  bullets with the feature in **bold** where it starts. Then `### Smaller
  things` and `### Fixes` — a fix says what the user saw go wrong, not the
  code that was wrong.
- **The footer**, verbatim: `reference/notes-footer.md`.

Menu paths and names as the English app says them (`**Edit ▸ Copy to Other
Pane**`, ⌥⌘C).

### 7. Commit, tag, push, publish

```bash
git add project.yml README.md
git commit      # "Set <version>, and say in the README what it is" + a body naming what the README gained
git tag -a v<version> -m "ByteRipper <version>"
git push origin main v<version>
gh release create v<version> build/release/ByteRipper-<version>.dmg \
    --title "ByteRipper <version> — …" --notes-file <notes.md> --latest
```

Publishing is outward-facing: confirm with the user before `git push` and
`gh release create` unless they asked for the release outright.

### 8. Verify

```bash
gh release view v<version> --json name,tagName,isDraft,isPrerelease,assets
gh api repos/maxshevelev/ByteRipper/releases/latest --jq .tag_name
```

The latest release is the new tag and carries exactly one asset,
`ByteRipper-<version>.dmg`. Report the release URL.
