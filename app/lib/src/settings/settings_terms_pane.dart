/// The 术语 domain: the hotword dictionary's full management — add,
/// rename in place, delete, browse — over the same bridge calls the
/// quick panel's quick-add makes (同源同文件). The file is the truth:
/// after every mutation the list re-reads it, and the engine re-reads
/// it when the next session opens (下一会话生效, no restart needed). The
/// main window's quick panel re-reads on open, plus follows a
/// terms-changed event so an open panel repaints too.

library;

import 'package:flutter/material.dart';

import '../design/controls.dart' show SrButton, SrField;
import '../design/hover.dart';
import '../design/toast.dart';
import '../design/tokens.dart';
import '../errors.dart';
import 'terms_store.dart';

class SettingsTermsPane extends StatefulWidget {
  const SettingsTermsPane({
    super.key,
    required this.store,
    required this.onTermsChanged,
  });

  final TermsStore store;

  /// Fires after every mutation that landed — the main window re-reads
  /// the dictionary so an open quick panel's chips repaint.
  final Future<void> Function() onTermsChanged;

  @override
  State<SettingsTermsPane> createState() => _SettingsTermsPaneState();
}

class _SettingsTermsPaneState extends State<SettingsTermsPane> {
  List<String> _terms = const [];
  bool _loaded = false;

