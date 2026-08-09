import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as mt;
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/core/utils/transparent_image.dart';
import 'package:kyber_launcher/features/mods/extensions/frosty_collection_extension.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';

/// Removes the folder a deleted mod sat in, once nothing is left in it.
///
/// A Nexus download unpacks into its own folder, so deleting the mod used to
/// leave that folder behind for every mod that was not a collection. Guarding
/// with `isWithin` rather than comparing against the base path keeps this off
/// the mods folder itself: `join(base, dirname('mod.fbmod'))` is `base/.`,
/// which no string compare against `base` ever caught.
void pruneEmptyModFolder(String basePath, String filename) {
  final folder = Directory(join(basePath, dirname(filename)));
  if (!isWithin(basePath, folder.path)) return;
  if (folder.listSync().isEmpty) folder.deleteSync();
}

class DeleteModsDialog extends StatefulWidget {
  const DeleteModsDialog({required this.mods, super.key});

  final List<FrostyMod> mods;

  @override
  State<DeleteModsDialog> createState() => _DeleteModsDialogState();
}

class _DeleteModsDialogState extends State<DeleteModsDialog> {
  Map<String, List<ModCollectionMetaData>> affectedCollections = {};
  List<String> undeletableMods = [];

  @override
  void initState() {
    final collections = collectionBox.values;
    final frostyCollections = sl.get<ModService>().mods.where(
      (e) => e.isCollection,
    );
    for (final mod in widget.mods) {
      if (frostyCollections.any((e) => e.mods!.contains(mod.filename))) {
        undeletableMods.add(mod.filename);
        continue;
      }

      for (final collection in collections) {
        if (collection.mods.any(
          (element) => element.filename == mod.filename,
        )) {
          if (affectedCollections.containsKey(mod.filename)) {
            affectedCollections[mod.filename]!.add(collection);
          } else {
            affectedCollections[mod.filename] = [collection];
          }
        }
      }
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return KyberContentDialog(
      title: const Text('WARNING'),
      constraints: const BoxConstraints(maxWidth: 700, maxHeight: 500),
      actions: [
        KyberButton(
          text: 'DELETE',
          icon: const Icon(mt.Icons.delete_outline),
          onPressed: () {
            for (final mod in widget.mods) {
              if (undeletableMods.contains(mod.filename)) {
                continue;
              }

              for (final collection
                  in (affectedCollections[mod.filename] ?? [])) {
                collection as ModCollectionMetaData;
                collection.mods.removeWhere(
                  (element) => element.filename == mod.filename,
                );
                collectionBox.put(collection.localId, collection);
              }

              final basePath = ModService.getBasePath();
              try {
                if (mod.isCollection) {
                  for (final path in mod.getMods()!) {
                    try {
                      File(join(basePath, path)).deleteSync();
                    } catch (e, s) {
                      NotificationService.showNotification(
                        message: 'Failed to delete mod: $path',
                        severity: InfoBarSeverity.error,
                      );
                      Logger.root.severe('Failed to delete mod: $path', e, s);
                    }
                  }
                }

                File(join(basePath, mod.filename)).deleteSync();
                pruneEmptyModFolder(basePath, mod.filename);
              } catch (e, s) {
                NotificationService.showNotification(
                  message: 'Failed to delete mod: ${mod.filename}',
                  severity: InfoBarSeverity.error,
                );
                Logger.root.severe(
                  'Failed to delete mod: ${mod.filename}',
                  e,
                  s,
                );
              }
            }

            NotificationService.showNotification(
              message: 'Deletion complete!',
              severity: InfoBarSeverity.success,
            );
            sl.get<ModService>().refresh();
            if (mounted) {
              Navigator.of(context).pop(true);
            }
          },
        ),
        KyberButton(
          text: 'CANCEL',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      content: Column(
        children: [
          const Text(
            'DELETING THE FOLLOWING MOD(S) WILL REMOVE THEM FROM COLLECTIONS',
            style: TextStyle(
              fontFamily: FontFamily.battlefrontUI,
              fontSize: 16,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              const itemHeight = 50;
              final containerHeight =
                  (widget.mods.length > 3 ? 3 : widget.mods.length) *
                  itemHeight;

              return SizedBox(
                height: containerHeight.toDouble() + 70,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _CustomPainter(),
                      ),
                    ),
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withOpacity(.5),
                        margin: const EdgeInsets.symmetric(
                          vertical: 20,
                          horizontal: 13,
                        ),
                        alignment: Alignment.center,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(
                            12,
                          ).copyWith(top: 0, bottom: 0),
                          shrinkWrap: true,
                          itemBuilder: (context, index) {
                            final mod = widget.mods[index];
                            final isUndeletable = undeletableMods.contains(
                              mod.filename,
                            );
                            final isAffected = affectedCollections.containsKey(
                              mod.filename,
                            );
                            final collections =
                                affectedCollections[mod.filename] ?? [];
                            return Container(
                              height: 50,
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  Image.memory(
                                    mod.icon ?? kTransparentImage,
                                    width: 42,
                                    height: 42,
                                  ),
                                  const SizedBox(width: 10),
                                  DefaultTextStyle.merge(
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: kButtonBorder,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          mod.details.name,
                                          style: const TextStyle(
                                            fontSize: 20,
                                            color: Colors.white,
                                          ),
                                        ),
                                        if (isUndeletable) ...[
                                          const Text(
                                            'This mod is part of a Frosty Collection and cannot be deleted',
                                          ),
                                        ] else if (isAffected) ...[
                                          Text(
                                            collections
                                                .map((e) => e.title)
                                                .join(', '),
                                          ),
                                        ] else ...[
                                          const Text(
                                            'This mod is not part of any collection',
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                          itemCount: widget.mods.length,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CustomPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path_0 = Path();
    path_0.moveTo(0, 18);
    path_0.lineTo(size.width, 18);

    path_0.moveTo(0, size.height - 18);
    path_0.lineTo(size.width, size.height - 18);
    // dash border on the left side. 10 pixels long, 4 pixels apart
    for (var i = 0; i < size.height; i += 20) {
      path_0.moveTo(12, i.toDouble());
      path_0.lineTo(12, i.toDouble() + 10);
    }

    for (var i = 0; i < size.height; i += 20) {
      path_0.moveTo(size.width - 12, i.toDouble());
      path_0.lineTo(size.width - 12, i.toDouble() + 10);
    }

    final paint_0 = Paint()
      ..color = kGrayColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(path_0, paint_0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
