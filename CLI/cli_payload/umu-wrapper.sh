#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Original source: ACowAdonis kyber-bf2-linux tarball
#   (src/share/kyber-bf2/payload/cli/umu-wrapper.sh, V1.0.0)
# Vendored 2026-05-05 into the Kyber Linux Port. Bundled and
# distributed under GPL-3.0-or-later; modifications (if any) are
# tracked in this file's history.
#
# Wrapper around umu-run that sets proper Steam integration for BF2
# Overrides GAMEID from "umu-0" to BF2's Steam App ID
# Overrides EAEntitlementSource from "EA" to "STEAM" (matching actual purchase source)
# Does NOT override WINEPREFIX/STEAM_COMPAT_DATA_PATH - Maxima's internal prefix must be used

# Ensure Wine sees a valid locale. Without LC_ALL in the environment, Wine
# may not correctly report en-US via GetUserDefaultLCID(), causing the game's
# internal language entitlement check to fail with "installed in a language
# that you are not entitled to play."
# Sanitize PATH: Launcher's Dart code appends to PATH using semicolons
# (Windows separator) instead of colons (Linux separator). Replace any
# semicolons with colons so Wine/umu-run see a valid PATH.
export PATH="${PATH//;/:}"

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

export GAMEID=1237950
export SteamAppId=1237950
export SteamGameId=1237950
export STORE=steam

# Override Maxima's hardcoded EAEntitlementSource=EA to match Steam purchase
export EAEntitlementSource=STEAM
export EAExternalSource=STEAM
export EALaunchOwner=STEAM

# Disable gamedrive compat option. When UMU_ID is set, Proton's protonfixes
# force-enables gamedrive which creates x: -> $HOME and u: -> /media in
# dosdevices. These extra drive letters break get_os_pid() which only handles
# Z: prefix stripping. With gamedrive disabled, setup_dir_drive() will
# actively remove any existing x:/u: symlinks.
export PROTON_SET_GAME_DRIVE=0

# Compile shaders asynchronously. Prevents stutter from shader compilation
# at the cost of brief visual artifacts on first encounter.
export DXVK_ASYNC=1

# Use Wine's built-in msvcp140 instead of the native Microsoft DLL.
# SafetyHook (statically linked in Kyber.dll) has a static std::mutex in
# Allocator::global() that is constexpr zero-initialized. Native msvcp140's
# _Mtx_lock assumes the internal implementation pointer at offset 8 is valid,
# but it's null for zero-initialized mutexes. Wine's built-in msvcp140 handles
# this correctly using its own synchronization primitives.
export WINEDLLOVERRIDES="msvcp140=b;${WINEDLLOVERRIDES}"

# MAXIMA-LINUX-PORT-MOD 2026-05-24: resolve effective proton directory.
# Resolution order matches maxima-lib's proton_dir():
#   1. KYBER_PROTON_PATH env-var (power-user override)
#   2. ~/.local/share/maxima/custom_proton_path sidecar file (launcher UI)
#   3. ~/.local/share/maxima/wine/proton (maxima auto-managed default)
# Single source of truth so both case-branches below stay consistent
# (Bug-Hunter #2).
KYBER_RESOLVED_PROTON_DIR="${KYBER_PROTON_PATH:-}"
if [ -z "$KYBER_RESOLVED_PROTON_DIR" ]; then
  _kyber_sidecar="$HOME/.local/share/maxima/custom_proton_path"
  if [ -f "$_kyber_sidecar" ]; then
    # Bash $() strips trailing newlines but preserves internal whitespace.
    # Critical: don't tr -d '[:space:]' here - that would strip spaces INSIDE
    # the path (e.g. "Proton-GE Latest" -> "Proton-GELatest" → no such dir).
    KYBER_RESOLVED_PROTON_DIR=$(<"$_kyber_sidecar")
  fi
fi
if [ -z "$KYBER_RESOLVED_PROTON_DIR" ]; then
  KYBER_RESOLVED_PROTON_DIR="$HOME/.local/share/maxima/wine/proton"
