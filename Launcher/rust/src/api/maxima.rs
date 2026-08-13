use std::io::Sink;

use flutter_rust_bridge::for_generated::anyhow::bail;
use lazy_static::lazy_static;
use log::{debug, error, info, set_max_level, warn, LevelFilter};
use maxima::core::auth::context::AuthContext;
use maxima::core::auth::login::{begin_oauth_login_flow, manual_login};
use maxima::core::auth::{nucleus_auth_exchange, nucleus_token_exchange, TokenResponse};
use maxima::core::clients::JUNO_PC_CLIENT_ID;
use maxima::core::launch::{LaunchMode, LaunchOptions};
use maxima::core::service_layer::{ServiceGetBasicPlayerRequest, ServiceGetBasicPlayerRequestBuilder, ServiceGetUserPlayerRequestBuilder, ServiceLayerError, ServicePlayer as MaximaServicePlayer, ServicePlayersPage, ServiceSearchPlayerRequest, ServiceSearchPlayerRequestBuilder, ServiceUserGameProduct, SERVICE_REQUEST_GETBASICPLAYER, SERVICE_REQUEST_GETUSERPLAYER, SERVICE_REQUEST_SEARCHPLAYER};
use maxima::core::{launch, LockedMaxima, Maxima, MaximaEvent};
pub use maxima::rtm::client::BasicPresence;
use maxima::util::native::maxima_dir;
use maxima::util::registry::read_game_path;
#[cfg(windows)]
use maxima::{
    core::background_service::request_registry_setup,
    util::service::{is_service_running, is_service_valid, register_service_user, start_service},
};
use maxima::{
    core::service_layer::{ServiceFriends, ServiceGetMyFriendsRequestBuilder, SERVICE_REQUEST_GETMYFRIENDS},
    util::{log::init_logger, registry::check_registry_validity},
};
use regex::Regex;
use tokio::net::TcpListener;

use crate::frb_generated::{RustAutoOpaque, StreamSink};

pub struct ServiceImage {
    pub height: Option<u16>,
    pub width: Option<u16>,
    pub path: String,
}

pub struct ServiceAvatarList {
    pub small: ServiceImage,
    pub medium: ServiceImage,
    pub large: ServiceImage,
}

pub struct ServicePlayer {
    pub id: String,
    pub pd: String,
    pub psd: String,
    pub display_name: String,
    pub unique_name: String,
    pub nickname: String,
    pub avatar: Option<ServiceAvatarList>,
    pub relationship: String,
}

lazy_static! {
    static ref MANUAL_LOGIN_PATTERN: Regex = Regex::new(r"^(.*):(.*)$").unwrap();
}
static mut _maxima: Option<LockedMaxima> = None;
static mut _rpc_connected: bool = false;

async fn create_maxima_instance() {
    unsafe {
        _maxima = Some(Maxima::new().await.unwrap());
    }
}

fn maxima() -> &'static LockedMaxima {
    unsafe { _maxima.as_ref().unwrap() }
}

#[cfg(windows)]
pub async fn inject_kyber(pid: u32, path: String) -> anyhow::Result<()> {
    use maxima::core::background_service::request_library_injection;
    Ok(request_library_injection(pid, &path).await?)
}

#[cfg(not(windows))]
pub async fn inject_kyber(pid: u32, path: String) -> anyhow::Result<()> {
    use maxima::core::background_service::request_library_injection;
    // On a fresh install the Wine prefix does not exist yet when start_game()
    // runs its pre-launch vivoxsdk symlink, so that call no-ops. BF2 is running
    // by the time we inject, so re-run it here: without the vivoxsdk.dll link
    // the Wine loader fails Kyber.dll with OS error 126 (module not found).
    #[cfg(target_os = "linux")]
    crate::linux_setup::ensure_vivoxsdk_in_wine_system32();
    // path arrives as a Linux absolute path (e.g. /home/…/module/Kyber.dll).
    // wine-helper.exe runs inside Wine where the Unix root is exposed as Z:\.
    let wine_path = if path.starts_with('/') {
        format!("Z:{}", path.replace('/', "\\"))
    } else {
        path
    };
    Ok(request_library_injection(pid, &wine_path).await?)
}

fn convert_service_player(player: &MaximaServicePlayer) -> ServicePlayer {
    ServicePlayer {
        id: player.id().to_owned(),
        pd: player.pd().to_owned(),
        psd: player.psd().to_owned(),
        display_name: player.display_name().to_owned(),
        unique_name: player.unique_name().to_owned(),
        nickname: player.nickname().to_owned(),
        avatar: match player.avatar() {
            Some(avatar) => Some(ServiceAvatarList {
                small: ServiceImage {
                    height: avatar.small().height().to_owned(),
                    width: avatar.small().width().to_owned(),
                    path: avatar.small().path().to_owned(),
                },
                medium: ServiceImage {
                    height: avatar.medium().height().to_owned(),
                    width: avatar.medium().width().to_owned(),
                    path: avatar.medium().path().to_owned(),
                },
                large: ServiceImage {
                    height: avatar.large().height().to_owned(),
                    width: avatar.large().width().to_owned(),
                    path: avatar.large().path().to_owned(),
                },
            }),
            None => None,
        },
        relationship: player.relationship().to_string(),
    }
}

pub async fn get_friend_list() -> anyhow::Result<Vec<ServicePlayer>> {
    let maxima = maxima().lock().await;

    let response = maxima.friends(0).await?;

    let mut friends: Vec<ServicePlayer> = Vec::new();
    for player in response {
        friends.push(convert_service_player(&player));
    }

    return Ok(friends);
}

#[frb(mirror(BasicPresence), non_opaque)]
pub enum _BasicPresence {
    Unknown,
    Offline,
    Online,
    Dnd,
    Away,
}

#[frb(non_opaque)]
pub struct RtmPresence {
    pub player_id: String,
    pub basic: BasicPresence,
    pub status: String,
    pub game: Option<String>,
}

pub async fn set_rtm_presence(status: String) -> anyhow::Result<()> {
    let mut maxima = maxima().lock().await;
    maxima.rtm().set_presence(BasicPresence::Online, &status, "Origin.OFR.50.0002148").await?;
    drop(maxima);
    Ok(())
}

pub async fn start_rtm_connection() -> anyhow::Result<()> {
    unsafe {
        if _rpc_connected {
            return Ok(());
        }
    }

    let mut maxima_l = maxima().lock().await;
    let friends = maxima_l.friends(0).await?;
    let rtm = maxima_l.rtm();
    rtm.login().await?;
    rtm.set_presence(BasicPresence::Online, "KYBER", "Origin.OFR.50.0002148")
        .await?;

    let players: Vec<String> = friends
        .iter()
        .map(|f| f.id().to_owned())
        .collect();

    rtm.subscribe(&players).await?;
    drop(maxima_l);

    unsafe {
        _rpc_connected = true;
    }

    Ok(())
}

