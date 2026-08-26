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
【逐字保留】术语、产品名、代码、URL、英文缩写、数字与单位,一律逐字保留,不得改写、翻译或\"纠正\"拼写。若下方给出术语参考,以其拼写为准。";

const NUMERALS: &str = "\
【中文数字规范化】口语数字读法转为标准书面形式:\"百分之三十\"→\"30%\",\"一百二十万\"→\"120万\",\"六月二十一号\"→\"6月21日\";成语、习语与专有名词中的数字保持原样;拿不准时保留原样。";

const INTENSITY_LIGHT_TOUCH: &str = "\
【整理强度】轻修(本次输入较短):只做第 1、2、3 类变换与数字规范化、标点修正。禁止改变句序,禁止合并或拆分句子,禁止改写措辞风格,禁止增删任何信息。用户的原措辞与表达顺序尽量原样保留。";

const INTENSITY_FULL: &str = "\
【整理强度】全量修正(本次输入为中长段):五类变换全部执行,允许篇章级逻辑重组、句序调整、合并与压缩提密,产出结构清晰、信息密度高的书面文本;铁律仍然优先。";

/// The single built-in default register (通用书面), used whenever no
/// scenario directive is selected.
const DEFAULT_REGISTER: &str = "通用书面语:清晰、准确、自然的现代书面汉语。";

/// The line that rides a user's style directive, right under it: the
/// directive shapes form and tone only, and the fidelity rule above
/// outranks it — stated where the model reads the directive, not just in
/// the rule block far above (ADR-0004: 铁律恒高于自定义指令).
const DIRECTIVE_SUBORDINATION: &str = "(语体指令只塑造形式与语气;与【保真铁律】或任何其他规则冲突时,一律以铁律为准,不得因此增删或改写事实内容)";

fn intensity_directive(intensity: Intensity) -> &'static str {
    match intensity {
        Intensity::LightTouch => INTENSITY_LIGHT_TOUCH,
        Intensity::Full => INTENSITY_FULL,
    }
}

/// Compose the full chat prompt for one rectify request.
pub fn compose_prompt(request: &RectifyRequest, intensity: Intensity) -> ChatPrompt {
    let style_line = match &request.style_directive {
        None => format!("【目标语体】{DEFAULT_REGISTER}"),
        Some(text) => format!("【目标语体】{text}"),
    };
    let mut system = [
        HEADER,
        "",
        FIDELITY_RULE,
        "",
        TRANSFORMS,
        "",
        SELF_CORRECTION,
        "",
        VERBATIM,
        "",
        NUMERALS,
        "",
        intensity_directive(intensity),
        "",
        style_line.as_str(),
    ]
    .join("\n");
    if request.style_directive.is_some() {
        system.push('\n');
        system.push_str(DIRECTIVE_SUBORDINATION);
    }

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

    ChatPrompt { system, user }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(style_directive: Option<&str>, terms: Vec<&str>) -> RectifyRequest {
        RectifyRequest {
            raw_transcript: "嗯你好世界".into(),
            paragraphs: vec!["嗯你好世界".into()],
            style_directive: style_directive.map(String::from),
            terms: terms.into_iter().map(String::from).collect(),
        }
    }

    #[test]
    fn system_prompt_carries_the_fidelity_rule_and_all_transforms() {
        let prompt = compose_prompt(&request(None, vec![]), Intensity::Full);
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
        let prompt = compose_prompt(&request(None, vec![]), Intensity::LightTouch);
        let intensity = INTENSITY_LIGHT_TOUCH;
        assert!(intensity.contains("禁止改变句序"));
        assert!(intensity.contains("禁止改写措辞风格"));
        assert!(prompt.system.contains("轻修"));
        assert!(!prompt.system.contains("全量修正"));
    }

    #[test]
    fn full_rectify_allows_reorganization() {
        let prompt = compose_prompt(&request(None, vec![]), Intensity::Full);
        assert!(INTENSITY_FULL.contains("允许篇章级逻辑重组"));
        assert!(prompt.system.contains("全量修正"));
    }

    #[test]
    fn no_directive_means_the_default_register_without_subordination() {
        let prompt = compose_prompt(&request(None, vec![]), Intensity::Full);
        assert!(prompt.system.contains("通用书面语"));
        // The built-in register is engine-owned and consistent with the
        // rules; the subordination line is the user-directive guard.
        assert!(!prompt.system.contains(DIRECTIVE_SUBORDINATION));
    }

    #[test]
    fn a_directive_rides_the_prompt_verbatim_and_subordinates_to_the_fidelity_rule() {
        let directive = "输出将直接用作 AI 提示词:可按逻辑分点、分行组织";
        let prompt = compose_prompt(&request(Some(directive), vec![]), Intensity::Full);
        assert!(prompt.system.contains(&format!("【目标语体】{directive}")));
        // The user's directive replaces the default register line, and the
        // fidelity rule is restated right under it.
        assert!(!prompt.system.contains("通用书面语"));
        assert!(prompt.system.contains(DIRECTIVE_SUBORDINATION));
        let subordination_at = prompt
            .system
            .find(DIRECTIVE_SUBORDINATION)
            .expect("subordination line present");
        let directive_at = prompt.system.find(directive).expect("directive present");
        let fidelity_at = prompt.system.find("【保真铁律】").expect("fidelity rule");
        assert!(fidelity_at < directive_at);
        assert!(directive_at < subordination_at);
    }

    #[test]
    fn user_message_joins_paragraphs_and_renders_terms() {
        let mut req = request(None, vec!["Kubernetes", "QRS 波群"]);
        req.paragraphs = vec!["第一段".into(), "第二段".into()];
        let prompt = compose_prompt(&req, Intensity::Full);
        assert!(prompt.user.contains("第一段\n\n第二段"));
        assert!(prompt.user.contains("【术语参考】"));
        assert!(prompt.user.contains("- Kubernetes"));
        assert!(prompt.user.contains("- QRS 波群"));
    }

    #[test]
    fn no_terms_section_without_terms() {
        let prompt = compose_prompt(&request(None, vec![]), Intensity::Full);
        assert!(!prompt.user.contains("术语参考"));
    }
}
