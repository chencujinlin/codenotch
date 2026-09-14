# Repository Guidelines

## Project Structure & Module Organization

Codenotch is a macOS 15+ SwiftUI/AppKit application. `Sources/App/` owns lifecycle;
`Sources/Providers/` reads provider quotas; `Sources/Model/` holds usage models and
daily Token accounting. `Sources/Notch/`, `Sources/Features/`, and
`Sources/DesignSystem/` define the notch and its animation. Settings live in
`Sources/Settings/`; translations in `Sources/Localizable.xcstrings`.
`Tests/` groups tests by concern. `docs/` contains design and accounting notes.
The Windows port in `windows/` has a separate toolchain and localization system.

## Build, Test, and Development Commands

- `brew install xcodegen`: install the generator for `project.yml`.
- `make build`: generate and build the macOS Debug app using full Xcode.
- `make run`: build and launch locally.
- `make test`: run the complete macOS test suite; `make test-ci` disables signing.
- `python3 Scripts/build-local.py`: build `build/Codenotch.app` using Command Line
  Tools and SwiftPM. This local variant disables upstream automatic updates.
- `python3 Scripts/build-local.py --tokens-only`: run standalone Token tests
  without Xcode or the app's network dependencies.

Do not edit generated `.xcodeproj` files. Keep prerequisites and commands in
`README.md` and `README.zh-CN.md` synchronized with scripts.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members.
Follow surrounding Swift code; no repository-wide formatter is configured.
Route visible copy through `L10n.t("English source")`; preserve interpolation
types in translations. Never cache localized copy in `static let`.
Prefer small, focused changes and comments explaining constraints.

## Testing Guidelines

Existing tests use XCTest; daily Token tests use Swift Testing. Use descriptive
`test…` names and synthetic fixtures. Cover cache accounting, duplicate records,
forks, partial files, and calendar boundaries when changing statistics. No numeric
coverage threshold exists. Run relevant tests and report unavailable checks.

## Commit & Pull Request Guidelines

Use concise, imperative commit subjects consistent with upstream history.
Explain resulting behavior and validation in PRs; link issues and include
screenshots for UI changes. Preserve the existing notch design.

## Security & Configuration

Never commit credentials, real transcripts, or generated build artifacts.
Read logs without modifying them; retain only usage metadata. Unsupported or
incomplete data must have an explicit status, never an invented count.
