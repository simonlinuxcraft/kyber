import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/nexusmods/dialogs/nexusmods_login.dart';
import 'package:kyber_launcher/features/nexusmods/services/nexusmods_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:kyber_launcher/features/navigation_bar/helper/protocol_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:url_launcher/url_launcher_string.dart';

class NexusDownloadService {
  NexusDownloadService._();

  static Future<(String, String)> getNexusDownload(
    String downloadUrl, {
    int tries = 0,
  }) async {
    if (tries > 2) {
      throw Exception('Failed to download mod after 2 attempts');
    }

    if (sl.get<NexusModsService>().nexusUser?.isPremium ?? false) {
      final uri = Uri.parse(downloadUrl);
      final downloadLinks = await sl
          .get<NexusModsService>()
          .nexusBridge
          .apiClient
          .getDownloadLink(
            'starwarsbattlefront22017',
            int.parse(uri.pathSegments.last),
            int.parse(uri.queryParameters['file_id']!),
            null,
            null,
          );

      final downloadLink = Uri.parse(downloadLinks.first.uri);
      final filename = downloadLink.pathSegments.last;
      return (downloadLink.toString(), filename);
    }

    // Linux: bypass the HeadlessInAppWebView trick entirely. The plugin is
    // a no-op stub (no WPE WebKit on Ubuntu 24.04+), so the
    // GenerateDownloadUrl request goes directly through dio with the
    // user's Nexus API key as authentication. Same endpoint and body as
    // the WebView path, just authenticated with `apikey:` header instead
    // of session cookies. Works for both free and premium accounts.
    if (Platform.isLinux) {
      return _getNexusDownloadLinux(downloadUrl, tries: tries);
    }

    final downloadCompleter = Completer<String>();
    late HeadlessInAppWebView webView;

    try {
      final fileId = Uri.parse(downloadUrl).queryParameters['file_id'];
      final body = 'fid=$fileId&game_id=2229';
      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(
            'https://www.nexusmods.com/Core/Libs/Common/Managers/Downloads?GenerateDownloadUrl',
          ),
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'x-requested-with': 'XMLHttpRequest',
          },
          body: Uint8List.fromList(body.codeUnits),
        ),
        onLoadStop: (controller, url) async {
          final currentDocumentContent = await controller.evaluateJavascript(
            source: 'document.body.innerText',
          );
          try {
            final decoded = currentDocumentContent != null
                ? jsonDecode(currentDocumentContent as String)
                : null;
            if (decoded != null && decoded['url'] != null) {
              final uri = decoded['url'] as String;
              if (!downloadCompleter.isCompleted) {
                return downloadCompleter.complete(uri);
              }
            }

            downloadCompleter.completeError(
              TimeoutException('Download URL not found in response'),
            );
          } catch (e) {
            downloadCompleter.completeError(
              TimeoutException('Download URL not found in response'),
            );
          }
        },
        initialSettings: InAppWebViewSettings(),
        webViewEnvironment: webViewEnvironment,
      );

      await webView.run();

      final uri = await downloadCompleter.future.timeout(
        const .new(seconds: 15),
      );

      final filename = uri
          .split('/')
          .last
          .split('?')
          .first
          .replaceAll('%', '_');

      return (uri, filename);
    } on TimeoutException catch (e, s) {
      NotificationService.error(
        message:
            'Failed to create download link. This is usually caused by being logged out of Nexus Mods.',
      );
      final x = await showKyberDialog<bool?>(
        context: navigatorKey.currentContext!,
        builder: (_) => const NexusmodsLogin(),
      );
      if (x != null && x) {
        return getNexusDownload(downloadUrl, tries: tries + 1);
      } else {
        throw Exception('Failed to find download button');
      }
    } catch (e, s) {
      Logger('download_service').severe('Failed to download mod', e, s);
      final htmlContent = await webView.webViewController?.evaluateJavascript(
        source: 'document.getElementById("section").innerHTML',
      );
      if (htmlContent != null) {
        await File(
          join(applicationDocumentsDirectory, 'error.html'),
        ).writeAsString(htmlContent as String);
      }
      rethrow;
    } finally {
      Logger.root.info('Disposing WebView');
      await webView.dispose();
    }
  }

  /// Linux mod-download flow for free Nexus accounts.
  ///
  /// The internal AJAX endpoint (Core/Libs/.../GenerateDownloadUrl) needs
  /// a session cookie we cannot obtain headlessly. Premium accounts hit
  /// the early-return above and never reach this path. So for free
  /// accounts on Linux we mirror the kyber-bf2-linux reference build:
  ///
  ///   1. Open the mod page in the system browser with a clear toast
  ///      asking the user to press "Mod Manager Download".
  ///   2. Park a one-shot completer on `ProtocolHelper.awaitNextNxmUrl`.
  ///      The browser click triggers our xdg-mime handler
  ///      (nxm_handler.sh) which drops the nxm:// URL into
  ///      $XDG_RUNTIME_DIR/kyber/nxm-response. The inotify watcher in
  ///      ProtocolHelper completes the completer instead of routing the
  ///      URL through handleCall() - that way we don't enqueue a second,
  ///      duplicate download.
  ///   3. Parse `key` + `expires` out of the captured nxm:// URL and
  ///      hand them to the regular Nexus REST API
  ///      (`/games/{game}/mods/{mod}/files/{file}/download_link.json`).
  ///      Those short-lived tokens are what makes free-user downloads
  ///      work - without them the same call returns 403.
  static Future<(String, String)> _getNexusDownloadLinux(
    String downloadUrl, {
    int tries = 0,
  }) async {
    final logger = Logger('download_service');

    final service = sl.get<NexusModsService>();
    final apiToken = service.apiToken;
    if (apiToken == null || apiToken.isEmpty) {
      logger.warning('No Nexus API token available for Linux download');
      NotificationService.error(
        message: 'Please log in to Nexus Mods first.',
      );
      final loggedIn = await showKyberDialog<bool?>(
        context: navigatorKey.currentContext!,
        builder: (_) => const NexusmodsLogin(),
      );
      if (loggedIn != null && loggedIn && tries < 2) {
        return getNexusDownload(downloadUrl, tries: tries + 1);
      }
      throw Exception('Nexus API token missing');
    }

    final modUri = Uri.parse(downloadUrl);
    final fileId = modUri.queryParameters['file_id'];
    if (fileId == null) {
      throw ArgumentError(
        'No file_id in Nexus download URL: $downloadUrl',
      );
    }

    logger.info('Trying NXM protocol handler for non-premium download');

    // Park the wait BEFORE opening the browser so a fast click can't
    // race us. Browser click typically takes >1s, but better safe.
    final nxmCompleter = ProtocolHelper.awaitNextNxmUrl();

    // Open the regular Nexus mod-files page - same URL pattern the
    // working tarball build uses. The "Mod Manager Download" button
    // is rendered conditionally by Nexus's frontend JavaScript: it
    // only appears once the browser has a registered handler for the
    // nxm:// scheme. Our xdg-mime registration covers the system
    // level, but each browser additionally needs the user to confirm
    // the handler the FIRST time a nxm:// link is clicked
    // (security UX - Firefox/Chromium will not trust a system-level
    // handler silently). Once accepted, the button shows up on
    // every subsequent visit and our xdg-mime → nxm_handler.sh →
    // inotify pipeline takes over automatically.
    final modSlug = modUri.pathSegments.contains('mods')
        ? modUri.pathSegments[
            modUri.pathSegments.indexOf('mods') - 1]
        : 'starwarsbattlefront22017';
    final modIdFromPath = modUri.pathSegments.isNotEmpty
        ? modUri.pathSegments.last
        : '';
    final modFilesUrl =
        'https://www.nexusmods.com/$modSlug/mods/$modIdFromPath'
        '?tab=files&file_id=$fileId';

    NotificationService.showNotification(
      message: 'Opening the mod page in your browser. Click "Mod '
          'Manager Download" there. If the button is missing: enter '
          '"nxm:test" in the address bar once and select "Kyber NXM '
          'Handler" - the button will then appear on every mod page.',
      severity: InfoBarSeverity.info,
    );
    try {
      await launchUrlString(
        modFilesUrl,
        mode: LaunchMode.externalApplication,
      );
    } catch (e, s) {
      ProtocolHelper.cancelPendingNxmWait(nxmCompleter);
      logger.severe('Failed to open Nexus mod page in browser', e, s);
      throw Exception('Cannot open browser to start NXM download flow');
    }

    final String nxmUrl;
    try {
      nxmUrl = await nxmCompleter.future.timeout(
        const Duration(seconds: 180),
      );
    } on TimeoutException {
      ProtocolHelper.cancelPendingNxmWait(nxmCompleter);
      NotificationService.error(
        message:
            'No NXM response received within 180 seconds. Please click '
            '"Mod Manager Download" in the browser tab that opened.',
      );
      throw Exception('No NXM response received within 180 seconds');
    } catch (e) {
      ProtocolHelper.cancelPendingNxmWait(nxmCompleter);
      rethrow;
    }

    logger.info('NXM response captured: $nxmUrl');

    final nxmUri = Uri.parse(nxmUrl);
    final key = nxmUri.queryParameters['key'];
    final expiresRaw = nxmUri.queryParameters['expires'];
    if (key == null || expiresRaw == null) {
      throw Exception('NXM URL missing key/expires: $nxmUrl');
    }
    final expires = int.tryParse(expiresRaw);
    if (expires == null) {
      throw Exception('NXM URL has non-numeric expires: $nxmUrl');
    }

    // nxm://starwarsbattlefront22017/mods/<modId>/files/<fileId>?key=...
    final segments = nxmUri.pathSegments;
    final nxmModId = int.parse(segments[segments.indexOf('mods') + 1]);
    final nxmFileId = int.parse(segments[segments.indexOf('files') + 1]);

    final downloadLinks =
        await service.nexusBridge.apiClient.getDownloadLink(
      'starwarsbattlefront22017',
      nxmModId,
      nxmFileId,
      key,
      expires,
    );
    if (downloadLinks.isEmpty) {
      throw Exception('Nexus returned no download links for nxm: $nxmUrl');
    }

    final resolved = Uri.parse(downloadLinks.first.uri);
    final filename = resolved.pathSegments.last;
    logger.info('NXM download link resolved: $resolved');
    return (resolved.toString(), filename);
  }

}
