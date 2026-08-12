import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kyber_launcher/main.dart';

//final box = box;

/// Largest value that fits a protobuf int32 field.
const int kMaxInt32 = 0x7FFFFFFF;

/// The push-to-talk keycode is sent over an int32 proto field. Flutter's
/// `LogicalKeyboardKey.keyId` for non-printable keys lives on a high plane and
/// exceeds int32, which would crash `SetVoipSettingsRequest`. Fall back to the
/// platform default ('T') when a stored value is out of range.
int sanitizePushToTalkKey(int value) {
  if (value < 0 || value > kMaxInt32) {
    return Platform.isWindows ? 0x54 : 116;
  }
  return value;
}

/// Write a plain file under ~/.config/kyber-linuxport. Both readers run before
/// the Dart VM exists (AppRun's shell, the GTK runner), and neither can read
/// the launcher's Hive store, hence the plain-file contract. `null` removes the
/// file. Best-effort; the Hive pref drives the UI regardless.
void _writeLinuxPref(String name, String? content) {
  if (!Platform.isLinux) return;
  final cfg = Platform.environment['XDG_CONFIG_HOME'];
  final home = Platform.environment['HOME'];
  final base = (cfg != null && cfg.isNotEmpty)
      ? cfg
      : (home != null && home.isNotEmpty ? '$home/.config' : null);
  if (base == null) return;
  final dir = Directory('$base/kyber-linuxport');
  final file = File('${dir.path}/$name');
  try {
    if (content != null) {
      dir.createSync(recursive: true);
      file.writeAsStringSync(content);
    } else if (file.existsSync()) {
      file.deleteSync();
    }
  } on FileSystemException {
    // best-effort; choice is still recorded in Hive
  }
}

/// Mirror the "Native Wayland" toggle for AppRun, which applies GDK_BACKEND
/// before GTK initialises. Removing the file leaves x11 as the default.
void writeWaylandBackendPref(bool wayland) =>
    _writeLinuxPref('backend', wayland ? 'wayland\n' : null);

/// Mirror the renderer choice for my_application.cc, which selects the engine
/// renderer before the view is created. Removing the file leaves the engine
/// default (Impeller). A KYBER_RENDERER env var still overrides both.
void writeRendererPref(bool skia) =>
    _writeLinuxPref('renderer', skia ? 'skia\n' : null);

class Preferences {
  static final general = General();
  static final debug = Debug();
  static final customization = Customization();
  static final hostServer = HostServer();
  static final windowData = WindowData();
  static final admin = Admin();
  static final nexusMods = NexusMods();
  static final patreon = Patreon();
}

class General {
  int? get lastSelectedModBrowserCategory =>
      box.get('lastSelectedModBrowserCategory') as int?;

  set lastSelectedModBrowserCategory(int? value) =>
      box.put('lastSelectedModBrowserCategory', value);

  bool get enabledPreloadMods =>
      box.get('enabledPreloadMods', defaultValue: true) as bool;

  set enabledPreloadMods(bool value) => box.put('enabledPreloadMods', value);

  bool get incrementalDownloadsEnabled =>
      box.get('incrementalDownloadsEnabled', defaultValue: true) as bool;

  set incrementalDownloadsEnabled(bool value) =>
      box.put('incrementalDownloadsEnabled', value);

  // Linux only. Mirrored to a plain file via writeWaylandBackendPref so AppRun
  // can apply GDK_BACKEND before GTK init. Applied on next launch (restart).
  bool get nativeWayland =>
      box.get('nativeWayland', defaultValue: false) as bool;

  set nativeWayland(bool value) => box.put('nativeWayland', value);

  // Linux only. Mirrored to a plain file via writeRendererPref so the GTK
  // runner can pick the renderer before the engine starts. Impeller is the
  // engine default and wins on dedicated GPUs; Skia wins on integrated or
  // software-rendered ones. Applied on next launch (restart).
  bool get skiaRenderer => box.get('skiaRenderer', defaultValue: false) as bool;

  set skiaRenderer(bool value) => box.put('skiaRenderer', value);

  String? get currentVersion => box.get('currentVersion') as String?;

  set currentVersion(String? value) => box.put('currentVersion', value);

  bool get developerMode =>
      box.get('developerMode', defaultValue: false) as bool;

