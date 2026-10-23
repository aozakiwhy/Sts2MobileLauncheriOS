# iOS 移植设计与验收

## 事实与交付边界

本仓库原有可用平台是 Android。`ios/` 是新增的原生版本管理器基础工程，**没有完成游戏运行时移植**。Android 的 Godot 模板、Mono native library、FMOD AAR、JNI 与 Harmony patch 后端均不能直接链接进 iOS App。

Godot 文档确认 C# iOS 导出仍有实验性限制，导出需要 macOS。引擎支持 C# iOS 导出并不证明它能够在 iPhone 上动态加载 PC 程序集、运行 Android 补丁或任意模组。NativeAOT、Mono 解释执行 / AOT、自定义运行时路线需要独立验证；不能把普通侧载签名当作已经获得 JIT 或动态代码能力。

Apple App Review 2.5.2 对下载并执行改变 App 功能的代码有约束。因此“任意下载历史游戏 DLL + 任意 C# 模组”不能直接承诺作为 App Store 发行方案。开发签名、侧载及任何特别运行环境也需要分别验证技术能力，不能用来推断商店审核结果。

## 当前目录与协议

`ios/Core` 是无网络依赖的 Swift package，`ios/App` 是 SwiftUI 壳。所有记录位于 App 私有 Application Support 下的 `Sts2Launcher`：

- `library.json`：schema 1，payload / profile 元数据与 selected profile UUID。
- `payloads/<payload UUID>/game/`：私有导入副本，版本标签仅展示，不用于构造路径。
- `instances/<profile UUID>/default/1/`：独立游客 account root。
- `instances/<profile UUID>/mods/`：独立模组目录，当前不导入或执行模组。
- `staging/<UUID>/`：复制与验证事务；取消 / 普通失败清理。

不同版本始终隔离。当前没有 Steam ID 映射、全局存档合并、云同步、快照恢复或 Android 数据迁移。后续增加这些功能不能更改旧版本目录或静默合并 normal / modded 存档。

## 分阶段验收

### 1. 原生版本管理器（本次基础代码）

核心 XCTest 覆盖安装 / 选择 / 重启、存档根隔离、无效 PCK、缺文件、符号链接拒绝、索引损坏、索引写失败回滚、取消、重叠目录、无符号 64 位 Manifest ID 和未接 runtime 拒绝启动。macOS CI 应执行 `swift test` 与 iOS 模拟器编译。仍需实体设备 / Files provider 的 UI 和大文件取消 smoke。

### 用户设备与交付方向

目标设备：用户提供 iPhone 15 Pro，系统描述为 iOS 26 / 27；用户本地没有 Mac / Xcode，使用 IPA 安装。当前 CI 已增加 ARM64 真机未签名 IPA 交付，签名由用户安装工具完成；具体系统小版本 / build 与签名工具仍待确认。未进行该设备实测，不承诺未来或未验证系统的兼容性。

这决定构建放在 GitHub 的 macOS runner，不能以要求用户安装本地 Xcode 作为唯一交付路径。运行时研究优先评估普通签名环境可用的解释执行 / AOT 方案；不得假定安装 IPA 自动获得 JIT。Microsoft NativeAOT 文档明确不支持动态 Assembly.LoadFile，因此它不能直接满足任意历史游戏 DLL 和 C# 模组动态加载。Mono 解释执行与 Harmony 动态补丁的兼容性仍需单独实证，不能仅开启 UseInterpreter 就宣布移植成功。

### 2. 最小运行时验证（阻塞游戏启动）

需要 macOS + Xcode、目标 iPhone 的 iOS 版本与芯片、预期签名 / 安装方式；这些信息决定可用的运行时路线。先构建有触摸、音频与生命周期处理的合成 Godot C# 场景，分别记录：

- ARM64 Mach-O 的原生依赖和 Godot / GodotSharp ABI 匹配。
- 选定运行时是否支持动态程序集、反射、泛型实例化、Harmony / MonoMod 动态补丁。
- FMOD iOS SDK 与游戏音频版本一致，Spine / 图形插件是否有可用 iOS 构建。
- 前后台切换、音频打断、横屏 / 安全区、内存压力和触控映射。

只有合成验证通过才接入用户本地游戏。游戏验收至少覆盖主菜单、开始单人战斗、保存、退出、重新进入读档，不能以启动页或首帧截图代替。

### 3. Steam 原生接入

参考 Android 的 `steam-protocol`、`steam-content`、`steam/auth`、`steam/cloud` 和 `steam/download`；它们是 Java/Kotlin / protobuf / native 压缩代码，不能从 Swift 直接调用 Android JNI。需要选择 iOS 可构建的协议实现或移植，验证端到端鉴权与传输。

- 登录 / Guard / 取消 / 超时 / 账号切换需隔离旧回调；刷新令牌仅存 Keychain，不把令牌交给网页或 MOD。
- OpenID 只证明身份，不能当作 Steam Cloud / depot 授权。
- SteamPipe 通过拥有权与 depot 授权下载，精确 Manifest 使用 `UInt64` / 十进制字符串，无权限 / 不存在时明确失败，不能回退最新版。
- 历史目录与可下载性分开建模。即使列出某个历史版本，也不表示 Steam 仍提供该快照或当前账号有权限。
- Cloud 基于当前 profile account root，白名单 normal / modded 分开；拉取前备份，基于共同祖先检测冲突，部分失败不能推进全部 baseline。

### 4. 模组与多版本运行

先实现公开列表 / item 元数据，再实现带授权的实际内容下载、hash 校验、前置依赖、隔离 staging、明确冲突确认与安装索引。只有选定运行时实际验证 C# / Harmony 能力后才启用加载。每个游戏版本与模组组合需要单独标记支持状态，Android compatibility target 不得自动视为 iOS 支持证明。

## 官方参考

- [Godot C# 平台支持](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/index.html)
- [Godot iOS 导出](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html)
- [Apple App Review Guidelines，2.5.2](https://developer.apple.com/app-store/review/guidelines/)
- [Steam ICloudService](https://partner.steamgames.com/doc/webapi/ICloudService)
- [.NET NativeAOT 限制](https://learn.microsoft.com/dotnet/core/deploying/native-aot/)
- [.NET iOS 解释执行](https://learn.microsoft.com/dotnet/maui/macios/interpreter)
- [Apple 已注册设备分发](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)

这些资料限定设计边界，不构成本项目已通过真机测试、取得分发授权或通过审核的证明。
