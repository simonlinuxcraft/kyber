//! Linux-only environment bootstrap.
//!
//! The primary fix for BF2's "wrong language" Origin error lives in
//! `setup_wine_registry()` (sets `Locale=en_US` directly in the Wine prefix).
//! This module is the second line of defence: it makes sure that other
//! subprocesses spawned by the launcher (umu-run, the maxima-bootstrap, the
//! Wine helper, the pressure-vessel container) actually find an
//! `en_US.UTF-8` locale on disk when they invoke `setlocale()`.
//!
//! Strategy:
//!   1. Probe `setlocale(LC_ALL, "en_US.UTF-8")` to see whether the locale
//!      already exists (it does on most Ubuntu/Debian/Fedora desktops once
//!      the user has enabled the `locales` / `glibc-langpack-en` package).
//!   2. If it does NOT exist, try to compile it into a per-user directory
//!      with `localedef --no-archive`. This needs the i18n source files
//!      (`/usr/share/i18n/locales/en_US`) and the `localedef` binary; on
//!      glibc-based distros both ship as part of the libc-bin/glibc-common
//!      package and are present by default.
//!   3. Export `LOCPATH` so that subprocess `setlocale()` calls can find
//!      our generated locale. We deliberately do NOT touch the `LANG` or
//!      `LC_ALL` of the launcher process: the user picked their UI
//!      language and we should not silently flip the launcher to English.
//!      The Wine subprocesses get `LC_ALL=en_US.UTF-8` from
//!      `umu-wrapper.sh`, which combined with our `LOCPATH` is enough.

#![cfg(target_os = "linux")]

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::process::Command;

const TARGET_LOCALE: &str = "en_US.UTF-8";
const I18N_SOURCE: &str = "/usr/share/i18n/locales/en_US";

/// BF2 Steam App ID — used to locate the Steam compatdata wine prefix.
const BF2_STEAM_APP_ID: &str = "1237950";

/// Ensure the critical Maxima → Steam-compatdata wine prefix symlink exists.
/// Without this symlink Maxima creates its own empty wine prefix, missing all
/// BF2 install state (Origin registry entries, EA Desktop user.ini, license
/// cache, etc.) — game would fail to launch with an Origin/EA error.
///
/// The symlink also has to outlive any cleanup script the user might run,
/// so we verify (and rebuild if needed) on every `init_app()`.
///
/// Located possible Steam library roots (in order):
///   - $STEAM_LIBRARY_ROOT (manual override)
///   - /mnt/Games/SteamLibrary  (current setup)
///   - $HOME/.steam/steam
///   - $HOME/.local/share/Steam
pub fn ensure_critical_symlinks() {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return,
    };

    let link_path = PathBuf::from(format!(
        "{}/.local/share/maxima/wine/prefix",
        home
    ));

    let candidates: Vec<PathBuf> = std::env::var("STEAM_LIBRARY_ROOT")
        .ok()
        .map(PathBuf::from)
        .into_iter()
        .chain([
            PathBuf::from("/mnt/Games/SteamLibrary"),
            PathBuf::from(format!("{}/.steam/steam", home)),
            PathBuf::from(format!("{}/.local/share/Steam", home)),
        ])
        .map(|root| root.join("steamapps/compatdata").join(BF2_STEAM_APP_ID).join("pfx"))
        .collect();

    let target = match candidates.iter().find(|p| p.exists()) {
        Some(p) => p.clone(),
        None => {
            log::warn!(
                "No BF2 Steam compatdata found in any candidate path. Tried: {}. \
                 Open Steam and let it create the BF2 prefix once, then restart.",
                candidates.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ")
            );
            return;
        }
    };

    // If something exists at link_path, verify it.
    if let Ok(meta) = std::fs::symlink_metadata(&link_path) {
        if meta.file_type().is_symlink() {
            match std::fs::read_link(&link_path) {
                Ok(current) if current == target => {
                    log::debug!(
                        "Maxima wine prefix symlink OK: {} -> {}",
                        link_path.display(),
                        target.display()
                    );
                    return;
                }
                Ok(current) => {
                    log::warn!(
                        "Maxima wine prefix symlink points to {} but should point to {}; \
                         replacing.",
                        current.display(),
                        target.display()
                    );
                    if let Err(e) = std::fs::remove_file(&link_path) {
                        log::warn!("Failed to remove stale symlink: {}", e);
                        return;
                    }
                }
                Err(e) => {
                    log::warn!("Failed to read existing symlink target: {}", e);
                    return;
                }
            }
        } else {
            // It's a regular dir/file — don't blindly clobber user data.
            log::warn!(
                "{} already exists and is not a symlink (looks like a real \
                 directory). Refusing to replace; please move it aside if you \
                 want Maxima to use the Steam compatdata prefix.",
                link_path.display()
            );
            return;
        }
    }

    // Make sure the parent dir exists before creating the symlink.
    if let Some(parent) = link_path.parent() {
        if !parent.exists() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                log::warn!(
                    "Failed to create parent dir {}: {}",
                    parent.display(),
                    e
                );
                return;
            }
        }
    }

    match std::os::unix::fs::symlink(&target, &link_path) {
        Ok(()) => log::info!(
            "Restored Maxima wine prefix symlink: {} -> {}",
            link_path.display(),
            target.display()
        ),
        Err(e) => log::warn!(
            "Failed to create symlink {} -> {}: {}",
            link_path.display(),
            target.display(),
            e
        ),
    }
}