// pub async fn set_rtm_presence(
//     presence: BasicPresence,
//     status: String,
//     game: Option<String>,
// ) -> anyhow::Result<()> {
//     let mut maxima = maxima().lock().await;
//     maxima.rtm().set_presence(presence, &status, &game)
//         .await?;
//
//     drop(maxima);
//     Ok(())
// }

pub async fn get_rtm_presences(presence_sink: StreamSink<RtmPresence>) -> anyhow::Result<()> {
    tokio::spawn(async move {
        loop {
            let mut maxima = maxima().lock().await;
            maxima.rtm().heartbeat().await;
            {
                let store = maxima.rtm().presence_store().lock().await;
                for entry in store.iter() {
                    let is_closed = presence_sink.add(RtmPresence {
                        player_id: entry.0.to_owned().to_string(),
                        basic: entry.1.basic().to_owned(),
                        status: entry.1.status().to_owned(),
                        game: entry.1.game().to_owned(),
                    });

                    if is_closed.is_err() {
                        break;
                    }
                }
            }

            drop(maxima);
            tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        }
    });

    return Ok(());
}

pub async fn lsx_get_event_stream(pid: u32, is_startup: Option<bool>, game_sink: StreamSink<String>) {
    let maxima_arc = maxima().clone();
    let timeout = if is_startup.is_none() {
        std::time::Duration::from_millis(25)
    } else {
        std::time::Duration::from_millis(100)
    };

    loop {
        let mut maxima = maxima_arc.lock().await;

        for event in maxima.consume_pending_events() {
            match event {
                MaximaEvent::ReceivedLSXRequest(e_pid, request) => {
                    if e_pid != pid {
                        continue;
                    }

                    let name: &'static str = request.into();
                    let is_closed = game_sink.add(name.to_string());
                    if is_closed.is_err() {
                        return;
                    }
                }
                _ => (),
            }
        }

        maxima.update().await;
        if maxima.playing().is_none() {
            break;
        }

        drop(maxima);
        tokio::time::sleep(timeout).await;
    }
}

// MAXIMA-LINUX-PORT-MOD 2026-06-07: progress of the GE-Proton runtime download
// that runs inside start_game on first launch. Surfaced so the start-game
// dialog can show a percentage instead of a frozen-looking window during the
// ~516MB download. total_bytes == 0 is an idle tick (no active download).
pub struct ProtonDownloadProgress {
    pub label: String,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
}

