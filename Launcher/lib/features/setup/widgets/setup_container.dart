import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' as mt;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_fadein/flutter_fadein.dart';
import 'package:grpc/grpc.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/maxima/providers/maxima_cubit.dart';
import 'package:kyber_launcher/features/maxima/screens/maxima_login.dart';
import 'package:kyber_launcher/features/navigation_bar/services/linux_first_start.dart';
import 'package:kyber_launcher/features/patreon/services/patreon_service.dart';
import 'package:kyber_launcher/features/setup/widgets/mod_selector.dart';
import 'package:kyber_launcher/features/setup/widgets/nexus_login_screen.dart';
import 'package:kyber_launcher/gen/assets.gen.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/utils/background_blur.dart';
import 'package:kyber_launcher/shared/ui/utils/button_builder.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher_string.dart';

class SetupContainer extends StatefulWidget {
  const SetupContainer({
    required this.showWebView,
    required this.page,
    required this.onNexusLogin,
    required this.onNexusCancel,
    required this.onNexusSuccess,
    super.key,
  });

  final int page;
  final VoidCallback onNexusLogin;
  final VoidCallback onNexusCancel;
  final VoidCallback onNexusSuccess;
  final bool showWebView;

  @override
  State<SetupContainer> createState() => _SetupContainerState();
}

class _SetupContainerState extends State<SetupContainer> {
  bool showOverlay = false;
  bool whitelistPrompt = false;
  bool loading = false;

