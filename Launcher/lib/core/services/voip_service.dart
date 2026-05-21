import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber/gen/Proto/kyber_interface.pb.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/core/services/vivox_sdk_service.dart';
import 'package:kyber_launcher/features/maxima/models/maxima_game_instance.dart';
import 'package:kyber_launcher/features/settings/widgets/voip_key_picker.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:logging/logging.dart';

class VoipService with ChangeNotifier {
  final _logger = Logger('voip_service');

  late bool _isEnabled;
  late bool _isPushToTalkEnabled;
  late int _pushToTalkKey;
  late List<VoipDevice> _inputDevices;
  late List<VoipDevice> _outputDevices;
  String _selectedInputDevice = '';
  String _selectedOutputDevice = '';

  bool get isEnabled => _isEnabled;

  List<VoipDevice> get inputDevices => _inputDevices;

  List<VoipDevice> get outputDevices => _outputDevices;

  String get selectedInputDevice => _selectedInputDevice;

  String get selectedOutputDevice => _selectedOutputDevice;

  bool get isPushToTalkEnabled => _isPushToTalkEnabled;

  int get pushToTalkKey => _pushToTalkKey;

  VoipService getInstance() {
    _logger.info('Initializing VoIP service');

    _inputDevices = [];
    _outputDevices = [];

    _selectedInputDevice = Preferences.general.selectedInputDevice;
    _selectedOutputDevice = Preferences.general.selectedOutputDevice;

    _pushToTalkKey = Preferences.general.pushToTalkKey;
    _isPushToTalkEnabled = Preferences.general.pushToTalk;

    _isEnabled = Preferences.general.voiceChatEnabled;

    return this;
  }

  void clearDevices() {
    _inputDevices = [];
    _outputDevices = [];
    notifyListeners();
  }

  Future<void> setPushToTalk({required bool enabled}) async {
    _isPushToTalkEnabled = enabled;
    Preferences.general.pushToTalk = enabled;
    notifyListeners();
    await setGameVoipSettings();
  }

  Future<void> setPushToTalkKey({required VoipKeyResponse key}) async {
    final keyId = sanitizePushToTalkKey(key.keyId);
    _pushToTalkKey = keyId;
    Preferences.general.pushToTalkKey = keyId;
    Preferences.general.pushToTalkKeyDisplay = key.display;
    notifyListeners();
    await setGameVoipSettings();
  }

  Future<void> setVoiceChat({required bool enabled}) async {
    _isEnabled = enabled;
    Preferences.general.voiceChatEnabled = enabled;
    notifyListeners();
    await setGameVoipSettings();
  }

  Future<void> setInputDevices(List<VoipDevice> devices) async {
    final defaultDevice = devices.firstWhere(
      (e) => e.id.contains('Default System Device'),
      orElse: () => devices.first,
    );
    devices.move(devices.indexOf(defaultDevice), 0);

    if (_selectedInputDevice.isEmpty ||
        !devices.any((e) => e.id == _selectedInputDevice)) {
      _logger.info('Device not found, setting default input device');
      await setInputDevice(defaultDevice.id);
    }

    _logger.info('Setting default input device to $_selectedInputDevice');
    _inputDevices = devices;
    notifyListeners();
  }

  Future<void> setOutputDevices(List<VoipDevice> devices) async {
    final defaultDevice = devices.firstWhere(
      (e) => e.id.contains('Default System Device'),
      orElse: () => devices.first,
    );
    devices.move(devices.indexOf(defaultDevice), 0);

    if (_selectedOutputDevice.isEmpty ||
        !devices.any((e) => e.id.contains(_selectedOutputDevice))) {
      await setOutputDevice(defaultDevice.id);
    }

    _logger.info('Setting default output device to $_selectedOutputDevice');
    _outputDevices = devices;
    notifyListeners();
  }

  Future<void> setGameVoipSettings() async {
    notifyListeners();

    if (!sl.isRegistered<MaximaGameInstance>()) {
      return;
    }

    _logger.info('Setting voip settings');
    final client = sl.get<MaximaGameInstance>();

    await client.clientService.client.setVoipSettings(
      SetVoipSettingsRequest(
        enabled: Preferences.general.voiceChatEnabled,
        inputVolume: (75 * Preferences.general.defaultInputVolume ~/ 100)
            .toDouble(),
        outputVolume: (75 * Preferences.general.defaultOutputVolume ~/ 100)
            .toDouble(),
        inputDeviceId: _selectedInputDevice.trim(),
        outputDeviceId: _selectedOutputDevice.trim(),
        pushToTalkEnabled: _isPushToTalkEnabled,
        pushToTalkKey: sanitizePushToTalkKey(_pushToTalkKey),
      ),
    );
    client.voipSettings = VoipSettings();
  }

  Future<void> setInputDevice(String id) async {
    notifyListeners();
    _selectedInputDevice = id;
    Preferences.general.selectedInputDevice = id;
  }

  Future<void> setOutputDevice(String id) async {
    notifyListeners();
    _selectedOutputDevice = id;
    Preferences.general.selectedOutputDevice = id;
  }
}
