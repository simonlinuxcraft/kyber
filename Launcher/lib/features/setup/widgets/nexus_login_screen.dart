import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/nexusmods/services/nexusmods_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher_string.dart';

// Linux: url_launcher spawns `xdg-open` with the AppImage's polluted
// environment (LD_LIBRARY_PATH, GTK_*, GI_TYPELIB_PATH, and an XDG_DATA_DIRS
// rewritten to point into the bundle). On KDE / SteamOS that makes xdg-open
// unable to resolve the real default browser and fall back to Discover's
// appstream handler (the "install Firefox" page). The EA login opens the
// browser through a sanitized xdg-open (maxima `open_login_url`); mirror that
// here so the NexusMods sign-in opens the actual browser, not the software
// store. Falls back to url_launcher if the sanitized spawn fails.
Future<bool> _openUrlExternalSanitized(String url) async {
  if (!Platform.isLinux) {
    return launchUrlString(url, mode: LaunchMode.externalApplication);
  }
  try {
    final env = Map<String, String>.from(Platform.environment);
    final appdir = env['APPDIR'] ?? '';
    final orig = env['KYBER_ORIG_XDG_DATA_DIRS'];
    final base = (orig != null && orig.isNotEmpty)
        ? orig
        : (env['XDG_DATA_DIRS'] ?? '');
    final dirs = <String>[];
    for (final d in base.split(':')) {
      if (d.isEmpty) continue;
      if (appdir.isNotEmpty && d.startsWith(appdir)) continue; // drop bundle share
      dirs.add(d);
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      dirs.add('$home/.local/share/flatpak/exports/share');
    }
    dirs.addAll(const [
      '/var/lib/flatpak/exports/share',
      '/usr/local/share',
      '/usr/share',
    ]);
    final seen = <String>{};
    env['XDG_DATA_DIRS'] = dirs.where(seen.add).join(':');
    for (final k in const [
      'GTK_PATH',
      'GDK_PIXBUF_MODULE_FILE',
      'GTK_IM_MODULE_FILE',
      'GI_TYPELIB_PATH',
      'GSETTINGS_SCHEMA_DIR',
      'GTK_EXE_PREFIX',
      'GTK_DATA_PREFIX',
      'GTK_THEME',
      'GDK_BACKEND',
      'LD_LIBRARY_PATH',
    ]) {
      env.remove(k);
    }
    final result = await Process.run(
      'xdg-open',
      [url],
      environment: env,
      includeParentEnvironment: false,
    );
    if (result.exitCode == 0) return true;
    Logger.root.warning('sanitized xdg-open exited ${result.exitCode} for $url');
  } catch (e) {
    Logger.root.warning('sanitized xdg-open failed for $url: $e');
  }
  return launchUrlString(url, mode: LaunchMode.externalApplication);
}

class NexusLoginScreen extends StatefulWidget {
  const NexusLoginScreen({
    required this.onShowOverlay,
    required this.onSuccess,
    super.key,
  });

  final void Function(bool showOverlay) onShowOverlay;
  final void Function() onSuccess;

  @override
  State<NexusLoginScreen> createState() => _NexusLoginScreenState();
}

class _NexusLoginScreenState extends State<NexusLoginScreen> {
  InAppWebViewController? controller;

  // On Linux there is no working in-app WebView (libwpewebkit-1.0 is gone on
  // Ubuntu 24.04+; the bundled flutter_inappwebview_linux is a no-op stub).
  // Instead, hand the SSO sign-in URL to the system browser and rely on the
  // wss://sso.nexusmods.com flow inside requestApiToken to deliver the token.
  bool get _useExternalBrowser => Platform.isLinux;

  String? _externalLoginUrl;
  String? _externalError;
  bool _externalAuthInFlight = false;

