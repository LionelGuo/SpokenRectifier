/// The shell UI: a frameless always-on-top window that morphs between the
/// floating orb (idle / recording), the recording panel (live transcript),
/// the rectifying card (streaming chunks), and the preview card
/// (confirm on Enter / cancel on Esc).
///
/// Pure widgets on top of [SpeechController] — no platform channels here,
/// so everything is widget-testable.

library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputType;

import 'app_state.dart';
import 'src/rust/api.dart' show BridgeSessionState;

const hotkeyHint = 'Ctrl+Alt+V 开始 / 结束';

class SpokenRectifierApp extends StatelessWidget {
  const SpokenRectifierApp({super.key, required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpokenRectifier',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true)
          .copyWith(scaffoldBackgroundColor: Colors.transparent),
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _PhaseView(controller: controller),
      ),
    );
  }
}

/// Picks the surface for the current phase; hidden orb + idle = nothing.
class _PhaseView extends StatelessWidget {
  const _PhaseView({required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    Widget current;
    switch (controller.phase) {
      case BridgeSessionState.idle:
      case BridgeSessionState.inserted:
      case BridgeSessionState.cancelled:
        current = !controller.orbVisible
            ? const SizedBox.shrink()
            : IdleOrb(controller: controller);
      case BridgeSessionState.recording:
        current = controller.panelExpanded
            ? RecordingPanel(controller: controller)
            : RecordingOrb(controller: controller);
      case BridgeSessionState.rectifying:
        current = RectifyingCard(controller: controller);
      case BridgeSessionState.preview:
        current = PreviewCard(controller: controller);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: current,
    );
  }
}

class IdleOrb extends StatelessWidget {
  const IdleOrb({super.key, required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.lastInserted != null)
              _FlashBanner(
                key: const Key('inserted-flash'),
                icon: Icons.check_circle,
                color: Colors.greenAccent,
                label: '已插入:${controller.lastInserted}',
              ),
            if (controller.lastError != null)
              _FlashBanner(
                key: const Key('error-flash'),
                icon: Icons.error_outline,
                color: Colors.redAccent,
                label: controller.lastError!,
              ),
            _OrbShell(
              color: const Color(0xFF2E3A59),
              onTap: controller.startSession,
              child: const Icon(Icons.mic_none, color: Colors.white, size: 34),
            ),
          ],
        ),
      ),
    );
  }
}

class RecordingOrb extends StatefulWidget {
  const RecordingOrb({super.key, required this.controller});

  final SpeechController controller;

  @override
  State<RecordingOrb> createState() => _RecordingOrbState();
}

class _RecordingOrbState extends State<RecordingOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: ScaleTransition(
          scale: Tween(
            begin: 0.94,
            end: 1.14,
          ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
          child: _OrbShell(
            color: const Color(0xFFB3261E),
            onTap: widget.controller.togglePanel,
            child: const Icon(Icons.mic, color: Colors.white, size: 34),
          ),
        ),
      ),
    );
  }
}

/// Shared orb visuals with tap feedback.
class _OrbShell extends StatelessWidget {
  const _OrbShell({
    required this.color,
    required this.onTap,
    required this.child,
  });

  final Color color;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color.withValues(alpha: 0.95), color],
              radius: 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.55),
                blurRadius: 22,
                spreadRadius: 2,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

