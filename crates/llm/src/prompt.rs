//! Prompt composition for rectify (glossary: 修正, 保真铁律, 风格指令).
//!
//! The system prompt carries the fidelity rule and every transform rule;
//! intensity and the style directive inject their own lines; terms render
//! as a reference list in the user message. Composition is pure and
//! deterministic — golden tests freeze the exact text.
//!
//! Placeholders (`‡N‡`) are injected, never baked in: without a sentinel in
//! the frozen transcript the composition is byte-identical to the
//! pre-placeholder prompt (ADR-0012). With pins the response grammar is
//! inline — the model writes each slot where it rides as `‡N:值‡`, bare
//! `‡N‡` meaning an empty prefill (ADR-0013). With pins and prefill off
//! the pinned branch swaps to the raw pass-through form — zero
//! absorption, marks riding the rectified text as-is, no census table
//! (ADR-0014); the prefill flag never touches a no-pin composition.

use spokenrectifier_engine::provider::llm::RectifyRequest;

use crate::intensity::Intensity;

/// A chat completion prompt: fixed rules plus per-request directives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatPrompt {
    pub system: String,
    pub user: String,
}

const HEADER: &str = "\
你是一个中文口语转写修正器。输入是即兴口语的逐字转写,包含磕巴、口头语、口头更正与补充;输出是可直接使用的书面文本。直接输出修正后的文本本身:不要前言、不要解释、不要用代码块或引号包裹。";

const FIDELITY_RULE: &str = "\
【保真铁律】(最高优先级,与任何其他规则冲突时以本条为准)
- 不得捏造转写中没有的信息。
- 不得丢失用户明确表达的意思。
- 只删除真正的冗余;拿不准时,保留。
- 保真优先于信息密度:压缩提密与保真冲突时,一律保真。";

const TRANSFORMS: &str = "\
【五类变换】
1. 去口头语与磕巴:删除语气词(嗯、呃、那个、就是说、嘛、哈)、无意义重复与停顿填充。
2. 应用口头更正:\"不对,应该是X\"\"说错了\"\"再说清楚一点\"等修订前文的部分,按语义合并进被修订的内容;更正引导语本身不得出现在修正文本中。
3. 去冗余:复述、车轱辘话、同义重复。
4. 篇章逻辑重组:调整语序、合并拆分句子、按逻辑重新分段(受下方【整理强度】限制)。
5. 语体转换:口语措辞改为书面措辞。";

const SELF_CORRECTION: &str = "\
【自纠判定】只把\"明确的自我修正痕迹\"当作口头更正合并(说错后立刻更正的部分);当\"不对\"\"但是\"\"不过\"等词承载真实语义转折时,必须保留其语义,不得当作口头语删除。";

const VERBATIM: &str = "\
【逐字保留】术语、产品名、代码、URL、英文缩写、数字与单位,一律逐字保留,不得改写、翻译或\"纠正\"拼写——\"拼写\"指内容本身,大小写等纯形态属性属语体范畴,随【目标语体】执行。若下方给出术语参考,以其拼写为准。";

const NUMERALS: &str = "\
【中文数字规范化】口语数字读法转为标准书面形式:\"百分之三十\"→\"30%\",\"一百二十万\"→\"120万\",\"六月二十一号\"→\"6月21日\";成语、习语与专有名词中的数字保持原样;拿不准时保留原样。";

const INTENSITY_LIGHT_TOUCH: &str = "\
【整理强度】轻修(本次输入较短):只做第 1、2、3 类变换与数字规范化、标点修正。禁止改变句序,禁止合并或拆分句子,禁止改写措辞风格,禁止增删任何信息。用户的原措辞与表达顺序尽量原样保留。";

const INTENSITY_FULL: &str = "\
【整理强度】全量修正(本次输入为中长段):五类变换全部执行,允许篇章级逻辑重组、句序调整、合并与压缩提密,产出结构清晰、信息密度高的书面文本;铁律仍然优先。";

/// The single built-in default register (通用书面), used whenever no
/// scenario directive is selected.
const DEFAULT_REGISTER: &str = "通用书面语:清晰、准确、自然的现代书面汉语。";

/// The header riding a user's style directive: enforcement framing, so
/// the directive reads as an order, not a suggestion. Real-machine
/// testing showed a bare directive line is followed only intermittently.
const DIRECTIVE_ENFORCEMENT: &str = "(用户指定的输出形态,必须严格执行)";

/// The precedence line right under a user's style directive. The
/// directive outranks every FORM rule — including the verbatim-preservation
/// clause's letter-case ("不得改写拼写" would otherwise eat an "all
/// uppercase" directive) — and only the fidelity rule outranks it, scoped
/// to facts and meaning, never to form (ADR-0004: 铁律恒高于自定义指令,
/// but the 铁律 governs facts, not casing). An earlier wording ("与任何
/// 其他规则冲突时以铁律为准") actively sabotaged directives by yielding
/// to every rule in the prompt.
const DIRECTIVE_PRECEDENCE: &str = "(优先级:本指令高于其他一切语体、格式与拼写形态规则——包括【逐字保留】与【术语参考】的大小写与拼写形态;仅【保真铁律】高于本指令:不得因此捏造信息或丢失用户明确表达的意思)";

/// The reminder appended to the user message when a directive is active:
/// recency at generation start, next to the text being transformed — the
/// system prompt's directive block is far above by the time tokens are
/// generated.
const DIRECTIVE_REMINDER: &str =
    "【语体指令】(必须逐字执行;高于一切拼写与格式保留规则,仅保真铁律例外)";

/// The header riding the global directive (ticket 22): the same
/// enforcement framing as a scenario's — a bare directive line is
/// followed only intermittently, so it reads as an order, not a
/// suggestion.
const GLOBAL_ENFORCEMENT: &str = "(用户设定的全局指令,必须严格执行)";

/// The precedence line right under the global directive. It outranks
/// every FORM rule like a scenario's does, but sits one step BELOW the
/// scenario directive: only the fidelity rule and a scenario outrank it,
/// and a conflict follows the scenario (ADR-0006's
/// 铁律 > 场景 > 全局 > 其他形式规则).
const GLOBAL_PRECEDENCE: &str = "(优先级:本指令高于其他一切语体、格式与拼写形态规则;仅【保真铁律】与场景指令高于本指令——与场景指令冲突时,以场景指令为准)";

