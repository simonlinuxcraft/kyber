import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/core.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/core/services/module_version_service.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/kyber/dialogs/kyber_anti_virus_exclusion.dart';
import 'package:kyber_launcher/features/maxima/dialogs/launch_error_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/maxima_expired_session_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/maxima_game_locator_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/maxima_game_not_found_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/maxima_inject_failure_dialog.dart';
import 'package:kyber_launcher/features/maxima/helper/maxima_helper.dart';
import 'package:kyber_launcher/features/mods/helper/preloaded_mods_helper.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/gen/rust/api/maxima.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:logging/logging.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class MaximaStartGameDialog extends StatefulWidget {
  const MaximaStartGameDialog({
    super.key,
    this.gameDataDir,
    this.initializeRequest,
    this.mods,
    this.refreshJoinToken,
  });

  final String? gameDataDir;
  final List<FrostyMod>? mods;
  final InitializeRequest? initializeRequest;

  /// Returns a fresh join token when the current one is close to its 15 minute
  /// expiry, or null when it is still good. Only set for joins, never hosting.
  final Future<String?> Function()? refreshJoinToken;

  @override
  State<MaximaStartGameDialog> createState() => _MaximaStartGameDialogState();
}

class _MaximaStartGameDialogState extends State<MaximaStartGameDialog> {
  Timer? _gameStatusTimer;
  StreamSubscription<String>? _gameEvents;
  // First-launch GE-Proton runtime download progress (Linux). Lets the dialog
  // show a percentage during the ~516MB download instead of looking frozen.
  StreamSubscription<ProtonDownloadProgress>? _protonProgress;

  bool updating = false;
  bool preloadingMods = false;
  String? lastEvent;
  int? protonDownloadedBytes;
  int? protonTotalBytes;
  // KYBER-LINUX-PORT-MOD: launch step reported by Rust, e.g. registry 3/13,
  // and a running clock so a long first launch does not look frozen.
  String step = '';
  final _elapsed = Stopwatch()..start();
  Timer? _clock;

