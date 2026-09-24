//! The recording session: transcript accumulation — paragraphs, the
//! interim partial, pinned placeholders, in-flight snapshots, and the
//! silence baselines — with the invariants (tickets 16/35) in the field
//! and method docs below.

use tokio_util::sync::CancellationToken;

use crate::command::SessionStyle;
use crate::config::EngineTimings;
use crate::event::SessionId;

pub(crate) struct Session {
    pub(crate) id: SessionId,
    /// The hotword dictionary snapshotted when the session opened; the
    /// session's recognition bias and rectify term reference both read it,
    /// so mid-session dictionary edits wait for the next session.
    pub(crate) terms: Vec<String>,
    /// Passage mode snapshotted when the session opened, so a runtime
    /// switch applies from the next session on.
    pub(crate) passage_mode: bool,
    /// The latency timings snapshotted when the session opened, so a
    /// runtime switch applies from the next session on (and never pulls
    /// thresholds out from under a running session).
    pub(crate) timings: EngineTimings,
    /// Paragraphs closed by a paragraph mark.
    pub(crate) paragraphs: Vec<String>,
    /// Finalized speech since the last paragraph mark.
    pub(crate) current_paragraph: String,
    /// Interim speech not yet finalized.
    pub(crate) partial: String,
    /// Placeholders pinned so far, in pin order; the number is the index
    /// plus 1. Held outside the three transcript strings and spliced in
    /// at render time, so later speech never disturbs a pin and the
    /// freeze reuses the live join instead of recomputing positions.
    pub(crate) pins: Vec<Pin>,
    /// The snapshot constraint an in-flight pin opened: `Some` while the
    /// sentence a pin split is still awaiting its first non-empty Final.
    /// Transcript frames may only extend the frozen prefix, and a
    /// paragraph mark cannot split the pinned row. See [`InFlight`].
    pub(crate) in_flight: Option<InFlight>,
    /// Whether the current silence run already emitted a paragraph mark.
    pub(crate) paragraph_marked_current_silence: bool,
    /// Speech happened since the last paragraph mark (VAD activity or
    /// transcript events) — the next threshold silence closes a paragraph.
    pub(crate) speech_since_mark: bool,
    /// The current silence run's elapsed as last reported by the
    /// recognizer — the rebasing point a pin press captures (工单 35).
    pub(crate) last_silence_ms: u64,
    /// Silence already elapsed when the last pin pressed: the paragraph
    /// threshold is judged on what accumulated after the press, so a
    /// press mid-pause buys the pin its own full silence window (工单
    /// 35). The session-end threshold keeps the raw elapsed. Speech
    /// resets this along with the recognizer's own silence run.
    pub(crate) silence_baseline_ms: u64,
    /// Any speech at all this session. A session with none is discarded on
    /// stop/auto-end instead of rectifying an empty utterance.
    pub(crate) any_speech: bool,
    /// Raw transcript frozen when recording ended.
    pub(crate) frozen: Option<FrozenUtterance>,
    /// The one-time style pick this session was re-rectified under
    /// (ticket 23's 指定场景, ticket 28's 默认); `Live` on mic sessions
    /// and plain re-rectifies, which follow the live selection instead.
    /// Pinned for the session's lifetime: rerolls keep it, and it dies
    /// with the session.
    pub(crate) style: SessionStyle,
    /// The store id of the history entry this session re-runs, if any —
    /// a pass-through from the retrieval command, recorded with the
    /// session pair as its 来源会话. `None` on every mic session.
    pub(crate) source_session_id: Option<i64>,
    /// Whether this session was upgraded to quick mode (ADR-0020) by a
    /// hotkey chord held past the threshold. Decided at most once, and
    /// dropped the moment the session fails into preview: from there
    /// every attempt runs the ordinary path again.
    pub(crate) quick: bool,
    /// `[rectify.quick] rectify` as snapshotted when the session opened
    /// (the timings rule): on, a quick stop runs the light-touch pass and
    /// inserts its result; off, the frozen raw transcript is inserted
    /// untouched and no model runs.
    pub(crate) quick_rectify: bool,
    /// The hotkey chord is physically down right now — the shell's hold
    /// watcher reporting (ADR-0020). A held chord suppresses the silence
    /// auto-end: the speaker is mid-gesture and the release ends the
    /// session. False at open, because the watcher arms only after the
    /// session starts, so nothing carries over between sessions.
    pub(crate) hold_gate: bool,
    /// The rectified text as it will be inserted (possibly user-edited).
    pub(crate) preview_text: String,
    /// Ends the ASR stream consumption; fired when recording ends.
    pub(crate) asr_cancel: CancellationToken,
    /// Token of the current rectify attempt; fresh per attempt so rerolls
    /// get a live token after the previous recording-end cancellation.
    pub(crate) rectify_cancel: Option<CancellationToken>,
}