  @override
  Widget build(BuildContext context) {
    if (widget.page == 2) {
      return const ModSelector();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: BackgroundBlur(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: decoColor, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: BlocBuilder<MaximaCubit, MaximaState>(
            builder: (context, state) {
              if (widget.showWebView) {
                return Stack(
                  children: [
                    NexusLoginScreen(
                      onShowOverlay: (showOverlay) {
                        setState(() {
                          this.showOverlay = showOverlay;
                        });
                      },
                      onSuccess: widget.onNexusSuccess,
                    ),
                    if (showOverlay)
                      Positioned.fill(
                        child: FadeIn(
                          child: Container(
                            color: FluentTheme.of(
                              context,
                            ).micaBackgroundColor.withOpacity(.9),
                            alignment: Alignment.center,
                            child: const Center(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    height: 30,
                                    width: 30,
                                    child: ProgressRing(),
                                  ),
                                  SizedBox(width: 15),
                                  Text(
                                    'Waiting for Nexus Mods...',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontFamily: FontFamily.battlefrontUI,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SizedBox(
                            height: 40,
                            width: 40,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: BackgroundBlur(
                                child: ButtonBuilder(
                                  builder: (context, hovered) {
                                    return AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: hovered
                                              ? kActiveColor
                                              : decoColor,
                                          width: 2,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.all(6),
                                      child: const Icon(
                                        mt.Icons.cancel_rounded,
                                      ),
                                      //child: const Text(
                                      //  'CANCEL LOGIN',
                                      //  style: TextStyle(
                                      //    fontFamily: FontFamily.battlefrontUI,
                                      //    fontSize: 16,
                                      //    height: 1,
                                      //  ),
                                      //),
                                    );
                                  },
                                  onClick: widget.onNexusCancel,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 14,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 105,
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.page == 0
                                    ? 'SIGN IN: EA'
                                    : 'SIGN IN: NEXUS MODS',
                                style: TextStyle(
                                  fontFamily: FontFamily.battlefrontUI,
                                  fontSize: 28,
                                  color: kActiveColor,
                                ),
                              ),
                              Text(
                                widget.page == 0
                                    ? 'VALIDATE GAME OWNERSHIP AND ACCESS ONLINE FEATURES IN-GAME.'
                                    : 'LINK ACCOUNT AND ACCESS INTEGRATED NEXUS MODS FUNCTIONALITY.',
                                style: const TextStyle(
                                  fontFamily: FontFamily.battlefrontUI,
                                  fontSize: 17,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          height: 2,
                          color: decoColor,
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Builder(
                              builder: (context) {
                                if (whitelistPrompt) {
                                  return DefaultTextStyle(
                                    style: FluentTheme.of(context)
                                        .typography
                                        .body!
                                        .copyWith(
                                          fontSize: 16,
                                        ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Are you sure you want to add your current account to the whitelist?',
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          'Current account: ${state.servicePlayer?.displayName}',
                                        ),
                                        const SizedBox(height: 20),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            KyberButton(
                                              text: 'Log out',
                                              onPressed: loading
                                                  ? null
                                                  : () => context
                                                        .read<MaximaCubit>()
                                                        .logout(),
                                            ),
                                            KyberButton(
                                              text: 'Add to whitelist',
                                              onPressed: loading
                                                  ? null
                                                  : () async {
                                                      try {
                                                        setState(
                                                          () => loading = true,
                                                        );
                                                        await PatreonService.addToWhitelist();
                                                        await Future.delayed(
                                                          const Duration(
                                                            milliseconds: 200,
                                                          ),
                                                        );
                                                        context
                                                            .read<MaximaCubit>()
                                                            .requestLogin(
                                                              skipMaximaCheck:
                                                                  true,
                                                            );
                                                        setState(
                                                          () =>
                                                              whitelistPrompt =
                                                                  false,
                                                        );
                                                      } catch (e, s) {
                                                        final message = switch (e) {
                                                          GrpcError(
                                                            message: final message,
                                                          ) =>
                                                            message ??
                                                                'Unknown GRPC Error',
                                                          _ => e.toString(),
                                                        };

                                                        Logger.root.warning(
                                                          'Failed to add to whitelist: $message',
                                                          e,
                                                          s,
                                                        );
                                                        NotificationService.showNotification(
                                                          title:
                                                              'Failed to add to whitelist',
                                                          message: message,
                                                          severity:
                                                              InfoBarSeverity
                                                                  .error,
                                                        );
                                                      } finally {
                                                        setState(
                                                          () => loading = false,
                                                        );
                                                      }
                                                    },
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                if (state.error != null &&
                                    !state.error!.contains('whitelist')) {
                                  return MaximaErrorWidget(state: state);
                                } else if (state.error != null &&
                                    state.error!.contains('whitelist')) {
                                  return Column(
                                    children: [
                                      Text(state.error ?? 'An error occurred'),
                                      const SizedBox(height: 10),
                                      DefaultTextStyle(
                                        style: FluentTheme.of(context)
                                            .typography
                                            .body!
                                            .copyWith(
                                              fontSize: 16,
                                            ),
                                        child: Row(
                                          children: [
                                            Text(
                                              'EA-ID: ${state.servicePlayer?.uniqueName}',
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 30),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          KyberButton(
                                            text: 'Log out',
                                            onPressed: loading
                                                ? null
                                                : () => context
                                                      .read<MaximaCubit>()
                                                      .logout(),
                                          ),
                                          KyberButton(
                                            text: 'Authorize Patreon',
                                            onPressed: loading
                                                ? null
                                                : () async {
                                                    try {
                                                      setState(
                                                        () => loading = true,
                                                      );
                                                      final code =
                                                          await PatreonService.requestOAuthLogin();
                                                      if (code == null) {
                                                        NotificationService.error(
                                                          title:
                                                              'Authorization failed',
                                                          message:
                                                              'No code was returned',
                                                        );
                                                        return;
                                                      }

                                                      await PatreonService.fetchToken(
                                                        code,
                                                      );

                                                      setState(() {
                                                        whitelistPrompt = true;
                                                        loading = false;
                                                      });
                                                      NotificationService.showNotification(
                                                        title:
                                                            'Authorization successful',
                                                        message:
                                                            'You have been successfully authorized as a Patreon member',
                                                        severity:
                                                            InfoBarSeverity
                                                                .success,
                                                      );
                                                    } catch (e, s) {
                                                      Logger.root.warning(
                                                        'Failed to authorize Patreon',
                                                        e,
                                                        s,
                                                      );
                                                      if (e is GrpcError) {
                                                        return NotificationService.showNotification(
                                                          title:
                                                              'Authorization failed',
                                                          message:
                                                              e.message ??
                                                              'An error occurred',
                                                          severity:
                                                              InfoBarSeverity
                                                                  .error,
                                                        );
                                                      } else if (e
                                                          is PatreonException) {
                                                        Logger.root.warning(
                                                          'Failed to authorize Patreon: $e',
                                                        );
                                                        return NotificationService.showNotification(
                                                          title:
                                                              'Authorization failed',
                                                          message: e.message,
                                                          severity:
                                                              InfoBarSeverity
                                                                  .error,
                                                        );
                                                      }

                                                      NotificationService.showNotification(
                                                        title:
                                                            'Authorization failed',
                                                        message:
                                                            'An error occurred',
                                                        severity:
                                                            InfoBarSeverity
                                                                .error,
                                                      );
                                                    } finally {
                                                      setState(
                                                        () => loading = false,
                                                      );
                                                    }
                                                  },
                                          ),
                                        ],
                                      ),
                                    ],
                                  );
                                }

                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      widget.page == 0
                                          ? 'Open the official EA Sign In page:'
                                          : 'Open the official Nexus Mods sign in page:',
                                      style: const TextStyle(
                                        fontFamily: FontFamily.battlefrontUI,
                                        fontSize: 18,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    ButtonBuilder(
                                      builder: (context, hovered) {
                                        return AnimatedContainer(
                                          height: 50,
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            border: Border.all(
                                              color: hovered
                                                  ? kActiveColor
                                                  : decoColor,
                                              width: 2,
                                            ),
                                          ),
                                          child: AnimatedDefaultTextStyle(
                                            duration: const Duration(
                                              milliseconds: 200,
                                            ),
                                            style: const TextStyle(
                                              color: kWhiteColor,
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Expanded(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          10,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        if (widget.page == 0)
                                                          Assets.logos.eaPlay
                                                              .svg(
                                                                color:
                                                                    kWhiteColor,
                                                                height: 30,
                                                              )
                                                        else
                                                          Assets.logos.nexusMods
                                                              .svg(
                                                                color:
                                                                    kWhiteColor,
                                                                height: 30,
                                                              ),
                                                        const SizedBox(
                                                          width: 10,
                                                        ),
                                                        const Text(
                                                          'SIGN IN',
                                                          style: TextStyle(
                                                            fontFamily: FontFamily
                                                                .battlefrontUI,
                                                            fontSize: 20,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                Container(
                                                  width: 2,
                                                  color: decoColor,
                                                ),
                                                const SizedBox(width: 8),
                                                if (loading)
                                                  Container(
                                                    width: 30,
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 10,
                                                          horizontal: 2,
                                                        ),
                                                    child: const ProgressRing(),
                                                  )
                                                else
                                                  const SizedBox(
                                                    width: 30,
                                                    child: Icon(
                                                      mt.Icons.login,
                                                      size: 24,
                                                    ),
                                                  ),
                                                const SizedBox(width: 10),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                      onClick: () async {
                                        try {
                                          setState(() => loading = true);
                                          if (widget.page == 0) {
                                            // KYBER-LINUX-PORT-MOD: the menu
                                            // entry brings the qrc:// handler
                                            // this first login returns through.
                                            if (Platform.isLinux) {
                                              await linuxFirstStart(context);
                                            }
                                            if (!context.mounted) return;
                                            await context
                                                .read<MaximaCubit>()
                                                .requestLogin();
                                          } else {
                                            widget.onNexusLogin();
                                          }
                                        } finally {
                                          if (mounted)
                                            setState(() => loading = false);
                                        }
                                      },
                                    ),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.bottomLeft,
                                        child: Text(
                                          widget.page == 0
                                              ? 'The official EA Sign In page will open in an external browser. This step is required to proceed.'
                                              : 'The official Nexus Mods sign in page will open in this window. Skipping this step will disable all integrated Nexus Mods functionality.',
                                          style: const TextStyle(
                                            fontFamily:
                                                FontFamily.battlefrontUI,
                                            fontSize: 17,
                                            color: kGrayColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 2,
                    color: decoColor,
                  ),
                  Expanded(
                    flex: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 105,
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'TRANSPARENCY',
                                style: TextStyle(
                                  fontFamily: FontFamily.battlefrontUI,
                                  fontSize: 28,
                                ),
                              ),
                              Text(
                                'Maxima authentication service'.toUpperCase(),
                                style: const TextStyle(
                                  fontFamily: FontFamily.battlefrontUI,
                                  fontSize: 17,
                                  color: kGrayColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          height: 2,
                          color: decoColor,
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: SingleChildScrollView(
                              child: RichText(
                                text: TextSpan(
                                  children: [
                                    const TextSpan(
                                      text: 'MAXIMA\n\n',
                                      style: TextStyle(
                                        fontFamily: FontFamily.battlefrontUI,
                                        fontSize: 20,
                                      ),
                                    ),
                                    const TextSpan(
                                      text:
                                          'EA Sign In utilises Maxima - an in-development third-party replacement for the EA App. Maxima is developed and operated by Armchair Developers - the team behind KYBER for STAR WARS: Battlefront II.',
                                    ),
                                    const TextSpan(
                                      text:
                                          '\n\nIn the interest of maintaining transparency the entirety of Maxima’s source code is publicly available for viewing.\n\n',
                                    ),
                                    TextSpan(
                                      text: 'VIEW SOURCE CODE - MAXIMA',
                                      style: TextStyle(
                                        color: kActiveColor,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          launchUrlString(
                                            'https://github.com/ArmchairDevelopers/Maxima',
                                          );
                                        },
                                    ),
                                    const TextSpan(
                                      text: '\n\nKYBER',
                                      style: TextStyle(
                                        fontFamily: FontFamily.battlefrontUI,
                                        fontSize: 20,
                                      ),
                                    ),
                                    const TextSpan(
                                      text:
                                          '\n\nKYBER is a third-party launcher, mod interface, and game server platform for STAR WARS: Battlefront II developed and operated by Armchair Developers.',
                                    ),
                                    const TextSpan(
                                      text:
                                          '\n\nIn the interest of maintaining transparency the entirety of KYBER’s source code is publicly available for viewing.\n\n',
                                    ),
                                    TextSpan(
                                      text: 'VIEW SOURCE CODE - KYBER',
                                      style: TextStyle(
                                        color: kActiveColor,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          launchUrlString(
                                            'https://github.com/ArmchairDevelopers/Kyber',
                                          );
                                        },
                                    ),
                                    const TextSpan(
                                      text: '\n\nARMCHAIR DEVELOPERS',
                                      style: TextStyle(
                                        fontFamily: FontFamily.battlefrontUI,
                                        fontSize: 20,
                                      ),
                                    ),
                                    const TextSpan(
                                      text:
                                          '\n\nArmchair Developers is independently operated and is not, in any way, affiliated with Electronic Arts (EA).\n\n',
                                    ),
                                    TextSpan(
                                      text: 'LEARN MORE',
                                      style: TextStyle(
                                        color: kActiveColor,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          //launchUrlString('https://docs.flutter.io/flutter/services/UrlLauncher-class.html');
                                        },
                                    ),
                                  ],
                                  style: const TextStyle(
                                    fontFamily: FontFamily.battlefrontUI,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
