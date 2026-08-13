use std::{path::PathBuf, time::Instant};

use anyhow::bail;
use lazy_static::lazy_static;

#[cfg(windows)]
use maxima::{
    core::background_service::request_registry_setup,
    util::service::{is_service_running, is_service_valid, register_service_user, start_service},
};

use maxima::{
    content::manager::QueuedGameBuilder, core::{clients::JUNO_PC_CLIENT_SECRET, endpoints::API_NUCLEUS_TOKEN}, util::{log::init_logger, registry::check_registry_validity}
};
use log::{debug, error, info, warn, LevelFilter};
use maxima::core::auth::context::AuthContext;
use maxima::core::auth::login::{begin_oauth_login_flow, manual_login};
use maxima::core::auth::{nucleus_auth_exchange, nucleus_token_exchange, TokenResponse};
use maxima::core::clients::JUNO_PC_CLIENT_ID;
use maxima::core::{launch, LockedMaxima, Maxima, MaximaEvent, MaximaOptionsBuilder};
use maxima::core::launch::{LaunchMode, LaunchOptions};
use maxima::core::service_layer::ServiceUserGameProduct;
use maxima::util::native::module_path;
use maxima::util::registry::read_game_path;
use regex::Regex;
use tokio::net::TcpListener;
use crate::frb_generated::StreamSink;
use reqwest::{redirect, Client, Url};

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

async fn create_maxima_instance(is_dummy: bool) {
    unsafe {
        _maxima = Maxima::new_with_options(MaximaOptionsBuilder::default().load_auth_storage(!is_dummy).dummy_local_user(is_dummy).build().unwrap()).await.ok();
    }
}

fn maxima() -> &'static LockedMaxima {
    unsafe { _maxima.as_ref().unwrap() }
}

pub async fn lsx_get_event_stream(pid: u32, game_sink: StreamSink<String>) {
    let maxima_arc = maxima().clone();
    loop {
        let mut maxima = maxima_arc.lock().await;

        for event in maxima.consume_pending_events() {
            match event {
                MaximaEvent::ReceivedLSXRequest(e_pid, request) => {
                    if (e_pid != pid) {
                        continue;
                    }

                    let name: &'static str = request.into();
                    let is_closed = game_sink.add(name.to_string());
                    if is_closed.is_err() {
                        return;
                    }
                },
                _ => (),
            }
        }

        maxima.update().await;
        if maxima.playing().is_none() {
            break;
        }

        drop(maxima);
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

pub async fn start_game(
    game_slug: String,
    game_path_override: Option<String>,
    game_args: Option<Vec<String>>,
    user: Option<String>,
    pass: Option<String>,
) -> anyhow::Result<u32> {
    let maxima_arc = maxima().clone();

    let dummy_user = maxima().lock().await.dummy_local_user();
    let launch_option = if dummy_user {
        LaunchMode::OnlineOffline(1035052.to_string(), user.unwrap(), pass.unwrap())
    } else {
        let offer_id = {
            let mut maxima = maxima_arc.lock().await;
            let game = maxima.mut_library().game_by_base_slug(&game_slug).await;
            if game.is_err() {
                bail!(game.err().unwrap().to_string());
            }

            let game = game?;
            if game.is_none() {
                bail!("Game not found");
            }

            let game = game.unwrap();
            game.offer_id().to_owned()
        };

        LaunchMode::Online(offer_id)
    };

    launch::start_game(maxima_arc.clone(), launch_option, LaunchOptions {
        path_override: game_path_override,
        arguments: game_args.unwrap_or_default(),
        cloud_saves: false,
    }).await?;

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
                },
                _ => (),
            }
        }

        drop(maxima);
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

fn is_maxima_running() -> bool {
    unsafe { _maxima.is_some() }
}

