# SpokenRectifier 壳(Flutter)

托盘常驻的 Windows 桌面壳,经 flutter_rust_bridge 接 Rust 引擎,当前由假 Provider 驱动:
按下热键后,从录音(脚本化"语音"喂数)到流式修正、预览确认/取消的完整流程在真窗口里可见。

## 交互

- **全局热键 `Ctrl+Alt+V`**:空闲 → 开始录音;录音 → 结束并修正;预览 → 确认插入。
- **悬浮球**:空闲灰球(点击开始);录音红球呼吸动画(点击展开转写面板);可从托盘菜单或托盘图标点击开关。
- **录音面板**:流式转写(分段以换行呈现)、段落计数、结束/取消。
- **修正中**:卡片内流式显示逐字到达的修正文本。
- **预览窗**:可编辑文本;`Enter`(字段未聚焦时)或热键确认,`Esc` 取消,可重新生成;确认后回到悬浮球并闪现"已插入"。

## 构建与运行(Windows)

前置:Flutter SDK(stable,含 Windows 桌面)、Rust 工具链、Visual Studio 2022(含 C++ 桌面开发)。

```
cd app
flutter run -d windows
```

Rust 侧(`rust/` 桥接 crate 及其依赖)由 cargokit 在构建中自动编译,无需手动 cargo build。

## 开发(改桥接 API 后重新生成绑定)

```
cargo install flutter_rust_bridge_codegen   # 一次性
cd app
flutter_rust_bridge_codegen generate
flutter analyze && flutter test
```

桥接 API 在 `rust/src/api/`(按域一文件:engine/demo/state 与各设置面;`Bridge*` 线类型与
引擎类型解耦,`api.rs` 门面再导出);UI 逻辑全部在
`lib/app_state.dart` + `lib/app_root.dart`,经 `SpeechEngineGateway` 注入,widget 测试用纯 Dart
假网关(`test/fake_gateway.dart`),不依赖 Rust 动态库。