/// The user-message reminder for the global directive — same recency
/// rationale as [`DIRECTIVE_REMINDER`]. With both directives active the
/// global reminder comes FIRST and the scenario's stays last: recency
/// goes to the stronger, matching the precedence order.
const GLOBAL_REMINDER: &str =
    "【全局指令】(必须执行;高于一切拼写与格式保留规则,仅保真铁律与场景指令例外)";

// -- the placeholder branch (ADR-0012; grammar per ADR-0013) --------------
//
// Everything in this block exists ONLY when the frozen transcript's
// mechanical census finds at least one ‡digits‡ sentinel. A no-pin request
// must stay byte-identical to today's composition — the untouched golden
// files freeze that contract — so nothing here may leak into the no-pin
// path.

/// The placeholder rule: its own precedence tier right under the fidelity
/// rule (铁律 > 占位符专条 > 场景 > 全局 > 形式规则). The fidelity rule
/// governs facts and meaning; this rule governs the slots' identity,
/// glyph, count, and position — disjoint jurisdictions (ADR-0012). The
/// response grammar it teaches is inline: each slot rides the rectified
/// text where it anchors as `‡N:值‡`, the bare `‡N‡` always legal and
/// meaning an empty prefill; values carry no `‡` and no newline (ADR-0013).
///
/// Example-free since ticket 31's third in-round ruling: concrete example
/// content taught token-matching rather than the noun-phrase principle,
/// and the eval suite's shared vocabulary with those examples made a
/// passing run ambiguous between generalization and echo. The user ruled
/// the prompt stays example-free even though a controlled experiment
/// showed demonstrations carry the induction (zero examples collapsed
/// absorption to nothing; decorrelated examples preserved it) — whatever
/// passes the suite now is genuine generalization, nothing else. The
/// absorption bullet therefore leads with the default action and demotes
/// the bare form to an exception (the later cut-and-paste framing
/// "移不是抄" was itself replaced by the two-step action plus the
/// self-check ban in the C+AB arm below).
///
/// Ticket 37's C arm rewrote the wording for the model's eyes only
/// (ticket 36, ruling 4): jargon tied to invisible key actions
/// (钉入/钉前/钉后) became text positions the model can see
/// (记号之前/之后), grammar-internal terms (裸形, 内联形态, 分辖,
/// 机械普查) became plain descriptions, and explanations were expanded
/// rather than compressed — semantics unchanged item by item.
///
/// The C+AB arm (ticket 36, rulings 1-3) then rebuilt the absorption
/// bullet on that wording: both sides of the mark are equal candidates
/// (the 31-1 direction clause 「钉后不回吸」 retired — pressing the key
/// before or after saying the referent is equally likely), a two-sided
/// race is decided by which side names the thing more completely, and a
/// genuine ambiguity (different things, both complete) absorbs nothing.
/// The noun-phrase criterion is operationalized: a noun or proper-name
/// head must close the phrase, its modifiers ride whole; bare modifiers,
/// bare demonstratives and pronouns never qualify. Execution became two
/// explicit steps — delete the phrase from the body, write it verbatim
/// as the prefill — closed by the output self-check ban, which replaces
/// the 移不是抄 metaphor against the duplication failure.
const PLACEHOLDER_RULE: &str = "\
【占位符】(【保真铁律】管事实与意思,本条管槽;本条高于其他一切规则)
- 转写里的 ‡数字‡ 记号(如 ‡1‡)是用户特意放进转写的待填槽:不是措辞、不是冗余、不是标点,也不是数字读法。
- 修正文本里,每个槽在转写中原来的位置写成 ‡编号:值‡,其中编号就是记号里的数字,冒号后直接写预填值;预填值里不得出现 ‡,也不得换行。
- 决定不吸收的槽只写记号本身 ‡编号‡(冒号与值都不写,预填为空);编号原样保留:不改写、不翻译、不规范化,也不加引号或代码块等任何包裹。
- 槽与槽之间不算冗余:不合并、不删减,也不新增转写里没有的记号;编号不按【中文数字规范化】转换。
- 占位符是普通的句法成分:重组句子时,不得把它从紧挨着的内容上撕开。
- 应用口头更正时,不得把槽当成更正引导语或被替代的内容删掉;更正只改预填值,不删槽。
- 吸收:记号两侧平等对待——哪一侧紧挨着槽有完整的名词短语,就把那一侧的名词短语整块吸进该槽的预填值。
  - 名词短语的判定:短语以名词或专有名字收尾,连同它的全部定语(指示、数量、领属、形容、小句定语)整块算一个名词短语——指示语、专名、名称性短语、文件名、路径、编号都属此类;路径与文件名移进预填不算【逐字保留】说的改写。只有定语(「项目里的」这类只说范围、没把事物名出来的修饰语)、光杆指示词(「那个」)、代词——没有名词中心语的——都不算,不吸。
  - 两侧都紧挨着完整的名词短语时:吸把事物名得更完整的一侧,落选的一侧留在正文(同一事物的不同说法,取说得全的一侧);两侧各说的是不同事物、又都说得完整——真歧义,拿不准就不吸。
  - 吸收是两个动作:第一步,从正文里删掉该短语;第二步,预填值=该短语原文照写。自查:预填值里的内容,正文中一个字都不得再出现。吸收只写预填值,不写正文。
  - 确实拿不准时不吸收,槽只写记号本身 ‡编号‡(空值)。";

/// The sentence appended to the HEADER with pins: the sentinel survives
/// the header's own written-form and no-wrapping demands. The 【预填】
/// block demand retired with the block itself (ADR-0013) — the response is
/// the rectified text alone, slots inline. Grammar-agnostic, so both
/// pinned forms carry it verbatim (ADR-0014).
const PLACEHOLDER_HEADER_TAIL: &str = "记号不受本段书面化与包裹禁令约束。";

