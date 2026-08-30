//! Prompt composition for rectify (glossary: 修正, 保真铁律, 风格指令).
//!
//! The system prompt carries the fidelity rule and every transform rule;
//! intensity and the style directive inject their own lines; terms render
//! as a reference list in the user message. Composition is pure and
//! deterministic — golden tests freeze the exact text.

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

fn intensity_directive(intensity: Intensity) -> &'static str {
    match intensity {
        Intensity::LightTouch => INTENSITY_LIGHT_TOUCH,
        Intensity::Full => INTENSITY_FULL,
    }
}

/// Compose the full chat prompt for one rectify request.
pub fn compose_prompt(request: &RectifyRequest, intensity: Intensity) -> ChatPrompt {
    let mut system_sections: Vec<String> = vec![
        HEADER.into(),
        String::new(),
        FIDELITY_RULE.into(),
        String::new(),
        TRANSFORMS.into(),
        String::new(),
        SELF_CORRECTION.into(),
        String::new(),
        VERBATIM.into(),
        String::new(),
        NUMERALS.into(),
        String::new(),
        intensity_directive(intensity).into(),
        String::new(),
    ];
    // The global directive's own block, one step above 【目标语体】 in the
    // precedence order — absent entirely when unset, so the prompt stays
    // byte-identical to the pre-global composition.
    if let Some(text) = &request.global_directive {
        system_sections.push(format!(
            "【全局指令】{GLOBAL_ENFORCEMENT}\n{text}\n{GLOBAL_PRECEDENCE}"
        ));
        system_sections.push(String::new());
    }
    match &request.style_directive {
        None => system_sections.push(format!("【目标语体】{DEFAULT_REGISTER}")),
        Some(text) => system_sections.push(format!(
            "【目标语体】{DIRECTIVE_ENFORCEMENT}\n{text}\n{DIRECTIVE_PRECEDENCE}"
        )),
    }
    let system = system_sections.join("\n");

    let mut user = format!("【原始转写】\n{}", request.paragraphs.join("\n\n"));
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
        user.push_str(&format!("\n\n{GLOBAL_REMINDER}\n{text}"));
    }
    if let Some(text) = &request.style_directive {
        user.push_str(&format!("\n\n{DIRECTIVE_REMINDER}\n{text}"));
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
}
