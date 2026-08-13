# `cli_payload/` - vendored Linux-runtime helpers

This directory contains files that ship with the `kyber_cli` Linux
build but are *not* products of the Kyber sources themselves. They
were vendored from the ACowAdonis **`kyber-bf2-linux`** reference
tarball (V1.0.0), checked out locally at
`/mnt/.../kyber-bf2-linux/` (path on the original maintainer's
machine).

All files in this directory are bundled and distributed as part of
the Kyber Linux Port. The aggregate is conveyed under
**GPL-3.0-only** (parent-repo aggregation, see `Kyber/NOTICE.md` §G);
each file's individual SPDX header reflects its upstream license
(`GPL-3.0-or-later` from the ACowAdonis tarball).

## File-by-file provenance

| File | Source in tarball | Notes |
|---|---|---|
| `umu-wrapper.sh` | `src/share/kyber-bf2/payload/cli/umu-wrapper.sh` | Bash wrapper around umu-run; sets GAMEID, EAEntitlementSource, locale env. SPDX header added in our copy. |
| `ea-auth-webview.py` | `src/share/kyber-bf2/payload/cli/ea-auth-webview.py` | PyGObject + WebKit2 helper for the EA OAuth login flow. SPDX header added. |
| `kyber-auth-helper.sh` | `src/share/kyber-bf2/payload/cli/kyber-auth-helper.sh` | Coordination script invoked by the launcher to drive `ea-auth-webview.py`. SPDX header added. |
| `wine-helper.exe` | `src/share/kyber-bf2/payload/cli/wine-helper.exe` | Pre-built Win32 PE binary, ~786 KiB. **See "wine-helper.exe source" below.** |
| `bin/xdg-open` | `src/share/kyber-bf2/payload/cli/bin/xdg-open` (if present in tarball) | Shim that prefers the host's `xdg-open` over the umu-pressure-vessel one. |

## `wine-helper.exe` source - GPLv3 §6(b) written offer

`wine-helper.exe` is a pre-compiled Windows PE binary that ships in
the ACowAdonis `kyber-bf2-linux` reference tarball (V1.0.0). It
acts as a small Wine-side helper that the Linux launcher invokes
to query the in-Wine PID of the running game executable. The
binary's original source has not been published in a public
repository as of the time of this distribution.

To meet GPLv3 §6 source-availability obligations when this binary
is conveyed as part of the Kyber Linux Port (e.g. in an AppImage
release), the **Kyber Linux Port maintainers offer to provide the
complete corresponding source code** for `wine-helper.exe`, on a
durable physical medium customarily used for software interchange,
**for a period of at least three years from the date of
conveyance**, at no charge beyond the cost of physically performing
the source distribution. This is a §6(b) written offer.

**To request the source**, open an issue at
<https://github.com/simonlinuxcraft/kyber-linuxport-unofficial/issues>
with the title `wine-helper.exe source request` and include the
release version (e.g. AppImage filename / git tag) you received
the binary with. The maintainers will then either:

- supply the source directly (if obtainable from the upstream
  Maxima maintainers), or
- point to a public source repository where the binary's source
  has since been published (§6(d)), or
- replace the bundled binary with a maintainer-rebuilt equivalent
  whose source is in this repository.

Until that request is filed, `wine-helper.exe` is conveyed under
this written offer.

## Modifications

No content modifications have been made to the files in this
directory beyond the addition of the SPDX license headers in
plain-text files. The binary `wine-helper.exe` is byte-identical
to the tarball.