  @override
  void initState() {
    super.initState();
    if (_useExternalBrowser) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runExternalBrowserLogin();
      });
    }
  }

  Future<void> _runExternalBrowserLogin() async {
    if (_externalAuthInFlight) return;
    setState(() {
      _externalAuthInFlight = true;
      _externalError = null;
      _externalLoginUrl = null;
    });
    widget.onShowOverlay(true);
    try {
      await sl.get<NexusModsService>().requestApiToken(
        onUrl: (url) async {
          if (mounted) {
            setState(() => _externalLoginUrl = url);
          }
          final ok = await _openUrlExternalSanitized(url);
          if (!ok) {
            Logger.root.warning('Failed to launch system browser for $url');
          }
        },
      );
      if (!mounted) return;
      widget.onSuccess();
    } catch (e, s) {
      Logger.root.severe('External browser login failed', e, s);
      if (!mounted) return;
      setState(() {
        _externalError = e.toString();
        _externalAuthInFlight = false;
      });
      NotificationService.error(
        message: 'NexusMods login failed: $e',
      );
    } finally {
      if (mounted) {
        widget.onShowOverlay(false);
      }
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_useExternalBrowser) {
      return _ExternalBrowserLoginView(
        loginUrl: _externalLoginUrl,
        error: _externalError,
        inFlight: _externalAuthInFlight,
        onRetry: _runExternalBrowserLogin,
        onReopenUrl: _externalLoginUrl == null
            ? null
            : () => _openUrlExternalSanitized(_externalLoginUrl!),
      );
    }

    return InAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialUrlRequest: URLRequest(
        url: WebUri('https://users.nexusmods.com/auth/sign_in'),
      ),
      initialSettings: InAppWebViewSettings(
        forceDark: ForceDark.ON,
        isInspectable: true,
      ),
      onWebViewCreated: (controller) async {
        await CookieManager.instance(
          webViewEnvironment: webViewEnvironment,
        ).deleteAllCookies();
      },
      onLoadStart: (controller, url) async {
        final uri = url.toString();

        if (uri.startsWith('https://users.nexusmods.com')) {
          widget.onShowOverlay(true);
          return;
        }
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        if (!mounted) return;
        widget.onShowOverlay(false);

        if (errorResponse.contentType != 'text/html') {
          NotificationService.error(
            message:
                'An error occurred while loading the page. Please try again later.',
          );
          return;
        }

        Logger.root.severe(
          'http error: ${String.fromCharCodes(errorResponse.data ?? [])} (code: ${errorResponse.statusCode}, url: ${request.url})',
        );
      },
      onLoadStop: (controller, url) async {
        if (!mounted) return;

        final uri = url.toString();
        if (uri.startsWith('https://users.nexusmods.com/account') ||
            uri.startsWith('https://users.nexusmods.com/account/security')) {
          widget.onShowOverlay(true);
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri('https://www.nexusmods.com/starwarsbattlefront22017'),
            ),
          );
          return;
        }

        if (uri.startsWith('https://users.nexusmods.com/auth') ||
            uri.startsWith('https://users.nexusmods.com/register')) {
          widget.onShowOverlay(false);
          return;
        }

        if (uri.startsWith(
          'https://www.nexusmods.com/games/starwarsbattlefront22017',
        )) {
          await sl.get<NexusModsService>().requestApiToken(
            onUrl: (url) => controller.loadUrl(
              urlRequest: URLRequest(url: WebUri(url)),
            ),
          );
          widget.onSuccess();
        }

        if (uri.startsWith('https://www.nexusmods.com/sso')) {
          await controller.evaluateJavascript(
            source:
                '''document.getElementsByClassName('hero-overlay')[0].scrollIntoView();''',
          );
          widget.onShowOverlay(false);
          return;
        }
      },
    );
  }
}

class _ExternalBrowserLoginView extends StatelessWidget {
  const _ExternalBrowserLoginView({
    required this.loginUrl,
    required this.error,
    required this.inFlight,
    required this.onRetry,
    required this.onReopenUrl,
  });

  final String? loginUrl;
  final String? error;
  final bool inFlight;
  final VoidCallback onRetry;
  final VoidCallback? onReopenUrl;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'NexusMods Login',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              if (error != null) ...[
                Text(
                  'Login failed: $error',
                  style: const TextStyle(color: Color(0xffd13438)),
                ),
                const SizedBox(height: 16),
                Button(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ] else ...[
                const Text(
                  'Your default browser will open the NexusMods sign-in page. '
                  'Once you approve the request, you can return here — the '
                  'launcher will detect the login automatically.',
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    if (inFlight) ...[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      const Text('Waiting for NexusMods…'),
                    ],
                  ],
                ),
                if (onReopenUrl != null) ...[
                  const SizedBox(height: 24),
                  HyperlinkButton(
                    onPressed: onReopenUrl,
                    child: const Text('Re-open browser sign-in page'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