/// Make sure a usable `en_US.UTF-8` locale is reachable to all child
/// processes. Called from `init_app()` *before* any tokio runtime or other
/// background thread is started, so the `unsafe { set_var }` is sound.
pub fn ensure_en_us_utf8_locale() {
    if locale_already_works() {
        log::debug!("en_US.UTF-8 already available system-wide; nothing to do");
        return;
    }

    let target_dir = match user_locale_root() {
        Some(d) => d,
        None => {
            log::warn!(
                "Cannot determine $HOME — skipping en_US.UTF-8 generation. \
                 BF2 may fall back to the host locale."
            );
            return;
        }
    };

    let locale_dir = target_dir.join(TARGET_LOCALE);

    // We don't trust an existing locale_dir as proof of a finished
    // generation: localedef may have been killed mid-write, leaving a
    // partial LC_* file set. Re-running localedef is cheap (~100ms) and
    // generate_user_locale() wipes the directory before each attempt,
    // so we always (re)generate when the system probe failed.
    if !Path::new(I18N_SOURCE).exists() {
        log::warn!(
            "{} missing — install the locale source package \
             (Ubuntu/Debian: `locales`, Fedora/RHEL: `glibc-langpack-en`, \
             Arch/openSUSE: already in `glibc`). Falling back to whatever \
             the host already exports.",
            I18N_SOURCE,
        );
        return;
    }

    match generate_user_locale(&locale_dir) {
        Ok(()) => log::info!(
            "Generated {} into {}",
            TARGET_LOCALE,
            locale_dir.display()
        ),
        Err(err) => {
            log::warn!(
                "Failed to generate {} into {}: {err}. \
                 BF2 may abort with the language entitlement error \
                 even though the Wine registry has the correct locale.",
                TARGET_LOCALE,
                locale_dir.display()
            );
            return;
        }
    }

    prepend_locpath(&target_dir);
}

fn locale_already_works() -> bool {
    let locale = match CString::new(TARGET_LOCALE) {
        Ok(s) => s,
        Err(_) => return false,
    };

    // SAFETY: setlocale is process-global state. We are called from
    // init_app() before any other thread is spawned, so no concurrent
    // setlocale racing with us is possible.
    //
    // The probe has a side effect: passing a non-NULL locale name *changes*
    // the process's C locale. We don't want that — the user picked their
    // UI language and locale-sensitive C calls (Dart's intl, GTK number
    // formatting) should keep that. So we capture the previous locale and
    // restore it after the probe.
    let previous_ptr = unsafe { libc::setlocale(libc::LC_ALL, std::ptr::null()) };
    let previous = if previous_ptr.is_null() {
        None
    } else {
        // setlocale returns a pointer to a static buffer; copy out before
        // calling setlocale again, which will overwrite that buffer.
        unsafe { std::ffi::CStr::from_ptr(previous_ptr) }
            .to_owned()
            .into()
    };

    let probe = unsafe { libc::setlocale(libc::LC_ALL, locale.as_ptr()) };
    let works = !probe.is_null();

    if let Some(prev) = previous {
        // Restore the original locale. This is best-effort — if it fails
        // we accept the en_US.UTF-8 leak (the alternative is a broken
        // locale state, which is worse).
        unsafe { libc::setlocale(libc::LC_ALL, prev.as_ptr()) };
    }

    works
}

