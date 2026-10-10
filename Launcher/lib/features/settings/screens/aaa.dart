import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/gstreamer_check.dart';
import 'package:kyber_launcher/gen/assets.gen.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

const credits = <String, Map<String, List<String>>>{
  'KYBER TEAM': {
    'LEAD DEVELOPER': ['7reax'],
    'LEAD DESIGNER': ['dcat'],
    'DEVELOPERS': ['Magix', 'Nuuby'],
    'LEAD SUPPORT': ['Danarc504'],
    'LEAD SAFETY': ['alovelybell'],
    'TEAM MEMBERS': [
      'WesternUniverse',
      'Cor3o',
      'HonouredOne',
      'Gravehall',
      'jediexe',
    ],
    'COMMUNITY LIASON': ['ScorchRaserik'],
  },
  'MAXIMA TEAM': {
    'DEVELOPERS': ['Linguin', 'headassbtw', 'wannkunstbeikor', 'Gustash'],
  },
  'COMMUNITY CONTRIBUTORS': {
    'GAME LOGIC DEVELOPERS': ['TofuDriverTom', 'Mophead'],
    '3D ART': ['Hammie', 'Deggial Nox'],
    'VIDEO EDITOR': ['Spikul'],
    '2D ART': ['Larsson'],
  },
};

const acknowledgements = {
  'KYBER FOUNDER': ['battledash'],
  'FROSTY TOOLSUITE': ['GalaxyMan2015'],
  'BATTLEFRONT PLUS\nLEAD DEVELOPER': ['TheSpartanCV'],
};

List<String> bfpDevs = <String>[];

const specialThanks = [
  'TheSpartanCV',
  'Magix',
  'Mophead',
  'Dyvinia',
  'ywingpilot2',
  'Rollokster',
  'BattlefrontUpdates',
  'DMSchann',
  'BattlefrontFR',
  'AZZATRU',
  'Star Wars Uplink',
  'CinematicCaptures',
  'Yuki663',
  'Boxip',
  'Schlaubi',
  'SammyBoiii',
  'Ark3ros',
  'Charlemagne',
  'Coltonon',
  'Blakus',
  'Split Screen',
  'Escathon',
  'BoomStick',
  'Bombastic',
  'Kal´siem',
  'ablehnung',
  'ExN108',
  'Nuuby',
  'AdamRaichu',
  'IanZeArtist',
  'Rick Astley',
];

class Credits extends StatefulWidget {
  const Credits({super.key});

  @override
  State<Credits> createState() => _CreditsState();
}

class _CreditsState extends State<Credits> {
  PatronListResponse? patrons;
  final AudioPlayer? player = canPlayAudio ? AudioPlayer() : null;
  final listController = ListController();
  final scrollController = ScrollController();

