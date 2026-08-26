/// The shell UI: a frameless always-on-top window that morphs between the
/// floating orb (idle / recording), the recording panel (live transcript),
/// the rectifying card (streaming chunks), and the preview card
/// (confirm on Enter / cancel on Esc).
///
/// While recording, the orb and panel reflect the VAD speaking state: lit
/// red with a live mic while talking, muted with a slashed mic in pauses.
///
/// Pure widgets on top of [SpeechController] — no platform channels here,
/// so everything is widget-testable.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey, TextInputType;

import 'app_state.dart';
import 'src/rust/api.dart'
    show BridgeHistoryEntry, BridgeSessionState;

const hotkeyHint = 'Ctrl+Alt+V 开始 / 结束';

/// Window footprints per phase. Rectifying shares the preview footprint:
/// reroll cycles preview <-> rectifying, and shrinking the window under the
/// still-fading outgoing preview card would clip it mid-transition.
const orbWindowSize = Size(100, 116);
const recordingPanelWindowSize = Size(480, 384);
const previewWindowSize = Size(580, 440);
const historyWindowSize = Size(480, 460);

/// The window size for a phase; `panelExpanded` only matters while
/// recording (collapsed orb vs expanded transcript panel), and
/// `historyOpen` only while idle (orb vs history panel).
Size windowSizeFor(
  BridgeSessionState phase, {
  required bool panelExpanded,
  bool historyOpen = false,
}) {
  return switch (phase) {
    BridgeSessionState.idle ||
    BridgeSessionState.inserted ||
    BridgeSessionState.cancelled =>
      historyOpen ? historyWindowSize : orbWindowSize,
    BridgeSessionState.recording =>
      panelExpanded ? recordingPanelWindowSize : orbWindowSize,
    BridgeSessionState.rectifying || BridgeSessionState.preview =>
      previewWindowSize,
  };
}

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
        if (controller.historyOpen) {
          current = HistoryPanel(controller: controller);
        } else {
          current = !controller.orbVisible
              ? const SizedBox.shrink()
              : IdleOrb(controller: controller);
        }
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
            _Banners(controller: controller),
            _OrbShell(
              color: const Color(0xFF2E3A59),
              onTap: controller.startSession,
              onLongPress: controller.toggleHistory,
              child: const Icon(Icons.mic_none, color: Colors.white, size: 34),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inserted / error flashes above whatever idle surface is showing
/// (orb or history panel).
class _Banners extends StatelessWidget {
  const _Banners({required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
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
      ],
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
    final speaking = widget.controller.speaking;
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: ScaleTransition(
          scale: Tween(
            begin: speaking ? 0.94 : 0.97,
            end: speaking ? 1.14 : 1.05,
          ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
          child: _OrbShell(
            color: speaking ? const Color(0xFFB3261E) : const Color(0xFF3A4A63),
            onTap: widget.controller.togglePanel,
            child: Icon(
              speaking ? Icons.mic : Icons.mic_off,
              key: Key(speaking ? 'orb-speaking' : 'orb-silent'),
              color: Colors.white,
              size: 34,
            ),
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
    this.onLongPress,
  });

  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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

/// The scenario picker (场景): pick the register the next rectify
/// targets, rerolls included — 默认 (the built-in register) or one of the
/// user's library entries. The tray's 风格 submenu mirrors it for idle
/// switching.
class ScenarioPicker extends StatelessWidget {
  const ScenarioPicker({super.key, required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      // The card is a bare Container: the dropdown needs a Material
      // ancestor for its popup (and gains a sane default text style).
      child: Material(
        color: Colors.transparent,
        child: DropdownButton<String?>(
          key: const Key('scenario-picker'),
          isExpanded: true,
          value: controller.selectedScenario,
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text('默认', key: const Key('scenario-item-default')),
            ),
            for (final scenario in controller.scenarios)
              DropdownMenuItem<String?>(
                value: scenario.name,
                child: Text(
                  scenario.name,
                  key: Key('scenario-item-${scenario.name}'),
                ),
              ),
          ],
          onChanged: controller.selectScenario,
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
      height: 364,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _RecordingDot(),
              const SizedBox(width: 8),
              Text(
                '录音中 · ${controller.speaking ? '说话中' : '静音'} · '
                '段落 ${controller.paragraphMarks}',
                // Explicit style: the card is a bare Container with no
                // Material ancestor, so an unstyled Text falls back to the
                // debug error style (huge, red, underlined).
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
              const Spacer(),
              IconButton(
                tooltip: '收起',
                onPressed: controller.togglePanel,
                icon: const Icon(Icons.unfold_more),
              ),
            ],
          ),
          const Divider(height: 12),
          // An empty library hides the whole row: nothing to pick, no
          // noise (ADR-0004) — the default register needs no switcher.
          if (controller.scenarios.isNotEmpty) ...[
            ScenarioPicker(controller: controller),
            const SizedBox(height: 8),
          ],
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
              Text(
                '正在修正 ${controller.previewText.length} 字',
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
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

  /// Whether the raw transcript shows under the editable rectified text
  /// (原始转写对照: the session's raw speech next to its rectification).
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    // The field renders the controller's previewText; from here on the
    // only writer is the user (every change goes up to the controller,
    // which owns the debounce). While the phase moves on, the card may
    // still be fading out with its last text — nothing syncs it anymore.
    _text = TextEditingController(text: widget.controller.previewText);
    _fieldFocus = FocusNode(debugLabel: 'preview-field');
    _cardFocus = FocusNode(debugLabel: 'preview-card');
  }

  @override
  void dispose() {
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
      widget.controller.editPreviewText(stripped);
      widget.controller.confirmWhatYouSee();
      return;
    }
    widget.controller.editPreviewText(value);
  }

  /// The editable rectified text.
  Widget get _editor => Container(
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
      );

  /// The session's raw transcript, read-only, under the rectified text.
  Widget get _rawPanel => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white12),
          color: Colors.black.withValues(alpha: 0.25),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '原始转写',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  widget.controller.liveText,
                  key: const Key('raw-transcript'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        // Enter confirms while the editable field does not hold focus
        // (the field keeps Enter for itself while editing, so the IME's
        // Enter-to-commit keeps working; the hotkey also confirms). Every
        // confirm path shares the controller's confirm-what-you-see entry.
        const SingleActivator(
          LogicalKeyboardKey.enter,
        ): widget.controller.confirmWhatYouSee,
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
                  const Text(
                    '预览确认',
                    style: TextStyle(fontSize: 14, color: Colors.white),
                  ),
                  IconButton(
                    key: const Key('preview-raw-toggle'),
                    tooltip: '对照原文',
                    visualDensity: VisualDensity.compact,
                    isSelected: _showRaw,
                    onPressed: () => setState(() => _showRaw = !_showRaw),
                    icon: const Icon(Icons.compare_arrows, size: 18),
                  ),
                  const Spacer(),
                  Text(
                    hintKeyLabels,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
              const Divider(height: 12),
              Expanded(
                child: _showRaw
                    ? Column(
                        children: [
                          Expanded(child: _editor),
                          const Divider(height: 14),
                          SizedBox(height: 130, child: _rawPanel),
                        ],
                      )
                    : _editor,
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
                    onPressed: widget.controller.confirmWhatYouSee,
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

/// The history panel: recent sessions with the raw transcript
/// retrievable — copy it to the clipboard, or re-run it through
/// rectification. One click clears everything (same as the tray item).
///
/// Pure widget over [SpeechController]: it renders `controller.history`
/// and hands actions back; the fake gateway covers it in widget tests.
class HistoryPanel extends StatelessWidget {
  const HistoryPanel({super.key, required this.controller});

  final SpeechController controller;

  static String _timeLabel(BigInt createdAtMs) {
    final time = DateTime.fromMillisecondsSinceEpoch(createdAtMs.toInt());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Banners(controller: controller),
            _Card(
              width: 460,
              height: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.history, size: 18),
                      const SizedBox(width: 8),
                      const Text('历史记录'),
                      const Spacer(),
                      TextButton(
                        key: const Key('history-clear'),
                        onPressed: controller.clearHistory,
                        child: const Text('清空'),
                      ),
                      IconButton(
                        key: const Key('history-close'),
                        tooltip: '收起',
                        onPressed: controller.toggleHistory,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                  const Divider(height: 12),
                  Expanded(
                    child: controller.history.isEmpty
                        ? const Center(
                            key: Key('history-empty'),
                            child: Text(
                              '暂无历史记录',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            key: const Key('history-list'),
                            itemCount: controller.history.length,
                            itemBuilder: (context, index) => _HistoryEntryTile(
                              controller: controller,
                              entry: controller.history[index],
                              timeLabel: _timeLabel(
                                controller.history[index].createdAtMs,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One stored session: the raw transcript (retrievable) over its
/// rectified text (context, muted).
class _HistoryEntryTile extends StatelessWidget {
  const _HistoryEntryTile({
    required this.controller,
    required this.entry,
    required this.timeLabel,
  });

  final SpeechController controller;
  final BridgeHistoryEntry entry;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                timeLabel,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const Spacer(),
              TextButton(
                key: Key('history-copy-${entry.id}'),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: entry.rawTranscript)),
                child: const Text('复制原文'),
              ),
              TextButton(
                key: Key('history-rectify-${entry.id}'),
                onPressed: () => controller.rectifyFromHistory(entry.rawTranscript),
                child: const Text('重新修正'),
              ),
            ],
          ),
          Text(
            entry.rawTranscript,
            key: Key('history-raw-${entry.id}'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            entry.rectifiedText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

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
            // Wrapped, not single-line: insert errors name the failing step
            // ("SendInput delivered N of M events") and the diagnosis is in
            // the tail a single clipped line would eat.
            child: Text(
              label,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
