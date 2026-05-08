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

# Intercept wine-helper.exe calls and run them directly using Proton's Wine
# binary, bypassing umu-run's pressure-vessel container. Each umu-run
# invocation creates an isolated container, so wine-helper.exe in its own
# container cannot see the game's processes. By running Wine directly, we
# connect to the existing wineserver (shared via WINEPREFIX on host FS).
case "$1" in
  *wine-helper.exe)
    # MAXIMA-LINUX-PORT-MOD: BF2 läuft in einem pressure-vessel-Container mit
    # eigenem PID-Namespace. wine-helper.exe muss IM SELBEN Container laufen,
    # sonst sieht OpenProcess(<Wine-PID>) den BF2-Prozess nicht und die DLL-
    # Injection schlägt still fehl. Lokalisiere den laufenden Game-Container-
    # Bus via steam-runtime-launch-client --list und führe wine-helper darin.
    LAUNCH_CLIENT="$HOME/.local/share/umu/steamrt3/pressure-vessel/bin/steam-runtime-launch-client"
    BF2_BUS=""
    if [ -x "$LAUNCH_CLIENT" ]; then
      BF2_BUS=$("$LAUNCH_CLIENT" --list 2>/dev/null | \
        grep -E '^--bus-name=com\.steampowered\.App[a-f0-9]+$' | head -1 | \
        sed 's|^--bus-name=||')
    fi
    if [ -n "$BF2_BUS" ]; then
      echo "[umu-wrapper] routing wine-helper into container bus: $BF2_BUS" >&2
      exec "$LAUNCH_CLIENT" --bus-name="$BF2_BUS" -- wine64 "$@"
    fi
    # Fallback: host namespace (OpenProcess auf Container-PIDs schlägt fehl)
    echo "[umu-wrapper] WARN: no game container bus found, falling back to host wine64 (inject likely fails)" >&2
    PROTON_DIR="$HOME/.local/share/maxima/wine/proton"
    WINE_BIN="$PROTON_DIR/files/bin/wine64"
    export WINEPREFIX="$HOME/.local/share/maxima/wine/prefix"
    export WINEDEBUG="fixme-all"
    export WINEFSYNC=1
    export WINEESYNC=1
    export LD_LIBRARY_PATH="$PROTON_DIR/files/lib64:$PROTON_DIR/files/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PATH="$PROTON_DIR/files/bin:$PATH"
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
    PROTON_DIR="$HOME/.local/share/maxima/wine/proton"
    WINE_BIN="$PROTON_DIR/files/bin/wine64"
    if [ -x "$WINE_BIN" ]; then
      WINEPREFIX="$HOME/.local/share/maxima/wine/prefix" \
      WINEDEBUG="fixme-all" \
      WINEFSYNC=1 WINEESYNC=1 \
      LD_LIBRARY_PATH="$PROTON_DIR/files/lib64:$PROTON_DIR/files/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
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
      LD_LIBRARY_PATH="$PROTON_DIR/files/lib64:$PROTON_DIR/files/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$WINE_BIN" reg add "HKCU\\Environment" \
          /v KYBER_HIDE_CONSOLE /t REG_SZ /d 1 /f 2>/dev/null
    fi
    exec "$HOME/.local/share/maxima/wine/umu/umu-run" "$@"
    ;;
esac
