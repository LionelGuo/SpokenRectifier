# SpokenRectifier

把即兴说出的口语段修正为保真、高信息密度的书面文本的语音输入工具(首发 Windows,未来或扩展其他平台)。

对着它说话可以磕巴、可以停顿思考、可以说"不对,应该是 X"、"再补充一点"——引擎负责应用口头更正、去除冗余、篇章重组与语体转换,产出遵守保真铁律的修正文本:绝不捏造、绝不丢失明确表达的意思。术语表见 [`CONTEXT.md`](CONTEXT.md),架构决策见 [`docs/adr/`](docs/adr/)。

## 当前状态

早期开发中。已落地:**Rust 引擎 crate(命令进、事件出的单一测试缝)与全假件确定性测试、`sr-replay` 脚本回放驱动器、修正管线(`crates/llm`:强度分档 + 保真 prompt + OpenAI 兼容流式客户端)与 `sr-rectify` 真 LLM 演示驱动器、麦克风采集与 VAD(`crates/audio`:cpal 采集 + 能量 VAD,真实 AsrProvider——说话状态、静音语义、设备失效反馈;无声段不判语音即幻觉抑制门)、Flutter 壳(`app/`:托盘 + 热键 + 悬浮球 + 预览窗,真麦克风驱动,转写文本待 ASR 适配器)**。真实 ASR 适配器尚未开始。

## 布局

```
crates/engine   核心引擎:会话状态机 + Provider trait(ASR / 修正 LLM / 插入器 / 时钟)
crates/audio    麦克风采集 + VAD:cpal 默认输入设备 → 16k mono s16 → 能量 VAD → AsrProvider
crates/llm      修正管线:强度分档、prompt 组装(保真铁律/五类变换)、OpenAI 兼容流式客户端
crates/cli      sr-replay:脚本化假会话回放;sr-rectify:canned 口语段 × 真 LLM 演示
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

## 配置与密钥

配置分两层:`spokenrectifier.toml`(可入库的共享配置)与 `spokenrectifier.local.toml`(git 忽略,`api_key` 只能放这里,或用各档 `api_key_env` 指定的环境变量);本地值逐字段覆盖共享值。完整 schema 见 [`spokenrectifier.example.toml`](spokenrectifier.example.toml)。

## 许可

计划采用 Apache-2.0,MVP 后公开源码。
