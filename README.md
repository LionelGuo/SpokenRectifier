# SpokenRectifier

把即兴说出的口语段修正为保真、高信息密度的书面文本的语音输入工具(首发 Windows,未来或扩展其他平台)。

对着它说话可以磕巴、可以停顿思考、可以说"不对,应该是 X"、"再补充一点"——引擎负责应用口头更正、去除冗余、篇章重组与语体转换,产出遵守保真铁律的修正文本:绝不捏造、绝不丢失明确表达的意思。术语表见 [`CONTEXT.md`](CONTEXT.md),架构决策见 [`docs/adr/`](docs/adr/)。

## 当前状态

早期开发中。已落地:**Rust 引擎 crate(命令进、事件出的单一测试缝)与全假件确定性测试、`sr-replay` 脚本回放驱动器、修正管线(`crates/llm`:强度分档 + 保真 prompt + OpenAI 兼容流式客户端)与 `sr-rectify` 真 LLM 演示驱动器、麦克风采集与 VAD(`crates/audio`:cpal 采集 + 能量 VAD,真实 AsrProvider——说话状态、静音语义、设备失效反馈;无声段不判语音即幻觉抑制门)、阿里云端 ASR 适配器(`crates/aliyun`:qwen3-asr-flash-realtime 实时 WebSocket 协议,`[asr]` 配置带 key 即启用——说话段+拖尾静音才上链、断线限次重连补发、部分/最终转写回流引擎;无 key 自动回退纯麦克风模式)、真实插入(`crates/insertion`:剪贴板借还 + Ctrl+V 粘贴,或逐字键入回退——目标窗口记忆/焦点归还、25 秒修正硬上限可见可取消)、Flutter 壳(`app/`:托盘 + 热键 + 悬浮球 + 预览窗,真麦克风;`[llm]` 带 key 即真 LLM 流式修正,预览可编辑、对照原文、reroll;无 key 纯演示模式——`[asr]` 有 key 而 `[llm]` 无 key 直接报错,真转写永不喂假修正)**。

## 布局

```
crates/engine   核心引擎:会话状态机 + Provider trait(ASR / 修正 LLM / 插入器 / 时钟)
crates/audio    麦克风采集 + VAD:cpal 默认输入设备 → 16k mono s16 → 能量 VAD → AsrProvider
crates/aliyun   阿里云端 ASR 适配器:qwen3-asr-flash-realtime 实时 WS 协议、上链门控、断线重连
crates/insertion 真实插入:剪贴板借还 + Ctrl+V 粘贴 / 逐字键入回退,目标窗口记忆与焦点归还(已知边界:管理员/提权目标窗口按 UIPI 规则丢弃模拟按键,两种模式均失效)
crates/llm      修正管线:强度分档、prompt 组装(保真铁律/五类变换)、OpenAI 兼容流式客户端
crates/cli      sr-replay:脚本化假会话回放;sr-rectify:canned 口语段 × 真 LLM 演示;sr-eval:保真金样例评测(真 LLM × 机器断言)
app/            Flutter 壳:托盘常驻、Ctrl+Alt+V 全局热键、悬浮球、预览窗(真麦克风)
app/rust        flutter_rust_bridge 缝:引擎命令/事件流暴露给 Flutter(Bridge* 线类型)
```

引擎公共 API 即测试缝:命令(`StartSession` / `StopSession` / `Cancel` / `ConfirmInsert` / `Reroll` / …)经 `Engine::execute` 进入,事件(`SessionStateChanged` / `LiveTranscriptUpdated` / `ParagraphMarked` / `RectifiedTextChunk` / …)经 `Engine::subscribe` 流出。ASR、LLM、插入器、时钟全部为可注入 trait,全部测试无需网络与真实音频设备。

## 构建与测试

```
cargo build
cargo test          # 一键构建并运行全部确定性测试
cargo clippy --workspace --all-targets
```

## 回放演示

```
cargo run -p sr-replay -- crates/cli/demo-script.txt
```

