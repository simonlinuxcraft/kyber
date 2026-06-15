import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as mt;
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/features/settings/screens/aaa.dart';
import 'package:kyber_launcher/features/settings/screens/pages/accounts_and_updates.dart';
import 'package:kyber_launcher/features/settings/screens/pages/language_and_accessibility.dart';
import 'package:kyber_launcher/features/settings/screens/pages/logs_and_activity.dart';
import 'package:kyber_launcher/features/settings/screens/pages/mod_support.dart';
import 'package:kyber_launcher/features/settings/screens/pages/proximity_chat.dart';
import 'package:kyber_launcher/gen/assets.gen.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Linux-port release version, shown next to the upstream Kyber client version
// in Settings. Keep in sync with the GitHub release / CHANGELOG each release.
const String kLinuxPortVersion = '0.1.0-beta.6.4.5';

class SettingsList extends StatefulWidget {
  const SettingsList({this.initialIndex, super.key});

  final int? initialIndex;

  @override
  State<SettingsList> createState() => _SettingsListState();
}

class _SettingsListState extends State<SettingsList> {
  final horizontalLength = 3;
  final verticalLength = 2;
  int? selectedIndex;
  int hoveredIndex = -1;
  int hoveredRow = -1;

  @override
  void initState() {
    selectedIndex = widget.initialIndex;
    super.initState();
  }

  final items = <Map<String, dynamic>>[
    {
      'title': 'LANGUAGE & ACCESSIBILITY',
      'description': 'CHANGE LANGUAGE, PROXY & ACCESSIBILITY SETTINGS',
      'child': const LanguageAndAccessibility(),
    },
    {
      'title': 'MODS / PROTON',
      'description': 'CONFIGURE MODS SETTINGS, IMPORT FROM FROSTY & MORE',
      'child': const ModSupport(),
    },
    {
      'title': 'CREDITS LIST',
      'description': 'VIEW DEVELOPERS, CONTRIBUTORS & PATREON SUPPORTERS',
      'child': const Credits(),
    },
    {
      'title': 'INGAME SETTINGS',
      'description': 'Configure Proximity Chat settings'.toUpperCase(),
      'child': const ProximityChat(),
    },
    {
      'title': 'LOGS & ACTIVITY',
      'description': 'VIEW ACTIVITY & DEBUG LOGGING SETTINGS',
      'child': const LogsAndActivity(),
    },
    {
      'title': 'ACCOUNTS & UPDATES',
      'description': 'LOGOUT, UPDATE SETTINGS & MORE',
      'child': const AccountsAndUpdates(),
    },
  ];

