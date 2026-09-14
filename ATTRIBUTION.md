# 来源与致谢 / Attribution

## 原项目：Codenotch

本仓库基于 [vinzdg/codenotch](https://github.com/vinzdg/codenotch)，原作者为
Vinz，其他贡献者记录在 Git 历史中。应用框架、刘海视觉设计与动画、额度读取、
会话提醒、原有图标及未修改的功能均来自上游。

派生起点为上游提交
[`6c28672`](https://github.com/vinzdg/codenotch/commit/6c28672c300fadcb7fb59a277ba9d3997d74f1d2)。
本仓库保留该提交及之前的历史，完整保留 [MIT 许可证](LICENSE) 和
`Copyright (c) 2026 Vinz` 声明。新增代码同样按 MIT 许可证提供。

This is an unofficial derivative of **Codenotch by Vinz and its contributors**.
The upstream implementation, design, assets, history, and copyright remain
attributed to their original authors. Our additions use the same MIT license.

## 本仓库的修改

- 完善 macOS 简体中文界面。
- 新增 Claude Code / Codex 每日 Token 明细、账户筛选、模型统计及 7／30 天趋势。
- 新增统计测试、中文文档和 Command Line Tools 本地构建脚本。
- 本地发行包使用独立应用标识，停用上游自动更新。

This edition adds Simplified Chinese localization, daily token accounting,
tests, documentation, and a local build workflow. It is maintained by
[@chencujinlin](https://github.com/chencujinlin), separately from upstream.

## 统计参考：Tokei

[cclank/tokei](https://github.com/cclank/tokei) 是功能与统计规则的参考来源，
尤其是其 [CALCULATION.md](https://github.com/cclank/tokei/blob/27e229ee9461ca60adcadbc201662d6a3dfd6071/CALCULATION.md)
对日志字段、缓存计数和 Codex 分叉重放的说明。
本仓库在 Swift 中实现了统计模块；未包含 Tokei 的采集脚本、应用源码或素材。
Tokei 的费用估算和跨设备同步尚未移植。

Tokei informed the feature and accounting rules. Its collector, application
source, and assets are not bundled here. This attribution does not apply
Codenotch's MIT license to Tokei or imply endorsement by its authors.

## 仓库关系与发行包

这是从上游历史创建的独立 GitHub 仓库，目前未加入 GitHub 的 Fork 网络。
代码来源和派生关系以上述链接与保留的提交历史为准。
本仓库发布的版本不代表 Codenotch 或 Tokei 的官方版本，也不声称获得原作者背书。

本地构建脚本将原项目许可证、本文及所用依赖的许可证／声明打包到
`Codenotch.app/Contents/Resources/Licenses/`。各第三方组件仍适用其各自的许可证。

The GitHub repository is standalone; it does not currently display a platform
Fork relationship. Releases from this repository are unofficial. Bundled
third-party components retain their respective licenses and notices.