演示脚本包含两场会话:篇章模式下静音只分段随后取消(零输出),以及完整链路(停止 → 流式修正 → 预览编辑 → 确认插入)。脚本语法见 `crates/cli/src/main.rs` 顶部注释。

## 修正演示(真 LLM,无需麦克风)

```
# 密钥:在仓库根目录创建 spokenrectifier.local.toml(git 忽略),写入
#   [llm]
#   api_key = "sk-..."     # DeepSeek
# 或导出 DEEPSEEK_API_KEY 环境变量。参见 spokenrectifier.example.toml。
cargo run -p sr-replay --bin sr-rectify -- crates/cli/demo-utterance.txt
```

`demo-utterance.txt` 含两场会话:39 字短句(低于阈值 → 轻修)与中长会议口述(全量修正),同一模型、仅 prompt 强度不同,覆盖口头更正、补充、磕巴、中英夹杂与中文数字。修正文本以 token 增量流式打印,随后插入 stdout。

## 保真评测(真 LLM,机器断言)

```
cargo run -p sr-replay --bin sr-eval                    # 全部用例,报告打印 stdout
cargo run -p sr-replay --bin sr-eval -- --only short-   # 只跑一个前缀/一条
cargo run -p sr-replay --bin sr-eval -- --report out.md # 报告另存 markdown
```

金样例评测集(`crates/cli/eval/cases.toml`,23 条,七类覆盖:口头更正/补充/磕巴冗余/中英夹杂/术语/中文数字/短句轻修边界)骑引擎缝逐条跑真 LLM,输出按失败类别(捏造/丢失/过度改写/保留失败/残留)分计的通过率报告;退出码 0/1/2 = 全过/有失败/环境错。追加用例即编辑该文件,零其他改动。基线通过率与已知缺口记录在 [`crates/cli/eval/BASELINE.md`](crates/cli/eval/BASELINE.md);每夜定时入口 `scripts/nightly-eval.sh`(报告落不入库的 `.scratch/eval/`)。

## 配置与密钥

配置分两层:`spokenrectifier.toml`(可入库的共享配置)与 `spokenrectifier.local.toml`(git 忽略,`api_key` 只能放这里,或用各档 `api_key_env` 指定的环境变量);共享文件的任何 section 下出现非空 `api_key` 都会在启动时被拒绝。本地值逐字段覆盖共享值;两个文件各自按「工作目录 → 可执行文件目录」查找。完整 schema 见 [`spokenrectifier.example.toml`](spokenrectifier.example.toml)。

术语词表(工单 08)是同目录下的纯文本文件 `spokenrectifier-terms.txt`(git 忽略):一行一词,`#` 注释;每次会话开始时重读,改完即生效于下一会话。支持识别偏置的 Provider(阿里)把词表注入 ASR 识别;所有 Provider 同时把词表作为修正 prompt 的术语参考(逐字保留)兜底纠错。

语体(工单 09,ADR-0004)只有一种内置默认:通用书面。需要别的语体时,在场景库 `spokenrectifier-scenarios.toml`(与配置文件同目录,git 忽略)自建命名场景,一段名字配一段风格指令:

```toml
[[scenario]]
name = "Prompt"
directive = "输出将直接用作 AI 提示词:信息密度优先,可分点分行,行内代码用反引号"
```

托盘「风格」子菜单与录音展开面板的场景行可随时在「默认」与各场景间切换,立即作用于下一次修正(reroll 同样受影响);选择不持久化,重启回到默认;场景库缺失或损坏按空库处理(面板场景行隐藏、托盘只剩「默认」),不报错不落盘。风格指令只塑形式与语气,保真铁律恒在其上。托盘「打开配置文件」在系统编辑器里打开共享配置(不存在时先落一个带注释的桩文件)。配置校验:未知 vendor、空 model/base_url、配了端点却没有可解析的 key,都在启动横幅给出明确报错,不会静默回退演示模式。

## 许可

计划采用 Apache-2.0,MVP 后公开源码。
