// Linux env bootstrap. Mostly locale handling so BF2 doesn't bail with
// the Origin language entitlement error on non-English hosts. The wine
// registry side of that fix is in setup_wine_registry(); this file
// generates an en_US.UTF-8 locale into ~/.local/share/kyber/locale if
// the host doesn't already have one, then exposes it via LOCPATH for
// subprocesses. Does not touch the launcher's own LANG/LC_ALL.

#![cfg(target_os = "linux")]

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::process::Command;

const TARGET_LOCALE: &str = "en_US.UTF-8";
const I18N_SOURCE: &str = "/usr/share/i18n/locales/en_US";

const BF2_STEAM_APP_ID: &str = "1237950";

// Maxima needs its wine prefix to be the BF2 Steam compatdata prefix
// (otherwise Origin registry / EA desktop state is missing and BF2 bails
// with an Origin error). We symlink ~/.local/share/maxima/wine/prefix to
// it. Run on every init_app() because a cleanup script could remove it.
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
            // It's a regular dir/file - don't blindly clobber user data.
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

// Make sure en_US.UTF-8 is reachable to subprocesses. Called from
// init_app() before any tokio thread starts, so set_var is sound.
pub fn ensure_en_us_utf8_locale() {
    if locale_already_works() {
        log::debug!("en_US.UTF-8 already available system-wide; nothing to do");
        return;
    }

    let target_dir = match user_locale_root() {
        Some(d) => d,
        None => {
            log::warn!(
                "Cannot determine $HOME - skipping en_US.UTF-8 generation. \
                 BF2 may fall back to the host locale."
            );
            return;
        }
    };

    let locale_dir = target_dir.join(TARGET_LOCALE);

    // Always regenerate when the system probe fails. An existing
    // locale_dir is not proof of completeness - localedef can be killed
    // mid-write leaving a partial LC_* set.
    if !Path::new(I18N_SOURCE).exists() {
        log::warn!(
            "{} missing - install the locale source package \
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

    // SAFETY: setlocale is process-global. Called from init_app() before
    // any thread is spawned, no racing possible. Capture + restore the
    // previous locale because the probe itself changes process state.
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
        // Restore the original locale. This is best-effort - if it fails
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

// Steam/Wine env vars BF2 needs to launch via the in-process Maxima
// FFI. Subprocesses inherit these. Called from init_app() before tokio
// starts, set_var is sound there.
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
        // var_os checks let users override per-launch via env.
        if std::env::var_os("DXVK_ASYNC").is_none() {
            std::env::set_var("DXVK_ASYNC", "1");
        }

        // Larger pulse buffers stop audio crackle on BF2 loading screens
        // when disk-IO spikes. 120 ms was enough on my box without
        // noticeable latency impact.
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

// Patches the BF2 locale-critical keys in user.reg + system.reg
// directly. Replaces Maxima's 15 sequential `reg add` calls (each
// ~3 s of pressure-vessel spawn via umu-run) with two text-edit
// passes (~50 ms). Skipped when wineserver is running - Wine flushes
// on shutdown and would clobber the writes.
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
        log::debug!("user.reg already in BF2-locale state - no write needed");
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

    // EA Games\STAR WARS Battlefront II key — Maxima's is_installed() check
    // looks here (via the install_check_override from the service layer) to
    // confirm BF2 is installed. Fresh Steam-Proton prefixes don't get this
    // key written automatically (the EA installer never runs), so we set it
    // ourselves from the Steam-detected install dir. Without it, users get
    // a "GAME NOT FOUND" dialog even though BF2 is fully installed via Steam.
    if let Some(install_dir) = bf2_install_dir_for_wine() {
        let keys: Vec<(&str, &str)> = vec![
            ("DisplayName", "STAR WARS Battlefront II"),
            ("Install Dir", install_dir.as_str()),
            ("locale", "en_US"),
        ];
        patched = ensure_keys_in_section(
            &patched,
            r"Software\\EA Games\\STAR WARS Battlefront II",
            &keys,
        );
        patched = ensure_keys_in_section(
            &patched,
            r"Software\\WoW6432Node\\EA Games\\STAR WARS Battlefront II",
            &keys,
        );
    } else {
        log::warn!(
            "Skipping EA Games\\STAR WARS Battlefront II registry patch \
             (BF2 install path could not be resolved from Steam). The \
             launcher may show 'GAME NOT FOUND' until BF2 is installed \
             via Steam-Proton."
        );
    }

    if patched == content {
        log::debug!("system.reg already in BF2-locale state - no write needed");
        return;
    }
    match std::fs::write(&path, patched) {
        Ok(_) => log::info!(
            "Wine system.reg patched: EA Desktop + Origin + Origin Games + \
             WoW6432Node Origin Games + EA Games\\STAR WARS Battlefront II"
        ),
        Err(e) => log::warn!("Failed to write system.reg: {}", e),
    }
}

// Returns the BF2 install dir as a Wine path (Z:/...) for the EA Games
// registry section. Z: is the conventional Wine drive that maps to the
// Linux host root, so we just prefix the Linux path. Returns None when
// Steam metadata doesn't know where BF2 lives (BF2 not installed, or
// Steam library at an unusual path the detection doesn't probe).
// Values get overwritten on every launch to match current Steam metadata.
fn bf2_install_dir_for_wine() -> Option<String> {
    match maxima::util::registry::read_game_path("bf2") {
        Ok(path) => {
            let s = format!("Z:{}", path.to_string_lossy());
            log::info!("BF2 install dir resolved for Wine registry: {}", s);
            Some(s)
        }
        Err(e) => {
            log::warn!(
                "read_game_path(bf2) failed: {}. Skipping EA Games registry \
                 patch. Set STEAM_LIBRARY_ROOT if BF2 lives outside the \
                 default Steam libraries.",
                e
            );
            None
        }
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
        // Section missing - append at end with all requested keys.
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
        "{}/.local/share/maxima/wine/prefix/drive_c/users/steamuser\
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

// Symlink vivoxsdk.dll into Wine's System32. Kyber.dll has a static
// import on it, so without the link Wine's loader blows up with OS
// error 126 and the inject panics. The module updater drops vivoxsdk
// in ~/.local/share/kyber/module/ which isn't on Wine's search path,
// so we just link it where the loader actually looks.
//
// Runs from start_game() (pre-launch), not init_app(). The module
// updater only fetches the DLL after login, so it may not exist yet
// when the app boots.
pub fn ensure_vivoxsdk_in_wine_system32() {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return,
    };
    let source = PathBuf::from(format!(
        "{}/.local/share/kyber/module/vivoxsdk.dll",
        home
    ));
    if !source.exists() {
        log::debug!(
            "vivoxsdk.dll not at {} yet (module updater hasn't run); \
             skipping system32 symlink",
            source.display()
        );
        return;
    }

    let system32 = PathBuf::from(format!(
        "{}/.local/share/maxima/wine/prefix/drive_c/windows/system32",
        home
    ));
    if !system32.exists() {
        log::warn!(
            "{} missing. Wine prefix not initialised, skipping vivoxsdk.dll \
             symlink. Subsequent BF2 launch may fail to inject.",
            system32.display()
        );
        return;
    }

    let target = system32.join("vivoxsdk.dll");

    if let Ok(meta) = std::fs::symlink_metadata(&target) {
        if meta.file_type().is_symlink() {
            if let Ok(current) = std::fs::read_link(&target) {
                if current == source {
                    log::debug!("vivoxsdk.dll symlink already at {}", target.display());
                    return;
                }
            }
            if let Err(e) = std::fs::remove_file(&target) {
                log::warn!("Failed to remove stale vivoxsdk.dll symlink: {}", e);
                return;
            }
        } else {
            // Real file already there. Probably a manual user copy or some
            // earlier bootstrap dropped one. Don't clobber.
            log::debug!(
                "vivoxsdk.dll already at {} (not a symlink), leaving alone",
                target.display()
            );
            return;
        }
    }

    match std::os::unix::fs::symlink(&source, &target) {
        Ok(()) => log::info!(
            "vivoxsdk.dll symlink: {} -> {}",
            target.display(),
            source.display()
        ),
        Err(e) => log::warn!(
            "Failed to symlink vivoxsdk.dll {} -> {}: {}",
            target.display(),
            source.display(),
            e
        ),
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

    // SAFETY: see locale_already_works() - single-threaded init context.
    unsafe {
        std::env::set_var("LOCPATH", &combined);
    }

    log::info!(
        "Exported LOCPATH={} so child processes find {}",
        combined.to_string_lossy(),
        TARGET_LOCALE,
    );
}
