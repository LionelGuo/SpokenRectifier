part of 'slot_surface.dart';

/// The preview surface's IME adapter (A3 出舱): the state core mixes this
/// in to BE the [TextInputClient] — the platform connection, the shadow
/// value the platform model holds, the view id the engine demands and
/// every client callback live here, over the core's projection and
/// paint-space seams. The composing overlay itself stays in the core
/// (the whole rendering pipeline reads it); this mixin owns its
/// platform half — the connection lifecycle and the commit/diff
/// protocol.
mixin _SlotSurfaceIme on _SlotSurfaceStateCore implements TextInputClient {
  TextInputConnection? _connection;
  TextEditingValue _shadow = TextEditingValue.empty;

  /// The view the connection targets. The engine rejects setClient
  /// without an integer viewId — without it no platform text model
  /// exists and typed characters are silently dropped (the 22 号
  /// acceptance-round finding).
  int? _viewId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newViewId = View.of(context).viewId;
    if (_isPreview && newViewId != _viewId) {
      _viewId = newViewId;
      // The live connection's config names the old view; re-open under
      // the current one.
      if (widget.focusNode?.hasFocus ?? false) _openConnection();
    }
  }

  @override
  void initState() {
    super.initState();
    if (_isPreview) {
      widget.focusNode?.addListener(_onFocusChanged);
      // Opening waits for didChangeDependencies: the view id the engine
      // demands is only resolvable there.
    }
  }

  // -- the core's IME seams -----------------------------------------------
  //
  // Linearization hides mixin members from core code, so the core's
  // dispose / round-reset paths call these seams, and its abstract
  // _syncShadow resolves to the one under the platform section below.

  @override
  void _imeDispose() {
    if (_isPreview) {
      widget.focusNode?.removeListener(_onFocusChanged);
      _connection?.close();
    }
  }

  @override
  void _imeResetConnection() {
    _connection?.close();
    _connection = null;
    if (widget.focusNode?.hasFocus ?? false) {
      _openConnection();
    }
  }

  // -- the platform text input ---------------------------------------------
  void _onFocusChanged() {
    if (widget.focusNode?.hasFocus ?? false) {
      _openConnection();
    } else {
      _connection?.close();
      _connection = null;
    }
  }

  void _openConnection() {
    _connection?.close();
    _shadow = _buildShadow();
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: _viewId,
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      ),
    );
    _connection!
      ..show()
      ..setEditingState(_shadow);
  }

  /// The shadow value: what the platform model holds — the paragraph text
  /// (composing included) with the editor's selection at paint offsets.
  /// While composing, the selection rides the composing run's end, the
  /// platform's own convention (text_input_model.cc).
  TextEditingValue _buildShadow() {
    final edges = _editor.selectionEdges;
    final int base;
    final int extent;
    if (_composing.isNotEmpty) {
      base = extent = _composingPaintEnd;
    } else if (edges == null) {
      base = extent = _caretPaintFlat;
    } else {
      base = _paintOf(_projection.cursorToFlat(edges.$1));
      extent = _paintOf(_projection.cursorToFlat(edges.$2));
    }
    return TextEditingValue(
      text: _paragraphText,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
      composing: _composing.isEmpty
          ? TextRange.empty
          : TextRange(start: _composingPaintStart, end: _composingPaintEnd),
    );
  }

  /// Push the local state to the platform after a local mutation. Never
  /// while composing: rewriting the editing state mid-composition breaks
  /// the IME, and a composition leaves no local mutations (the keys are
  /// consumed).
  @override
  void _syncShadow() {
    if (_composing.isNotEmpty) return;
    _shadow = _buildShadow();
    _connection?.setEditingState(_shadow);
    _reportCaretGeometry();
  }

  /// Tell the IME where the caret sits, so the candidate window homes to
  /// it (EditableText does the same after every caret move).
  void _reportCaretGeometry() {
    final paragraph = _paragraph;
    final connection = _connection;
    if (paragraph == null || connection == null || !connection.attached) {
      return;
    }
    final transform = paragraph.getTransformTo(null);
    connection.setEditableSizeAndTransform(paragraph.size, transform);
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // The new pre-edit run, exactly as the platform holds it.
    final composingRange = value.composing;
    final newComposing = composingRange.isValid && !composingRange.isCollapsed
        ? value.text.substring(composingRange.start, composingRange.end)
        : '';
    final previousComposing = _shadow.composing;
    final hadComposing =
        previousComposing.isValid && !previousComposing.isCollapsed;

    if (_shadow.text.isEmpty) {
      // No shadow was ever pushed (a race with the connection): adopt the
      // platform state without touching the model.
      _composing = newComposing;
      _shadow = value;
      setState(() {});
      return;
    }

    // Everything outside the composing windows must be the projection
    // plus committed insertions; diff the two bases to find them. Each
    // side's window is stripped at the PLATFORM's own indices: the
    // engine composes over the selection at its start
    // (text_input_model.cc deletes the selection on the first compose
    // change), a position none of our own state describes.
    final newBase = newComposing.isEmpty
        ? value.text
        : value.text.replaceRange(composingRange.start, composingRange.end, '');
    final oldBase = hadComposing
        ? _shadow.text.replaceRange(
            previousComposing.start,
            previousComposing.end,
            '',
          )
        : _shadow.text;

    var prefix = 0;
    while (prefix < oldBase.length &&
        prefix < newBase.length &&
        oldBase[prefix] == newBase[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldBase.length - prefix &&
        suffix < newBase.length - prefix &&
        oldBase[oldBase.length - 1 - suffix] ==
            newBase[newBase.length - 1 - suffix]) {
      suffix++;
    }
    final inserted = newBase.substring(prefix, newBase.length - suffix);

    if (inserted.isNotEmpty) {
      // A commit or a plain keystroke: one atomic model insert (one undo
      // step, 值与骨架同栈). Over a composition the editor's still-live
      // selection is what was being composed over — inserting replaces
      // it, which lands the replacement the IME committed.
      _editor.insert(inserted);
    }
    // A shrunk middle with nothing inserted is the compose-start deletion
    // of the selection: the model keeps it and the composing overlay
    // covers it until the commit (or the cancel) arrives.
    _composing = newComposing;
    _shadow = value;

    _blink.value = 0;
    widget.onChanged?.call(_editor.doc.substitute());
    _revealCaret();
    setState(() {});
  }

  @override
  void performAction(TextInputAction action) {
    // Newlines arrive as model inserts (the key handler) or committed
    // text (the Windows plugin adds '\n' to the editing state before
    // this action); there is nothing to do here. Multiline fields never
    // finalize on actions.
  }

  @override
  void connectionClosed() {
    _connection = null;
    if (widget.focusNode?.hasFocus ?? false) _openConnection();
  }

  @override
  TextEditingValue? get currentTextEditingValue => _shadow;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  // The desktop-multiline surface takes no part in the mobile/IME
  // affordances; the defaults it would inherit through `with` are spelled
  // out because this class *implements* the client interface.
  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  bool onFocusReceived() => false;

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void showToolbar() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performSelector(String selectorName) {}
}
