import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/features/mods/helper/mod_helper.dart';
import 'package:kyber_launcher/features/settings/dialogs/chromium_download_dialog.dart';
import 'package:collection/collection.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/download_manager/models/download_link_type.dart' as dl;
import 'package:kyber_launcher/features/download_manager/models/download_request.dart';
import 'package:kyber_launcher/features/download_manager/services/download_orchestrator.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/features/nexusmods/services/nexusmods_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/elements/kyber_event_container.dart';
import 'package:kyber_launcher/shared/ui/elements/list/kyber_list.dart';

class CollectionImport extends StatefulWidget {
  const CollectionImport({required this.collectionPath, super.key});

  final String collectionPath;

  @override
  State<CollectionImport> createState() => _CollectionImportState();
}

class _CollectionImportState extends State<CollectionImport> {
  ModCollectionMetaData? _metaData;
  bool _importing = false;

  int get _missingCount =>
      _metaData?.mods
          .where((m) => !ModHelper.isInstalled(m.name, m.version))
          .length ??
      0;

  @override
  void initState() {
    if (!File(widget.collectionPath).existsSync()) {
      return;
    }

    ModCollection.readCollection(File(widget.collectionPath)).then((value) {
      setState(() => _metaData = value);
    });
    super.initState();
  }

  /// Adds the collection to the launcher, whether or not every mod is there.
  ///
  /// Installed mods are pointed at their local file so they work right away.
  /// Missing ones stay in the collection with their download link and show up
  /// marked, the same way they do on this screen. Downloads are only queued
  /// for premium accounts, because that is the only case where Nexus hands
  /// the file over without the download being confirmed on the site.
  Future<void> _import() async {
    final collection = _metaData;
    if (collection == null) return;

    setState(() => _importing = true);
    final premium = sl.get<NexusModsService>().nexusUser?.isPremium ?? false;
    var queued = 0;
    var missing = 0;

    try {
      for (var i = 0; i < collection.mods.length; i++) {
        final mod = collection.mods[i];

        if (ModHelper.isInstalled(mod.name, mod.version)) {
          final localMod = sl
              .get<ModService>()
              .mods
              .where(
                (m) =>
                    m.details.name == mod.name &&
                    m.details.version == mod.version,
              )
              .firstOrNull;
          if (localMod != null) {
            collection.mods[i] = mod.copyWith(filename: localMod.filename);
            continue;
          }
        }

        // Keeps name, version and link, so the entry stays in the collection
        // and is shown as missing until the mod turns up.
        collection.mods[i] = CollectionMod(
          name: mod.name,
          version: mod.version,
          link: mod.link,
        );
        missing++;

        if (!premium || mod.link.isEmpty) continue;
        try {
          await sl.get<DownloadOrchestrator>().enqueueDownload(
            DownloadRequest(
              link: mod.link,
              displayName: mod.name,
              linkType: mod.link.startsWith('https://www.nexusmods')
                  ? dl.DownloadLinkType.nexus
                  : dl.DownloadLinkType.direct,
            ),
          );
          queued++;
        } on Object catch (e) {
          Logger.root.warning('Could not queue ${mod.name}', e);
        }
      }

      final id = const Uuid().v4();
      await collectionBox.put(id, collection.copyWith(localId: id));

      final String message;
      if (missing == 0) {
        message = 'Added ${collection.title}';
      } else if (queued > 0) {
        message = 'Added ${collection.title}, downloading $queued mods';
      } else {
        message =
            'Added ${collection.title}, $missing mods are still missing '
            'and stay marked in the collection';
      }

      NotificationService.showNotification(
        message: message,
        severity: missing == 0 || queued > 0
            ? InfoBarSeverity.success
            : InfoBarSeverity.warning,
      );
      router.pop();
    } on Object catch (e) {
      NotificationService.showNotification(
        message: 'Could not add the collection: $e',
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_metaData == null) {
      return const Center(child: ProgressRing());
    }

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              const Expanded(child: Placeholder()),
              const SizedBox(width: 20),
              SizedBox(
                width: 400,
                child: KyberEventContainer(
                  expand: true,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Collection Mods'.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 15,
                                fontFamily: FontFamily.battlefrontUI,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 7.5),
                      Expanded(
                        child: KyberList(
                          itemPadding: EdgeInsets.zero,
                          activeIndex: -1,
                          physics: const ScrollPhysics(),
                          itemBuilder: (context, index) {
                            final mod = _metaData!.mods.elementAt(index);
                            final isInstalled = ModHelper.isInstalled(
                              mod.name,
                              mod.version,
                            );
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 16,
                                horizontal: 13,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isInstalled
                                        ? FluentIcons.check_mark
                                        : FluentIcons.error_badge,
                                    color: isInstalled
                                        ? Colors.green
                                        : Colors.red,
                                    size: 19,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: AutoSizeText(
                                      '${mod.name} (${mod.version})',
                                      style: const TextStyle(
                                        fontSize: 18,
                                        height: 1,
                                        color: kWhiteColor,
                                        fontFamily: FontFamily.battlefrontUI,
                                      ),
                                      maxLines: 1,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    formatBytes(200, 2),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: kWhiteColor1,
                                      fontFamily: FontFamily.battlefrontUI,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                          itemCount: _metaData!.mods.length,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            KyberButton(
              text: 'CANCEL',
              onPressed: router.pop,
            ),
            KyberButton(
              text: _missingCount == 0
                  ? 'ADD COLLECTION'
                  : (sl.get<NexusModsService>().nexusUser?.isPremium ?? false)
                        ? 'DOWNLOAD COLLECTION MODS'
                        : 'ADD COLLECTION ANYWAY',
              onPressed: _importing ? null : _import,
            ),
          ],
        ),
      ],
    );
  }
}