pub(crate) struct FrozenUtterance {
    pub(crate) raw_transcript: String,
    pub(crate) paragraphs: Vec<String>,
}

/// A pinned placeholder (钉入): the sentinel `‡N‡` held at a fixed point
/// of the transcript. The number is the identity — from 1, in pin order,
/// per session; never changed, never reused, never carried across
/// sessions.
pub(crate) struct Pin {
    number: usize,
    anchor: PinAnchor,
}

impl Pin {
    /// The placeholder's textual form: `‡N‡`, ASCII digits, no padding —
    /// the same bytes in the live transcript, the frozen transcript, and
    /// the rectify request.
    fn sentinel(&self) -> String {
        format!("‡{}‡", self.number)
    }
}

/// Where a pin sits: virtual paragraph `paragraph` (the closed paragraphs,
/// then the current paragraph as the last index) at byte `offset` within
/// it. The anchor cannot go stale: closed paragraphs are immutable, the
/// current paragraph only ever appends (keeping its content when it
/// closes), and the interim partial is never pinned into — a draft in
/// flight at the press is frozen onto the finalized side first (ticket
/// 16), so the pin still lands after finalized text.
#[derive(Debug)]
pub(crate) struct PinAnchor {
    paragraph: usize,
    offset: usize,
}

/// The constraint an in-flight pin opens (ticket 16): the press froze the
/// draft spoken so far into the finalized side as the pin's left — dead to
/// the recognizer's later rewrites — and until this sentence's first
/// non-empty Final arrives, transcript frames may only extend the text
/// after the pin on top of the frozen prefix. The snapshot is cumulative
/// across pins stacked in the same sentence: each later press freezes the
/// tail it collected, growing the prefix the recognizer must still start
/// with.
pub(crate) struct InFlight {
    /// The frozen speech-side prefix, in bytes: exactly what this sentence
    /// has committed to the current paragraph. Prefix checks and strips
    /// are byte-exact against it, and it never contains a sentinel (pins
    /// live outside the transcript strings).
    snapshot: String,
}

impl Session {
    /// A fresh session: nothing said, nothing frozen, not quick. Both
    /// session openings (recording, history re-rectify) start from this
    /// shape, each snapshotting the dictionary, passage mode, timings,
    /// and quick-rectify setting as it opens.
    pub(crate) fn new(
        id: SessionId,
        terms: Vec<String>,
        passage_mode: bool,
        timings: EngineTimings,
        quick_rectify: bool,
    ) -> Self {
        Self {
            id,
            terms,
            passage_mode,
            timings,
            quick_rectify,
            paragraphs: Vec::new(),
            current_paragraph: String::new(),
            partial: String::new(),
            pins: Vec::new(),
            in_flight: None,
            paragraph_marked_current_silence: false,
            speech_since_mark: false,
            last_silence_ms: 0,
            silence_baseline_ms: 0,
            any_speech: false,
            frozen: None,
            style: SessionStyle::Live,
            source_session_id: None,
            quick: false,
            hold_gate: false,
            preview_text: String::new(),
            asr_cancel: CancellationToken::new(),
            rectify_cancel: None,
        }
    }

    /// Cumulative live transcript: the paragraph lines with pins spliced
    /// in, the current line carrying any interim partial appended after
    /// the finalized text. An empty current line is dropped as before —
    /// pins make it non-empty.
    pub(crate) fn live_text(&self) -> String {
        let mut lines = self.rendered_paragraphs();
        let current = lines
            .last_mut()
            .expect("the current line is always rendered");
        current.push_str(&self.partial);
        if current.is_empty() {
            lines.pop();
        }
        lines.join("\n")
    }

    /// The transcript's paragraph lines with every pin spliced in: the
    /// closed paragraphs in order, then the current paragraph as the
    /// virtual last line — included even when textless, because a
    /// pin-only line is content. The one join behind both the live
    /// transcript and the freeze, so the frozen paragraphs are never a
    /// second computation of position.
    fn rendered_paragraphs(&self) -> Vec<String> {
        let mut lines: Vec<String> = self
            .paragraphs
            .iter()
            .enumerate()
            .map(|(index, text)| self.splice_pins(index, text))
            .collect();
        lines.push(self.splice_pins(self.paragraphs.len(), &self.current_paragraph));
        lines
    }