  @override
  void initState() {
    final x = Future.value(
      sl.get<KyberGRPCService>().launcherClient.patronList(Empty()),
    );
    final contributorsFuture = _fetchBfpContributors();

    Future.delayed(const Duration(seconds: 1), () async {
      if (!mounted) return;

      final result = await Future.wait([x, contributorsFuture]);

      if (!mounted) return;

      await player?.play(
        AssetSource(Assets.sounds.kblCredits.split('/').skip(1).join('/')),
        volume: .25,
      );

      await player?.seek(const .new(milliseconds: 750));

      if (!mounted) return;

      bfpDevs = result.last as List<String>;

      setState(() => patrons = result.first as PatronListResponse);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;

      if (scrollController.position.pixels != 0) return;

      final scrollDuration = Duration(
        seconds: 8 + (patrons?.patronNames.length ?? 0) ~/ 4,
      );

      await scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: scrollDuration,
        curve: Curves.linear,
      );
    });
    super.initState();
  }

  @override
  void dispose() {
    scrollController.dispose();
    listController.dispose();
    player?.dispose();
    super.dispose();
  }

  Future<List<String>> _fetchBfpContributors() async {
    final resp = await Dio().get<String>(
      'https://battlefront.plus/lists/devs.json',
    );
    final parsed = jsonDecode(resp.data!) as List<dynamic>;
    return parsed.map((e) => e['name'] as String).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (patrons == null) {
      return const Center(child: ProgressRing());
    }

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 60),
            child: Assets.logos.kyberArmchair.svg(
              color: kWhiteColor,
              height: 140,
            ),
          ),
        ),
        SuperSliverList(
          delegate: SliverChildListDelegate(
            credits.entries.map((section) {
              return Column(
                children: [
                  Text(
                    section.key,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: .bold,
                      color: Colors.white,
                      fontFamily: FontFamily.battlefrontUI,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...section.value.entries.map((role) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 8),
                      child: Row(
                        mainAxisAlignment: .center,
                        crossAxisAlignment: .start,
                        children: [
                          Expanded(
                            child: Row(
                              mainAxisAlignment: .end,
                              children: [
                                SizedBox(
                                  width: 220,
                                  child: Text(
                                    role.key,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: .bold,
                                      fontFamily: FontFamily.battlefrontUI,
                                      height: 1.4,
                                    ),
                                    textAlign: .end,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: .start,
                              children: role.value
                                  .map(
                                    (name) => Text(
                                      name,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        color: Colors.white,
                                        fontFamily: FontFamily.battlefrontUI,
                                        height: 1.4,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 20),
                ],
              );
            }).toList(),
          ),
        ),
        const SliverToBoxAdapter(
          child: Center(
            child: Text(
              'ACKNOWLEDGEMENTS',
              style: TextStyle(
                fontSize: 22,
                fontWeight: .bold,
                color: Colors.white,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 50),
            child: Text(
              'WE WOULD LIKE TO SPECIALLY THANK THE FOLLOWING PEOPLE FOR WITHOUT WHICH NONE OF THIS WOULD BE POSSIBLE',
              textAlign: .center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: .bold,
                color: Colors.white,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverList(
          delegate: SliverChildListDelegate(
            acknowledgements.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Row(
                  mainAxisAlignment: .center,
                  crossAxisAlignment: .start,
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisAlignment: .end,
                        children: [
                          SizedBox(
                            width: 220,
                            child: Text(
                              entry.key,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: .bold,
                                fontFamily: FontFamily.battlefrontUI,
                                height: 1.4,
                              ),
                              textAlign: .end,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: .start,
                        children: entry.value
                            .map(
                              (name) => Text(
                                name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  color: Colors.white,
                                  fontFamily: FontFamily.battlefrontUI,
                                  height: 1.4,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        const SliverToBoxAdapter(
          child: Center(
            child: Text(
              'BATTLEFRONT PLUS\nCONTRIBUTORS',
              style: TextStyle(
                fontSize: 22,
                fontWeight: .bold,
                color: Colors.white,
                fontFamily: FontFamily.battlefrontUI,
              ),
              textAlign: .center,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            childAspectRatio: 4.5,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              return Text(
                bfpDevs[index],
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontFamily: FontFamily.battlefrontUI,
                ),
                textAlign: .center,
              );
            },
            childCount: bfpDevs.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        const SliverToBoxAdapter(
          child: Center(
            child: Text(
              'PATREON SUPPORTERS',
              style: TextStyle(
                fontSize: 22,
                fontWeight: .bold,
                color: Colors.white,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            childAspectRatio: 4.5,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final patronNames = patrons?.patronNames.toList() ?? [];
              return Text(
                patronNames[index],
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontFamily: FontFamily.battlefrontUI,
                ),
                textAlign: .center,
              );
            },
            childCount: patrons?.patronNames.length ?? 0,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        const SliverToBoxAdapter(
          child: Center(
            child: Text(
              'SPECIAL THANKS',
              style: TextStyle(
                fontSize: 22,
                fontWeight: .bold,
                color: Colors.white,
                fontFamily: FontFamily.battlefrontUI,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: Container(
            width: 700,
            alignment: Alignment.center,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 4,
              ),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: specialThanks.length,
              itemBuilder: (context, index) {
                return Text(
                  specialThanks[index],
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontFamily: FontFamily.battlefrontUI,
                  ),
                  textAlign: .center,
                );
              },
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}