fn user_locale_root() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".local/share/kyber/locale"))
}

fn generate_user_locale(locale_dir: &Path) -> std::io::Result<()> {
    if let Some(parent) = locale_dir.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Wipe any previous half-written attempt. localedef happily writes a
    // partial set of LC_* files if it crashes mid-way (e.g. disk full);
    // a subsequent run sees a populated directory, skips the regeneration,
    // and setlocale() keeps failing forever.
    if locale_dir.exists() {
        std::fs::remove_dir_all(locale_dir)?;
    }

    let output = Command::new("localedef")
        .arg("--no-archive")
        .arg("-i")
        .arg("en_US")
        .arg("-f")
        .arg("UTF-8")
        .arg(locale_dir)
        .output()
        .map_err(|err| {
            std::io::Error::new(
                err.kind(),
                format!(
                    "could not invoke localedef ({err}). On glibc distros it is \
                     part of `libc-bin` (Debian/Ubuntu) or `glibc-common` \
                     (Fedora/RHEL); musl-based distros do not ship it."
                ),
            )
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(std::io::Error::other(format!(
            "localedef exited with {}: {}",
            output.status,
            stderr.trim()
        )));
    }
    Ok(())
}

/// Set all Steam / Wine env vars required for BF2 to launch correctly via the
/// Launcher's in-process Maxima FFI. Called from `init_app()` before the
/// Tokio runtime starts so `set_var()` is single-threaded and sound.
///
/// These vars are inherited by every child process (maxima-bootstrap, umu-run,
/// pressure-vessel, Wine, BF2) because `Command` inherits the parent env.
/// `MAXIMA_WINE_COMMAND` makes Maxima call `umu-wrapper.sh` instead of
/// `umu-run` directly, which in turn handles the wine-helper.exe bypass.
pub fn setup_steam_launch_env() {
    // SAFETY: called before any thread is spawned (init_app() precedes
    // setup_default_user_utils() which starts the Tokio threadpool).
    unsafe {
        std::env::set_var("EAEntitlementSource", "STEAM");
        std::env::set_var("EAExternalSource", "STEAM");
        std::env::set_var("EALaunchOwner", "STEAM");
        std::env::set_var("EAGameLocale", "en_US");
        // Steam/Proton passes STEAM_GAME_LANGUAGE to games as a language override.
        // Setting it to "english" prevents Proton from inheriting the system language.
        std::env::set_var("STEAM_GAME_LANGUAGE", "english");
        std::env::set_var("GAMEID", "1237950");
        std::env::set_var("SteamAppId", "1237950");
        std::env::set_var("SteamGameId", "1237950");
        std::env::set_var("STORE", "steam");
        std::env::set_var("PROTON_SET_GAME_DRIVE", "0");
        // DXVK_ASYNC=1 is only set if the user hasn't overridden it. Lets
        // launching with `env DXVK_ASYNC=0 …` bypass our default for testing
        // (e.g. when the system pipeline cache was built in sync mode and
        // mixing with async causes shader-recompile stutter / audio underruns
        // during loading screens).
        if std::env::var_os("DXVK_ASYNC").is_none() {
            std::env::set_var("DXVK_ASYNC", "1");
        }

        // Audio buffer enlargement to suppress crackle during BF2 loading
        // screens. Without these, PulseAudio buffer underruns when disk-IO
        // spikes (asset streaming, mod loading) cause audible audio cutouts.
        // Verified empirically 2026-05-07: 120 ms eliminates crackle without
        // noticeable latency impact for game audio.
        // PULSE_LATENCY_MSEC: PulseAudio host-side buffer (host pulseaudio).
        // WINE_PULSE_LATENCY_MSEC: Wine's winepulse.drv internal buffer.
        // STAGING_AUDIO_DURATION: wine-staging fallback (microseconds).
        // var_os check lets users override per-launch via env if the default
        // is wrong on their hardware.
        if std::env::var_os("PULSE_LATENCY_MSEC").is_none() {
            std::env::set_var("PULSE_LATENCY_MSEC", "120");
        }
        if std::env::var_os("WINE_PULSE_LATENCY_MSEC").is_none() {
            std::env::set_var("WINE_PULSE_LATENCY_MSEC", "120");
        }
        if std::env::var_os("STAGING_AUDIO_DURATION").is_none() {
            std::env::set_var("STAGING_AUDIO_DURATION", "120000");
        }

        let existing_overrides = std::env::var("WINEDLLOVERRIDES").unwrap_or_default();
        let new_overrides = if existing_overrides.is_empty() {
            "msvcp140=b".to_string()
        } else {
            format!("msvcp140=b;{}", existing_overrides)
        };
        std::env::set_var("WINEDLLOVERRIDES", new_overrides);

        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                let wrapper = dir.join("cli/umu-wrapper.sh");
                if wrapper.exists() {
                    std::env::set_var("MAXIMA_WINE_COMMAND", &wrapper);
                    log::info!("MAXIMA_WINE_COMMAND -> {}", wrapper.display());
                } else {
                    log::warn!("umu-wrapper.sh not found at {}; MAXIMA_WINE_COMMAND unset", wrapper.display());
                }
            }
        }
    }
}

