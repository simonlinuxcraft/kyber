import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/features/maxima/dialogs/custom_game_path_dialog.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';

const _kGameName = 'STAR WARS™ Battlefront™ II';

class MaximaGameLocatorDialog extends StatefulWidget {
  const MaximaGameLocatorDialog({super.key});

  @override
  State<MaximaGameLocatorDialog> createState() =>
      _MaximaGameLocatorDialogState();
}

class _MaximaGameLocatorDialogState extends State<MaximaGameLocatorDialog> {
  @override
  Widget build(BuildContext context) {
    return KyberContentDialog(
      title: const Text('GAME NOT FOUND'),
      constraints: const BoxConstraints(
        maxWidth: 600,
        maxHeight: 400,
      ),
      content: const DefaultTextStyle(
        style: TextStyle(
          color: kWhiteColor,
          fontFamily: FontFamily.battlefrontUI,
          fontSize: 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$_kGameName could not be located.'),
            SizedBox(height: 20),
            Text(
              'If you have the game from Steam, please launch the game at least once without Kyber.',
            ),
            SizedBox(height: 20),
            Text(
              'If the game is installed in a custom location, you can '
              'set the game executable manually.',
            ),
          ],
        ),
      ),
      actions: [
        KyberButton(
          onPressed: () {
            Navigator.of(context).pop();
            showKyberDialog(
              context: navigatorKey.currentContext!,
              builder: (_) => const CustomGamePathDialog(),
            );
          },
          text: 'SET GAME FOLDER',
        ),
        KyberButton(
          onPressed: () => Navigator.of(context).pop(),
          text: 'CLOSE',
        ),
      ],
    );
  }
}
