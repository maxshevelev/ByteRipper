# Building ByteRipper

Everything a fork needs and a reader of the [README](README.md) does not: how
the project is built, how it is tested, and how it is put together.

## Build

The Xcode project is **generated**, not committed: the repository keeps
`project.yml` and [XcodeGen](https://github.com/yonaskolb/XcodeGen) makes
`ByteRipper.xcodeproj` from it. Run it after cloning, and again after adding a
source file or a package:

```sh
xcodegen generate
xcodebuild build -project ByteRipper.xcodeproj -scheme ByteRipper -destination 'platform=macOS'
```

A universal release build, the way the `.dmg` is made — ad-hoc signed, because a
build signed with a personal Apple Development identity carries that person's
name and team inside the binary, which is not what to hand to strangers:

```sh
xcodebuild build -project ByteRipper.xcodeproj -scheme ByteRipper \
  -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
```

How a machine's own signing is set up, and why it is worth setting up at all —
a folder the app is given access to stops being accessible after the next build
unless the identity is a real one — is written in `Signing.xcconfig`, beside
the settings it configures.

The app icon — a black flash package on a transparent ground, five leads above
and below, `A5` beside a `FF` marked as a difference — is generated rather than
drawn by hand: `Design/AppIcon.swift` renders the 1024 pt master and
`Design/render-appicon.sh` slices it into the asset catalog.

## Tests

```sh
# the Core package, then the app suite in groups, one group at a time
Scripts/run-tests.sh

# only the classes a change touches
Scripts/run-tests.sh -o "Library|Search"
```

Ninety-five test classes in one `xcodebuild test` is a single process holding a
real window-server session for twenty minutes, and the tests that wait on a
window, an animation or a panel are the ones that give up when the Mac is busy.
The script cuts them into groups and runs one group at a time, tearing the test
host down in between. Never run two of them at once: they share one UI session,
and what that produces reads exactly like a real bug.

## Architecture

Storage layer (`ByteRipperCore`) → model (`BinaryDocument`, diff, search, undo)
→ view-models (`PaneViewModel`, `WindowModel`) → AppKit views (`HexView`,
`FilePaneView`, `ComparisonView`, `MinimapView`). Domain code is pure Swift and
unit-tested; all UI runs on the main actor, and long-running work (diff, search,
the overview map) runs in background tasks.

Every unit of code outside the app target is a local SPM package — shared
libraries under `Packages/`, the tool-module panels under `Modules/` — and there
are no remote dependencies. The one exception is decoders and encoders for
published formats: the reference C sources, vendored unmodified, with their
origin and version written down beside them.

The behaviour is specified in `Design/REQUIREMENTS.md`, and the design documents
beside it record why each feature came out the way it did.
