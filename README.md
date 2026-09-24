# SpokenRectifier

SpokenRectifier(口语滤波器)是一个 Windows 语音输入工具:把即兴说出的口语段修正为保真、高信息密度的书面文本,并直接插入你正在输入的地方。

> Speak naturally — SpokenRectifier turns impromptu, self-corrected speech into faithful written text, and types it right where you were typing.

对着它说话可以磕巴、可以停顿思考、可以说「不对,应该是 X」「再补充一点」:引擎负责应用口头更正、去除冗余、重组篇章与转换语体,产出遵守保真铁律的修正文本——绝不捏造,绝不丢失明确表达的意思。

## 工作方式

1. 光标落在任意输入处,按 `Ctrl+Alt+V`(默认主流程热键)开始录入;
2. 随意地说——篇章模式下静音只分段、不结束会话,可以边想边说;
3. 再按一次热键结束录入,修正文本流式生成;
4. 预览里就地编辑、填写占位符、重生成,满意后确认;
5. 文本插入回你最初所在的输入处(粘贴或逐字键入)。

悬浮球的左键点按与热键同构;托盘菜单提供显示开关、场景切换、配置入口与清空历史。

## 特性

- **篇章模式**:长停顿只标记分段,会话由你显式结束,无压力口述长内容;
- **口头更正按语义合并**:「不对,应该是 X」「再补充一点」直接生效,不出现在成文里;
- **保真铁律**:修正只删真正的冗余,拿不准时保留;语体与密度永远让位于保真;
- **占位符钉入**:聆听中按 `Alt+B` 在此刻钉一个槽,预览阶段就地补值,修正器尽量给出预填初值;
- **两档整理强度**:短句轻修(去口头语、应用口头更正,不改篇章结构与措辞)、中长段全量修正;字数阈值、思考策略均可调;
- **快速模式**:`Ctrl+Alt+V` 按住不放越过阈值,本场升级为直通——松开即结束,流完自动插入,无预览(默认关闭,设置中开启);
- **多供应商,自带密钥**:ASR 内置阿里云、火山引擎、腾讯云适配器;修正走任一 OpenAI 兼容端点(DeepSeek、通义、火山方舟、OpenAI、自建网关);
- **术语词表与场景**:领域术语注入识别与修正;命名场景(目标语体)随时切换,指令只塑形式与语气;
- **历史与取回**:已插入会话仅文本、仅本机留存,可复制原文、可送回重跑;保留期可调,可一键清空,也可完全不留存;
- **悬浮球 / 全局热键 / 托盘**三种入口;开机自启可在设置中开关;
- **音频永不落盘**。

## 安装

从仓库的 Releases 页下载任一附件:

- `SpokenRectifier-Setup-x.y.z.exe` —— 安装器,按用户安装(不需要管理员权限)。安装页的「开机自启」勾选项默认不勾,装后随时在应用内开关;
- `SpokenRectifier-x.y.z-win64.zip` —— 免安装版,解压到任意目录后运行其中的 `spokenrectifier_app.exe`。

**SmartScreen 提示**(二进制未签名,发布早期为常态):

- 弹出「Windows 已保护你的电脑」:点「更多信息」→「仍要运行」;装一次即收敛;
- Windows 11 若开启了「智能应用控制」,会被直接拦截且没有「仍要运行」:到「Windows 安全中心 → 应用和浏览器控制 → 智能应用控制设置」关闭后再安装。

## 密钥配置(自带 key)

识别与修正各需要一个云服务密钥,费用直接产生在你自己的云账号上——本项目不内置、不代理、不中转任何密钥或流量。

| 用途 | 默认预设 | 其他选择 |
| --- | --- | --- |
| 修正 LLM | DeepSeek(`deepseek-flash`) | 任一 OpenAI 兼容端点:通义、火山方舟、OpenAI、自建网关 |
| 云 ASR | 阿里云百炼(`qwen3-asr-flash-realtime`) | 火山引擎、腾讯云 |

两种配法:

1. **图形界面(推荐)**:悬浮球右键 → 快捷面板 →「打开设置」→「模型与连接」页,选供应商、填 API 密钥,保存即落盘;
2. **配置文件**:密钥只允许住在 `spokenrectifier.local.toml`(git 已忽略)或各供应商的环境变量(如 `DASHSCOPE_API_KEY`、`DEEPSEEK_API_KEY`)。配置分「可入库共享层 + 本地覆盖层」两层逐字段合并;完整 schema 与全部可调项见 [`spokenrectifier.example.toml`](spokenrectifier.example.toml),托盘「打开配置文件」会在系统编辑器里打开共享配置(不存在时先生成带注释的桩文件)。