fi

# Tolerant layout detection: probe known wine64 locations across builds.
# GE-Proton uses files/bin/, Valve stock uses dist/bin/, some Lutris/Heroic
# builds use a flat bin/. Returns empty if none found - caller handles.
#
# MAXIMA-LINUX-PORT-MOD 2026-05-25: also probe `wine` (no `64` suffix) for
# Wine-10 WoW64 single-binary builds (proton-cachyos 11.0, future GE-Proton
# 11+). Wine 10 merged 32/64-bit into one multilib binary named just `wine`.
# Prefer `wine64` when both exist so legacy split-binary builds keep their
# original behaviour.
_kyber_resolve_wine_bin() {
  local dir="$1"
  for sub in files/bin/wine64 dist/bin/wine64 bin/wine64 \
             files/bin/wine dist/bin/wine bin/wine; do
    if [ -x "$dir/$sub" ]; then
      printf '%s' "$dir/$sub"
      return 0
    fi
  done
  return 1
}

_kyber_resolve_lib_paths() {
  # Returns a colon-joined list of ALL existing library directories under the
  # given proton dir. Critical: must include both lib64 AND lib (32-bit), the
  # original wrapper had both. Wine-helper.exe and parts of pressure-vessel
  # need 32-bit libs even on 64-bit games.
  local dir="$1"
  local out=""
  for sub in files/lib64 dist/lib64 lib64 files/lib dist/lib lib; do
    if [ -d "$dir/$sub" ]; then
      if [ -z "$out" ]; then
        out="$dir/$sub"
      else
        out="$out:$dir/$sub"
      fi
    fi
  done
  printf '%s' "$out"
}

# Stderr log of resolved proton dir so the launcher log shows exactly which
# proton each wine call used. Cheap, helps debug custom-proton issues.
echo "[umu-wrapper] PROTON_DIR=$KYBER_RESOLVED_PROTON_DIR" >&2