/// Patches Wine's `user.reg` to use en-US locale, preventing EA's
/// "language not entitled" error. Wine initialises the prefix locale from
/// `$LANG`, so on German systems `Locale=00000407` ends up in the registry.
/// BF2 calls `GetUserDefaultLCID()` which reads this value, not `LC_ALL`.
///
/// Called from `init_app()` (existing prefix) and from `start_game()` (first
/// run: prefix may be created by bootstrap after `init_app()` ran).
///
/// Backwards-compatible wrapper around `patch_wine_registry_for_bf2()`.
/// New callers should invoke `patch_wine_registry_for_bf2()` directly to
/// also patch the BF2 catalog / Steam-language / HKCU\Environment keys
/// in a single pass.
pub fn patch_wine_locale_to_en_us() {
    patch_wine_registry_for_bf2();
}

/// Direct file-level patch of the entire BF2 locale-critical key set in
/// the Wine prefix. Replaces the 15 sequential `reg add` calls in Maxima's
/// `setup_wine_registry()` (each costs ~3s of pressure-vessel container
/// spawn via umu-run) with two text-edit passes that take ~50ms total.
///
/// Strategy:
/// - User.reg sections: `Control Panel\International`, `Software\Valve\Steam`,
///   `Environment` — patched in-place.
/// - System.reg sections: `Software\Electronic Arts\EA Desktop`,
///   `Software\Origin`, `Software\Origin Games\1035052`,
///   `Software\WoW6432Node\Origin Games\1035052` — patched in-place.
/// - Each section: existing keys are replaced with the expected values;
///   missing keys are appended within the section; missing sections are
///   appended at the end of the file.
/// - Skipped entirely when `wineserver` is currently running — Wine
///   serialises the registry to disk on shutdown and would clobber our
///   writes. The Maxima `setup_wine_registry()` umu-run path is the
///   fallback in that case (and on a fresh prefix where the files do
///   not exist yet).
///
/// After this runs, the in-Maxima `verify_locale_is_english()` pre-flight
/// (the four critical keys via `reg query`) reports OK and
/// `setup_wine_registry()` skips its 15-entry loop. Net cold-launch
/// effect on a typical warm Wine prefix: ~45s saved.
pub fn patch_wine_registry_for_bf2() {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return,
    };
    let prefix = format!("{}/.local/share/maxima/wine/prefix", home);

    if is_wineserver_running() {
        log::info!(
            "patch_wine_registry_for_bf2: wineserver active; skipping \
             direct-file-patch (Maxima's setup_wine_registry will run via \
             umu-run instead)"
        );
        return;
    }

    patch_user_reg_for_bf2(&prefix);
    patch_system_reg_for_bf2(&prefix);
}

fn is_wineserver_running() -> bool {
    use std::process::Command;
    Command::new("pgrep")
        .arg("-x")
        .arg("wineserver")
        .output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false)
}