  set developerMode(bool value) => box.put('developerMode', value);

  bool get setup => box.get('setup', defaultValue: false) as bool;

  set setup(bool value) => box.put('setup', value);

  String? get lastSelectedGameCollection =>
      box.get('lastSelectedGameCollection') as String?;

  set lastSelectedGameCollection(String? value) =>
      box.put('lastSelectedGameCollection', value);

  bool get gameWithoutMods =>
      box.get('gameWithoutMods', defaultValue: false) as bool;

  set gameWithoutMods(bool value) => box.put('gameWithoutMods', value);

  String get modsPath => box.get('modsPath', defaultValue: '') as String;

  set modsPath(String value) => box.put('modsPath', value);

  // Manual BF2 executable path (full path to starwarsbattlefrontii.exe).
  // Override for when Steam auto-detection misses the install (custom
  // Steam root, external library). Null = automatic detection.
  String? get customGamePath {
    final value = box.get('customGamePath') as String?;
    return (value != null && value.isNotEmpty) ? value : null;
  }

  set customGamePath(String? value) => box.put('customGamePath', value);

  String get proxy => box.get('proxy', defaultValue: '') as String;

  set proxy(String value) => box.put('proxy', value);

  bool get discordRPC => box.get('discordRPC', defaultValue: true) as bool;

  set discordRPC(bool value) => box.put('discordRPC', value);

  bool get ingameHotkeyEnabled =>
      box.get('ingameHotkeyEnabled', defaultValue: true) as bool;

  set ingameHotkeyEnabled(bool value) => box.put('ingameHotkeyEnabled', value);

  bool get sentryOptedOut =>
      box.get('sentryOptedOut', defaultValue: false) as bool;

  set sentryOptedOut(bool value) => box.put('sentryOptedOut', value);

  bool get acceptedRules =>
      box.get('acceptedRules1', defaultValue: false) as bool;

  set acceptedRules(bool value) => box.put('acceptedRules1', value);

  bool get openBetaDialogShown =>
      box.get('openBetaDialogShown1', defaultValue: false) as bool;

  set openBetaDialogShown(bool value) => box.put('openBetaDialogShown1', value);

  int get modBrowserPerPage =>
      box.get('modBrowserPerPage', defaultValue: 20) as int;

  set modBrowserPerPage(int value) => box.put('modBrowserPerPage', value);

  int get defaultInputVolume =>
      box.get('defaultInputVolume', defaultValue: 65) as int;

  set defaultInputVolume(int value) => box.put('defaultInputVolume', value);

  bool get voiceChatEnabled =>
      box.get('voiceChatEnabled', defaultValue: true) as bool;

  set voiceChatEnabled(bool enabled) => box.put('voiceChatEnabled', enabled);

  int get defaultOutputVolume =>
      box.get('defaultOutputVolume', defaultValue: 65) as int;

  set defaultOutputVolume(int value) => box.put('defaultOutputVolume', value);

  bool get pushToTalk => box.get('pushToTalk', defaultValue: true) as bool;

  set pushToTalk(bool value) => box.put('pushToTalk', value);

  String get pushToTalkKeyDisplay =>
      box.get('pushToTalkKeybindDisplay', defaultValue: 'T') as String;

  set pushToTalkKeyDisplay(String value) =>
      box.put('pushToTalkKeybindDisplay', value);

  // 116 -> T
  int get pushToTalkKey => sanitizePushToTalkKey(
    box.get(
          'pushToTalkKeybind',
          defaultValue: Platform.isWindows ? 0x54 : 116,
        )
        as int,
  );

  set pushToTalkKey(int value) => box.put('pushToTalkKeybind', value);

  String get selectedInputDevice =>
      box.get('inputDevice', defaultValue: '') as String;

  set selectedInputDevice(String value) => box.put('inputDevice', value);

  String get selectedOutputDevice =>
      box.get('outputDevice', defaultValue: '') as String;

  set selectedOutputDevice(String value) => box.put('outputDevice', value);

  String? get selectedCosmeticCollection =>
      box.get('selectedCosmeticCollection') as String?;

  set selectedCosmeticCollection(String? value) =>
      box.put('selectedCosmeticCollection', value);

  bool get useCosmetics => box.get('useCosmetics', defaultValue: true) as bool;

  set useCosmetics(bool value) => box.put('useCosmetics', value);