  @override
  Widget build(BuildContext context) {
    if (selectedIndex != null) {
      return _SettingsSubPage(
        title: items.elementAt(selectedIndex!)['title'] as String,
        description: items.elementAt(selectedIndex!)['description'] as String,
        onClose: () {
          setState(() {
            selectedIndex = null;
          });
        },
        child: items.elementAt(selectedIndex!)['child'] as Widget,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.all(
            Radius.circular(kDefaultOuterBorderRadius - 0.5),
          ),
          child: BackgroundBlur(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < verticalLength; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var j = 0; j < horizontalLength; j++)
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onEnter: (_) => setState(() {
                            hoveredIndex = i * horizontalLength + j;
                            hoveredRow = i;
                          }),
                          onExit: (_) => setState(() {
                            hoveredIndex = -1;
                            hoveredRow = -1;
                          }),
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                hoveredIndex = -1;
                                selectedIndex = i * horizontalLength + j;
                              });
                            },
                            child: _SettingsContainer(
                              horizontalIndex: j,
                              verticalIndex: i,
                              hoveredIndex: hoveredIndex,
                              item:
                                  items.elementAt(
                                        i * horizontalLength + j,
                                      )['title']
                                      as String,
                              index: i * horizontalLength + j,
                              hoveredRow: hoveredRow,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: const BorderRadius.all(
            Radius.circular(kDefaultInnerBorderRadius),
          ),
          child: Container(
            alignment: Alignment.center,
            width: 340,
            decoration: BoxDecoration(
              border: Border.all(
                color: decoColor,
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(kDefaultInnerBorderRadius),
            ),
            child: FutureBuilder(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const SizedBox.shrink();
                }

                if (snapshot.data?.version == null) {
                  return const SizedBox.shrink();
                }

                return Text(
                  'VERSION: ${snapshot.data?.version}#CL${snapshot.data?.buildNumber}\n'
                  'unofficial Linux port $kLinuxPortVersion',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: FontFamily.iBMPlexMono,
                    fontSize: 13,
                    color: Colors.white,
                  ),
                  maxLines: 2,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsSubPage extends StatelessWidget {
  const _SettingsSubPage({
    required this.title,
    required this.description,
    required this.child,
    required this.onClose,
  });

  final VoidCallback onClose;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(kDefaultOuterBorderRadius),
                ),
                child: BackgroundBlur(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(kDefaultOuterBorderRadius),
                      ),
                      border: kDefaultAllBorder,
                    ),
                    child: SizedBox(
                      height: 65,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontFamily: FontFamily.battlefrontUI,
                                      fontSize: 20,
                                      height: 1,
                                    ),
                                  ),
                                  Text(
                                    description,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      color: kWhiteColor,
                                      fontFamily: FontFamily.battlefrontUI,
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 15),
                            KyberIconButton(
                              iconData: mt.Icons.close,
                              onPressed: onClose,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(kDefaultOuterBorderRadius),
                  ),
                  child: BackgroundBlur(
                    child: mt.Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(
                                  kDefaultOuterBorderRadius,
                                ),
                              ),
                              child: Container(
                                decoration: const BoxDecoration(
                                  borderRadius: BorderRadius.vertical(
                                    bottom: Radius.circular(
                                      kDefaultOuterBorderRadius,
                                    ),
                                  ),
                                  border: Border(
                                    bottom: kDefaultBorder,
                                    left: kDefaultBorder,
                                    right: kDefaultBorder,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: child,
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: const BoxDecoration(
                                borderRadius: BorderRadius.vertical(
                                  bottom: Radius.circular(
                                    kDefaultOuterBorderRadius,
                                  ),
                                ),
                                border: Border(bottom: kDefaultBorder),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        /*ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: KyberCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                SizedBox(
                  height: 65,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontFamily: FontFamily.battlefrontUI,
                                  fontSize: 20,
                                  height: 1,
                                ),
                              ),
                              Text(
                                description,
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: kWhiteColor,
                                  fontFamily: FontFamily.battlefrontUI,
                                  height: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 15),
                        KyberIconButton(
                          iconData: mt.Icons.close,
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                ),
                ContainerSeparator(),
                Expanded(child: child),
              ],
            ),
          ),
        ),*/
      ],
    );
  }
}

class _SettingsContainer extends StatelessWidget {
  const _SettingsContainer({
    required this.horizontalIndex,
    required this.verticalIndex,
    required this.hoveredIndex,
    required this.item,
    required this.index,
    required this.hoveredRow,
  });

  final int horizontalIndex;
  final int verticalIndex;
  final int hoveredIndex;
  final int index;
  final int hoveredRow;
  final String item;

  @override
  Widget build(BuildContext context) {
    final isHovered = index == hoveredIndex;
    BorderRadius? borderRadius;
    if (horizontalIndex == 0) {
      if (verticalIndex == 0) {
        borderRadius = const BorderRadius.only(
          topLeft: Radius.circular(kDefaultOuterBorderRadius),
        );
      } else if (verticalIndex == 1) {
        borderRadius = const BorderRadius.only(
          bottomLeft: Radius.circular(kDefaultOuterBorderRadius),
        );
      }
    } else if (horizontalIndex == 2) {
      if (verticalIndex == 0) {
        borderRadius = const BorderRadius.only(
          topRight: Radius.circular(kDefaultOuterBorderRadius),
        );
      } else if (verticalIndex == 1) {
        borderRadius = const BorderRadius.only(
          bottomRight: Radius.circular(kDefaultOuterBorderRadius),
        );
      }
    }

    final border = Border(
      top: kDefaultBorder.copyWith(
        color: isHovered ? kActiveColor : decoColor,
      ),
      left: horizontalIndex == 2
          ? BorderSide.none
          : kDefaultBorder.copyWith(
              color:
                  (horizontalIndex == 0
                      ? isHovered
                      : (hoveredIndex == index - 1 || isHovered))
                  ? kActiveColor
                  : decoColor,
            ),
      right: horizontalIndex == 0
          ? BorderSide.none
          : kDefaultBorder.copyWith(
              color:
                  (horizontalIndex == 2
                      ? isHovered
                      : (hoveredIndex == index + 1 || isHovered))
                  ? kActiveColor
                  : decoColor,
            ),
      bottom: kDefaultBorder.copyWith(
        color: isHovered ? kActiveColor : decoColor,
      ),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 220,
      width: 350,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: border,
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 150),
            style: TextStyle(
              color: isHovered ? kActiveColor : Colors.white,
            ),
            child: Text(
              item,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child:
                  [
                        Assets.images.settings.laa,
                        Assets.images.settings.mods,
                        Assets.images.settings.credits,
                        Assets.images.settings.pc,
                        Assets.images.settings.logs,
                        Assets.images.settings.aau,
                      ]
                      .elementAt(index)
                      .svg(
                        color: isHovered ? kActiveColor : Colors.white,
                      ),
            ),
          ),
        ],
      ),
    );
  }
}