/// Streams GE-Proton download progress to the launcher UI. Polls the
/// maxima-lib download slot ~4x/sec and forwards it. Emits an idle tick
/// (total_bytes == 0) when nothing is downloading; the Dart side ignores
/// those and relies on them only to notice the subscription was cancelled
/// (sink.add then errors, ending the loop). The caller (start-game dialog)
/// cancels the subscription once start_game resolves, so this never leaks.
pub async fn get_proton_download_progress(sink: StreamSink<ProtonDownloadProgress>) {
    loop {
        let msg = match maxima::util::github::download_progress() {
            Some((label, downloaded, total)) => ProtonDownloadProgress {
                label,
                downloaded_bytes: downloaded,
                total_bytes: total,
            },
            None => ProtonDownloadProgress {
                label: String::new(),
                downloaded_bytes: 0,
                total_bytes: 0,
            },
        };
        if sink.add(msg).is_err() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
}

pub async fn get_user(pd: String) -> anyhow::Result<ServicePlayer> {
    let maxima_arc = maxima().clone();
    let maxima = maxima_arc.lock().await;

    let response: Result<MaximaServicePlayer, ServiceLayerError> = maxima
        .service_layer()
        .request(
            SERVICE_REQUEST_GETBASICPLAYER,
            ServiceGetBasicPlayerRequestBuilder::default()
                .pd(pd)
                .build()?,
        )
        .await;

    if let Err(err) = response {
        error!("Failed to get user by PD: {}", err);
        bail!(err);
    }

    let player = response?;
    Ok(convert_service_player(&player))
}

pub async fn search_user(name: String) -> anyhow::Result<ServicePlayer> {
    let maxima_arc = maxima().clone();
    let mut maxima = maxima_arc.lock().await;

    let response: Result<ServicePlayersPage, ServiceLayerError> = maxima
        .service_layer()
        .request(
            SERVICE_REQUEST_SEARCHPLAYER,
            ServiceSearchPlayerRequestBuilder::default()
                .is_mutual_friends_enabled(false)
                .page_number(1)
                .page_size(1)
                .search_text(name)
                .build()?,
        )
        .await;

    if let Err(err) = response {
        error!("Failed to search user by PD: {}", err);
        bail!(err);
    }

    let response = response?;
    
    if response.items().is_empty() {
        bail!("User not found");
    }
    
    let player = response.items().first().unwrap();
    Ok(convert_service_player(player))
}

pub async fn check_game_installation() -> anyhow::Result<()> {
    let maxima_arc = maxima().clone();
    let mut maxima = maxima_arc.lock().await;
    let game = maxima.mut_library().game_by_base_slug("star-wars-battlefront-2").await;
    if game.is_err() {
        bail!(game.err().unwrap())
    }

    let game = game?;
    if game.is_none() {
        bail!("Game not found");
    }

    let game = game.unwrap();
    if !game.is_installed().await {
        bail!("Game not installed");
    }

    Ok(())
}

pub async fn start_game(
    game_slug: String,
    game_path_override: Option<String>,
    game_args: Option<Vec<String>>,
) -> anyhow::Result<u32> {
    let maxima_arc = maxima().clone();

    let offer_id = {
        let mut maxima = maxima_arc.lock().await;
        let game = maxima.mut_library().game_by_base_slug(&game_slug).await;
        if game.is_err() {
            bail!(game.err().unwrap())
        }

        let game = game?;
        if game.is_none() {
            bail!("Game not found");
        }

        let game = game.unwrap();
        // skip the install check when the user set an explicit path override
        if game_path_override.is_none() && !game.is_installed().await {
            bail!("Game not installed");
        }

        game.offer_id().to_owned()
    };

    // Re-verify the critical Maxima → Steam-compatdata symlink right before
    // launch, covers the case where it was removed/replaced after init_app()
    // (e.g. by a cleanup script, by Steam Verify Local Files, or by manual fs
    // tinkering). Cheap to run; bails early if the symlink is already correct.
    #[cfg(target_os = "linux")]
    {
        crate::linux_setup::ensure_critical_symlinks();

        // MAXIMA-LINUX-PORT-MOD (6.4.3 diag): init_app's log lines are lost
        // when the FFI initialises before the Dart log stream attaches, so
        // re-log the effective wine runner at launch time. Also probe umu's
        // runtime lock: umu takes a blocking flock on it, so a stale umu
        // process from a previous session stalls every new umu call.
        log::info!(
            "launch diag: MAXIMA_WINE_COMMAND = {}",
            std::env::var("MAXIMA_WINE_COMMAND")
                .unwrap_or_else(|_| "(unset - reg/inject go to raw umu-run)".into())
        );
        if let Ok(home) = std::env::var("HOME") {
            let umu_lock = format!("{}/.local/share/umu/umu.lock", home);
            if std::path::Path::new(&umu_lock).exists() {
                match std::process::Command::new("flock")
                    .args(["-n", &umu_lock, "-c", "true"])
                    .status()
                {
                    Ok(s) if s.success() => log::info!("launch diag: umu.lock is free"),
                    Ok(_) => log::warn!(
                        "launch diag: umu.lock is HELD by another process - a stale \
                         umu/wine run from a previous session is likely blocking the \
                         launch flow; reboot or kill leftover umu/wineserver processes"
                    ),
                    Err(e) => log::debug!("launch diag: flock probe unavailable: {}", e),
                }
            }
        }
        // BF2 launches with WINEPREFIX = ~/.local/share/maxima/wine/prefix. If
        // that link does not resolve, the launch can only die with a cryptic
        // Origin error, so surface an actionable message instead. A custom game
        // path only sets the .exe, it does not create the Proton prefix.
        if !crate::linux_setup::bf2_wine_prefix_available() {
            // MAXIMA-LINUX-PORT-MOD: Non-Steam fallback. No BF2 Steam compatdata.
            // Opt in only when the user pointed us at a real BF2 copy (custom game
            // path whose folder exists) or forced it via env. A plain Steam user
            // who merely never launched BF2 via Steam has no custom path and keeps
            // getting the actionable "launch once via Steam" message below, so the
            // existing fail-fast is preserved (no regression).
            let custom_path_valid = game_path_override
                .as_deref()
                .map(|p| {
                    std::path::Path::new(p)
                        .parent()
                        .map(|d| d.exists())
                        .unwrap_or(false)
                })
                .unwrap_or(false);
            let forced = std::env::var("KYBER_FORCE_STANDALONE_PREFIX")
                .map(|v| !v.trim().is_empty())
                .unwrap_or(false);

            if custom_path_valid || forced {
                // Fail clean instead of kicking off the ~516MB cold GE-Proton
                // download that stalls on a Steam Deck: require Proton already on
                // disk (KYBER_PROTON_PATH / sidecar / auto-detected GE-Proton or
                // proton-cachyos).
                if !maxima::unix::wine::proton_resolvable_without_download() {
                    bail!(
                        "No Proton build found for the non-Steam launch path. Install \
                         GE-Proton or proton-cachyos (via Steam's compatibilitytools.d, \
                         Lutris or Heroic) or set KYBER_PROTON_PATH to a Proton \
                         directory, then try again."
                    );
                }
                crate::linux_setup::ensure_standalone_prefix().map_err(|e| {
                    anyhow::anyhow!("Could not set up the non-Steam wine prefix: {}", e)
                })?;
            } else if game_path_override.is_some() {
                // Custom path set but its folder is missing (typo, unmounted drive).
                bail!(
                    "The custom Battlefront II path's folder was not found. Check the \
                     path and that the drive is mounted, then try again."
                );
            } else {
                bail!(
                    "No Steam Proton prefix for Battlefront II was found. Launch \
                     Battlefront II once through Steam (Proton) so Steam creates the \
                     prefix, then start it from Kyber again. To run a non-Steam copy, \
                     set a custom game path in settings."
                );
            }
        }
    }

    // MAXIMA-LINUX-PORT-MOD 2026-05-26: reconcile wine/proton routing right
    // before launch. Surfaces CustomProtonInvalid as an Err that propagates
    // through start_game to the launcher's Dart side, which shows the
    // hard-error dialog with [Reset to default] [Cancel] options. Idempotent
    // - cheap when already in correct state.
    #[cfg(target_os = "linux")]
    maxima::unix::wine::ensure_proton_routing().map_err(|e| anyhow::anyhow!(e))?;

    // Ensure Wine locale is en-US before bootstrap launches BF2.
    // Also covers first-run: if prefix was just created by a prior bootstrap
    // invocation, the file now exists and we can patch it.
    #[cfg(target_os = "linux")]
    crate::linux_setup::patch_wine_locale_to_en_us();
    #[cfg(target_os = "linux")]
    crate::linux_setup::patch_ea_user_language();
    #[cfg(target_os = "linux")]
    crate::linux_setup::ensure_vivoxsdk_in_wine_system32();

    // TODO: re-enable cloud-saves (@headassbtw please fix)
    launch::start_game(maxima_arc.clone(), LaunchMode::Online(offer_id), LaunchOptions {
        path_override: game_path_override,
        arguments: game_args.unwrap_or_default(),
        cloud_saves: false,
    }).await?;

    // MAXIMA-LINUX-PORT-MOD 2026-08-13: last-resort backstop for the handshake
    // wait. The real decision is playing() below, which rides maxima's own grace
    // window (launch.rs launch_grace_remaining, 300s after the bootstrap helper
    // exits). That window is deliberately generous and must stay the deciding
    // factor: its comment records that 120s once refocused the launcher over a
    // still-loading game on a slow Steam Deck, so anything tighter here would
    // reintroduce exactly that bug. This constant only exists for the case where
    // playing() never flips, and is set far above the grace window so it can
    // never be the one that ends a launch that maxima still considers alive.
    //
    // Do not "tune" this down to the launch times measured on a fast desktop
    // (11 to 19 seconds warm). Those say nothing about a cold prefix on SD-card
    // storage, which is the hardware this has to survive.
    const HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(600);
    let wait_started = std::time::Instant::now();

    loop {
        let mut maxima = maxima_arc.lock().await;
        for event in maxima.consume_pending_events() {
            match event {
                MaximaEvent::ReceivedLSXRequest(pid, request) => {
                    let name: &'static str = request.into();
                    if name != "ChallengeResponse" {
                        continue;
                    }

                    debug!("Received ChallengeResponse from LSX for PID {}!", pid);

                    return Ok(pid);
                }
                _ => (),
            }
        }

        maxima.update().await;

        // MAXIMA-LINUX-PORT-MOD 2026-08-13: bound the wait. This loop used to
        // have exactly one exit, the ChallengeResponse above, so a launch that
        // died before BF2 ever opened its LSX connection left the launcher on
        // "GAME LAUNCHING" forever with no error at all. Reported from the
        // field: the game window appears for a moment under Valve Proton 10.0
        // and Experimental, then exits. update_playing_status() already decides
        // when a launch is over (never while LSX is connected or the bootstrap
        // is alive, otherwise after the post-bootstrap-exit grace window) and
        // logs the Proton and Wine output on the way, so reuse that decision
        // instead of adding a second, competing timeout. Same pattern as
        // lsx_get_event_stream above.
        // MAXIMA-LINUX-PORT-MOD 2026-08-13: a wineserver liveness probe used to
        // sit here to end a dead launch sooner than the grace window does. It
        // was removed: Proton runs the game through the waitforexitandrun verb,
        // which waits for the previous wineserver to shut down before starting
        // the game, so a window with no wineserver attached to the prefix is
        // part of a perfectly healthy launch. A probe landing in that window
        // aborts a launch that was about to succeed. Do not reintroduce it
        // without a signal that cannot occur during a normal start.
        if maxima.playing().is_none() || wait_started.elapsed() >= HANDSHAKE_TIMEOUT {
            // Drain once more before giving up: a ChallengeResponse queued
            // between the consume above and this point is a valid launch and
            // has to win over the bail.
            for event in maxima.consume_pending_events() {
                if let MaximaEvent::ReceivedLSXRequest(pid, request) = event {
                    let name: &'static str = request.into();
                    if name == "ChallengeResponse" {
                        debug!("Received ChallengeResponse from LSX for PID {}!", pid);
                        return Ok(pid);
                    }
                }
            }

            bail!(
                "Battlefront II started and exited again without connecting to \
                 the launcher. The most likely cause is the Proton version: \
                 Kyber is tested against GE-Proton10-34, and Valve's Proton 10.0 \
                 and Proton Experimental have been reported to fail exactly like \
                 this. Clear the custom Proton path in settings so Kyber uses the \
                 version it expects, or point it at GE-Proton10-34. Other causes \
                 produce the same symptom, among them a damaged Wine prefix, \
                 missing or modified game files, and the game being killed for \
                 running out of memory. The launcher log holds the Proton and \
                 Wine output of this launch."
            );
        }

        drop(maxima);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
}

fn is_maxima_running() -> bool {
    unsafe { _maxima.is_some() }
}

pub async fn check_game_ownership() -> anyhow::Result<bool> {
    let maxima_arc = maxima().clone();
    let mut maxima = maxima_arc.lock().await;

    let game = maxima.mut_library().game_by_base_slug("star-wars-battlefront-2").await;
    if game.is_err() {
        bail!(game.err().unwrap())
    }

    let game = game?;
    if game.is_none() {
        return Ok(false);
    }

    Ok(true)
}

async fn login(login_override: Option<String>) -> anyhow::Result<TokenResponse> {
    info!("Beginning login flow..");
    let mut auth_context = AuthContext::new()?;

    if let Some(access_token) = &login_override {
        let access_token = if let Some(captures) = MANUAL_LOGIN_PATTERN.captures(&access_token) {
            let persona = &captures[1];
            let password = &captures[2];

            let login_result = manual_login(persona, password).await;
            if login_result.is_err() {
                bail!("Login failed: {}", login_result.err().unwrap().to_string());
            }

            login_result.unwrap()
        } else {
            access_token.to_owned()
        };

        auth_context.set_access_token(&access_token);
        let code = nucleus_auth_exchange(&auth_context, JUNO_PC_CLIENT_ID, "code").await?;
        auth_context.set_code(&code);
    } else {
        begin_oauth_login_flow(&mut auth_context).await?
    };

    if auth_context.code().is_none() {
        bail!("Login failed!");
    }

    if login_override.is_none() {
        info!("Received login...");
    }

    let token_res = nucleus_token_exchange(&auth_context).await;
    if token_res.is_err() {
        bail!("Login failed: {}", token_res.err().unwrap().to_string());
    }

    let token_res = token_res?;
    Ok(token_res)
}

pub async fn get_auth_token() -> String {
    let y = maxima().lock().await;
    {
        let mut auth_storage = y.auth_storage().lock().await;
        let token = auth_storage.access_token().await;
        return token.unwrap().unwrap();
    }
}

#[frb(sync)]
pub fn get_game_dir(game_slug: String) -> String {
    let result = read_game_path(&game_slug);

    match result {
        Ok(path) => path.to_str().unwrap().to_string(),
        Err(_) => "".to_string(),
    }
}

pub async fn is_logged_in() -> bool {
    let y = maxima().lock().await;
    {
        let mut auth_storage = y.auth_storage().lock().await;
        let logged_in = auth_storage.logged_in().await;
        return logged_in.unwrap_or(false);
    }
}

/// Starts the login flow. When not logged in, will start EA OAuth2 login flow. When logged in, will return the current player as [ServicePlayer].
///
/// [login_override] - When set, will override the login flow and use the provided credentials instead. Format: persona:password
pub async fn login_flow(login_override: Option<String>) -> anyhow::Result<ServicePlayer> {
    let y = maxima().lock().await;
    {
        let mut auth_storage = y.auth_storage().lock().await;
        let logged_in = auth_storage.logged_in().await?;
        if !logged_in || login_override.is_some() {
            info!("Logging in...");
            let token_res = login(login_override).await?;
            auth_storage.add_account(&token_res).await?;
        }
    }

    let local_user = y.local_user().await?;
    let user = local_user.player().as_ref().unwrap();

    Ok(convert_service_player(&user))
}

#[cfg(windows)]
pub async fn check_service() -> anyhow::Result<()> {
    if !is_service_running()? {
        info!("Starting service...");
        start_service().await?;
    }

    Ok(())
}

#[cfg(not(windows))]
pub async fn check_service() -> anyhow::Result<()> {
    Ok(())
}

#[cfg(windows)]
async fn native_setup() -> anyhow::Result<()> {
    if !is_service_valid()? {
        info!("Installing service...");
        register_service_user()?;
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }

    if !is_service_running()? {
        info!("Starting service...");
        start_service().await?;
    }

    if let Err(err) = check_registry_validity() {
        warn!("{}, fixing...", err);
        request_registry_setup().await?;
    }

    Ok(())
}

#[cfg(not(windows))]
async fn native_setup() -> anyhow::Result<()> {
    use maxima::util::registry::set_up_registry;

    if let Err(err) = check_registry_validity() {
        warn!("{}, fixing...", err);
        set_up_registry()?;
    }

    Ok(())
}

/// Starts Maxima.
///
/// [enable_logger] - Whether to enable logging. Defaults to false. (Attention: Logging breaks Flutter's Hot Reload/Restart)
pub async fn start_maxima(
    enable_logger: Option<bool>
) -> anyhow::Result<()> {
    if is_maxima_running() {
        return Ok(());
    }

    native_setup().await?;
    create_maxima_instance().await;

    let lsx_port = {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        listener.local_addr().unwrap().port()
    };

    maxima().lock().await.set_lsx_port(lsx_port);

    let maxima_arc = maxima().clone();
    {
        let maxima = maxima_arc.lock().await;
        maxima.start_lsx(maxima_arc.clone()).await?;
    }

    Ok(())
}

#[frb(init)]
pub fn init_app() {
    // Linux locale bootstrap MUST happen before setup_default_user_utils()
    // because the latter spawns the tokio runtime threads, after which
    // std::env::set_var() would race with concurrent env reads (UB on
    // glibc). Doing it first keeps the env mutation single-threaded.
    //
    // ensure_critical_symlinks() runs FIRST: subsequent registry/INI patches
    // operate on the wine prefix at ~/.local/share/maxima/wine/prefix. If
    // that symlink is missing or wrong, the patches go to a useless empty
    // prefix and BF2 launches against the un-patched Steam compatdata.
    #[cfg(target_os = "linux")]
    crate::linux_setup::ensure_critical_symlinks();

    // MAXIMA-LINUX-PORT-MOD 2026-05-26: Option H proton routing. Whenever
    // the launcher boots, reconcile wine/proton's filesystem state with the
    // sidecar (real Maxima-managed dir vs symlink to custom proton). Runs
    // early in init_app because: (a) it's a pure filesystem operation safe
    // before tokio start, (b) Maxima's install_wine which runs later will
    // see the correct state and skip on custom mode. Invalid custom paths
    // are surfaced from start_game later, not here - init_app must not
    // block app startup just because a stale sidecar points at a removed
    // proton install.
    #[cfg(target_os = "linux")]
    if let Err(e) = maxima::unix::wine::ensure_proton_routing() {
        log::warn!(
            "[ensure_proton_routing] init_app: failed to reconcile wine/proton: {}. \
             start_game will retry and surface any error to the user.",
            e
        );
    }
    #[cfg(target_os = "linux")]
    crate::linux_setup::ensure_en_us_utf8_locale();
    #[cfg(target_os = "linux")]
    crate::linux_setup::setup_steam_launch_env();
    #[cfg(target_os = "linux")]
    crate::linux_setup::patch_wine_locale_to_en_us();
    #[cfg(target_os = "linux")]
    crate::linux_setup::patch_ea_user_language();

    flutter_rust_bridge::setup_default_user_utils();

    // flutter_logger_init! is declared at module level with LevelFilter::Debug,
    // but the global max-level starts at Off until a logger is installed.
    // After setup_default_user_utils() the FRB logger is registered, lock the
    // max level to Debug so that debug!/trace! calls in maxima-lib are not
    // silently discarded before reaching the Dart log stream.
    set_max_level(LevelFilter::Debug);
}

// MAXIMA-LINUX-PORT-MOD 2026-05-24: Custom Proton override API.
//
// The user-supplied proton path is stored in a sidecar file at
// ~/.local/share/maxima/custom_proton_path (read by maxima-lib's proton_dir()
// at every wine call, no env::set_var needed). This avoids the unsafe race
// of mutating env-vars after tokio threads have spawned, and supports
// hot-switching without launcher restart.

pub struct ProtonValidation {
    pub valid: bool,
    pub layout: String,
    pub in_home: bool,
    pub error: Option<String>,
}

pub struct ProtonCandidate {
    pub path: String,
    pub display_name: String,
    pub version_hint: Option<String>,
    pub in_home: bool,
}

// KYBER-LINUX-PORT-MOD 2026-08-12: what the next launch will actually run.
// `tag` is read from the build itself, never from its directory name, so a
// directory named after another release cannot misreport it. `origin` is
// "custom" (user setting), "detected" (pinned build found on the system),
// "managed" (downloaded by us) or "download" (nothing on disk yet).
pub struct ActiveProton {
    pub path: String,
    pub tag: String,
    pub origin: String,
}

/// Result of a BF2 VKD3D shader cache clear attempt. `reason` is a stable
/// machine-readable tag the UI maps to a localised InfoBar message.
pub struct ShaderCacheClearResult {
    pub removed: bool,
    pub bytes_freed: u64,
    pub path: Option<String>,
    /// One of: "removed", "not_present", "bf2_not_installed",
    /// "bf2_running", "permission_denied".
    pub reason: String,
}

/// Single file we manage. BF2 is DX12, so VKD3D-Proton owns its pipeline
/// cache here; there is no DXVK cache to worry about. Steam's wineprefix
/// shadercache/ stays untouched.
#[cfg(target_os = "linux")]
const BF2_VKD3D_CACHE_FILENAME: &str = "vkd3d-proton.cache";

#[cfg(target_os = "linux")]
fn sidecar_path() -> anyhow::Result<std::path::PathBuf> {
    Ok(maxima_dir()?.join("custom_proton_path"))
}

#[cfg(target_os = "linux")]
fn path_in_home(p: &std::path::Path) -> bool {
    std::env::var("HOME")
        .map(|h| p.starts_with(&h))
        .unwrap_or(false)
}

#[cfg(target_os = "linux")]
fn detect_layout(p: &std::path::Path) -> Option<String> {
    use std::os::unix::fs::PermissionsExt;
    let exec_at = |sub: &str| -> bool {
        std::fs::metadata(p.join(sub))
            .map(|m| m.is_file() && (m.permissions().mode() & 0o111 != 0))
            .unwrap_or(false)
    };
    // MAXIMA-LINUX-PORT-MOD 2026-05-25: detect Wine 10 WoW64 single-binary
    // builds where `wine64` is a symlink pointing back to `wine`. The dialog
    // surfaces this via a `-wow64` layout suffix so the user gets an extra
    // warning before saving - dll-syringe 0.15.2 in wine-helper.exe is
    // known-broken against the WoW64 single-binary layout.
    let wine64_is_wow64_symlink = |sub_dir: &str| -> bool {
        let path = p.join(sub_dir).join("wine64");
        if let Ok(meta) = std::fs::symlink_metadata(&path) {
            if meta.file_type().is_symlink() {
                if let Ok(target) = std::fs::read_link(&path) {
                    let s = target.to_string_lossy();
                    return s == "wine" || s.ends_with("/wine");
                }
            }
        }
        false
    };
    if p.join("proton").exists() {
        // Probe the inner bin dirs to flag WoW64 even when the top-level
        // proton script is the umu entry point.
        for sub in ["files/bin", "dist/bin", "bin"] {
            if wine64_is_wow64_symlink(sub) {
                return Some("proton-script-wow64".to_string());
            }
            if !exec_at(&format!("{}/wine64", sub)) && exec_at(&format!("{}/wine", sub)) {
                return Some("proton-script-wow64".to_string());
            }
        }
        Some("proton-script".to_string())
    } else if exec_at("files/bin/wine64") {
        if wine64_is_wow64_symlink("files/bin") {
            Some("ge-files-wow64".to_string())
        } else {
            Some("ge-files".to_string())
        }
    } else if exec_at("dist/bin/wine64") {
        if wine64_is_wow64_symlink("dist/bin") {
            Some("valve-dist-wow64".to_string())
        } else {
            Some("valve-dist".to_string())
        }
    } else if exec_at("bin/wine64") {
        if wine64_is_wow64_symlink("bin") {
            Some("flat-bin-wow64".to_string())
        } else {
            Some("flat-bin".to_string())
        }
    } else if exec_at("files/bin/wine") {
        Some("ge-files-wow64".to_string())
    } else if exec_at("dist/bin/wine") {
        Some("valve-dist-wow64".to_string())
    } else if exec_at("bin/wine") {
        Some("flat-bin-wow64".to_string())
    } else {
        None
    }
}

#[cfg(target_os = "linux")]
fn read_proton_version_hint(p: &std::path::Path) -> Option<String> {
    for candidate in &["version", "version.txt"] {
        if let Ok(content) = std::fs::read_to_string(p.join(candidate)) {
            let trimmed = content.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.lines().next().unwrap_or(trimmed).to_string());
            }
        }
    }
    None
}

