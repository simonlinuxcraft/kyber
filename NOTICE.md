# NOTICE - Kyber Linux Port

This repository is a **Linux port** of upstream
[ArmchairDevelopers/Kyber](https://github.com/ArmchairDevelopers/Kyber).
The upstream project is licensed under **GPL-3.0-or-later** (see
`LICENSE`); all modifications below preserve that license.

This file is the central record of (a) modifications relative to
upstream, (b) third-party code vendored into this tree, and (c)
the licensing implications of the produced artefacts. It satisfies
the GPLv3 §5(a) "carry prominent notices stating that you modified
it" requirement at the repository level. Per-file and per-directory
detail is kept in the linked `CHANGES.md` / `NOTICE.md` files.

---

## A. Modifications to upstream Kyber

The Linux port adds and modifies code across several areas. None of
the modifications relicense any upstream-GPLv3 file; all derived
work is distributed as GPL-3.0-only (see "Aggregation license" below).

| Area | Status | Detail |
|---|---|---|
| `Launcher/` (Flutter/Dart) | Modified | Linux-specific paths, CLI subprocess delegation for game launch, NXM protocol handler, self-update pipeline |
| `Launcher/linux/` | New | Linux entry-point and helper shell scripts (SPDX headers in each file) |
| `Launcher/lib/core/services/linux_*.dart`, `Launcher/lib/features/.../*linux*.dart` | New | Linux-only Dart services |
| `Launcher/third_party/flutter_inappwebview_linux_stub/` | New | No-op stub of the upstream `flutter_inappwebview_linux` package; see `Launcher/third_party/flutter_inappwebview_linux_stub/NOTICE.md` |
| `CLI/` (Flutter/Dart) | Modified | Native Linux build, FRB-bridge tied to the patched Maxima copy below |
| `CLI/cli_payload/` | New (vendored) | Helper scripts and binaries from the ACowAdonis tarball; see `CLI/cli_payload/README.md` |
| `ThirdParty/Maxima/` | Modified | Patched local copy of upstream Maxima (GPL-3.0); see `ThirdParty/Maxima/CHANGES.md` |
| `CLI/ThirdParty/Maxima/` | Modified | Second patched copy of upstream Maxima; see `CLI/ThirdParty/Maxima/CHANGES.md` |
| `Module/` | Unchanged | Upstream Kyber game-side injection layer |

## B. Vendored third-party code

Files that originated outside this repository and are bundled here
for the Linux port to function:

| Path | Origin | Upstream license | Compliance notes |
|---|---|---|---|
| `CLI/cli_payload/umu-wrapper.sh` | ACowAdonis `kyber-bf2-linux` tarball, V1.0.0 | GPL-3.0-or-later (matches tarball) | SPDX header added; vendored 2026-05-05. **Modified 2026-05-07**: added wine-helper container-routing `case`, locale `reg add` and `KYBER_HIDE_CONSOLE` Wine-registry seeding. **Modified 2026-05-18**: dropped D-Bus container routing for wine-helper.exe, exec host wine64 directly. **Modified 2026-05-24**: tolerant Proton-layout detection (files/bin, dist/bin, bin) and resolution of the user-supplied custom Proton path via `KYBER_PROTON_PATH` env-var or `~/.local/share/maxima/custom_proton_path` sidecar file. **Modified 2026-05-25**: also accept the Wine 10 WoW64 single-binary layout (`wine` without `wine64` suffix, e.g. proton-cachyos 11.x). **Modified 2026-05-26**: the WINEPREFIX now stays the shared default - per-Proton routing happens at the `wine/proton` symlink level in maxima-lib instead of via per-prefix WINEPREFIX, keeping save games + EA App login state shared across Proton switches. Each block marked with `MAXIMA-LINUX-PORT-MOD` comments. |
| `CLI/cli_payload/ea-auth-webview.py` | Same | GPL-3.0-or-later | SPDX header added |
| `CLI/cli_payload/kyber-auth-helper.sh` | Same | GPL-3.0-or-later | SPDX header added |
| `CLI/cli_payload/wine-helper.exe` | Same (pre-built Win32 PE binary) | GPL-3.0-or-later (per tarball) | Binary, no in-tree source. **§6(b) written offer applies - see `CLI/cli_payload/README.md` for source-request procedure (GitHub Issues).** |
| `Launcher/third_party/flutter_inappwebview_linux_stub/lib/` | Upstream `flutter_inappwebview_linux` 0.1.0-beta.1 | Apache-2.0 | Verbatim copy; `LICENSE` and `NOTICE.md` carried with the stub |
| `Launcher/third_party/flutter_inappwebview_linux_stub/linux/*plugin_stub.cc` | New (Kyber Linux Port) | Apache-2.0 (matches host package) | Hand-written no-op replacement |
| `Launcher/assets/fonts/BarlowCondensed-Medium.ttf`, `…-MediumItalic.ttf` | Barlow project (jpt/barlow), v1.422+ | SIL Open Font License 1.1 | Replacement for proprietary Univers Next Pro Medium Condensed (the `BattlefrontUI` font family in `pubspec.yaml`); Barlow-OFL.txt carried alongside |
| `Launcher/assets/fonts/Barlow-OFL.txt` | jpt/barlow LICENSE | SIL OFL 1.1 (verbatim) | Required-with-redistribution per OFL §1 |
| `Launcher/assets/fonts/AurebeshRodian.otf` | AurekFonts/Aurebesh_Rodian (https://github.com/AurekFonts/Aurebesh_Rodian) | MIT | Replacement for proprietary Pixel Sagas Aurebesh; AurebeshRodian-LICENSE.txt carried alongside |
| `Launcher/assets/fonts/AurebeshRodian-LICENSE.txt` | AurekFonts/Aurebesh_Rodian LICENSE | MIT (verbatim) | Required by MIT clause to retain copyright + license notice |

## C. Cargo-patched dependencies

Both `Launcher/rust/Cargo.toml` and `CLI/rust/Cargo.toml` apply
`[patch.crates-io]` overrides to four crates, redirecting them at
ArmchairDevelopers- / Davenport- / lifegpc-maintained forks:

| Crate | Upstream license | Fork URL | Compliance status |
|---|---|---|---|
| `flate2` | MIT / Apache-2.0 | `github.com/ArmchairDevelopers/flate2-rs` | Pending verification that fork retains upstream LICENSE |
| `async-compression` | MIT / Apache-2.0 | `github.com/ArmchairDevelopers/async-compression` | Pending verification |
| `dll-syringe` | MIT | `github.com/Davenport-Physics/dll-syringe` | Pending verification |
| `pelite` | MIT | `github.com/lifegpc/pelite` | Pending verification |

All four upstream licenses are GPLv3-compatible. The forks
themselves must retain their respective `LICENSE` files and
markings; this is to be verified before the Kyber Linux Port repo
is published.

## D. Closed-source artefacts in `Launcher/`

The upstream Kyber project ships pre-built binary modules
(`Kyber.dll`, `vivoxsdk.dll`, BF2 game files, etc.) that are
**not** Kyber Linux Port artefacts and not GPLv3 covered. Their
redistribution is governed separately (EA EULA, Vivox SDK license,
and similar). The Kyber Linux Port does not redistribute any of
these binaries; users acquire them via Steam / EA Origin
themselves.

## E. Combined-work implications

The shared Rust library `librust_lib.so` (built from `Launcher/rust/`
and `CLI/rust/`) statically links the GPLv3 `maxima-lib`. Per the
FSF position on static linking, the resulting `.so` is a GPLv3
combined work. Consumers of that `.so` (the Flutter Launcher and
`kyber_cli`) are therefore GPLv3-conveyed when distributed with
the library. Since this repository as a whole is already
GPL-3.0-only, no additional licensing constraint arises;
distributors must, however, honour GPLv3 §6 source-availability
when they convey binaries.

## F. License files

- `LICENSE` - GPL-3.0 (full text), upstream-Kyber-provided
- `Launcher/third_party/flutter_inappwebview_linux_stub/LICENSE`
 - Apache-2.0 (upstream package license)
- `ThirdParty/Maxima/LICENSE` - GPL-3.0 (upstream Maxima)
- `CLI/ThirdParty/Maxima/LICENSE` - GPL-3.0 (upstream Maxima)

## G. Aggregation license

The Kyber Linux Port aggregates code under **GPL-3.0-only**. Selbst-erstellte
Linux-Port-Quellen (`Launcher/linux/*.sh`, `Launcher/linux/kyber-bf2`,
`Launcher/lib/core/services/linux_*.dart`, etc.) tragen einen
`SPDX-License-Identifier: GPL-3.0-only`-Header. Vendored Files aus dem
ACowAdonis-Tarball (`CLI/cli_payload/umu-wrapper.sh`,
`CLI/cli_payload/ea-auth-webview.py`, `CLI/cli_payload/kyber-auth-helper.sh`)
behalten ihren Upstream-Header `GPL-3.0-or-later`, weil dieser die
ursprüngliche Tarball-Lizenz korrekt wiedergibt. Da `GPL-3.0-only` eine
zulässige Wahl unter `GPL-3.0-or-later` ist (§14 GPLv3 erlaubt einem
Distributor, eine spezifischere spätere Version zu wählen), ist die
Aggregation unter `GPL-3.0-only` GPL-konform.

Upstream Kyber und upstream Maxima sind ihrerseits unter `GPL-3.0`
lizenziert (siehe ihre `LICENSE`-Dateien); diese Aufnahme als
`GPL-3.0-only` ist konsistent mit der `LICENSE`-Datei beider Upstreams.

## H. Maintainership

Linux port modifications are maintained by
**[simonlinuxcraft](https://github.com/simonlinuxcraft)** as
"Kyber Linux Port contributors" (currently a single contributor;
a CONTRIBUTORS file will be added if/when others join). The
upstream Kyber maintainers are listed in `README.md`.

---

This NOTICE will be updated when third-party code is added,
removed, or relicensed. Last reviewed: 2026-05-26.
