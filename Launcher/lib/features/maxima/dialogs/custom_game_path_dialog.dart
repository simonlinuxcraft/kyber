import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:kyber_launcher/shared/ui/elements/kyber_input.dart';

// Manual override for the BF2 game path. Reached from the Mod
// Configuration settings page and from the "Game not found" dialog.
// Only needed when Steam auto-detection misses the install. Maxima
// expects the full path to the game executable, not the folder.
class CustomGamePathDialog extends StatefulWidget {
  const CustomGamePathDialog({super.key});

  @override
  State<CustomGamePathDialog> createState() => _CustomGamePathDialogState();
}

class _CustomGamePathDialogState extends State<CustomGamePathDialog> {
  late TextEditingController controller;

  @override
  void initState() {
    controller = TextEditingController(
      text: Preferences.general.customGamePath ?? '',
    );
    super.initState();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KyberContentDialog(
      constraints: const BoxConstraints(maxWidth: 700, maxHeight: 460),
      title: Text('Custom Game Path'.toUpperCase()),
      content: Column(
        children: [
          Center(
            child: Text(
              'Set this only if the launcher cannot find Star Wars '
              'Battlefront II on its own. Select the game executable '
              'starwarsbattlefrontii.exe. Leave it empty to keep using '
              'automatic detection.',
              style: FluentTheme.of(
                context,
              ).typography.body?.copyWith(color: kWhiteColor),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: KyberInput(
                  controller: controller,
                  disabled: true,
                  placeholder: 'Automatic detection',
                ),
              ),
              const SizedBox(width: 20),
              KyberButton(
                onPressed: () async {
                  final file = await openFile(
                    acceptedTypeGroups: [
                      const XTypeGroup(
                        label: 'Game executable',
                        extensions: ['exe'],
                      ),
                    ],
                  );
                  if (file == null) {
                    return;
                  }

                  setState(() => controller.text = file.path);
                },
                text: 'Browse',
              ),
            ],
          ),
        ],
      ),
      actions: [
        KyberButton(
          onPressed: () => Navigator.of(context).pop(),
          text: 'Cancel',
        ),
        KyberButton(
          text: 'Clear',
          onPressed: () {
            Preferences.general.customGamePath = null;
            Navigator.of(context).pop();
          },
        ),
        KyberButton(
          text: 'Save',
          onPressed: () {
            final text = controller.text.trim();
            Preferences.general.customGamePath = text.isEmpty ? null : text;
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}