/// Write or clear the custom-proton sidecar file. Atomic via tmp+rename so
/// a partial write never produces a half-readable sidecar.
/// path = Some(non-empty): set override
/// path = None or Some(""): clear override (delete sidecar)
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn set_custom_proton_path(path: Option<String>) -> Result<(), String> {
    let sidecar = sidecar_path().map_err(|e| e.to_string())?;
    let parent = sidecar
        .parent()
        .ok_or_else(|| "sidecar has no parent dir".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;

    // MAXIMA-LINUX-PORT-MOD 2026-05-25: BF2 shader cache invalidation on
    // Proton switch. Read the sidecar value before we overwrite it so we
    // can fire the cache purge only when the effective Proton path
    // actually changes (a no-op Save with the same value must not nuke
    // the cache). Normalised to trimmed-or-None for comparison.
    let old_value = read_sidecar_trimmed(&sidecar);
    let new_value = path.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let proton_path_changed = old_value.as_deref() != new_value;

    // MAXIMA-LINUX-PORT-MOD 2026-05-25: refuse a Proton switch while a
    // wineserver from a previous BF2 session is still attached to our
    // prefix. Mixing the stale wineserver's wine version with a freshly
    // routed proton (after the symlink swap in ensure_proton_routing)
    // produces a silent protocol mismatch that hangs the next launch.
    // The error has a structured prefix so the UI can offer a kill-and-
    // retry path. No-op Save (same value) is never blocked, because no
    // state change would happen and the stale wineserver is irrelevant.
    if proton_path_changed && is_maxima_wineserver_alive() {
        return Err("wineserver_busy: a wineserver from a previous BF2 session is still attached to the Maxima prefix. Close BF2 fully, or use the Kill wineserver action, then try again.".to_string());
    }

    match new_value {
        Some(p) => {
            let tmp = sidecar.with_extension("tmp");
            std::fs::write(&tmp, p).map_err(|e| e.to_string())?;
            std::fs::rename(&tmp, &sidecar).map_err(|e| e.to_string())?;
        }
        None => {
            let _ = std::fs::remove_file(&sidecar);
        }
    }
    if proton_path_changed {
        // Best-effort: failure here does not propagate so the dialog
        // always reports its real Save outcome. Custom-game-path users
        // see the skip in the log and have the Clear button as the
        // escape hatch (tooltip points at it).
        purge_bf2_shader_cache_if_changed();
    } else {
        debug!("proton path unchanged, skipping shader cache purge");
    }

    // MAXIMA-LINUX-PORT-MOD 2026-05-26: reconcile wine/proton routing
    // immediately so the UI toggle takes effect without a launcher restart.
    // Errors are surfaced to the dialog (e.g. CustomProtonInvalid lets the
    // user fix the path before clicking Play). Best-effort: a routing
    // failure here also means start_game would fail, so reporting it now
    // saves a misleading "game not installed" later.
    maxima::unix::wine::ensure_proton_routing().map_err(|e| e.to_string())?;

    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn set_custom_proton_path(_path: Option<String>) -> Result<(), String> {
    Err("custom proton path is linux-only".to_string())
}

/// Read the current custom-proton sidecar value, trimmed.
/// Returns None when the file is missing, unreadable, or empty.
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn get_custom_proton_path() -> Option<String> {
    let sidecar = sidecar_path().ok()?;
    let content = std::fs::read_to_string(&sidecar).ok()?;
    let trimmed = content.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn get_custom_proton_path() -> Option<String> {
    None
}

/// The Proton build the next launch will use, for display in settings.
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn get_active_proton() -> ActiveProton {
    let (path, tag, origin) = maxima::unix::wine::active_proton_info();
    ActiveProton { path, tag, origin }
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn get_active_proton() -> ActiveProton {
    ActiveProton {
        path: String::new(),
        tag: String::new(),
        origin: "unsupported".to_string(),
    }
}

/// Live-validate a proton directory for the settings dialog UI. Cheap,
/// stat-only, returns a structured result so the UI can show specific
/// hints (warn icon for outside-$HOME, error message for bad layout).
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn validate_proton_path(path: String) -> ProtonValidation {
    let p = std::path::PathBuf::from(&path);
    let in_home = path_in_home(&p);

    if !p.is_dir() {
        return ProtonValidation {
            valid: false,
            layout: String::new(),
            in_home,
            error: Some(format!("path does not exist or is not a directory: {}", path)),
        };
    }

    match detect_layout(&p) {
        Some(layout) => ProtonValidation {
            valid: true,
            layout,
            in_home,
            error: None,
        },
        None => ProtonValidation {
            valid: false,
            layout: String::new(),
            in_home,
            error: Some("no wine binary found (expected files/bin/wine64, dist/bin/wine64, bin/wine64, files/bin/wine for Wine 10 WoW64, or top-level proton script)".to_string()),
        },
    }
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn validate_proton_path(_path: String) -> ProtonValidation {
    ProtonValidation {
        valid: false,
        layout: String::new(),
        in_home: false,
        error: Some("linux-only".to_string()),
    }
}

/// Discover proton installations in the well-known Steam compatibilitytools
/// locations across distros. Async because it touches the filesystem (up to
/// ~30 stat calls). Returns deduplicated, layout-validated candidates.
#[cfg(target_os = "linux")]
pub async fn scan_known_proton_locations() -> Vec<ProtonCandidate> {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return Vec::new(),
    };

    let roots: Vec<std::path::PathBuf> = vec![
        format!("{}/.local/share/Steam/compatibilitytools.d", home).into(),
        format!("{}/.steam/steam/compatibilitytools.d", home).into(),
        format!("{}/.steam/debian-installation/compatibilitytools.d", home).into(),
        format!("{}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d", home).into(),
        "/usr/share/steam/compatibilitytools.d".into(),
        "/usr/local/share/steam/compatibilitytools.d".into(),
    ];

    let mut seen: std::collections::HashSet<std::path::PathBuf> = std::collections::HashSet::new();
    let mut out: Vec<ProtonCandidate> = Vec::new();

    for root in roots {
        let entries = match std::fs::read_dir(&root) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let canonical = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
            if !seen.insert(canonical.clone()) {
                continue;
            }
            if detect_layout(&canonical).is_none() {
                continue;
            }
            let display_name = canonical
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("?")
                .to_string();
            let path_string = canonical.to_string_lossy().to_string();
            let in_home = path_in_home(&canonical);
            let version_hint = read_proton_version_hint(&canonical);

            out.push(ProtonCandidate {
                path: path_string,
                display_name,
                version_hint,
                in_home,
            });
        }
    }

    out
}

#[cfg(not(target_os = "linux"))]
pub async fn scan_known_proton_locations() -> Vec<ProtonCandidate> {
    Vec::new()
}

// MAXIMA-LINUX-PORT-MOD 2026-05-25: BF2 shader cache invalidation on Proton
// switch. Set of helpers + one FFI entry for the dialog's manual Clear
// button. The auto-purge path is internal (called by set_custom_proton_path
// on diff) and has no access to the Dart-side customGamePath override, so
// it can only resolve via the Steam registry. The manual FFI accepts an
// override and forwards it to the resolver.

#[cfg(target_os = "linux")]
fn read_sidecar_trimmed(sidecar: &std::path::Path) -> Option<String> {
    let content = std::fs::read_to_string(sidecar).ok()?;
    let trimmed = content.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Resolve the BF2 install directory. First honours the UI override (full
/// path to starwarsbattlefrontii.exe per the dialog contract, parented to
/// the install dir), else falls back to Maxima's Steam-libraryfolders.vdf
/// scanner, else returns None. None is not an error; the caller decides
/// whether to silently skip (auto path) or surface a warning (manual path).
#[cfg(target_os = "linux")]
fn resolve_bf2_install_dir(override_exe_path: Option<&str>) -> Option<std::path::PathBuf> {
    if let Some(raw) = override_exe_path {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            let exe = std::path::PathBuf::from(trimmed);
            let has_exe_suffix = exe
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("exe"))
                .unwrap_or(false);
            if has_exe_suffix {
                if let Some(parent) = exe.parent() {
                    if parent.is_dir() {
                        return Some(parent.to_path_buf());
                    } else {
                        warn!(
                            "Custom game-path override parent is not a directory: {}",
                            parent.display()
                        );
                    }
                }
            } else {
                warn!(
                    "Custom game-path override is not a .exe path: {}",
                    trimmed
                );
            }
        }
    }
    match read_game_path("bf2") {
        Ok(p) => Some(p),
        Err(e) => {
            warn!("BF2 install dir not discoverable via Steam registry: {}", e);
            None
        }
    }
}

/// Best-effort process check. BF2's exe `starwarsbattlefrontii.exe` maps to
/// Linux `comm` "starwarsbattlefron" (15-char kernel truncation). We scan
/// /proc/<pid>/comm to avoid hard-depending on pgrep being on PATH inside
/// the AppImage runtime.
#[cfg(target_os = "linux")]
fn is_bf2_running() -> bool {
    let entries = match std::fs::read_dir("/proc") {
        Ok(e) => e,
        Err(_) => return false,
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = match name.to_str() {
            Some(s) => s,
            None => continue,
        };
        if !name_str.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let comm_path = entry.path().join("comm");
        if let Ok(comm) = std::fs::read_to_string(&comm_path) {
            if comm.trim() == "starwarsbattlefron" {
                return true;
            }
        }
    }
    false
}

// MAXIMA-LINUX-PORT-MOD 2026-05-25: detect wineservers attached to the
// Maxima wine prefix. Used to refuse Proton-switches while a previous
// BF2 session's wineserver still owns the prefix (protocol mismatch
// between stale server and new client wine binary silently breaks the
// next launch). Prefix-scoped (not system-wide) so unrelated Wine games
// from other prefixes are untouched. Returns PIDs found.
#[cfg(target_os = "linux")]
fn find_maxima_wineserver_pids() -> Vec<i32> {
    let maxima_prefix = match maxima::unix::wine::default_wine_prefix_dir() {
        Ok(p) => p,
        Err(_) => return Vec::new(),
    };
    // Canonicalize so a symlinked prefix (Steam compatdata) matches the
    // wineserver's WINEPREFIX which is usually the real path.
    let prefix_targets: Vec<std::path::PathBuf> = {
        let mut v = vec![maxima_prefix.clone()];
        if let Ok(canon) = std::fs::canonicalize(&maxima_prefix) {
            if canon != maxima_prefix {
                v.push(canon);
            }
        }
        v
    };

    let mut pids = Vec::new();
    let entries = match std::fs::read_dir("/proc") {
        Ok(e) => e,
        Err(_) => return pids,
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = match name.to_str() {
            Some(s) => s,
            None => continue,
        };
        if !name_str.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        // Filter to wineserver processes only.
        let comm_path = entry.path().join("comm");
        match std::fs::read_to_string(&comm_path) {
            Ok(comm) => {
                if comm.trim() != "wineserver" {
                    continue;
                }
            }
            Err(_) => continue,
        }
        // Read environ to find WINEPREFIX. NUL-separated key=value pairs.
        let environ_path = entry.path().join("environ");
        let bytes = match std::fs::read(&environ_path) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let mut matched = false;
        for chunk in bytes.split(|&b| b == 0) {
            let s = match std::str::from_utf8(chunk) {
                Ok(s) => s,
                Err(_) => continue,
            };
            if let Some(value) = s.strip_prefix("WINEPREFIX=") {
                let p = std::path::PathBuf::from(value);
                let canon = std::fs::canonicalize(&p).unwrap_or_else(|_| p.clone());
                if prefix_targets.iter().any(|t| *t == p || *t == canon) {
                    matched = true;
                    break;
                }
            }
        }
        if matched {
            if let Ok(pid) = name_str.parse::<i32>() {
                pids.push(pid);
            }
        }
    }
    pids
}

#[cfg(target_os = "linux")]
fn is_maxima_wineserver_alive() -> bool {
    !find_maxima_wineserver_pids().is_empty()
}

/// Kill any wineservers that are attached to the Maxima wine prefix.
/// Sends SIGTERM, waits briefly, then SIGKILL stragglers. Prefix-scoped:
/// wineservers belonging to other Wine games are never touched.
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn kill_maxima_wineserver() -> Result<u32, String> {
    let pids = find_maxima_wineserver_pids();
    if pids.is_empty() {
        info!("kill_maxima_wineserver: no wineservers attached to maxima prefix");
        return Ok(0);
    }
    info!(
        "kill_maxima_wineserver: sending SIGTERM to {} wineserver pid(s): {:?}",
        pids.len(),
        pids
    );
    for &pid in &pids {
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    // Give wineserver up to ~3 seconds to exit gracefully, then SIGKILL.
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        if find_maxima_wineserver_pids().is_empty() {
            info!("kill_maxima_wineserver: all wineservers exited cleanly");
            return Ok(pids.len() as u32);
        }
    }
    let stragglers = find_maxima_wineserver_pids();
    if !stragglers.is_empty() {
        warn!(
            "kill_maxima_wineserver: SIGKILLing {} unresponsive pid(s): {:?}",
            stragglers.len(),
            stragglers
        );
        for &pid in &stragglers {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    Ok(pids.len() as u32)
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn kill_maxima_wineserver() -> Result<u32, String> {
    Err("wineserver kill is linux-only".to_string())
}

#[cfg(target_os = "linux")]
fn purge_shader_cache_impl(
    override_exe_path: Option<&str>,
) -> ShaderCacheClearResult {
    let install_dir = match resolve_bf2_install_dir(override_exe_path) {
        Some(d) => d,
        None => {
            return ShaderCacheClearResult {
                removed: false,
                bytes_freed: 0,
                path: None,
                reason: "bf2_not_installed".to_string(),
            };
        }
    };
    let cache_path = install_dir.join(BF2_VKD3D_CACHE_FILENAME);
    let cache_path_string = cache_path.to_string_lossy().to_string();

    if is_bf2_running() {
        return ShaderCacheClearResult {
            removed: false,
            bytes_freed: 0,
            path: Some(cache_path_string),
            reason: "bf2_running".to_string(),
        };
    }

    let bytes = std::fs::metadata(&cache_path)
        .map(|m| m.len())
        .unwrap_or(0);

    match std::fs::remove_file(&cache_path) {
        Ok(()) => ShaderCacheClearResult {
            removed: true,
            bytes_freed: bytes,
            path: Some(cache_path_string),
            reason: "removed".to_string(),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => ShaderCacheClearResult {
            removed: false,
            bytes_freed: 0,
            path: Some(cache_path_string),
            reason: "not_present".to_string(),
        },
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            ShaderCacheClearResult {
                removed: false,
                bytes_freed: 0,
                path: Some(cache_path_string),
                reason: "permission_denied".to_string(),
            }
        }
        Err(e) => ShaderCacheClearResult {
            removed: false,
            bytes_freed: 0,
            path: Some(cache_path_string),
            reason: format!("io_error: {}", e),
        },
    }
}

/// Auto-purge entry. Called only when set_custom_proton_path detected a
/// genuine path change. Errors are logged and swallowed so the Proton
/// switch itself reports its own outcome cleanly.
#[cfg(target_os = "linux")]
fn purge_bf2_shader_cache_if_changed() {
    let result = purge_shader_cache_impl(None);
    match result.reason.as_str() {
        "removed" => info!(
            "BF2 shader cache purged after proton switch: {} bytes ({})",
            result.bytes_freed,
            result.path.as_deref().unwrap_or("?")
        ),
        "not_present" => debug!("BF2 shader cache absent, nothing to purge after proton switch"),
        other => warn!(
            "BF2 shader cache purge skipped: {}. Use Clear shader cache button if you have a custom game path.",
            other
        ),
    }
}

/// Manual-Clear FFI invoked by the Custom Proton dialog. Accepts the
/// Dart-side customGamePath override so users with BF2 outside the Steam
/// registry can still clear. Returns the structured result; the dialog
/// maps `reason` to an InfoBar.
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn clear_bf2_shader_cache(
    game_exe_path_override: Option<String>,
) -> Result<ShaderCacheClearResult, String> {
    let override_ref = game_exe_path_override.as_deref();
    let result = purge_shader_cache_impl(override_ref);
    match result.reason.as_str() {
        "removed" => info!(
            "Manual shader cache clear: removed {} bytes ({})",
            result.bytes_freed,
            result.path.as_deref().unwrap_or("?")
        ),
        "not_present" => info!(
            "Manual shader cache clear: nothing to remove ({})",
            result.path.as_deref().unwrap_or("?")
        ),
        other => warn!(
            "Manual shader cache clear refused: {} ({})",
            other,
            result.path.as_deref().unwrap_or("?")
        ),
    }
    Ok(result)
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn clear_bf2_shader_cache(
    _game_exe_path_override: Option<String>,
) -> Result<ShaderCacheClearResult, String> {
    Err("shader cache clear is linux-only".to_string())
}

/// Result of a Wine prefix reset attempt. `reason` is one of "moved",
/// "wineserver_busy", "not_present".
pub struct PrefixResetResult {
    pub reason: String,
    pub backup_path: Option<String>,
}

// DISABLED 2026-08-13. Kept for reference, no UI path reaches it: the dialog
// button was removed after the first user test. Two problems, both real:
//
// 1. `~/.local/share/maxima/wine/prefix` is usually a SYMLINK into
//    <SteamLibrary>/steamapps/compatdata/1237950/pfx. canonicalize() resolves
//    it, so the code below renames the TARGET and leaves the symlink dangling.
// 2. The bigger one: on Linux a prefix reset also destroys game detection.
//    Maxima's OwnedOffer::is_installed() resolves install_check_override
//    through the Wine registry INSIDE the prefix, and the
//    `EA Games\STAR WARS Battlefront II\Install Dir` key is written by
//    linux_setup.rs by patching system.reg, which needs an existing prefix.
//    A fresh prefix therefore means "GAME NOT FOUND" until Steam-Proton has
//    rebuilt it once.
//
// Anyone reviving this has to carry system.reg/user.reg/userdef.reg over, or
// rerun the setup right after the move. Do not wire it back to a button
// without a reproducible case of a genuinely dead prefix to test against.
#[flutter_rust_bridge::frb(sync)]
#[cfg(target_os = "linux")]
pub fn reset_wine_prefix() -> Result<PrefixResetResult, String> {
    if is_maxima_wineserver_alive() {
        return Ok(PrefixResetResult {
            reason: "wineserver_busy".to_string(),
            backup_path: None,
        });
    }

    let prefix = maxima::unix::wine::default_wine_prefix_dir().map_err(|e| e.to_string())?;
    let real = std::fs::canonicalize(&prefix).unwrap_or(prefix);
    if !real.is_dir() {
        return Ok(PrefixResetResult {
            reason: "not_present".to_string(),
            backup_path: None,
        });
    }

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let backup = real.with_file_name(format!(
        "{}.kyber-backup-{}",
        real.file_name().and_then(|n| n.to_str()).unwrap_or("pfx"),
        stamp
    ));

    std::fs::rename(&real, &backup)
        .map_err(|e| format!("Could not move the prefix aside: {}", e))?;
    info!(
        "Wine prefix reset: moved {} to {}",
        real.display(),
        backup.display()
    );
    Ok(PrefixResetResult {
        reason: "moved".to_string(),
        backup_path: Some(backup.to_string_lossy().to_string()),
    })
}

#[flutter_rust_bridge::frb(sync)]
#[cfg(not(target_os = "linux"))]
pub fn reset_wine_prefix() -> Result<PrefixResetResult, String> {
    Err("prefix reset is linux-only".to_string())
}

flutter_logger::flutter_logger_init!(LevelFilter::Debug);
