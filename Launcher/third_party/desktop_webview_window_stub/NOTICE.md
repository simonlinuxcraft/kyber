# `desktop_webview_window_stub/` - modification notice

This directory is a modified, no-op stub copy of the upstream Dart package
[`desktop_webview_window`](https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_webview_window),
licensed under Apache License 2.0 (see `LICENSE` in this directory; copied
verbatim from the upstream pub.dev release at version `0.2.3`).

## Why this stub exists

The upstream plugin links `libwebkit2gtk-4.1`, pulling a ~122 MB webkit stack
into the AppImage that is never used on Linux (`flutter_web_auth_2` runs with
`useWebview: false`; nothing calls `WebviewWindow`). Bundling webkit also breaks
startup on distros without a system webkit (Steam Deck/SteamOS), because
webkit2gtk looks for its helper processes at a hardcoded path. The stub replaces
the upstream package via a `dependency_overrides:` entry in the Launcher
`pubspec.yaml`.

## Modifications relative to upstream

- `lib/desktop_webview_window.dart` and `linux/*` are hand-written no-op
  replacements (the plugin registers as a no-op; `WebviewWindow.create` throws
  `UnsupportedError`, `isWebviewAvailable` returns false).
- `linux/CMakeLists.txt` drops the webkit2gtk dependency (GTK only).
- `pubspec.yaml` keeps the upstream package name and platform declarations so
  `dependency_overrides:` resolves the substitution and the generated
  macOS/Windows plugin registrants stay identical to upstream.
- `lib/src/webview.dart` and `lib/src/create_configuration.dart` are copied
  unchanged from upstream.

## Distribution

- Apache-2.0 §4(a): the upstream `LICENSE` (provided here) ships with any
  conveyed copy.
- Apache-2.0 §4(b): the modified files above carry this notice of change.
- Apache-2.0 is GPLv3-compatible, so this stub may be combined with the
  GPLv3 Kyber tree.

## Attribution

- Upstream package: Copyright 2021 Mixin (see `LICENSE`).
- Stub modifications: simonlinuxcraft (Kyber Linux Port), 2026.
