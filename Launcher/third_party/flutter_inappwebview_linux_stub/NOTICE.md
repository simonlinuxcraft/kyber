# `flutter_inappwebview_linux_stub/` — modification notice

This directory is a **modified, no-op stub copy** of the upstream
Dart package
[`flutter_inappwebview_linux`](https://github.com/pichillilorenzo/flutter_inappwebview/tree/master/flutter_inappwebview_linux),
licensed under **Apache License 2.0** (see `LICENSE` in this
directory; copied verbatim from the upstream pub.dev release at
version `0.1.0-beta.1`).

## Why this stub exists

The upstream `flutter_inappwebview_linux` plugin requires the
`libwpewebkit-1.0-dev` system package, which is **no longer
available on Ubuntu 24.04+**. To keep the Kyber Linux Launcher
buildable on current Ubuntu releases, this directory replaces the
upstream package via a `dependency_overrides:` entry in the
Launcher `pubspec.yaml`.

## Modifications relative to upstream

- **`linux/flutter_inappwebview_linux_plugin_stub.cc`** is a
  hand-written replacement for the upstream
  `flutter_inappwebview_linux_plugin.cc`. It implements the same
  Flutter plugin entry points but does no actual WebView work
  (registers the plugin, returns success/no-op for all calls).
- **`linux/CMakeLists.txt`** has been simplified to drop the
  `libwpewebkit-1.0-dev` dependency.
- **`pubspec.yaml`** keeps the upstream package name
  (`flutter_inappwebview_linux`) so that `dependency_overrides:`
  resolves the substitution. The `description:` makes the stub
  status explicit.
- **`lib/`** files are unchanged from upstream.

## Distribution

When this stub is conveyed alongside the Kyber Linux port:

- Apache-2.0 §4(b) requires that all Apache-2.0 licensed files
  retain the upstream `LICENSE` (provided here) and that any
  modifications be carried with prominent notice (this `NOTICE.md`).
- Apache-2.0 is GPLv3-compatible, so this stub may legally be
  combined with the GPLv3 Kyber tree.

## Attribution

- Upstream package: copyright (c) 2018-present, the
  `flutter_inappwebview` authors (see upstream LICENSE/NOTICE).
- Stub modifications (this directory's plugin replacement and
  CMakeLists simplification): simonlinuxcraft (Kyber Linux Port),
  2026-05-05.
