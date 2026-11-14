import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:logging/logging.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class WindowHelper {
  static const Size _initialSize = Size(1400, 700);
  static final completedSetup = Completer<void>();

  static Future<void> initializeWindow() async {
    Logger('bootstrap').info('Initializing Window');
    final rememberedWindow = Preferences.customization.rememberWindowPosition;

    var size = _initialSize;
    if (rememberedWindow &&
        Preferences.windowData.windowWidth != null &&
        Preferences.windowData.windowHeight != null) {
      size = Size(
        Preferences.windowData.windowWidth!,
        Preferences.windowData.windowHeight!,
      );
    }

    unawaited(
      windowManager.waitUntilReadyToShow().then((_) async {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );

        // KYBER-LINUX-PORT-MOD: the Steam Deck screen is 1280 px wide, so
        // keep the window within the primary display.
        var minimum = _initialSize;
        if (Platform.isLinux) {
          final screen = await _primaryScreen();
          if (screen != null) {
            minimum = Size(
              min(minimum.width, screen.width),
              min(minimum.height, screen.height),
            );
            size = Size(
              min(size.width, screen.width),
              min(size.height, screen.height),
            );
          }
        }

        await windowManager.setBackgroundColor(Colors.transparent);
        await windowManager.setSize(size);
        await windowManager.setBrightness(Brightness.dark);
        await windowManager.setMinimumSize(minimum);
        if (!rememberedWindow) {
          await windowManager.center();
        }

        if (rememberedWindow &&
            Preferences.windowData.windowX != null &&
            Preferences.windowData.windowY != null) {
          final offset = Offset(
            Preferences.windowData.windowX!,
            Preferences.windowData.windowY!,
          );
          if (await isOnScreen(offset)) {
            await windowManager.setPosition(offset);
          } else {
            Logger('bootstrap').warning(
              'Remembered window position is not on any screen, centering instead.',
            );
            await windowManager.center();
            Preferences.windowData.windowX = null;
            Preferences.windowData.windowY = null;
          }
        }

        if (rememberedWindow && Preferences.windowData.windowMaximized) {
          await windowManager.maximize();
        }

        await windowManager.show();
        await windowManager.setSkipTaskbar(false);
        completedSetup.complete();
      }),
    );
  }

  static Future<Size?> _primaryScreen() async {
    try {
      final d = await screenRetriever.getPrimaryDisplay();
      return d.visibleSize ?? d.size;
      // No display info, keep the upstream sizes.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isOnScreen(Offset offset) async {
    final displays = await screenRetriever.getAllDisplays();
    for (final d in displays) {
      final pos = d.visiblePosition ?? Offset.zero;
      final sz = d.visibleSize ?? d.size;
      final rect = Rect.fromLTWH(pos.dx, pos.dy, sz.width, sz.height);
      if (rect.contains(offset)) return true;
    }

    return false;
  }
}