# MAXIMA-LINUX-PORT-MOD 2026-05-18: dropped the D-Bus container routing
# for wine-helper.exe and just exec host wine64 directly. The original
# wrapper (vendored 2026-05-05 from ACowAdonis kyber-bf2-linux V1.0.0)
# tried to route wine-helper into BF2's pressure-vessel via
# steam-runtime-launch-client --bus-name=com.steampowered.App[a-f0-9]+,
# but that regex only matches hex AppIDs. BF2's bus name uses the
# decimal AppID 1237950, so BF2_BUS was always empty and the wrapper
# dropped to the host-namespace fallback anyway.
#
# Host wine64 talks to BF2's wineserver via the shared WINEPREFIX
# socket no matter which pressure-vessel BF2 sits in, and the inject
# itself goes through wineserver, so we don't need BF2's PID namespace.
case "$1" in
  *wine-helper.exe)
    # MAXIMA-LINUX-PORT-MOD 2026-05-24: use resolved proton dir (custom or
    # default) with tolerant layout detection.
    # Note: tried forcing default proton here for inject stability with
    # dll-syringe, but mixing two wine64 binaries against the same
    # WINEPREFIX caused wineserver lock contention and froze the game
    # launch. Reverted - custom proton inject failure stays a known
    # limitation until wine-helper.exe itself drops dll-syringe.
    PROTON_DIR="$KYBER_RESOLVED_PROTON_DIR"
    WINE_BIN=$(_kyber_resolve_wine_bin "$PROTON_DIR")
    if [ -z "$WINE_BIN" ]; then
      echo "[umu-wrapper] wine64 not found under $PROTON_DIR (tried files/bin, dist/bin, bin). Custom proton path invalid or Maxima Proton not yet downloaded." >&2
      exit 1
    fi
    LIB_PATHS=$(_kyber_resolve_lib_paths "$PROTON_DIR")
    export WINEPREFIX="$HOME/.local/share/maxima/wine/prefix"
    export WINEDEBUG="fixme-all"
    export WINEFSYNC=1
    export WINEESYNC=1
    if [ -n "$LIB_PATHS" ]; then
      export LD_LIBRARY_PATH="$LIB_PATHS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    BIN_DIR=$(dirname "$WINE_BIN")
    export PATH="$BIN_DIR:$PATH"
    exec "$WINE_BIN" "$@"
    ;;

  # Registry commands - pass through directly
  reg|reg.exe)
    exec "$HOME/.local/share/maxima/wine/umu/umu-run" "$@"
    ;;

  # Game launch
  *)
    # Ensure Kyber.dll suppresses its AllocConsole() debug window on Linux.
    # The var is set by the Launcher and kyber_cli, but steam-runtime-launcher-
    # interface-0 / pressure-vessel may not forward unrecognised env vars through
    # the D-Bus container activation channel. Exporting it here guarantees it
    # reaches Wine regardless of the transport (exec-inherit, bwrap --setenv, or
    # D-Bus protocol env-list). See Kyber/Module/Source/Core/Program.cpp:139.
    export KYBER_HIDE_CONSOLE=1

    # Before launching the game, force-set the Wine locale to en-US.
    # The bootstrap's reg.exe calls trigger Wine's prefix initialisation which
    # reads $LANG (de_DE on German systems) and writes Locale=0x0407 into
    # HKCU\Control Panel\International. BF2 then calls GetUserDefaultLCID()
    # which returns de-DE, failing the language entitlement check.
    # We run wine64 directly (no umu-run overhead, uses the running wineserver)
    # immediately before the game launch so it takes effect before BF2 reads it.
    # MAXIMA-LINUX-PORT-MOD 2026-05-24: use resolved proton dir (custom or
    # default) with tolerant layout detection.
    PROTON_DIR="$KYBER_RESOLVED_PROTON_DIR"
    WINE_BIN=$(_kyber_resolve_wine_bin "$PROTON_DIR")
    if [ -n "$WINE_BIN" ]; then
      LIB_PATHS=$(_kyber_resolve_lib_paths "$PROTON_DIR")
      _kyber_ld="${LIB_PATHS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      WINEPREFIX="$HOME/.local/share/maxima/wine/prefix" \
      WINEDEBUG="fixme-all" \
      WINEFSYNC=1 WINEESYNC=1 \
      LD_LIBRARY_PATH="$_kyber_ld" \
        "$WINE_BIN" reg add "HKCU\\Control Panel\\International" \
          /v Locale /t REG_SZ /d 00000409 /f 2>/dev/null

      # MAXIMA-LINUX-PORT-MOD: Verified empirically that env vars set on the
      # Linux side (Dart Process.start environment, this script's `export`,
      # kyber_cli env) do NOT reach the BF2.exe process: cat /proc/<bf2-pid>/environ
      # shows only login-shell vars. Pressure-vessel / wineserver re-initialises
      # the PEB from sources other than the Linux env. Wine reads HKCU\Environment
      # at Win32 process start to seed PEB env, so writing KYBER_HIDE_CONSOLE
      # there is the only path that reaches Kyber.dll's std::getenv check
      # (Kyber/Module/Source/Core/Program.cpp:139).
      WINEPREFIX="$HOME/.local/share/maxima/wine/prefix" \
      WINEDEBUG="fixme-all" \
      WINEFSYNC=1 WINEESYNC=1 \
      LD_LIBRARY_PATH="$_kyber_ld" \
        "$WINE_BIN" reg add "HKCU\\Environment" \
          /v KYBER_HIDE_CONSOLE /t REG_SZ /d 1 /f 2>/dev/null
    fi
    # umu-run itself stays Maxima-managed - it reads PROTONPATH from its env
    # (set by maxima-lib's run_wine_command, which goes through proton_dir()
    # and therefore honors the custom override automatically).
    exec "$HOME/.local/share/maxima/wine/umu/umu-run" "$@"
    ;;
esac