    /// One paragraph with the pins anchored in it spliced in at their
    /// offsets. Pins only ever anchor at the then-current end, so
    /// sorting by offset is a no-op that merely makes the order explicit.
    ///
    /// The splice is also the pause-pin normalization (工单 35): the
    /// clause-final punctuation run immediately before a pin is deleted
    /// from the render. The recognizer finalizes a sentence mid-pause,
    /// so a pin pressed while the speaker reaches for the key lands
    /// behind its period — stripping the mark returns the in-sentence
    /// shape (`文件。‡1‡` renders `文件‡1‡`) every placeholder rule is
    /// written against. A render projection only: the raw strings and
    /// the anchors keep their bytes, only the pin's own line's left text
    /// is examined (a previous line's closing mark stays), a line-start
    /// pin has no left text, and same-offset stacked pins strip only
    /// the run ahead of the first of them.
    fn splice_pins(&self, index: usize, text: &str) -> String {
        let mut anchored: Vec<&Pin> = self
            .pins
            .iter()
            .filter(|pin| pin.anchor.paragraph == index)
            .collect();
        if anchored.is_empty() {
            return text.to_string();
        }
        anchored.sort_by_key(|pin| pin.anchor.offset);
        let mut spliced = String::with_capacity(text.len());
        let mut prev = 0;
        for pin in anchored {
            let slice = &text[prev..pin.anchor.offset];
            let strip = trailing_punctuation_len(slice);
            spliced.push_str(&slice[..slice.len() - strip]);
            spliced.push_str(&pin.sentinel());
            prev = pin.anchor.offset;
        }
        spliced.push_str(&text[prev..]);
        spliced
    }

    /// Pin a placeholder at the current end of the transcript. The anchor
    /// rides the paragraph structure, so the splice point stays put while
    /// later speech keeps folding in after the pin. A pin is not speech:
    /// the paragraph and discard rules never see it — but it does restart
    /// the paragraph-silence clock (工单 35): the recognizer finalizes the
    /// sentence while the speaker is still reaching for the key, so
    /// silence already banked by the reach must not close the paragraph
    /// around the pin. The session-end threshold is untouched by this.
    ///
    /// A draft in flight at the press becomes this pin's frozen left
    /// (ticket 16): the draft commits to the finalized side — the words on
    /// screen stay on screen — and the sentence's first non-empty Final is
    /// awaited under a snapshot constraint, so it cannot append the same
    /// words a second time. Pressing again under an open constraint
    /// stacks: the later pin freezes the tail collected so far, growing
    /// the snapshot by it.
    pub(crate) fn pin(&mut self) {
        if !self.partial.is_empty() {
            let draft = std::mem::take(&mut self.partial);
            self.current_paragraph.push_str(&draft);
            match &mut self.in_flight {
                Some(constraint) => constraint.snapshot.push_str(&draft),
                None => self.in_flight = Some(InFlight { snapshot: draft }),
            }
        }
        let anchor = if self.current_paragraph.is_empty() && !self.paragraphs.is_empty() {
            // Nothing new said since the last mark: the shown transcript
            // ends with the last closed paragraph, and so does the pin.
            PinAnchor {
                paragraph: self.paragraphs.len() - 1,
                offset: self.paragraphs.last().expect("checked non-empty").len(),
            }
        } else {
            // End of the current paragraph — offset 0 when it is empty:
            // the pin opens the paragraph, and speech said afterwards
            // lands after it. An in-flight press never reaches here with
            // an empty current paragraph: the draft it just committed
            // opens the row.
            PinAnchor {
                paragraph: self.paragraphs.len(),
                offset: self.current_paragraph.len(),
            }
        };
        let number = self.pins.len() + 1;
        self.pins.push(Pin { number, anchor });
        // The press rebases the paragraph-silence clock: the silence run
        // in flight keeps counting from zero as of now. The rebasing
        // point is the last reported elapsed — silence ticks arrive
        // periodically, so the estimate is only as stale as one tick.
        self.silence_baseline_ms = self.last_silence_ms;
    }

