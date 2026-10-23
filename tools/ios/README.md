# iOS 私有游戏输入准备工具

这些工具处理用户自己提供的游戏副本，不包含游戏，不构建完整 IPA。

## PCK 元数据适配

```bash
python3 tools/ios/test_prepare_pck.py -v
python3 tools/ios/prepare_pck.py /private/input/SlayTheSpire2.pck /private/output/SlayTheSpire2-ios-candidate.pck
```

需要 Python 3.10+。只接受未加密、目录位于文件末尾的 Godot PCK format 3。源文件不修改，输出路径必须不存在。输出先在同目录临时文件完成并验证索引 / 修改项 MD5，再发布。

处理范围：

- 从 `.godot/extension_list.cfg` 取消 Sentry 扩展注册。
- 解析 `project.binary` 的 ECFG 属性键，将已知的 `autoload/SentryInit` 或 `autoload/SentryBootstrap` 等长改为无效的 `xutoload/...`；不替换属性值里的同名文本。
- 删除 `addons/sentry/sentry.gdextension` 的索引项，更新被修改资源的长度 / MD5 和索引数量。
- 其他资源保留原偏移；现有 C# 占位资源保留，不按旧项目的固定数量重复添加。

这只是 iOS bring-up 的资源候选准备，不提供 FMOD / Spine 原生库，不完成引擎集成，不证明画面、声音、存档或性能正常。不要把生成的 PCK、程序集、私有索引或游戏资源提交到 GitHub。

该思路参考 [jhaizhou-ops/sts2-ios](https://github.com/jhaizhou-ops/sts2-ios)，核查 commit 为 `be1144212c7d5ac5d6c78fa56f7cb1d969397389`；许可证保留在 `UPSTREAM_LICENSE.txt`。本工具针对新版本的 `SentryBootstrap` 和完整 ECFG 属性边界进行了独立实现与测试。源项目的旧处理脚本只识别 `SentryInit`；本工具同时支持两种键名。

## 最小补丁清单

`core-patches.json` 是上述固定版本 manifest 的 27 项移植基础子集，用于该项目的 STS2Weaver。保留平台、路径、布局、触控、生命周期和 shader 预热补丁；不启用其四倍速、重开、快照或选牌助手入口。这份清单不等于任意版本兼容声明。

该清单仅用于固定上游的源码准备；使用前仍需对目标程序集进行类型、签名、织入与运行验证。公开 CI 只运行合成测试。游戏、私有输入的分析结果及变更后的资产均不入库。