  @override
  void initState() {
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      final available = await ModuleVersionService().updateAvailable(
        module: VersionModule.module,
      );
      if (available) {
        try {
          setState(() => updating = true);

          await ModuleVersionService().updateVersion(
            module: VersionModule.module,
          );

          if (!mounted) {
            return;
          }

          setState(() => updating = false);
        } catch (e, st) {
          if (mounted) {
            setState(() => updating = false);
          }

          final message = switch (e) {
            AnyhowException() => e.message,
            PanicException() => e.message,
            _ => e.toString(),
          };

          Logger.root.severe('Failed to update Kyber Module', e, st);
          await Sentry.captureException(e, stackTrace: st);
          NotificationService.showNotification(
            message: 'Failed to update Kyber Module: $message',
            severity: InfoBarSeverity.error,
          );

          Navigator.of(context).pop();

          return;
        }
      }

      final req = widget.initializeRequest ?? .new();
      if (Preferences.general.enabledPreloadMods) {
        setState(() => preloadingMods = true);
        final preloadedMods = await PreloadedModsHelper.preloadMods();
        if (!mounted) {
          return;
        }

        req.modData = .new(
          mods: req.modData.mods,
          explodedMods: req.modData.explodedMods,
          basePath: req.modData.basePath,
          modPaths: [
            ...req.modData.modPaths,
            ...preloadedMods,
          ],
        );
      }

      // Surface the GE-Proton runtime download (first launch) as a percentage.
      // Idle ticks (totalBytes == 0) only carry the step; the stream
      // self-closes once the subscription is cancelled below / on dispose.
      _protonProgress = getProtonDownloadProgress().listen((p) {
        final downloading = p.totalBytes != BigInt.zero;
        if (!mounted ||
            (!downloading && protonTotalBytes == null && p.step == step)) {
          return;
        }
        setState(() {
          step = p.step;
          protonDownloadedBytes = downloading
              ? p.downloadedBytes.toInt()
              : null;
          protonTotalBytes = downloading ? p.totalBytes.toInt() : null;
        });
      }, cancelOnError: true);

      await checkService();
      // startGame refreshes the join token right before the DLL reads it.
      await MaximaHelper.startGame(
            gameDataPath: widget.gameDataDir,
            initializeRequest: widget.initializeRequest,
            mods: widget.mods,
            refreshJoinToken: widget.refreshJoinToken,
          )
          .then((value) async {
            // Proton download (if any) is done once start_game resolves.
            _protonProgress?.cancel();
            if (!mounted) {
              return;
            }
            // The handshake is done, the game is still loading.
            setState(() => step = '');

            _gameEvents = value.eventStream.listen(
              (e) {
                setState(() => lastEvent = e);

                if ([
                      'IsProgressiveInstallationAvailable',
                      'GetGameInfo',
                      'GetInfo',
                    ].contains(e) &&
                    mounted) {
                  _gameEvents?.cancel();
                  if (mounted) {
                    Navigator.of(context).pop();
                  }
                }
              },
              onDone: () {
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              cancelOnError: true,
              onError: (_) {
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
            );
          })
          .onError((error, stackTrace) {
            _gameEvents?.cancel();
            _protonProgress?.cancel();
            // PID lookup miss or DLL handshake timeout: route both into the
            // recovery dialog (retry / CLI) instead of a dead-end toast.
            if (error is InjectHandshakeTimeoutException ||
                error is GamePidNotFoundException) {
              if (mounted) {
                Navigator.of(context).pop();
              }
              showKyberDialog(
                context: navigatorKey.currentContext!,
                builder: (_) => MaximaInjectFailureDialog(
                  initializeRequest: widget.initializeRequest,
                  gameDataPath: widget.gameDataDir,
                  mods: widget.mods,
                  errorMessage: error.toString(),
                  refreshJoinToken: widget.refreshJoinToken,
                ),
              );
              return;
            }
            if (error is AnyhowException) {
              if (mounted) {
                Navigator.of(context).pop();
              }

              if (error.message.contains('Game not found')) {
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (_) => const MaximaGameNotFoundDialog(),
                );
                return;
              } else if (error.message.contains('Game not installed')) {
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (_) => const MaximaGameLocatorDialog(),
                );
                return;
              } else if (error.message.contains('remote io error')) {
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (_) => const KyberAntiVirusExclusion(),
                );
                return;
              } else if (error.message.contains('invalid redirect')) {
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (_) => const MaximaExpiredSessionDialog(),
                );
                return;
              } else if (error.message.contains('failed to run wine command') ||
                  error.message.contains('Failed to inject Kyber') ||
                  error.message.contains('Failed to find PID')) {
                // FFI inject hit a wall - usually wine-helper not
                // reaching the wineserver, the PID lookup failing, or
                // a missing DLL import. Recovery dialog gives the user
                // a retry + CLI option.
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (_) => MaximaInjectFailureDialog(
                    initializeRequest: widget.initializeRequest,
                    gameDataPath: widget.gameDataDir,
                    mods: widget.mods,
                    errorMessage: error.message,
                    refreshJoinToken: widget.refreshJoinToken,
                  ),
                );
                return;
              }

              // KYBER-LINUX-PORT-MOD: on Linux these are mostly Proton or
              // prefix problems with instructions too long for a toast.
              if (Platform.isLinux) {
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (_) => LaunchErrorDialog(error.message),
                );
              } else {
                NotificationService.showNotification(
                  message:
                      'Failed to start game: '
                      '${error.message.split('Stack backtrace:').first.trim()}',
                  severity: InfoBarSeverity.error,
                );
              }
            } else if (error is PanicException) {
              if (mounted) {
                Navigator.of(context).pop();
              }

              showKyberDialog(
                context: navigatorKey.currentContext!,
                builder: (context) {
                  return KyberContentDialog(
                    title: Text('Failed to start game'.toUpperCase()),
                    content: Text(
                      error.message,
                      style: const TextStyle(
                        fontFamily: FontFamily.battlefrontUI,
                        fontSize: 17,
                      ),
                    ),
                    actions: [
                      KyberButton(
                        onPressed: () => Navigator.of(context).pop(),
                        text: 'Close',
                      ),
                    ],
                  );
                },
              );
            } else {
              // KYBER-LINUX-PORT-MOD: every branch closes the launch dialog
              // once. A second pop removed the whole page, leaving a blank
              // window.
              if (mounted) {
                Navigator.of(context).pop();
              }
              NotificationService.showNotification(
                message: 'Failed to start game: $error',
                severity: InfoBarSeverity.error,
              );
            }

            Sentry.captureException(error, stackTrace: stackTrace);
            Logger.root.severe(
              'Failed to start game: $error',
              error,
              stackTrace,
            );
          });
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    super.initState();
  }

  @override
  void dispose() {
    _gameEvents?.cancel();
    _protonProgress?.cancel();
    _gameStatusTimer?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = _elapsed.elapsed.inSeconds;
    final clock = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    return KyberContentDialog(
      title: Text('GAME LAUNCHING'.toUpperCase()),
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 300),
      content: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                height: 15,
                width: 15,
                child: RepaintBoundary(child: ProgressRing()),
              ),
              const SizedBox(
                width: 15,
              ),
              Flexible(
                child: Text(
                  updating
                      ? 'Updating Kyber Module...'
                      : step.isNotEmpty
                      ? '$step...'
                      : protonTotalBytes != null
                      ? 'Downloading Proton runtime...'
                      : 'Starting Game...',
                  style: FluentTheme.of(context).typography.bodyLarge,
                ),
              ),
              const SizedBox(width: 10),
              Text(clock, style: FluentTheme.of(context).typography.caption),
            ],
          ),
          const SizedBox(
            height: 10,
          ),
          Text(
            protonTotalBytes != null
                ? 'This can take a few minutes on a slow connection.'
                : step.contains('first launch')
                ? 'This only happens once and can take a minute or two.'
                : step.isNotEmpty
                ? 'Please wait while the game is starting.'
                : 'Please wait while the game is starting. This may take a few seconds.',
            style: FluentTheme.of(context).typography.body?.copyWith(
              color: kWhiteColor,
            ),
          ),
          if (protonTotalBytes != null && protonTotalBytes! > 0) ...[
            const SizedBox(height: 10),
            ProgressBar(
              value: ((protonDownloadedBytes ?? 0) / protonTotalBytes!) * 100,
            ),
            const SizedBox(height: 4),
            Text(
              '${((protonDownloadedBytes ?? 0) / 1048576).round()} / ${(protonTotalBytes! / 1048576).round()} MB',
              style: FluentTheme.of(context).typography.caption,
            ),
          ],
          const SizedBox(
            height: 10,
          ),
          Text(
            lastEvent ?? '',
            style: FluentTheme.of(context).typography.body,
          ),
        ],
      ),
    );
  }
}