未配置密钥时应用可启动,但不会产出修正文本。

## 使用

- **热键**:`Ctrl+Alt+V` 步进主流程(开始 → 结束并修正 → 确认插入),可在设置「通用」页改绑;
- **悬浮球**:左键与热键点按同构;空闲时右键展开快捷面板(修正三档高频点选、场景与历史入口);面板展开后就地变形为锚点钮,可拖动搬家;
- **场景**:托盘「场景」子菜单或录音面板的场景行切换目标语体,默认通用书面;场景在设置窗口「场景」页增删改;
- **术语**:设置窗口「术语」页维护领域词表,注入识别与修正;
- **历史**:长按空闲悬浮球,或快捷面板「全部历史与管理」;仅文本、仅本机,默认保留 30 天。

## 隐私

- **音频**:仅实时送你所配置的 ASR 供应商做识别,本机不落盘、不缓存;
- **文本**:原始转写与修正文本随修正请求送你所配置的 LLM 供应商;本地历史仅文本、仅本机,可在设置中缩短保留、一键清空或完全不留存(不留存开启即清空既有);
- 无账号、无遥测、无云同步;除你配置的云服务外,不与任何服务器通信。

## 已知限制

- **管理员(提权)目标窗口**:Windows UIPI 拦截普通进程的模拟按键,粘贴与键入两种插入模式对提权窗口均无效——系统安全边界,与安装形态无关;
- Windows 11「智能应用控制」开启态会硬拦未签名程序,见安装节;
- 仅支持 Windows 10/11(x64),界面语言为简体中文;
- 单次修正有硬上限(默认 25 秒,可配置),超时可见、可取消,重生成获得新的时限。

## 从源码构建

前置:Rust(rustup 按 `rust-toolchain.toml` 自动安装固定版本)、Flutter 3.47.x stable、Visual Studio「使用 C++ 的桌面开发」工作负载。

```
cargo test --workspace        # Rust 侧全部确定性测试(无需网络与音频设备)
cd app
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

产物在 `app/build/windows/x64/runner/Release/`。Flutter 与 Rust 之间的桥接生成物已提交,仅当改动 `app/rust` 的 API 缝时才需要本地重跑 codegen。

配置文件按「工作目录 → 可执行文件目录」顺序查找:开发运行时即仓库根目录,安装运行时即安装目录。

## 仓库布局与开发工具

```
crates/engine     核心引擎:会话状态机 + Provider trait(ASR / 修正 LLM / 插入器 / 时钟)
crates/audio      麦克风采集 + 能量 VAD
crates/asr        ASR 多供应商配置与 schema
crates/aliyun     阿里云实时 ASR 适配器(qwen3-asr-flash-realtime WS 协议)
crates/volcengine 火山引擎 ASR 适配器
crates/tencent    腾讯云 ASR 适配器
crates/insertion  真实插入:剪贴板借还 + Ctrl+V 粘贴 / 逐字键入回退
crates/llm        修正管线:强度分档、保真 prompt、OpenAI 兼容流式客户端
crates/store      本机业务库(SQLite:历史、术语、场景)
crates/config     分层配置加载与写回
crates/cli        sr-replay / sr-rectify / sr-eval 驱动器
crates/eval       保真评测:金样例、机器断言、报告
app/              Flutter 壳(托盘、热键、悬浮球、面板、设置窗)
app/rust          flutter_rust_bridge 缝:引擎命令/事件流暴露给 Flutter
```

引擎公共 API 即测试缝:命令(`StartSession` / `StopSession` / `Cancel` / `ConfirmInsert` / `Reroll` / …)经 `Engine::execute` 进入,事件经 `Engine::subscribe` 流出;ASR、LLM、插入器、时钟全部为可注入 trait,测试无需网络与真实音频设备。

常用驱动器:

```
cargo run -p sr-replay -- crates/cli/demo-script.txt                        # 脚本回放(无网络、无麦克风)
cargo run -p sr-replay --bin sr-rectify -- crates/cli/demo-utterance.txt    # 真 LLM 修正演示
cargo run -p sr-replay --bin sr-eval                                        # 保真金样例评测
```

评测集与基线记录在 [`crates/eval/`](crates/eval/)。

## 许可

[Apache-2.0](LICENSE)
