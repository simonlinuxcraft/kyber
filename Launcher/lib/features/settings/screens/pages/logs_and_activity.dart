import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/core/services/linux_status.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/core/services/rich_presence.dart';
import 'package:kyber_launcher/core/utils/custom_logger.dart';
import 'package:kyber_launcher/features/settings/dialogs/debug_logging_warning_dialog.dart';
import 'package:kyber_launcher/features/settings/screens/settings.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:kyber_launcher/shared/ui/ui.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class LogsAndActivity extends StatelessWidget {
  const LogsAndActivity({super.key});

  @override
  Widget build(BuildContext context) {
    return HiveListener(
      box: box,
      keys: const ['discordRPC'],
      builder: (bx) => SuperListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(8).copyWith(left: 20),
            child: Text(
              'ACTIVITY'.toUpperCase(),
              style: FluentTheme.of(context).typography.title!.copyWith(
                fontWeight: FontWeight.bold,
                color: kInactiveColor,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
          KyberTable(
            items: [
              KyberTableItem.switchButton(
                title: 'Discord Rich Presence',
                value: Preferences.general.discordRPC,
                onChange: (value) async {
                  Preferences.general.discordRPC = value;
                  if (!value) {
                    sl.get<RichPresence>().clearPresence();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.all(8).copyWith(left: 20),
            child: Text(
              'Logging & Sentry'.toUpperCase(),
              style: FluentTheme.of(context).typography.title!.copyWith(
                fontWeight: FontWeight.bold,
                color: kInactiveColor,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
          HiveListener(
            box: box,
            keys: const [
              'sentryOptedOut',
              'frbDebugLogs',
              'moduleDebugLogs',
              'grpcDebugLogs',
            ],
            builder: (_) => KyberTable(
              items: [
                KyberTableItem.button(
                  title: 'Logs',
                  text: 'Export Logs',
                  onClick: () async {
                    await CustomLogger.requestLogExport();
                  },
                ),
                KyberTableItem.button(
                  title:
                      "Opt ${Preferences.general.sentryOptedOut ? "In To" : "Out Of"} Sentry",
                  text: Preferences.general.sentryOptedOut
                      ? 'Opt In'
                      : 'Opt Out',
                  onClick: () async {
                    Preferences.general.sentryOptedOut =
                        !Preferences.general.sentryOptedOut;
                    if (Preferences.general.sentryOptedOut) {
                      await Sentry.close();
                    } else {
                      final info = await PackageInfo.fromPlatform();
                      initSentry(info.version);
                    }
                  },
                ),
                KyberTableItem.switchButton(
                  title: 'Launcher Debug Mode',
                  value: Preferences.debug.frbDebugLogs,
                  onChange: (value) async {
                    if (value) {
                      await showKyberDialog(
                        context: context,
                        builder: (_) => const DebugLoggingWarningDialog(),
                      );
                    }

                    if (!kDebugMode) {
                      PlatformInAppWebViewController
                              .debugLoggingSettings
                              .enabled =
                          value;
                      PlatformInAppWebViewController
                              .debugLoggingSettings
                              .usePrint =
                          value;
                    }

                    Logger.root.info(
                      '${value ? 'Enabled' : 'Disabled'} debug logs',
                    );
                    Logger.root.level = value ? Level.ALL : Level.INFO;
                    Preferences.debug.frbDebugLogs = value;
                    if (!value) {
                      CustomLogger.clearLogFile();
                    }
                  },
                ),
                KyberTableItem.switchButton(
                  title: 'Module Debug Mode',
                  value: Preferences.debug.moduleDebugLogs,
                  onChange: (value) async {
                    if (value) {
                      await showKyberDialog(
                        context: context,
                        builder: (_) => const DebugLoggingWarningDialog(),
                      );
                    }

                    Logger.root.info(
                      '${value ? 'Enabled' : 'Disabled'} module debug logs',
                    );
                    Preferences.debug.moduleDebugLogs = value;
                  },
                ),
                KyberTableItem.switchButton(
                  title: 'Module RPC Debug Mode',
                  value: Preferences.debug.grpcDebugLogs,
                  onChange: (value) async {
                    if (value) {
                      await showKyberDialog(
                        context: context,
                        builder: (_) => const DebugLoggingWarningDialog(),
                      );
                    }

                    Logger.root.info(
                      '${value ? 'Enabled' : 'Disabled'} module debug logs',
                    );
                    Preferences.debug.grpcDebugLogs = value;
                  },
                ),
              ],
            ),
          ),
          if (Platform.isLinux) ..._linuxSystem(context),
        ],
      ),
    );
  }

  // KYBER-LINUX-PORT-MOD: a screenshot of this answers most support questions.
  List<Widget> _linuxSystem(BuildContext context) {
    final status = linuxStatus();
    final style = FluentTheme.of(context).typography.body;
    return [
      const SizedBox(height: 10),
      const SettingsHeader(title: 'SYSTEM'),
      KyberTable(
        items: [
          for (final MapEntry(:key, :value) in status.entries)
            KyberTableItem.custom(
              title: key,
              builder: (_) => Text(value, style: style),
            ),
          KyberTableItem.button(
            title: 'For a bug report',
            text: 'Copy',
            onClick: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: [
                    for (final MapEntry(:key, :value) in status.entries)
                      '$key: $value',
                  ].join('\n'),
                ),
              );
              NotificationService.success(message: 'System info copied');
            },
          ),
        ],
      ),
    ];
  }
}