/// The placeholder rule's raw pass-through variant (ADR-0014, prefill
/// off): the model absorbs nothing and writes no values — each mark rides
/// the rectified text exactly as censused, the user fills the slots
/// afterwards. Five of the on-form's bullets survive, each guarding one
/// loss path: the definition (deliberate slot, not noise the transforms
/// may eat), verbatim pass-through (no rewriting, translation,
/// normalization or wrapping), no dedup between slots (no merging,
/// trimming, or fabricating numbers), ordinary syntax (reorganization
/// must not tear a mark from what it hugs), and self-correction (a mark
/// is neither a correction lead-in nor the replaced content). The value
/// grammar, the empty-prefill bare form, and the whole absorption subtree
/// are gone — in this form there is no value to write and nothing to
/// absorb, and teaching the grammar would invite the model to invent one.
/// The ticket's grilling round settled each bullet by recommendation
/// (`.scratch/prefill-switch/issues/01-prefill-off-variant.md`).
const PLACEHOLDER_RULE_OFF: &str = "\
【占位符】(【保真铁律】管事实与意思,本条管槽;本条高于其他一切规则)
- 转写里的 ‡数字‡ 记号(如 ‡1‡)是用户特意放进转写的待填槽:不是措辞、不是冗余、不是标点,也不是数字读法。
- 记号原样保留:照转写里的原样输出记号本身,不改写、不翻译、不规范化,也不加引号或代码块等任何包裹。
- 槽与槽之间不算冗余:不合并、不删减,也不新增转写里没有的记号;编号不按【中文数字规范化】转换。
- 占位符是普通的句法成分:重组句子时,不得把它从紧挨着的内容上撕开。
- 应用口头更正时,不得把槽当成更正引导语或被替代的内容删掉。";

/// Light-touch with pins commands absorption outright (ticket 32): the
/// real machine showed the model widening 原样保留 over the slot
/// transaction — a referent competing with a slot went unabsorbed, the
/// slot left bare. The exemption grew into a positive command: absorb as
/// usual, the absorbed referent leaves the body, and that is neither
/// 增删信息 nor a 原样保留 breach; the keep-original sentence excludes
/// the absorbed referent by name. The only intensity variant: full
/// rectify never forbids adding or dropping information. Ticket 37's
/// C+AB arm mirrored the ticket 36 rulings into this command: both sides
/// of the mark are candidates, completeness decides a two-sided race,
/// and a genuine ambiguity absorbs nothing (the criterion detail lives
/// in the placeholder rule, always present with pins).
const INTENSITY_LIGHT_TOUCH_PLACEHOLDERS: &str = "\
【整理强度】轻修(本次输入较短):只做第 1、2、3 类变换与数字规范化、标点修正。禁止改变句序,禁止合并或拆分句子,禁止改写措辞风格,禁止增删任何信息。记号两侧紧挨着槽的名词短语照常整块吸进预填——以把事物名得更完整的一侧为准,两侧各说的是不同事物且都完整就不吸;被吸走的不留在正文——吸收不算增删,也不违背原样保留。用户的原措辞与表达顺序尽量原样保留,被吸走的指称不算在内。";

/// The directive-precedence line with pins: the placeholder rule joins the
/// fidelity rule in the exception list — a directive may not restyle or
/// absorb a slot (ticket 12's injection-time rewrites). Grammar-agnostic,
/// so both pinned forms carry it verbatim (ADR-0014).
const DIRECTIVE_PRECEDENCE_PLACEHOLDERS: &str = "(优先级:本指令高于其他一切语体、格式与拼写形态规则——包括【逐字保留】与【术语参考】的大小写与拼写形态;仅【保真铁律】与【占位符】高于本指令:不得因此捏造信息或丢失用户明确表达的意思)";

/// The global-precedence line with pins: the placeholder rule joins the
/// fidelity rule and the scenario directive above the global directive.
const GLOBAL_PRECEDENCE_PLACEHOLDERS: &str = "(优先级:本指令高于其他一切语体、格式与拼写形态规则;仅【保真铁律】、【占位符】与场景指令高于本指令——与场景指令冲突时,以场景指令为准)";

/// The style reminder with pins: the exception list gains the placeholder
/// rule.
const DIRECTIVE_REMINDER_PLACEHOLDERS: &str =
    "【语体指令】(必须逐字执行;高于一切拼写与格式保留规则,仅保真铁律与【占位符】例外)";

/// The global reminder with pins: same gain, scenario still excepted.
const GLOBAL_REMINDER_PLACEHOLDERS: &str =
    "【全局指令】(必须执行;高于一切拼写与格式保留规则,仅保真铁律、【占位符】与场景指令例外)";

/// The census-table header in the user message. The table is a pure
/// number anchor now (ADR-0013): the response grammar no longer mirrors
/// it, so the rows are bare sentinels — the authoritative set against
/// fabrication. No values ride the request, ever: the first round has
/// nothing to carry, and a regen round never carries the user's current
/// values (ticket 13: 恒空, both rounds). Ticket 37's C arm turned the
/// header from the internal "机械普查,升序" phrasing into a direct
/// address to the model — an exhaustive, authoritative list — with the
/// authority semantics preserved (ticket 36, ruling 4).
const PLACEHOLDER_CENSUS_HEADER: &str =
    "【占位符清单】(上面转写里出现的占位符编号都在这里,从小到大排列;修正文本里的槽以这份清单为准)";

/// The placeholder reminder closing the user message with pins — always
/// the LAST block, below even the scenario's reminder: recency goes to
/// the strongest rule (ticket 12). The compressed demand is the inline
/// grammar itself (ADR-0013).
const PLACEHOLDER_REMINDER: &str = "【占位符】(必须执行:槽在原位写成 ‡编号:值‡,不吸收就只写记号本身 ‡编号‡;高于一切语体与格式规则,仅保真铁律例外)";

/// The pass-through form's closing reminder (ADR-0014): same position,
/// same precedence framing, only the demand swapped — verbatim
/// preservation instead of the inline grammar. No census table backs it
/// up in this form, so the reminder is the anti-loss net's last word.
const PLACEHOLDER_REMINDER_OFF: &str = "【占位符】(必须执行:记号按原样保留,不改写、不翻译、不规范化、不包裹、不删除;高于一切语体与格式规则,仅保真铁律例外)";

