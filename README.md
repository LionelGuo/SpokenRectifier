# SpokenRectifier

把即兴说出的口语段修正为保真、高信息密度的书面文本的语音输入工具(首发 Windows,未来或扩展其他平台)。

对着它说话可以磕巴、可以停顿思考、可以说"不对,应该是 X"、"再补充一点"——引擎负责应用口头更正、去除冗余、篇章重组与语体转换,产出遵守保真铁律的修正文本:绝不捏造、绝不丢失明确表达的意思。术语表见 [`CONTEXT.md`](CONTEXT.md),架构决策见 [`docs/adr/`](docs/adr/)。

## 当前状态

早期开发中。已落地:**Rust 引擎 crate(命令进、事件出的单一测试缝)与全假件确定性测试、`sr-replay` 脚本回放驱动器**。真实 ASR 适配器、修正管线、Flutter 壳尚未开始。

## 布局

```
crates/engine   核心引擎:会话状态机 + Provider trait(ASR / 修正 LLM / 插入器 / 时钟)
crates/cli      sr-replay:脚本化假会话回放驱动器,打印完整事件流
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

## 配置与密钥

本地密钥配置文件(`*.local.toml`,如 `spokenrectifier.local.toml`)被版本控制忽略,永不入库;参见 [`spokenrectifier.example.toml`](spokenrectifier.example.toml)。配置 schema 将随配置体系工作定稿。

## 许可

计划采用 Apache-2.0,MVP 后公开源码。
