import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/ui.dart';

// Push-to-talk keycodes go over an int32 proto field. Non-printable keys have
// a LogicalKeyboardKey.keyId above this limit and cannot be used.
const int _kMaxInt32 = 0x7FFFFFFF;

class VoipKeyResponse {
  VoipKeyResponse({
    required this.display,
    required this.keyId,
  });

  final String display;
  final int keyId; // On Windows: VK code. Elsewhere: logicalKey.key
}

class CharKeyPicker extends StatefulWidget {
  const CharKeyPicker({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final VoipKeyResponse? value;
  final ValueChanged<VoipKeyResponse> onChanged;

  @override
  State<CharKeyPicker> createState() => _CharKeyPickerState();
}

class _CharKeyPickerState extends State<CharKeyPicker> {
  final FocusNode _focusNode = FocusNode();
  bool _recording = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _recording && mounted) _stopRecording();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _recording = true;
      _hint = null;
    });
    _focusNode.requestFocus();
  }

  void _stopRecording() {
    setState(() {
      _recording = false;
      _hint = null;
    });
    _focusNode.unfocus();
  }

  KeyEventResult _onKeyEvent(KeyEvent e) {
    if (!_recording) return KeyEventResult.ignored;
    if (e is! KeyDownEvent) return KeyEventResult.ignored;

    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _stopRecording();
      return KeyEventResult.handled;
    }

    if (e.logicalKey.keyId > _kMaxInt32) {
      setState(() => _hint = 'Key not supported, try another');
      return KeyEventResult.handled;
    }

    widget.onChanged(
      VoipKeyResponse(
        display: e.logicalKey.keyLabel.isNotEmpty
            ? e.logicalKey.keyLabel
            : 'Key ${e.logicalKey.keyId.toRadixString(16)}',
        keyId: e.logicalKey.keyId,
      ),
    );
    _stopRecording();
    return KeyEventResult.handled;
  }

  void _onRawKey(RawKeyEvent e) {
    if (!_recording) return;
    if (e is! RawKeyDownEvent) return;

    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _stopRecording();
      return;
    }

    if (Platform.isWindows && e.data is RawKeyEventDataWindows) {
      final vk = (e.data as RawKeyEventDataWindows).keyCode;
      widget.onChanged(
        VoipKeyResponse(
          display: e.logicalKey.keyLabel,
          keyId: vk,
        ),
      );
      _stopRecording();
      return;
    }

    if (e.logicalKey.keyId > _kMaxInt32) {
      setState(() => _hint = 'Key not supported, try another');
      return;
    }

    widget.onChanged(
      VoipKeyResponse(
        display: e.logicalKey.keyLabel,
        keyId: e.logicalKey.keyId,
      ),
    );
    _stopRecording();
  }

  @override
  Widget build(BuildContext context) {
    final display = _recording
        ? (_hint ?? 'Press a key…')
        : (widget.value != null ? widget.value!.display : 'Unassigned');

    final child = GestureDetector(
      onTap: _startRecording,
      child: HoverBuilder(
        builder: (context, hovered) => Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Expanded(
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 100),
                  style: TextStyle(
                    color: hovered || _recording ? kActiveColor : Colors.white,
                    shadows: hovered || _recording
                        ? [
                            Shadow(
                              color: kActiveColor.withOpacity(0.5),
                              blurRadius: 10,
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    display,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      fontFamily: FontFamily.battlefrontUI,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 15),
            Icon(
              FluentIcons.play_solid,
              size: 20,
              color: _recording
                  ? kWhiteBackgroundColor
                  : hovered
                  ? kActiveColor
                  : kWhiteColor,
            ),
          ],
        ),
      ),
    );

    if (Platform.isWindows) {
      // ik ik it's deprecated but it's needed to get VK codes
      return RawKeyboardListener(
        focusNode: _focusNode,
        onKey: _onRawKey,
        child: child,
      );
    }

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: child,
    );
  }
}