/// The placeholder sentinel: ‡ + ASCII digits + ‡ (ticket 07). U+2021, so
/// every scan walks chars, never bytes.
const SENTINEL: char = '‡';

/// Mechanical census of the placeholder sentinels in the frozen
/// transcript: every `‡ASCII digits‡` shape counts — including tokens
/// that merely occur in the spoken text, since provenance is never
/// checked (story 20: shape is truth). Returns the distinct digit
/// strings, ascending by numeric value — the census table's row order.
/// A number occurring twice is one row: the number is the identity, and
/// the engine never reissues one.
fn census_placeholder_numbers(text: &str) -> Vec<&str> {
    let mut found: Vec<&str> = Vec::new();
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        if c != SENTINEL {
            continue;
        }
        let digits_start = at + c.len_utf8();
        let mut digits_end = digits_start;
        while let Some(&(i, '0'..='9')) = chars.peek() {
            digits_end = i + 1;
            chars.next();
        }
        if digits_end > digits_start && chars.peek().map(|&(_, c)| c) == Some(SENTINEL) {
            chars.next(); // the closing sentinel
            let digits = &text[digits_start..digits_end];
            if !found.contains(&digits) {
                found.push(digits);
            }
        }
    }
    // Ascending by numeric value. Sorting by (length, bytes) IS numeric
    // order for digit strings and cannot overflow a parse; the engine
    // issues no leading zeros, so a leading-zero shape from body text
    // just sorts among its own length class — still deterministic.
    found.sort_by(|a, b| (a.len(), *a).cmp(&(b.len(), *b)));
    found
}

