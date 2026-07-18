# Melos (Flutter/Dart) monorepo → aeb Migration — Status

Upstream: https://github.com/adityadroid/flutter-melos-monorepo (shallow
`--depth 1` clone via `itests/fetch-upstream.sh`).

## Why a melos monorepo is interesting

[Melos](https://melos.invertase.dev/) is the de-facto monorepo tool for
Dart/Flutter: `melos bootstrap` walks every `packages/*` + `apps/*` pubspec,
resolves them, and materialises a `pubspec_overrides.yaml` in each so local
packages resolve by *path* instead of pub.dev. Everything else (analyze,
test) is a `melos run <script>` that shells `dart`/`flutter` per package.

The migration question: aeb already has a `dart` SDK — does it slot in, and
what does replacing `melos bootstrap`'s path-linking look like?

## Modules

| Module | Kind | Compile (pub get + analyze) | Tests | Deps |
|--------|------|------|-------|------|
| packages/bk_utilities | pure Dart | OK | 1/1 | — |
| packages/bk_ui_kit | Flutter | OK | 1/1 | — |
| packages/bk_customers | Flutter | OK | 1/1 | — |
| packages/bk_ticketing | Flutter | OK | 1/1 | — |
| apps/booking_app | Flutter app | OK | 8/8 | bk_ticketing, bk_ui_kit, bk_utilities |
| apps/merchant_app | Flutter app | OK | 8/8 | bk_customers, bk_ui_kit, bk_utilities |

6 modules, 6/6 compile, **20/20 tests pass** (`aeb --scan '.build.ae'` then
`aeb --scan '.tests.ae'`).

## What aeb replaces

- **`melos bootstrap`** → per-app committed `pubspec_overrides.yaml` (the two
  `apps/*/pubspec_overrides.yaml` are tracked aeb overlay files, not upstream)
  + `build.dep()` edges for DAG ordering. No `melos` binary needed.
- **`melos run analyze`** (`dart analyze .` across all) → per-module
  `dart.analyze(b)`.
- **`melos test`** → per-module `dart.test(b)` (`flutter test`), so a failure
  in one package doesn't abort the others (per-module isolation, like the
  go-fyne migration).

## Toolchain

Every module pins `sdk: ">=2.18.0 <3.0.0"` and `flutter: 3.3.0`. The build
routes the dart SDK through the **Flutter-bundled Dart** via
`dart_bin("flutter")` — so `dart.pub_get`/`analyze`/`test` emit
`flutter pub get`/`analyze`/`test`, using Flutter's Dart 2.18 rather than a
system Dart 3.x (which the `<3.0.0` constraint rejects). Install **Flutter
3.3.10** (bundles Dart 2.18.6); tests are `flutter_test` widget/unit tests
that run headless on the Flutter tester — no device/emulator/Android SDK.

## Overlay adaptations (documented, in the tracked files)

- **intl pin.** The apps' upstream pubspecs ask `intl: ^0.18.0`, but Flutter
  3.3.x's `flutter_localizations` ships `intl 0.17.0` — version solving fails.
  The committed `pubspec_overrides.yaml` pins `intl: 0.17.0`.
- **`--no-fatal-infos`.** `flutter analyze` (unlike `dart analyze`) treats an
  info as fatal; the apps carry one upstream `sort_pub_dependencies` info. The
  app `.build.ae`s pass `analyze_flag("--no-fatal-infos")`.

## New dart SDK feature this migration surfaced

- `dart.analyze` gained an `analyze_flag("<flag>")` DSL setter (verbatim,
  repeatable — mirrors `test_flag`) so `--no-fatal-infos` /
  `--fatal-warnings` can be passed without a shell.