    /// Fold one interim frame into the partial. Under an open snapshot
    /// constraint the frame may only extend the frozen prefix: its
    /// remainder past the snapshot becomes the new tail. A frame that
    /// rewrites the frozen words — Volcano's no-utterance full-session
    /// restatement among them — is dropped whole: the tail keeps its last
    /// frame, and the constraint stands until the sentence's first
    /// non-empty Final decides it. Returns whether the transcript changed.
    pub(crate) fn fold_partial(&mut self, text: String) -> bool {
        match self.in_flight.as_ref() {
            Some(constraint) if !text.starts_with(&constraint.snapshot) => false,
            Some(constraint) => {
                self.partial = text[constraint.snapshot.len()..].to_string();
                true
            }
            None => {
                self.partial = text;
                true
            }
        }
    }

    /// Fold one finalized frame into the current paragraph. Under an open
    /// snapshot constraint this is the sentence's first non-empty Final,
    /// and it ends the constraint: matching the snapshot appends only the
    /// remainder past it (the pin's settled right); not matching appends
    /// the whole text after the pin as new finalized speech — the frozen
    /// left stays dead either way. An empty Final is ignored while the
    /// constraint stands: nothing was finalized, so the tail survives and
    /// only a non-empty Final may decide. Outside a constraint the fold is
    /// today's. Returns whether the transcript changed.
    pub(crate) fn fold_final(&mut self, text: String) -> bool {
        if let Some(constraint) = self.in_flight.take() {
            if text.is_empty() {
                self.in_flight = Some(constraint);
                return false;
            }
            let settled = if text.starts_with(&constraint.snapshot) {
                &text[constraint.snapshot.len()..]
            } else {
                text.as_str()
            };
            self.partial.clear();
            self.current_paragraph.push_str(settled);
            return true;
        }
        self.partial.clear();
        self.current_paragraph.push_str(&text);
        true
    }

    /// Freeze the recording into the session's utterance (recording end):
    /// the speech still in flight joins the transcript, pins splice
    /// through the same join the live transcript uses — position is never
    /// computed twice — and the ASR stream is cancelled. A pin-only
    /// current line counts as content, which is what keeps a pin-only
    /// session alive. Returns whether there is an utterance at all: a
    /// speechless session (noise only, nothing recognized) has nothing to
    /// rectify or paste, so the caller discards it.
    pub(crate) fn freeze(&mut self) -> bool {
        self.asr_cancel.cancel();
        // Speech still in flight when recording ended: the user said it,
        // so the fidelity rule keeps it in the transcript.
        self.current_paragraph.push_str(&self.partial);
        self.partial.clear();
        let mut paragraphs = self.rendered_paragraphs();
        let current = paragraphs
            .pop()
            .expect("the current line is always rendered");
        if !current.is_empty() {
            paragraphs.push(current);
        }
        let raw_transcript = paragraphs.join("\n");
        if raw_transcript.is_empty() && !self.any_speech {
            return false;
        }
        self.frozen = Some(FrozenUtterance {
            raw_transcript,
            paragraphs,
        });
        true
    }

    /// Speech happened (transcript or VAD activity): re-arm the paragraph
    /// marker for the next silence run and remember the session had
    /// content. Speech also restarts the recognizer's silence run from
    /// zero, so the rebasing point and the last-seen elapsed follow it.
    pub(crate) fn note_speech(&mut self) {
        self.paragraph_marked_current_silence = false;
        self.speech_since_mark = true;
        self.any_speech = true;
        self.last_silence_ms = 0;
        self.silence_baseline_ms = 0;
    }
}

/// The length, in bytes, of the run of clause-final punctuation at the
/// end of `text` — the marks a recognizer stamps when it finalizes a
/// sentence mid-pause, full- and half-width alike. The pin splice
/// deletes this run from the render ahead of the pin (工单 35).
fn trailing_punctuation_len(text: &str) -> usize {
    let mut len = 0;
    for ch in text.chars().rev() {
        if !is_clause_punctuation(ch) {
            break;
        }
        len += ch.len_utf8();
    }
    len
}

/// Whether `ch` is a clause-final mark: period, question, exclamation,
/// comma, enumeration comma, semicolon, colon, or ellipsis — the set the
/// recognizer uses to close a sentence or clause, in either width.
fn is_clause_punctuation(ch: char) -> bool {
    matches!(
        ch,
        '。' | '．'
            | '.'
            | '！'
            | '!'
            | '？'
            | '?'
            | '，'
            | ','
            | '、'
            | '；'
            | ';'
            | '：'
            | ':'
            | '…'
    )
}