fn patch_user_reg_for_bf2(prefix: &str) {
    let path = format!("{}/user.reg", prefix);
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut patched = content.clone();
    patched = ensure_keys_in_section(
        &patched,
        r"Control Panel\\International",
        &[
            ("Locale", "00000409"),
            ("LocaleName", "en-US"),
            ("sLanguage", "ENU"),
            ("sCountry", "United States"),
            ("iCountry", "1"),
        ],
    );
    patched = ensure_keys_in_section(
        &patched,
        r"Software\\Valve\\Steam",
        &[("language", "english")],
    );
    patched = ensure_keys_in_section(
        &patched,
        r"Environment",
        &[
            ("LANG", "en_US.UTF-8"),
            ("LC_ALL", "en_US.UTF-8"),
        ],
    );

    if patched == content {
        log::debug!("user.reg already in BF2-locale state — no write needed");
        return;
    }
    match std::fs::write(&path, patched) {
        Ok(_) => log::info!(
            "Wine user.reg patched: Control Panel\\International + \
             Software\\Valve\\Steam + Environment sections"
        ),
        Err(e) => log::warn!("Failed to write user.reg: {}", e),
    }
}

fn patch_system_reg_for_bf2(prefix: &str) {
    let path = format!("{}/system.reg", prefix);
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut patched = content.clone();
    patched = ensure_keys_in_section(
        &patched,
        r"Software\\Electronic Arts\\EA Desktop",
        &[("InstallSuccessful", "true")],
    );
    patched = ensure_keys_in_section(
        &patched,
        r"Software\\Origin",
        &[
            ("ClientPath", "C:/Windows/System32/conhost.exe"),
            ("InstallSuccessful", "true"),
        ],
    );
    patched = ensure_keys_in_section(
        &patched,
        r"Software\\Origin Games\\1035052",
        &[
            ("locale", "en_US"),
            ("displayname", "STAR WARS Battlefront II"),
        ],
    );
    patched = ensure_keys_in_section(
        &patched,
        r"Software\\WoW6432Node\\Origin Games\\1035052",
        &[
            ("locale", "en_US"),
            ("displayname", "STAR WARS Battlefront II"),
        ],
    );

    if patched == content {
        log::debug!("system.reg already in BF2-locale state — no write needed");
        return;
    }
    match std::fs::write(&path, patched) {
        Ok(_) => log::info!(
            "Wine system.reg patched: EA Desktop + Origin + Origin Games + \
             WoW6432Node Origin Games sections"
        ),
        Err(e) => log::warn!("Failed to write system.reg: {}", e),
    }
}

/// Ensure the named registry section contains every (key, value) pair in
/// `keys`. Existing keys with wrong values get replaced; missing keys get
/// appended within the section; if the section header is missing
/// entirely it gets appended at the end of the file.
///
/// Section paths are written exactly as Wine writes them, with literal
/// `\\` between path components (i.e. `r"Software\\Valve\\Steam"`).
fn ensure_keys_in_section(content: &str, section_path: &str, keys: &[(&str, &str)]) -> String {
    let section_marker = format!("[{}]", section_path);

    let lines: Vec<&str> = content.lines().collect();
    let mut section_start: Option<usize> = None;
    let mut section_end: Option<usize> = None;

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim_start();
        if section_start.is_none() && trimmed.starts_with(&section_marker)
            && (trimmed.len() == section_marker.len()
                || trimmed.as_bytes().get(section_marker.len()) == Some(&b' '))
        {
            section_start = Some(i);
            continue;
        }
        if section_start.is_some() && section_end.is_none() && trimmed.starts_with('[') {
            section_end = Some(i);
            break;
        }
    }

    if section_start.is_none() {
        // Section missing — append at end with all requested keys.
        let mut result = content.to_string();
        if !result.ends_with('\n') {
            result.push('\n');
        }
        result.push('\n');
        result.push_str(&section_marker);
        result.push('\n');
        for (k, v) in keys {
            result.push_str(&format!("\"{}\"=\"{}\"\n", k, v));
        }
        return result;
    }

    let start = section_start.unwrap();
    let end = section_end.unwrap_or(lines.len());

    let mut result_lines: Vec<String> = lines.iter().map(|s| s.to_string()).collect();
    let mut existing: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for i in (start + 1)..end {
        let trimmed = result_lines[i].trim_start();
        if let Some(rest) = trimmed.strip_prefix('"') {
            if let Some(eq) = rest.find("\"=") {
                let k = &rest[..eq];
                existing.insert(k.to_string(), i);
            }
        }
    }

    let mut to_append: Vec<(&str, &str)> = Vec::new();
    for (k, v) in keys {
        let new_line = format!("\"{}\"=\"{}\"", k, v);
        match existing.get(*k) {
            Some(&idx) => {
                if result_lines[idx] != new_line {
                    result_lines[idx] = new_line;
                }
            }
            None => to_append.push((*k, *v)),
        }
    }

    // Insert missing keys directly before the next section header (or
    // file end). Insert in reverse so indices stay valid.
    for (k, v) in to_append.iter().rev() {
        result_lines.insert(end, format!("\"{}\"=\"{}\"", k, v));
    }

    let mut joined = result_lines.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