  late final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final terms = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _terms = terms;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loaded = true);
      logRawError('err_terms_load', e);
      SrToast.of(context).show('术语读取失败', tone: SrToastTone.error);
    }
  }

  /// One mutation: apply, then re-read the file — local state only
  /// moves once the file has accepted the write, exactly like the
  /// scenario library's commit rule.
  Future<void> _mutate(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      logRawError('err_terms_op', e);
      SrToast.of(context).show('操作失败', tone: SrToastTone.error);
      return;
    }
    await _reload();
    await widget.onTermsChanged();
  }

  Future<void> _add() async {
    final term = _input.text.trim();
    if (term.isEmpty) return; // blank adds nothing (the quick-add rule)
    _input.clear();
    await _mutate(() => widget.store.add(term));
  }

  Future<void> _rename(String oldTerm) async {
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _TermEditorDialog(initialTerm: oldTerm, existingTerms: _terms),
    );
    if (edited == null || edited == oldTerm) return;
    await _mutate(() => widget.store.update(oldTerm, edited));
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('术语', style: SrType.title.copyWith(color: pal.textPrimary)),
        const SizedBox(height: 16),
        _AddRow(controller: _input, onAdd: _add),
        const SizedBox(height: 12),
        if (!_loaded)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else if (_terms.isEmpty)
          _EmptyDictionary()
        else
          for (final term in _terms)
            _TermRow(
              term: term,
              onRename: () => _rename(term),
              onRemove: () => _mutate(() => widget.store.remove(term)),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The add row — the quick panel's term-row recipe (container-drawn box,
// undecorated field, square add button)
// ---------------------------------------------------------------------------

class _AddRow extends StatelessWidget {
  const _AddRow({required this.controller, required this.onAdd});

  final TextEditingController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SrField(
            key: const Key('settings-terms-field'),
            controller: controller,
            hint: '添加术语',
            onSubmitted: (_) => onAdd(),
          ),
        ),
        const SizedBox(width: 8),
        SrButton(
          key: const Key('settings-terms-add'),
          primary: true,
          label: '添加',
          onTap: onAdd,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Term rows — hover reveals rename/remove (the scenario card's recipe)
// ---------------------------------------------------------------------------

class _TermRow extends StatelessWidget {
  const _TermRow({
    required this.term,
    required this.onRename,
    required this.onRemove,
  });

  final String term;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Padding(
      // Row gap outside the hover region, like the history rows.
      padding: const EdgeInsets.only(bottom: 6),
      child: SrHover(
        builder: (hover) => AnimatedContainer(
          key: Key('settings-terms-row:$term'),
          duration: SrMotion.fade,
          curve: SrMotion.curveFade,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: pal.surfaceRaised.withValues(alpha: hover ? 1 : 0),
            borderRadius: BorderRadius.circular(SrRadius.control),
            border: Border.all(color: pal.hairline),
          ),
          child: Row(
            children: [
              Icon(Icons.spellcheck_rounded, size: 15, color: pal.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  term,
                  style: SrType.caption.copyWith(color: pal.textSecondary),
                ),
              ),
              IgnorePointer(
                ignoring: !hover,
                child: AnimatedOpacity(
                  duration: SrMotion.fade,
                  curve: SrMotion.curveFade,
                  opacity: hover ? 1 : 0,
                  child: Row(
                    children: [
                      _TermAction(
                        key: Key('settings-terms-rename:$term'),
                        icon: Icons.edit_outlined,
                        tooltip: '重命名',
                        onTap: onRename,
                      ),
                      const SizedBox(width: 10),
                      _TermAction(
                        key: Key('settings-terms-remove:$term'),
                        icon: Icons.delete_outline_rounded,
                        tooltip: '删除',
                        onTap: onRemove,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TermAction extends StatelessWidget {
  const _TermAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return SrHover(
      builder: (hover) => Tooltip(
        message: tooltip,
        waitDuration: SrMotion.tooltipWait,
        child: GestureDetector(
          onTap: onTap,
          child: Icon(
            icon,
            size: 15,
            color: hover ? pal.accentText : pal.textTertiary,
          ),
        ),
      ),
    );
  }
}

class _EmptyDictionary extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 64, bottom: 64),
        child: Column(
          children: [
            Icon(Icons.spellcheck_rounded, size: 32, color: pal.textTertiary),
            const SizedBox(height: 12),
            Text(
              key: const Key('settings-terms-empty'),
              '暂无术语',
              style: SrType.body.copyWith(color: pal.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The rename dialog — the scenario editor's single-field recipe
// ---------------------------------------------------------------------------

class _TermEditorDialog extends StatefulWidget {
  const _TermEditorDialog({
    required this.initialTerm,
    required this.existingTerms,
  });

  final String initialTerm;

  /// The dictionary as the dialog opened — validation input, so a
  /// rename can never produce the duplicate the Rust writer refuses.
  final List<String> existingTerms;

  @override
  State<_TermEditorDialog> createState() => _TermEditorDialogState();
}

class _TermEditorDialogState extends State<_TermEditorDialog> {
  late final TextEditingController _term = TextEditingController(
    text: widget.initialTerm,
  );
  String? _error;

  @override
  void dispose() {
    _term.dispose();
    super.dispose();
  }

  void _save() {
    final term = _term.text.trim();
    if (term.isEmpty) {
      setState(() => _error = '术语不能为空');
      return;
    }
    final duplicatesAnother =
        widget.existingTerms.contains(term) && term != widget.initialTerm;
    if (duplicatesAnother) {
      setState(() => _error = '已存在相同术语');
      return;
    }
    Navigator.of(context).pop(term);
  }

  @override
  Widget build(BuildContext context) {
    final pal = srPalette(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '重命名术语',
                style: SrType.title.copyWith(color: pal.textPrimary),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('settings-terms-rename-field'),
                controller: _term,
                autofocus: true,
                onSubmitted: (_) => _save(),
                style: SrType.body.copyWith(color: pal.textPrimary),
                cursorColor: pal.accent,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  filled: true,
                  fillColor: pal.surfaceOverlay,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const Key('settings-terms-form-error'),
                  style: SrType.caption.copyWith(color: pal.live),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SrButton(
                    key: const Key('settings-terms-rename-cancel'),
                    label: '取消',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  SrButton(
                    key: const Key('settings-terms-rename-save'),
                    primary: true,
                    label: '保存',
                    onTap: _save,
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
