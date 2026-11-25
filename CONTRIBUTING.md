# Contributing

Thank you for helping.

## Licences of your contribution

- Changes in `FEGlobe/` are licensed under **AGPL-3.0-or-later with the App Store exception** (`FEGlobe/APPSTORE-EXCEPTION.md`).
- Changes everywhere else are licensed under **MPL-2.0** (`LICENSE`).

By opening a pull request you agree to this, and you confirm that you wrote the change or may license it this way. Start new source files with the `SPDX-License-Identifier` line.

## Working on it

1. `brew install xcodegen`
2. `go run ./tools/icon` (only if you change the icon)
3. `xcodegen`, then open `Atlas.xcodeproj`

Engine tests: in `FEGlobe/`, run `xcodebuild test -scheme FEGlobe -destination 'platform=iOS Simulator,name=<a simulator you have>'`.

## Data

Only add a data source if its licence is open (it allows use by anyone, for any purpose), and list it in `DATA.md` with the credit it asks for.
