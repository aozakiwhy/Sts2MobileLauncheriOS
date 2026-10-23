# iOS 启动器开发预览

**这是原生版本管理器基础工程，尚不能运行《杀戮尖塔 2》，不是已完成的游戏移植，也没有可玩的 IPA。**

## 当前功能

- SwiftUI 原生 iPhone / iPad 界面，最低 iOS 16。
- 无需登录的本地版本库：通过系统文件选择器导入**已解压的 PC 游戏根目录**。
- 分块复制到私有 staging，检查必需文件、PCK / PE 文件头与版本信息，计算 PCK 和 DLL 的 SHA-256。
- 每次导入生成独立 UUID、存档目录与模组目录。切换仅修改选中配置，不复制游戏或覆盖其他配置。
- 安装失败 / 取消回滚，索引原子写入；损坏索引报错并保留原文件，不静默重置。
- 拒绝符号链接、特殊文件、大小写 / Unicode 归一化重名、重叠来源目录，限制总计 16 GiB / 100,000 个条目。
- 提供 Steam 创意工坊的**浏览器链接**，不提供原生下载。

文件头检查仅确认基本容器形态，不是完整 PCK / 程序集验证或兼容认证。当前导入器不修改、加载、执行 PC 文件，也不复用 Android 的 PCK patch。

## 尚未实现

| 用户目标 | 当前状态 / 必要工作 |
| --- | --- |
| 游客本地游玩 | 只有游客版本管理；缺少可运行游戏的 iOS 引擎与兼容层 |
| Steam 登录 / Steam Guard | 未实现，不采集密码或令牌 |
| Steam Cloud 存档 | 未实现；需要有效授权会话、正确的云文件协议、冲突检测与拉取前备份 |
| 在线下载历史版本 | 未实现；需移植 SteamPipe、校验拥有权和 depot 授权；不能保证所有历史 Manifest 可访问 |
| 创意工坊原生下载 | 未实现；网页浏览不等于下载 / 订阅接口 |
| 普通 C# 模组运行 | 未实现；需验证动态代码、Harmony / MonoMod、原生依赖与每个游戏版本 |
| 游戏启动 | 明确拒绝启动，不使用计时器或假成功替代运行时 |

浏览器 Steam OpenID 身份不能代替游戏 depot / Steam Cloud 授权。游客可以导入自己合法获得的本地文件；游客在线下载本体需要另外存在且有权分发的来源，本工程未配置此类来源。

## 在 macOS 构建

安装完整 Xcode 并完成首次启动 / SDK 安装。XcodeGen 仅用于生成项目，不作为 App 运行时依赖：

```bash
brew install xcodegen
cd ios/Core
swift test
cd ..
xcodegen generate
xcodebuild -project Sts2Launcher.xcodeproj -scheme Sts2Launcher \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open Sts2Launcher.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中选择自己的 Development Team、唯一 Bundle ID 和连接的 iPhone，再点击 Run。生成的工程不包含签名团队 / 私钥。模拟器 `.app` 不能安装到 iPhone，也不是 IPA。设备 IPA 需要在 macOS 使用匹配的签名配置归档与导出，不能在 Linux 环境生成并验证。

`.github/workflows/ios.yml` 配置 macOS 核心测试与模拟器编译，产物名称为 `ios-simulator-preview`。工作流通过只代表版本管理器编译 / 测试通过，不代表游戏可玩。私有游戏文件不进入 CI。

## 手动检查

1. 在模拟器或 iPhone 上打开 App，首页应明确提示“目前无法启动游戏”。
2. 在“文件”App 解压自己已拥有的游戏包。选择直接包含 `SlayTheSpire2.pck`、`release_info.json` 和 `data_sts2_windows_x86_64` 的目录，导入时保持前台。
3. 导入两个不同版本，切换选中项，关闭 / 重新打开 App 检查选择保留。
4. 使用缺少必需文件的目录验证拒绝导入且旧版本仍保留。大文件导入时点击取消或切到后台，回到前台确认没有新增版本。
5. Steam 页应明确显示未接通；模组页只能跳转浏览器，不应出现“下载完成”或游戏启动成功。

进程被系统强制终止时可能留下未被索引的 staging / payload 目录；当前不自动删除这些目录或猜测恢复。首次运行没有模拟版本条目。

## 后续移植门槛

详见 [iOS 移植设计与验收](../doc/plan/ios-port.md)。首先用不含商业内容的最小 Godot C# 场景在实体 iPhone 验证运行时，再接入本地游戏。Android `.so` / AAR 和 Harmony 补丁不能重命名后作为 iOS runtime 使用。

## 开发参考

数据分层参考本仓库 `PayloadManager` / `LaunchProfileManager` 的 payload 与 profile 边界，iOS 存储格式独立，不读取 Android 私有索引。工程生成工具为 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（MIT）；其代码不打入 App。