async fn login(login_override: Option<String>) -> anyhow::Result<TokenResponse> {
    let mut auth_context = AuthContext::new()?;

    if let Some(access_token) = &login_override {
        let access_token = if let Some(captures) = MANUAL_LOGIN_PATTERN.captures(&access_token) {
            let persona = &captures[1];
            let password = &captures[2];

            let login_result = manual_login(persona, password).await;
            if login_result.is_err() {
                bail!("Login failed: {}", login_result.err().unwrap().to_string());
            }

            login_result?
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
    
    if token_res.is_err() {
        bail!("Login failed: {}", token_res.err().unwrap().to_string());
    }

    Ok(token_res?)
}

pub async fn get_auth_token() -> String {
    let y = maxima().lock().await;
    {
        let mut auth_storage = y.auth_storage().lock().await;
        let token = auth_storage.access_token().await;
        return token.unwrap().unwrap();
    }
}

pub async fn get_short_token() -> anyhow::Result<String> {
    let token = get_auth_token().await;
    let y = maxima().lock().await;
    {
        let mut auth_context = AuthContext::new()?;
        auth_context.set_access_token(&token);
        let code = nucleus_auth_exchange(&auth_context, JUNO_PC_CLIENT_ID, "code").await?;
        auth_context.set_code(&code);

        let query = vec![
            ("grant_type", "authorization_code"),
            ("code", &auth_context.code().unwrap()),
            ("code_verifier", &auth_context.code_verifier()),
            ("client_id", JUNO_PC_CLIENT_ID),
            ("client_secret", JUNO_PC_CLIENT_SECRET),
            ("redirect_uri", "qrc:///html/login_successful.html"),
            ("token_format", "OPAQUE"),
        ];
    
        let client = Client::builder()
            .redirect(redirect::Policy::none())
            .build()?;
        let res = client.post(API_NUCLEUS_TOKEN).form(&query).send().await?;
    
        let status = res.status();
        let text = res.text().await?;
        if status.is_client_error() || status.is_server_error() {
            bail!(
                "Token exchange failed with code {}: {}",
                auth_context.code().unwrap(),
                text
            );
        }
    
        let response: TokenResponse = serde_json::from_str(&text)?;

        drop(y);

        Ok(response.access_token().to_owned())
    }
}

pub async fn login_with_token(token: String) -> anyhow::Result<()> {
    let text = format!("{{\"access_token\":\"{}\",\"token_type\":\"JWS\",\"expires_in\":14400,\"refresh_token\":\"\"}}", token);
    
    let response: TokenResponse = serde_json::from_str(&text)?;
    let y = maxima().lock().await;
    {
        let mut auth_storage = y.auth_storage().lock().await;
        auth_storage.add_account(&response).await?;
    }

    Ok(())
}

pub async fn download_game(download_path: String, progress_sink: StreamSink<(usize, usize)>) -> anyhow::Result<()> {
    
    let mut maxima_c = maxima().lock().await;
    {
        let game = maxima_c.mut_library().game_by_base_slug("star-wars-battlefront-2").await;
        if game.is_err() {
            bail!(game.err().unwrap().to_string())
        }

        let game = game?;
        if game.is_none() {
            bail!("Game not found");
        }
        
        let game = game.unwrap();
        let offer_id = game.offer_id().to_owned();
        let builds = maxima_c
            .content_manager()
            .service()
            .available_builds(&offer_id)
            .await?;
        let build = builds.live_build();
        if build.is_none() {
            bail!("Couldn't find a suitable game build");
        }

        let build = build.unwrap();
        info!("Installing game build {}", build.to_string());

        let path = PathBuf::from(download_path);
        if !path.is_absolute() {
            error!("Path {:?} is not absolute.", path);
            return Ok(());
        }

        let game = QueuedGameBuilder::default()
            .offer_id(offer_id)
            .build_id(build.build_id().to_owned())
            .path(path.clone())
            .build()?;

        let start_time = Instant::now();
        maxima_c.content_manager().install_now(game).await?;
    }

    drop(maxima_c);

    loop {
        let mut x = maxima().lock().await;

        for event in x.consume_pending_events() {
            match event {
                MaximaEvent::ReceivedLSXRequest(_pid, _request) => (),
                _ => {}
            }
        }

        x.update().await;

        if let Some(downloader) = x.content_manager().current() {
            let current = downloader.bytes_downloaded();
            let total = downloader.bytes_total();

            progress_sink.add((current, total)).unwrap();
        } else {
            break;
        }

        drop(x);
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    Ok(())
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
    let service_player = ServicePlayer {
        id: user.id().to_owned(),
        pd: user.pd().to_owned(),
        psd: user.psd().to_owned(),
        display_name: user.display_name().to_owned(),
        unique_name: user.unique_name().to_owned(),
        nickname: user.nickname().to_owned(),
        avatar: match user.avatar() {
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
        relationship: user.relationship().to_string(),
    };

    Ok(service_player)
}

pub fn start_logger() {
    init_logger();
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

#[cfg(not(target_os = "macos"))]
pub async fn inject_kyber(path: String, pid: u32) -> anyhow::Result<()> {
    use maxima::core::background_service::request_library_injection;
    Ok(request_library_injection(pid, &path).await?)
}

#[cfg(target_os = "macos")]
pub async fn inject_kyber(path: String, pid: u32) -> anyhow::Result<()> {
    Ok(())
}

/// Starts Maxima.
///
/// [enable_logger] - Whether to enable logging. Defaults to false. (Attention: Logging breaks Flutter's Hot Reload/Restart)
pub async fn start_maxima(
    enable_logger: Option<bool>,
    dummy_auth_storage: Option<bool>,
) -> anyhow::Result<()> {
    if is_maxima_running() {
        error!("Maxima is already running!");
        return Ok(());
    }

    native_setup().await?;

    create_maxima_instance(dummy_auth_storage.unwrap_or(false)).await;

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
    flutter_rust_bridge::setup_default_user_utils();
}

flutter_logger::flutter_logger_init!(LevelFilter::Debug);