/// Compose the full chat prompt for one rectify request.
pub fn compose_prompt(request: &RectifyRequest, intensity: Intensity) -> ChatPrompt {
    // The injection gate: a mechanical census of the frozen transcript,
    // never a count of pin events — `RectifyRequest` carries none, and a
    // shape that merely occurs in the spoken text counts all the same
    // (ADR-0012). No sentinel, no placeholder branch anywhere below: the
    // no-pin composition stays byte-identical to the pre-placeholder
    // prompt, frozen by the untouched golden files.
    let slots = census_placeholder_numbers(&request.raw_transcript);
    let pins = !slots.is_empty();
    // The two pinned forms (ADR-0014): prefill on teaches the inline
    // grammar — the C+AB absorption wording untouched; prefill off is the
    // raw pass-through variant. Both share the header tail and the
    // exception-list rewrites, which teach no grammar; the rule body, the
    // light-touch variant and the closing reminder are form-specific, and
    // the census table exists only with the inline grammar to anchor.
    let inline = pins && request.prefill;
    let pass_through = pins && !request.prefill;

    let mut system_sections: Vec<String> = vec![
        if pins {
            format!("{HEADER}{PLACEHOLDER_HEADER_TAIL}")
        } else {
            HEADER.into()
        },
        String::new(),
        FIDELITY_RULE.into(),
        String::new(),
    ];
    // The placeholder rule slots between the fidelity rule and the five
    // transforms — its own precedence tier (ADR-0012: 铁律 > 占位符专条
    // > 场景 > 全局 > 形式规则); absent entirely without pins. The two
    // forms never coexist — the request's prefill flag picks one.
    if inline {
        system_sections.push(PLACEHOLDER_RULE.into());
        system_sections.push(String::new());
    } else if pass_through {
        system_sections.push(PLACEHOLDER_RULE_OFF.into());
        system_sections.push(String::new());
    }
    system_sections.push(TRANSFORMS.into());
    system_sections.push(String::new());
    system_sections.push(SELF_CORRECTION.into());
    system_sections.push(String::new());
    system_sections.push(VERBATIM.into());
    system_sections.push(String::new());
    system_sections.push(NUMERALS.into());
    system_sections.push(String::new());
    // Light-touch is the only intensity variant: absorption only writes
    // the prefill, so with the inline grammar it is carved out of the
    // no-adding-or-dropping ban. The pass-through form never absorbs, so
    // its light-touch is the plain rule verbatim — no variant of its own
    // (ADR-0014).
    system_sections.push(
        match (intensity, inline) {
            (Intensity::LightTouch, true) => INTENSITY_LIGHT_TOUCH_PLACEHOLDERS,
            (Intensity::LightTouch, false) => INTENSITY_LIGHT_TOUCH,
            (Intensity::Full, _) => INTENSITY_FULL,
        }
        .into(),
    );
    system_sections.push(String::new());
    // The global directive's own block, one step above 【目标语体】 in the
    // precedence order — absent entirely when unset, so the prompt stays
    // byte-identical to the pre-global composition. With pins both
    // precedence lines grow the placeholder rule in their exception
    // lists (ticket 12's injection-time rewrites).
    if let Some(text) = &request.global_directive {
        let precedence = if pins {
            GLOBAL_PRECEDENCE_PLACEHOLDERS
        } else {
            GLOBAL_PRECEDENCE
        };
        system_sections.push(format!(
            "【全局指令】{GLOBAL_ENFORCEMENT}\n{text}\n{precedence}"
        ));
        system_sections.push(String::new());
    }
    match &request.style_directive {
        None => system_sections.push(format!("【目标语体】{DEFAULT_REGISTER}")),
        Some(text) => {
            let precedence = if pins {
                DIRECTIVE_PRECEDENCE_PLACEHOLDERS
            } else {
                DIRECTIVE_PRECEDENCE
            };
            system_sections.push(format!(
                "【目标语体】{DIRECTIVE_ENFORCEMENT}\n{text}\n{precedence}"
            ));
        }
    }
    let system = system_sections.join("\n");

    let mut user = format!("【原始转写】\n{}", request.paragraphs.join("\n\n"));
    if inline {
        // The census table right after the transcript: every number a
        // bare-sentinel row, ascending — a pure number anchor, teaching
        // no response syntax (ADR-0013: the response grammar is inline).
        // The pass-through form carries no table (ADR-0014): the marks in
        // the transcript are the only anchor the model needs, and the
        // user ruled the off-form prompt stays as thin as that.
        let rows = slots
            .iter()
            .map(|n| format!("- ‡{n}‡"))
            .collect::<Vec<_>>()
            .join("\n");
        user.push_str(&format!("\n\n{PLACEHOLDER_CENSUS_HEADER}\n{rows}"));
    }
    if !request.terms.is_empty() {
        let list = request
            .terms
            .iter()
            .map(|t| format!("- {t}"))
            .collect::<Vec<_>>()
            .join("\n");
        user.push_str(&format!(
            "\n\n【术语参考】(逐字保留,以如下拼写为准)\n{list}"
        ));
    }
    if let Some(text) = &request.global_directive {
        let reminder = if pins {
            GLOBAL_REMINDER_PLACEHOLDERS
        } else {
            GLOBAL_REMINDER
        };
        user.push_str(&format!("\n\n{reminder}\n{text}"));
    }
    if let Some(text) = &request.style_directive {
        let reminder = if pins {
            DIRECTIVE_REMINDER_PLACEHOLDERS
        } else {
            DIRECTIVE_REMINDER
        };
        user.push_str(&format!("\n\n{reminder}\n{text}"));
    }
    if inline || pass_through {
        // Always the last block of the user message — below even the
        // scenario's reminder, recency to the strongest rule. Each form
        // carries its own demand (ADR-0014).
        let reminder = if inline {
            PLACEHOLDER_REMINDER
        } else {
            PLACEHOLDER_REMINDER_OFF
        };
        user.push_str(&format!("\n\n{reminder}"));
    }

    ChatPrompt { system, user }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(
        style_directive: Option<&str>,
        global_directive: Option<&str>,
        terms: Vec<&str>,
    ) -> RectifyRequest {
        RectifyRequest {
            raw_transcript: "嗯你好世界".into(),
            paragraphs: vec!["嗯你好世界".into()],
            style_directive: style_directive.map(String::from),
            global_directive: global_directive.map(String::from),
            terms: terms.into_iter().map(String::from).collect(),
            prefill: true,
        }
    }

    #[test]
    fn system_prompt_carries_the_fidelity_rule_and_all_transforms() {
        let prompt = compose_prompt(&request(None, None, vec![]), Intensity::Full);
        for fragment in [
            "保真优先于信息密度",
            "不得捏造转写中没有的信息",
            "【五类变换】",
            "应用口头更正",
            "【自纠判定】",
            "【逐字保留】",
            "【中文数字规范化】",
        ] {
            assert!(prompt.system.contains(fragment), "missing: {fragment}");
        }
    }

    #[test]
    fn light_touch_forbids_reordering_and_rewording() {
        let prompt = compose_prompt(&request(None, None, vec![]), Intensity::LightTouch);
        let intensity = INTENSITY_LIGHT_TOUCH;
        assert!(intensity.contains("禁止改变句序"));
        assert!(intensity.contains("禁止改写措辞风格"));
        assert!(prompt.system.contains("轻修"));
        assert!(!prompt.system.contains("全量修正"));
    }

    #[test]
    fn full_rectify_allows_reorganization() {
        let prompt = compose_prompt(&request(None, None, vec![]), Intensity::Full);
        assert!(INTENSITY_FULL.contains("允许篇章级逻辑重组"));
        assert!(prompt.system.contains("全量修正"));
    }

    #[test]
    fn no_directive_means_the_default_register_without_the_directive_guard() {
        let prompt = compose_prompt(&request(None, None, vec![]), Intensity::Full);
        assert!(prompt.system.contains("通用书面语"));
        // The built-in register is engine-owned and consistent with the
        // rules; the enforcement framing is the user-directive guard.
        assert!(!prompt.system.contains(DIRECTIVE_ENFORCEMENT));
        assert!(!prompt.system.contains(DIRECTIVE_PRECEDENCE));
        // And nothing rides the user message.
        assert!(!prompt.user.contains("语体指令"));
    }

    #[test]
    fn a_directive_rides_the_system_prompt_verbatim_with_enforcement_and_precedence() {
        let directive = "输出将直接用作 AI 提示词:可按逻辑分点、分行组织";
        let prompt = compose_prompt(&request(Some(directive), None, vec![]), Intensity::Full);
        // The user's directive replaces the default register, framed as an
        // order, with the precedence line right under it.
        assert!(!prompt.system.contains("通用书面语"));
        assert!(prompt.system.contains("【目标语体】"));
        assert!(prompt.system.contains(DIRECTIVE_ENFORCEMENT));
        let directive_at = prompt.system.find(directive).expect("directive present");
        let precedence_at = prompt
            .system
            .find(DIRECTIVE_PRECEDENCE)
            .expect("precedence line present");
        let fidelity_at = prompt.system.find("【保真铁律】").expect("fidelity rule");
        assert!(fidelity_at < directive_at);
        assert!(directive_at < precedence_at);
    }

    #[test]
    fn a_directive_is_repeated_at_the_end_of_the_user_message_after_the_terms() {
        let directive = "All English words are in uppercase letters.";
        let mut req = request(Some(directive), None, vec![]);
        req.paragraphs = vec!["第一段".into(), "第二段".into()];
        req.terms = vec!["RESTful".into(), "URL".into()];
        let prompt = compose_prompt(&req, Intensity::Full);
        // The reminder is the LAST block of the user message — after the
        // transcript and after the terms list, whose "以如下拼写为准"
        // would otherwise be the final word on letter-case.
        assert!(
            prompt
                .user
                .ends_with(&format!("{DIRECTIVE_REMINDER}\n{directive}"))
        );
        let terms_at = prompt.user.find("【术语参考】").expect("terms block");
        let reminder_at = prompt
            .user
            .find(DIRECTIVE_REMINDER)
            .expect("reminder present");
        assert!(terms_at < reminder_at);
    }

    #[test]
    fn user_message_joins_paragraphs_and_renders_terms() {
        let mut req = request(None, None, vec!["Kubernetes", "QRS 波群"]);
        req.paragraphs = vec!["第一段".into(), "第二段".into()];
        let prompt = compose_prompt(&req, Intensity::Full);
        assert!(prompt.user.contains("第一段\n\n第二段"));
        assert!(prompt.user.contains("【术语参考】"));
        assert!(prompt.user.contains("- Kubernetes"));
        assert!(prompt.user.contains("- QRS 波群"));
    }

    #[test]
    fn no_terms_section_without_terms() {
        let prompt = compose_prompt(&request(None, None, vec![]), Intensity::Full);
        assert!(!prompt.user.contains("术语参考"));
    }

    // -- the global directive's own layer (ticket 22) -----------------------

    const GLOBAL: &str = "全部输出以简体中文书写,语气克制。";

    #[test]
    fn no_global_directive_leaves_no_trace_of_its_block() {
        let prompt = compose_prompt(&request(None, None, vec![]), Intensity::Full);
        assert!(!prompt.system.contains("【全局指令】"));
        assert!(!prompt.system.contains(GLOBAL_ENFORCEMENT));
        assert!(!prompt.system.contains(GLOBAL_PRECEDENCE));
        assert!(!prompt.user.contains(GLOBAL_REMINDER));
        // The golden files freeze the byte-identity with the pre-global
        // composition; this documents the same contract at unit level.
    }

    #[test]
    fn a_global_directive_blocks_above_the_style_directive_with_its_own_precedence() {
        let prompt = compose_prompt(
            &request(Some("以 Markdown 分条输出"), Some(GLOBAL), vec![]),
            Intensity::Full,
        );
        let global_at = prompt.system.find(GLOBAL).expect("global present");
        let global_precedence_at = prompt
            .system
            .find(GLOBAL_PRECEDENCE)
            .expect("global precedence");
        let fidelity_at = prompt.system.find("【保真铁律】").expect("fidelity rule");
        // The style block's anchor: "【目标语体】" also appears inside the
        // verbatim-preservation rule above, so anchor on the framing only
        // the style block carries.
        let style_at = prompt
            .system
            .find(DIRECTIVE_ENFORCEMENT)
            .expect("style directive");
        // Its own block, framed and ordered: fidelity < global < global
        // precedence < the scenario's block below it.
        assert!(prompt.system.contains(GLOBAL_ENFORCEMENT));
        assert!(fidelity_at < global_at);
        assert!(global_at < global_precedence_at);
        assert!(global_precedence_at < style_at);
    }

    #[test]
    fn a_global_directive_adds_to_the_default_register_it_does_not_replace_it() {
        let prompt = compose_prompt(&request(None, Some(GLOBAL), vec![]), Intensity::Full);
        // No scenario: 【目标语体】 keeps the built-in register — the global
        // directive is purely additive.
        assert!(prompt.system.contains("【目标语体】通用书面语"));
    }

    #[test]
    fn dual_reminders_close_the_user_message_global_first_scenario_last() {
        let style = "以 Markdown 分条输出";
        let prompt = compose_prompt(
            &request(Some(style), Some(GLOBAL), vec!["RESTful"]),
            Intensity::Full,
        );
        // Recency goes to the stronger: the scenario's reminder is the
        // final word, the global's rides just above it.
        assert!(prompt.user.ends_with(&format!(
            "{GLOBAL_REMINDER}\n{GLOBAL}\n\n{DIRECTIVE_REMINDER}\n{style}"
        )));
        let global_reminder_at = prompt.user.find(GLOBAL_REMINDER).expect("global reminder");
        let directive_reminder_at = prompt
            .user
            .find(DIRECTIVE_REMINDER)
            .expect("style reminder");
        assert!(global_reminder_at < directive_reminder_at);
    }

    #[test]
    fn a_global_directive_alone_closes_the_user_message() {
        let prompt = compose_prompt(&request(None, Some(GLOBAL), vec![]), Intensity::Full);
        assert!(
            prompt
                .user
                .ends_with(&format!("{GLOBAL_REMINDER}\n{GLOBAL}"))
        );
    }

    // -- the placeholder branch (ticket 17, ADR-0012) -----------------------

    /// Numbers 1, 2 and 10 with 1 repeated — exercises dedup and numeric
    /// (not lexical) order in one transcript.
    fn pin_request(
        style_directive: Option<&str>,
        global_directive: Option<&str>,
        terms: Vec<&str>,
    ) -> RectifyRequest {
        let transcript = "嗯,发给张三‡1‡,再打开这个文件‡2‡,后来又提了‡1‡和‡10‡一次";
        RectifyRequest {
            raw_transcript: transcript.into(),
            paragraphs: vec![transcript.into()],
            style_directive: style_directive.map(String::from),
            global_directive: global_directive.map(String::from),
            terms: terms.into_iter().map(String::from).collect(),
            prefill: true,
        }
    }

    /// The pass-through twin of [`pin_request`] — same transcript, prefill
    /// off (ADR-0014).
    fn pin_request_off(
        style_directive: Option<&str>,
        global_directive: Option<&str>,
        terms: Vec<&str>,
    ) -> RectifyRequest {
        let mut request = pin_request(style_directive, global_directive, terms);
        request.prefill = false;
        request
    }

    #[test]
    fn placeholder_census_dedupes_and_sorts_numerically() {
        let numbers = census_placeholder_numbers("发给‡2‡再提‡10‡和‡1‡,又提了‡2‡");
        assert_eq!(numbers, vec!["1", "2", "10"]);
    }

    #[test]
    fn placeholder_census_only_accepts_the_exact_sentinel_shape() {
        // Space inside, full-width digits, letters, unclosed pairs, a bare
        // sentinel — none of it is a slot.
        assert!(census_placeholder_numbers("‡ 1‡ ‡１‡ ‡1 x‡ ‡1a‡ ‡‡ 没有记号").is_empty());
        // Adjacent tokens and a multi-digit one all count.
        assert_eq!(
            census_placeholder_numbers("相邻‡1‡‡2‡与多位‡12‡"),
            vec!["1", "2", "12"]
        );
    }

    #[test]
    fn a_sentinel_shape_in_plain_speech_triggers_injection() {
        // The census counts strings, never pin events — RectifyRequest
        // carries none. A shape that merely occurs in the spoken text is
        // a slot all the same (story 20: shape is truth).
        let mut req = request(None, None, vec![]);
        req.raw_transcript = "参考文档里的‡9‡记号".into();
        req.paragraphs = vec!["参考文档里的‡9‡记号".into()];
        let prompt = compose_prompt(&req, Intensity::Full);
        assert!(prompt.system.contains(PLACEHOLDER_RULE));
        assert!(prompt
            .user
            .contains(&format!("{PLACEHOLDER_CENSUS_HEADER}\n- ‡9‡")));
    }

    #[test]
    fn no_pin_prompts_carry_no_placeholder_trace_anywhere() {
        // 【占位符】/【占位符普查】/【预填】 cover every section, precedence
        // variant, reminder and the census; 照常整块吸进预填 covers the
        // light-touch variant's absorption command.
        for (style, global) in [
            (None, None),
            (Some("以 Markdown 分条输出"), None),
            (None, Some(GLOBAL)),
            (Some("以 Markdown 分条输出"), Some(GLOBAL)),
        ] {
            let prompt = compose_prompt(&request(style, global, vec![]), Intensity::LightTouch);
            for text in [&prompt.system, &prompt.user] {
                assert!(!text.contains("【占位符】"), "placeholder trace: {text}");
                assert!(!text.contains("【占位符清单】"), "census trace: {text}");
                assert!(!text.contains("【预填】"), "prefill trace: {text}");
                assert!(
                    !text.contains("照常整块吸进预填"),
                    "light-touch variant trace: {text}"
                );
            }
        }
    }

    #[test]
    fn pin_request_places_the_placeholder_rule_between_fidelity_and_transforms() {
        let prompt = compose_prompt(&pin_request(None, None, vec![]), Intensity::Full);
        let fidelity_at = prompt.system.find("【保真铁律】").expect("fidelity rule");
        let placeholder_at = prompt.system.find("【占位符】").expect("placeholder rule");
        let transforms_at = prompt.system.find("【五类变换】").expect("transforms");
        assert!(fidelity_at < placeholder_at);
        assert!(placeholder_at < transforms_at);
    }

    #[test]
    fn pin_request_appends_the_header_tail_sentinel_exemption() {
        let with_pins = compose_prompt(&pin_request(None, None, vec![]), Intensity::Full);
        assert!(
            with_pins
                .system
                .starts_with(&format!("{HEADER}{PLACEHOLDER_HEADER_TAIL}"))
        );
        let without = compose_prompt(&request(None, None, vec![]), Intensity::Full);
        assert!(without.system.starts_with(HEADER));
        assert!(!without.system.contains(PLACEHOLDER_HEADER_TAIL));
    }

    #[test]
    fn pin_prompts_teach_the_inline_grammar_and_leave_no_prefill_block_trace() {
        // With pins the rule teaches `‡编号:值‡` and the bare form, and
        // the retired 【预填】 block leaves NO trace anywhere — its
        // demand, its reminder mention and its row syntax are all gone
        // (ADR-0013's 块退役, zero residue).
        for intensity in [Intensity::LightTouch, Intensity::Full] {
            let prompt = compose_prompt(
                &pin_request(Some("以 Markdown 分条输出"), Some(GLOBAL), vec![]),
                intensity,
            );
            for text in [&prompt.system, &prompt.user] {
                assert!(!text.contains("【预填】"), "prefill-block trace: {text}");
                assert!(!text.contains("‡:"), "block row syntax trace: {text}");
            }
            assert!(prompt.system.contains("‡编号:值‡"));
            assert!(prompt.system.contains("只写记号本身 ‡编号‡"));
            assert!(prompt.system.contains("预填值里不得出现 ‡,也不得换行"));
            assert!(prompt.user.contains(PLACEHOLDER_REMINDER));
        }
    }

    #[test]
    fn pin_request_rewrites_the_exception_lists_of_both_precedence_tiers_and_reminders() {
        let prompt = compose_prompt(
            &pin_request(Some("以 Markdown 分条输出"), Some(GLOBAL), vec![]),
            Intensity::Full,
        );
        // The pin variants are in, the base lines are out — each base
        // constant differs from its variant, so containment is decisive.
        assert!(prompt.system.contains(DIRECTIVE_PRECEDENCE_PLACEHOLDERS));
        assert!(prompt.system.contains(GLOBAL_PRECEDENCE_PLACEHOLDERS));
        assert!(!prompt.system.contains(DIRECTIVE_PRECEDENCE));
        assert!(!prompt.system.contains(GLOBAL_PRECEDENCE));
        assert!(prompt.user.contains(DIRECTIVE_REMINDER_PLACEHOLDERS));
        assert!(prompt.user.contains(GLOBAL_REMINDER_PLACEHOLDERS));
        assert!(!prompt.user.contains(DIRECTIVE_REMINDER));
        assert!(!prompt.user.contains(GLOBAL_REMINDER));
    }

    #[test]
    fn light_touch_gains_the_absorption_command_only_with_pins() {
        let with_pins = compose_prompt(&pin_request(None, None, vec![]), Intensity::LightTouch);
        assert!(with_pins.system.contains(
            "记号两侧紧挨着槽的名词短语照常整块吸进预填——以把事物名得更完整的一侧为准,两侧各说的是不同事物且都完整就不吸"
        ));
        // The keep-original sentence excludes the absorbed referent by
        // name, so the two demands cannot be read as conflicting.
        assert!(with_pins.system.contains("被吸走的指称不算在内"));
        // Without pins the ban stays absolute; full rectify never carries
        // the command at all — it never forbids 增删 in the first place.
        let without = compose_prompt(&request(None, None, vec![]), Intensity::LightTouch);
        assert!(without.system.contains("禁止增删任何信息。"));
        assert!(!without.system.contains("照常整块吸进预填"));
        let full = compose_prompt(&pin_request(None, None, vec![]), Intensity::Full);
        assert!(!full.system.contains("照常整块吸进预填"));
    }

    #[test]
    fn numerals_rule_stays_byte_identical_with_pins() {
        // The number-normalization rule itself is never rewritten with
        // pins; the numbering exemption lives in the placeholder rule.
        let prompt = compose_prompt(&pin_request(None, None, vec![]), Intensity::Full);
        assert!(prompt.system.contains(NUMERALS));
    }

    #[test]
    fn user_message_orders_census_terms_global_scenario_then_placeholder_reminder_last() {
        let prompt = compose_prompt(
            &pin_request(Some("以 Markdown 分条输出"), Some(GLOBAL), vec!["RESTful"]),
            Intensity::Full,
        );
        let at = |needle: &str| {
            prompt
                .user
                .find(needle)
                .unwrap_or_else(|| panic!("missing {needle} in user message:\n{}", prompt.user))
        };
        assert!(at("【原始转写】") < at("【占位符清单】"));
        assert!(at("【占位符清单】") < at("【术语参考】"));
        assert!(at("【术语参考】") < at(GLOBAL_REMINDER_PLACEHOLDERS));
        assert!(at(GLOBAL_REMINDER_PLACEHOLDERS) < at(DIRECTIVE_REMINDER_PLACEHOLDERS));
        assert!(at(DIRECTIVE_REMINDER_PLACEHOLDERS) < at(PLACEHOLDER_REMINDER));
        // Recency to the strongest rule: the placeholder reminder is the
        // final word, below even the scenario's.
        assert!(prompt.user.ends_with(PLACEHOLDER_REMINDER));
    }

    #[test]
    fn census_table_renders_ascending_bare_sentinel_rows() {
        // One bare-sentinel row per number (the repeated ‡1‡ is one row),
        // numeric order, no value column at all — a pure number anchor.
        let prompt = compose_prompt(&pin_request(None, None, vec![]), Intensity::Full);
        assert!(
            prompt
                .user
                .contains(&format!(
                    "{PLACEHOLDER_CENSUS_HEADER}\n- ‡1‡\n- ‡2‡\n- ‡10‡"
                ))
        );
        assert!(!prompt.user.contains("- ‡1‡:"));
    }

    // -- the pass-through form (ADR-0014) ------------------------------------

    #[test]
    fn prefill_never_touches_the_no_pin_composition() {
        // The hard invariant of the prefill switch: without pins the flag
        // selects nothing — every directive combination and both
        // intensities compose byte-identically either way. ADR-0012's
        // no-pin contract cannot regress through the new key.
        for (style, global) in [
            (None, None),
            (Some("以 Markdown 分条输出"), None),
            (None, Some(GLOBAL)),
            (Some("以 Markdown 分条输出"), Some(GLOBAL)),
        ] {
            for intensity in [Intensity::LightTouch, Intensity::Full] {
                let mut off = request(style, global, vec![]);
                off.prefill = false;
                let on = request(style, global, vec![]);
                let off_prompt = compose_prompt(&off, intensity);
                let on_prompt = compose_prompt(&on, intensity);
                assert_eq!(off_prompt, on_prompt, "prefill leaked into no-pin: {style:?} {global:?}");
            }
        }
    }

    #[test]
    fn prefill_off_composes_the_pass_through_variant_with_zero_inline_trace() {
        // The off form carries its five-bullet rule, the shared header
        // tail and exception rewrites, and its own closing reminder — and
        // not one glyph of the inline grammar: no `‡编号:值‡` anywhere,
        // no census table, no absorption language at all.
        let prompt = compose_prompt(
            &pin_request_off(Some("以 Markdown 分条输出"), Some(GLOBAL), vec![]),
            Intensity::Full,
        );
        // The pass-through rule in, the inline rule out — the two consts
        // differ from the value-grammar bullet down, so full-string
        // containment is decisive.
        assert!(prompt.system.contains(PLACEHOLDER_RULE_OFF));
        assert!(!prompt.system.contains(PLACEHOLDER_RULE));
        assert!(prompt.system.starts_with(&format!("{HEADER}{PLACEHOLDER_HEADER_TAIL}")));
        // The shared exception rewrites: pin variants in, base lines out.
        assert!(prompt.system.contains(DIRECTIVE_PRECEDENCE_PLACEHOLDERS));
        assert!(prompt.system.contains(GLOBAL_PRECEDENCE_PLACEHOLDERS));
        assert!(!prompt.system.contains(DIRECTIVE_PRECEDENCE));
        assert!(!prompt.system.contains(GLOBAL_PRECEDENCE));
        assert!(prompt.user.contains(DIRECTIVE_REMINDER_PLACEHOLDERS));
        assert!(prompt.user.contains(GLOBAL_REMINDER_PLACEHOLDERS));
        assert!(!prompt.user.contains(DIRECTIVE_REMINDER));
        assert!(!prompt.user.contains(GLOBAL_REMINDER));
        // Zero inline-grammar trace in either message: the value shape,
        // the census table, and every absorption word — the off rule, the
        // plain light-touch rule and the precedence lines carry none.
        for text in [&prompt.system, &prompt.user] {
            assert!(!text.contains("‡编号:值‡"), "value grammar trace: {text}");
            assert!(!text.contains("【占位符清单】"), "census trace: {text}");
            assert!(!text.contains("吸收"), "absorption trace: {text}");
            assert!(!text.contains("预填"), "prefill trace: {text}");
        }
        // The pass-through reminder closes the user message, still below
        // the scenario's reminder.
        assert!(prompt.user.ends_with(PLACEHOLDER_REMINDER_OFF));
        assert!(!prompt.user.contains(PLACEHOLDER_REMINDER));
        // Same precedence tier as the inline form: fidelity < the rule <
        // the transforms.
        let fidelity_at = prompt.system.find("【保真铁律】").expect("fidelity rule");
        let placeholder_at = prompt.system.find("【占位符】").expect("off rule");
        let transforms_at = prompt.system.find("【五类变换】").expect("transforms");
        assert!(fidelity_at < placeholder_at);
        assert!(placeholder_at < transforms_at);
    }

    #[test]
    fn prefill_off_light_touch_is_the_plain_rule_verbatim() {
        // No absorption, nothing to carve out of the no-adding-or-dropping
        // ban: the off form's light-touch is the plain rule word for word,
        // both intensities carrying no placeholder variant of their own.
        let light = compose_prompt(&pin_request_off(None, None, vec![]), Intensity::LightTouch);
        assert!(light.system.contains(INTENSITY_LIGHT_TOUCH));
        assert!(light.system.contains("禁止增删任何信息。"));
        assert!(!light.system.contains("照常整块吸进预填"));
        assert!(!light.system.contains("被吸走的指称不算在内"));
        let full = compose_prompt(&pin_request_off(None, None, vec![]), Intensity::Full);
        assert!(full.system.contains(INTENSITY_FULL));
    }
}