fn patch_international_section_to_en_us(content: &str) -> String {
    let mut result = String::with_capacity(content.len());
    let mut in_section = false;

    for line in content.lines() {
        let trimmed = line.trim_start();

        if trimmed.starts_with('[') {
            // Section headers use literal \\ for the registry path separator.
            in_section = trimmed.contains("Control Panel\\\\International]");
            result.push_str(line);
            result.push('\n');
            continue;
        }

        if in_section {
            let replacement: Option<&str> = if trimmed.starts_with("\"Locale\"=") {
                Some("\"Locale\"=\"00000409\"")
            } else if trimmed.starts_with("\"LocaleName\"=") {
                Some("\"LocaleName\"=\"en-US\"")
            } else if trimmed.starts_with("\"sLanguage\"=") {
                Some("\"sLanguage\"=\"ENU\"")
            } else if trimmed.starts_with("\"sCountry\"=") {
                Some("\"sCountry\"=\"United States\"")
            } else if trimmed.starts_with("\"iCountry\"=") {
                Some("\"iCountry\"=\"1\"")
            } else {
                None
            };

            if let Some(r) = replacement {
                result.push_str(r);
                result.push('\n');
                continue;
            }
        }

        result.push_str(line);
        result.push('\n');
    }

    result
}

/// Patches the EA Desktop per-user INI file to force English, preventing the
/// "installed in a language you are not entitled to play" error.
///
/// EA's Origin SDK (embedded in BF2) reads `location.language` from this file
/// instead of `GetUserDefaultLCID()`. On a German system the value is written
/// as `de` during the first launch and cached permanently, so Wine registry
/// patches alone are insufficient.
///
/// Called alongside `patch_wine_locale_to_en_us()` from `init_app()` and
/// `start_game()`.
pub fn patch_ea_user_language() {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return,
    };
    let ea_dir = format!(
        "{}/.local/share/maxima/wine/prefix/pfx/drive_c/users/steamuser\
         /AppData/Local/Electronic Arts/EA Desktop",
        home
    );
    let dir = std::path::Path::new(&ea_dir);
    if !dir.exists() {
        return;
    }

    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if !name_str.starts_with("user_") || !name_str.ends_with(".ini") {
            continue;
        }
        let path = entry.path();
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        if !content.contains("location.language=") {
            continue;
        }
        let patched: String = content
            .lines()
            .map(|l| {
                if l.starts_with("location.language=") {
                    "location.language=en".to_string()
                } else {
                    l.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";

        if patched == content {
            continue;
        }
        match std::fs::write(&path, &patched) {
            Ok(_) => log::info!(
                "EA Desktop user.ini patched: location.language→en ({})",
                path.display()
            ),
            Err(e) => log::warn!(
                "Failed to patch EA Desktop user.ini {}: {}",
                path.display(),
                e
            ),
        }
    }
}

fn prepend_locpath(locpath_dir: &Path) {
    let dir_os = locpath_dir.as_os_str();

    let combined = match std::env::var_os("LOCPATH") {
        Some(prev) if !prev.is_empty() => {
            let mut v = std::ffi::OsString::new();
            v.push(dir_os);
            v.push(":");
            v.push(prev);
            v
        }
        _ => dir_os.to_os_string(),
    };

    // SAFETY: see locale_already_works() — single-threaded init context.
    unsafe {
        std::env::set_var("LOCPATH", &combined);
    }

    log::info!(
        "Exported LOCPATH={} so child processes find {}",
        combined.to_string_lossy(),
        TARGET_LOCALE,
    );
}