  String get locale =>
      box.get('locale', defaultValue: Platform.localeName.split('_').first)
          as String;

  set locale(String value) => box.put('locale', value);
}

class Patreon {
  String? get patreonId => box.get('patreon_id') as String?;

  set patreonId(String? value) => box.put('patreon_id', value);

  String? get membershipId => box.get('membership_id') as String?;

  set membershipId(String? value) => box.put('membership_id', value);
}

class NexusMods {
  bool get isLoggedIn =>
      box.get('nexusmods_login', defaultValue: false) as bool;

  set isLoggedIn(bool value) => box.put('nexusmods_login', value);

  String? get apiToken => box.get('nexusmods_api_token') as String?;

  set apiToken(String? value) => box.put('nexusmods_api_token', value);

  String? get refreshToken => box.get('nexusmods_refresh_token') as String?;

  set refreshToken(String? value) => box.put('nexusmods_refresh_token', value);
}

class Debug {
  bool get frbDebugLogs => box.get('frbDebugLogs', defaultValue: false) as bool;

  set frbDebugLogs(bool value) => box.put('frbDebugLogs', value);

  bool get grpcDebugLogs =>
      box.get('grpcDebugLogs', defaultValue: false) as bool;

  set grpcDebugLogs(bool value) => box.put('grpcDebugLogs', value);

  bool get moduleDebugLogs =>
      box.get('moduleDebugLogs', defaultValue: false) as bool;

  set moduleDebugLogs(bool value) => box.put('moduleDebugLogs', value);
}

class Customization {
  Color get activeColor =>
      Color(box.get('activeColor', defaultValue: 0xFFfab20a) as int);

  set activeColor(Color value) => box.put('activeColor', value.value);

  String? get backgroundImage => box.get('backgroundImage') as String?;

  set backgroundImage(String? value) => box.put('backgroundImage', value);

  bool get customBackground =>
      box.get('customBackground', defaultValue: false) as bool;

  set customBackground(bool value) => box.put('customBackground', value);

  bool get rememberWindowPosition =>
      box.get('rememberWindowPosition', defaultValue: true) as bool;

  set rememberWindowPosition(bool value) =>
      box.put('rememberWindowPosition', value);
}

class HostServer {
  String get name => box.get('hostName', defaultValue: '') as String;

  set name(String value) => box.put('hostName', value);

  String get description =>
      (box.get('hostDescription', defaultValue: '') as String?) ?? '';

  set description(String value) => box.put('hostDescription', value);

  String get password =>
      (box.get('hostPassword', defaultValue: '') as String?) ?? '';

  set password(String value) => box.put('hostPassword', value);

  int get maxPlayers =>
      box.get('hostMaxPlayers', defaultValue: 40) as int? ?? 40;

  set maxPlayers(int value) => box.put('hostMaxPlayers', value);

  int get maxSpectators =>
      box.get('hostMaxSpectators', defaultValue: 0) as int? ?? 0;

  set maxSpectators(int value) => box.put('hostMaxSpectators', value);

  String? get collection => box.get('hostingCollection') as String?;

  set collection(String? value) => box.put('hostingCollection', value);
}

class WindowData {
  double? get windowWidth => box.get('windowWidth') as double?;

  set windowWidth(double? value) => box.put('windowWidth', value);

  double? get windowHeight => box.get('windowHeight') as double?;

  set windowHeight(double? value) => box.put('windowHeight', value);

  double? get windowX => box.get('windowX') as double?;

  set windowX(double? value) => box.put('windowX', value);

  double? get windowY => box.get('windowY') as double?;

  set windowY(double? value) => box.put('windowY', value);

  bool get windowMaximized =>
      box.get('windowMaximized', defaultValue: false) as bool;

  set windowMaximized(bool value) => box.put('windowMaximized', value);
}

class Admin {
  bool get dummyServer => box.get('dummyServer', defaultValue: false) as bool;

  set dummyServer(bool value) => box.put('dummyServer', value);

  bool get removeBackground =>
      box.get('removeBackground', defaultValue: false) as bool;

  set removeBackground(bool value) => box.put('removeBackground', value);

  String get apiEnv => box.get('apiEnv', defaultValue: 'prod') as String;

  set apiEnv(String value) => box.put('apiEnv', value);
}