class RecordingPanel extends StatelessWidget {
  const RecordingPanel({super.key, required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    return _Card(
      width: 460,
      height: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _RecordingDot(),
              const SizedBox(width: 8),
              Text('录音中 · 段落 ${controller.paragraphMarks}'),
              const Spacer(),
              IconButton(
                tooltip: '收起',
                onPressed: controller.togglePanel,
                icon: const Icon(Icons.unfold_more),
              ),
            ],
          ),
          const Divider(height: 12),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                controller.liveText.isEmpty ? '…' : controller.liveText,
                key: const Key('live-transcript'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('panel-cancel'),
                onPressed: controller.cancelSession,
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('panel-stop'),
                onPressed: controller.stopSession,
                child: const Text('结束并修正'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class RectifyingCard extends StatelessWidget {
  const RectifyingCard({super.key, required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    return _Card(
      width: 460,
      height: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text('正在修正 ${controller.previewText.length} 字'),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                controller.previewText,
                key: const Key('rectifying-text'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PreviewCard extends StatefulWidget {
  const PreviewCard({super.key, required this.controller});

  final SpeechController controller;

  @override
  State<PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<PreviewCard> {
  late final TextEditingController _text;
  late final FocusNode _fieldFocus;
  late final FocusNode _cardFocus;
  Timer? _editDebounce;
  String _lastSynced = '';

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.controller.previewText);
    _fieldFocus = FocusNode(debugLabel: 'preview-field');
    _cardFocus = FocusNode(debugLabel: 'preview-card');
    _lastSynced = widget.controller.previewText;
    widget.controller.addListener(_syncFromStream);
  }

  /// Keep the field in step with streamed reroll output, without stomping
  /// the user's cursor while they edit.
  void _syncFromStream() {
    final streamed = widget.controller.previewText;
    if (streamed != _lastSynced && streamed != _text.text) {
      _text.value = TextEditingValue(
        text: streamed,
        selection: TextSelection.collapsed(offset: streamed.length),
      );
    }
    _lastSynced = streamed;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromStream);
    _editDebounce?.cancel();
    _fieldFocus.dispose();
    _cardFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onEdited(String value) {
    // Bare Enter in an unfocused-IME field arrives as an appended newline;
    // treat it as confirm (chat-input style). While the IME is composing,
    // Enter commits the composition instead — no newline is appended, so
    // it safely falls through to the composing commit.
    final composing = _text.value.composing;
    if (value.endsWith('\n') && composing == TextRange.empty) {
      final stripped = value.substring(0, value.length - 1);
      _text.value = TextEditingValue(
        text: stripped,
        selection: TextSelection.collapsed(offset: stripped.length),
      );
      _lastSynced = stripped;
      widget.controller.confirmInsert();
      return;
    }
    _lastSynced = value;
    _editDebounce?.cancel();
    _editDebounce = Timer(const Duration(milliseconds: 350), () {
      widget.controller.updatePreviewText(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        // Enter confirms while the editable field does not hold focus
        // (the field keeps Enter for itself while editing, so the IME's
        // Enter-to-commit keeps working; the hotkey also confirms).
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            widget.controller.confirmInsert(),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            widget.controller.cancelSession(),
      },
      child: Focus(
        focusNode: _cardFocus,
        autofocus: true,
        child: _Card(
          width: 560,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.rate_review_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Text('预览确认'),
                  const Spacer(),
                  Text(
                    hintKeyLabels,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
              const Divider(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white24),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: EditableText(
                    key: const Key('preview-field'),
                    controller: _text,
                    focusNode: _fieldFocus,
                    backgroundCursorColor: Colors.white38,
                    keyboardType: TextInputType.multiline,
                    maxLines: null,
                    expands: true,
                    forceLine: false,
                    onChanged: _onEdited,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: Colors.white,
                    ),
                    cursorColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    key: const Key('preview-reroll'),
                    onPressed: widget.controller.reroll,
                    child: const Text('重新生成'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('preview-cancel'),
                    onPressed: widget.controller.cancelSession,
                    child: const Text('取消 (Esc)'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('preview-confirm'),
                    onPressed: widget.controller.confirmInsert,
                    child: const Text('确认插入 (Enter)'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const hintKeyLabels = 'Enter 确认 · Esc 取消';

class _Card extends StatelessWidget {
  const _Card({required this.width, required this.height, required this.child});

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xEE1B2436),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 30,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Padding(padding: const EdgeInsets.all(14), child: child),
        ),
      ),
    );
  }
}

class _RecordingDot extends StatefulWidget {
  const _RecordingDot();

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _blink,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFFE57373),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _FlashBanner extends StatelessWidget {
  const _FlashBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      constraints: const BoxConstraints(maxWidth: 380),
      decoration: BoxDecoration(
        color: const Color(0xEE1B2436),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
