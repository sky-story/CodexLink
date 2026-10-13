# 第三方来源与版权

本工程从 RealDyllon/codex-remote 提交 `9a737fb` 复用 CodexMobile、codex-remote-bridge、relay 和本地启动脚本。根目录 LICENSE 保留原始 ISC 许可及 Copyright (c) 2025-2026 Emanuele Di Pietro。共享 daemon 控制、回执存储、原生控制输入框、安全修订和相关测试为本地新增或修改内容，沿用 ISC。

没有复用参考项目中的混淆桌面 JS、完整 Git 历史或私有设置，也没有复制其他五个第三方参考工程的源代码。

| 依赖 | 许可证 | 保存的声明 |
| --- | --- | --- |
| ws 8.x，精确版本以 package-lock.json 为准 | MIT | ThirdPartyLicenses/ws-MIT.txt |
| qrcode-terminal 0.12 | Apache-2.0 与内嵌 QRCode MIT 声明 | ThirdPartyLicenses/qrcode-terminal-Apache-MIT.txt |
| Textual 0.3.1 | MIT | ThirdPartyLicenses/textual-MIT.txt |
| swift-concurrency-extras 1.3.2 | MIT | ThirdPartyLicenses/swift-concurrency-extras-MIT.txt |
| swiftui-math 0.1.0 与 MathChat 衍生内容 | MIT | ThirdPartyLicenses/swiftui-math-MIT.txt、swiftui-math-fonts-LICENSE.txt |
| SwiftUIMath 内嵌 STIX 字体 | STIX Font License | ThirdPartyLicenses/swiftui-math-fonts-OFL.txt，文件名来自原依赖，不代表其正文是 SIL OFL |
| Geist / Geist Mono | SIL OFL 1.1 | ThirdPartyLicenses/geist-OFL.txt、geistmono-OFL.txt |
| JetBrains Mono | SIL OFL 1.1 | ThirdPartyLicenses/jetbrainsmono-OFL.txt |
| Mermaid 11.17.2 与实际捆绑的 64 个包 | MIT、ISC、BSD、Apache 等；DOMPurify 选用 Apache-2.0 | ThirdPartyLicenses/mermaid-bundle.txt；精确组件见 tools/mermaid/manifest.json |

Mermaid 的上游资源缺少可复现版本记录，已替换为固定 npm 依赖构建的离线资源。运行 `npm --prefix tools/mermaid ci --ignore-scripts` 和 `npm --prefix tools/mermaid run build` 可重建资源、内容哈希与依赖声明。KaTeX 固定为 0.18.2，修复审计报告的问题。所有许可合并进 App 的 `Resources/ThirdPartyNotices.txt`。

字体许可来自 Google Fonts 中对应官方字体目录，保留未修改字体与版权声明。Sentry 已从工程依赖及运行入口移除。Codex 本身为外部本机安装的程序，本仓库未分发 Codex 二进制或复制其 Rust 源码；对应 Apache-2.0/NOTICE 可在隔离的官方参考仓库查阅。

发布时应随源代码/分发包保留这些许可，并在自己的 App Store 页面使用自己的名称、Bundle ID、隐私政策和支持联系方式。本分支的法律说明与反馈链接已改为 CodexLink 仓库；上游版权与来源链接保留。
