import 'dart:async';

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
  });

  final String? gameDataDir;
  final List<FrostyMod>? mods;
  final InitializeRequest? initializeRequest;

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
      // Idle ticks (totalBytes == 0) are ignored; the stream self-closes once
      // the subscription is cancelled below / on dispose.
      _protonProgress = getProtonDownloadProgress().listen((p) {
        if (!mounted || p.totalBytes == BigInt.zero) {
          return;
        }
        setState(() {
          protonDownloadedBytes = p.downloadedBytes.toInt();
          protonTotalBytes = p.totalBytes.toInt();
        });
      }, cancelOnError: true);

      await checkService();
      await MaximaHelper.startGame(
            gameDataPath: widget.gameDataDir,
            initializeRequest: widget.initializeRequest,
            mods: widget.mods,
          )
          .then((value) async {
            // Proton download (if any) is done once start_game resolves.
            _protonProgress?.cancel();
            if (!mounted) {
              return;
            }

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
                // FFI inject hit a wall — usually wine-helper not
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
                  ),
                );
                return;
              } else if (error.message.contains('No Steam Proton prefix')) {
                // Missing BF2 Proton prefix (BF2 not run via Steam yet, or a
                // custom game path pointing at a non-Steam copy). Show the
                // actionable message from start_game in a dialog rather than a
                // toast that scrolls away.
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (context) => KyberContentDialog(
                    title: Text('No Proton prefix found'.toUpperCase()),
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
                  ),
                );
                return;
              } else if (error.message.contains(
                'without connecting to the launcher',
              )) {
                // KYBER-LINUX-PORT-MOD 2026-08-13: the launch-wait loop gave
                // up because the game exited before reaching the LSX
                // handshake. The message is a multi-sentence instruction, so a
                // toast is useless for it: six lines, ellipsised, gone after
                // five seconds. Same treatment as the missing-prefix case
                // above, with wider constraints because the text is longer.
                showKyberDialog(
                  context: navigatorKey.currentContext!,
                  builder: (context) => KyberContentDialog(
                    constraints: const BoxConstraints(
                      maxWidth: 560,
                      maxHeight: 640,
                    ),
                    title: Text('Game did not start'.toUpperCase()),
                    content: Text(
                      // anyhow appends "Stack backtrace:" and the frames to
                      // the message. That is noise for a player and pushes the
                      // actual instruction out of view, so cut it. The full
                      // trace stays in the log.
                      error.message.split('Stack backtrace:').first.trim(),
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
                  ),
                );
                return;
              }

              NotificationService.showNotification(
                message: 'Failed to start game: ${error.message}',
                severity: InfoBarSeverity.error,
              );
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

              // KYBER-LINUX-PORT-MOD: this branch already closed the launch
              // dialog, so falling through to the pop below would immediately
              // pop the error dialog we just pushed - the user saw the launch
              // fail with no message at all.
              Sentry.captureException(error, stackTrace: stackTrace);
              Logger.root.severe(
                'Failed to start game: $error',
                error,
                stackTrace,
              );
              return;
            } else {
              NotificationService.showNotification(
                message: 'Failed to start game: $error',
                severity: InfoBarSeverity.error,
              );
            }

            if (mounted) {
              Navigator.of(context).pop();
            }

            Sentry.captureException(error, stackTrace: stackTrace);
            Logger.root.severe(
              'Failed to start game: $error',
              error,
              stackTrace,
            );
          });
    });
    super.initState();
  }

  @override
  void dispose() {
    _gameEvents?.cancel();
    _protonProgress?.cancel();
    _gameStatusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              Text(
                updating
                    ? 'Updating Kyber Module...'
                    : protonTotalBytes != null
                    ? 'Downloading Proton runtime...'
                    : 'Starting Game...',
                style: FluentTheme.of(context).typography.bodyLarge,
              ),
            ],
          ),
          const SizedBox(
            height: 10,
          ),
          Text(
            protonTotalBytes != null
                ? 'Downloading the Proton runtime (~${(protonTotalBytes! / 1048576).round()} MB). This can take a few minutes on a slow connection; the download resumes if interrupted.'
                : 'Please wait while the game is starting. This may take a few seconds.',
            style: FluentTheme.of(context).typography.body?.copyWith(
              color: kWhiteColor,
            ),
          ),
          if (protonTotalBytes != null && protonTotalBytes! > 0) ...[
            const SizedBox(height: 10),
            ProgressBar(
              value:
                  ((protonDownloadedBytes ?? 0) / protonTotalBytes!) * 100,
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
