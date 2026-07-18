# Safe Space Cleaner

Windows 安全空间清理 skill。默认清理 `C:` 盘，只处理白名单内的临时文件和可重建缓存；每次都先审计，确认后再删除，并生成完整报告。

`审计 → 显示计划 → 令牌确认 → 逐项复核 → 删除 → 报告`

## 默认会删除

| 类别 | 会删除什么 | 删除后的影响 |
| --- | --- | --- |
| 用户临时文件 | `%TEMP%` 中超过保留期的文件 | 应用需要时会重新创建 |
| Windows 临时文件 | `Windows\Temp` 中超过保留期且当前可安全访问的文件 | 锁定或受保护文件会自动跳过 |
| 图形缓存 | DirectX、NVIDIA DX/GL 着色器缓存 | 游戏或图形应用首次启动可能短暂重新编译 |
| 浏览器缓存 | 已关闭的 Edge、Chrome、Firefox 的 `Cache`、`Code Cache`、`GPUCache` 等纯缓存目录 | 网页资源会重新下载；账号和浏览记录不受影响 |
| VS Code 缓存 | 已关闭 VS Code 后的 `Cache`、`Code Cache`、`GPUCache`、`CachedData` | VS Code 会按需重建 |
| pip 缓存 | 通过 `py -m pip cache purge` 清理 | 后续安装可能重新下载包 |
| uv 缓存 | 通过 `uv cache clean` 清理 | 后续操作可能重新下载或构建 |
| npm 与 npx 缓存 | 通过 `npm cache clean --force` 和 `npm cache npx rm --force` 清理 | 后续安装或 npx 执行可能重新下载包 |

纯缓存不设保留期。临时文件默认保留 30 天；使用 `Aggressive` 时默认保留 7 天。应用仍在运行、文件被锁定、审计后发生变化或路径校验失败时，一律跳过。

## 只列出，由你决定

| 类别 | 默认动作 |
| --- | --- |
| 旧安装包、压缩包 | 显示路径、大小、影响和候选 ID，不自动删除 |
| 大文件 | 显示候选清单，不自动删除 |
| 崩溃转储、Windows 错误报告 | 显示候选清单，避免误删诊断证据 |
| NuGet、Gradle、Maven、Cargo、Conda 缓存或仓库 | 显示候选清单，避免破坏离线构建或环境 |
| 回收站 | 只提示使用 Windows 界面检查 |

只有明确指定候选 ID 或完整路径后，skill 才会处理这些项目；一次确认不会扩展到同目录或其他类别。

## 永远不会直接删除

| 保护对象 | 包括 |
| --- | --- |
| 个人文件 | `Downloads`、`Desktop`、`Documents`、图片、视频、云盘与同步目录 |
| 浏览器资料 | 账号、Cookie、密码、历史记录、书签、扩展、会话和个人资料 |
| Windows 核心与恢复数据 | `System32`、`WinSxS`、`Windows\Installer`、更新存储、`Windows.old`、分页文件、休眠文件、还原点和卷影副本 |
| 项目与运行环境 | Git 仓库、项目目录、`.venv`、Conda 环境、R 库、`node_modules` 和本地数据库 |
| 虚拟磁盘 | WSL、Docker、Hyper-V、Android 模拟器及其他虚拟磁盘文件 |
| 特殊路径 | 符号链接、联接点、挂载点、离线占位符和归属不明的路径 |

文件再大也不会降低保护级别；skill 不会停止应用、服务、Windows Update 或安全软件来强制删除。

## 使用

将 `safe-space-cleaner` 目录复制到 Codex skills 目录，然后输入：

```text
使用 $safe-space-cleaner 清理我的 C 盘。默认临时文件和纯缓存可以清理，旧安装包和大文件列出来让我决定，并生成完整报告。
```

只审计其他盘：

```text
使用 $safe-space-cleaner 只审计 D 盘，不删除任何文件。
```

报告默认写入 Git 已忽略的 `local-reports/`，包含 Markdown 摘要、逐项 CSV、结构化 JSON、审计计划与最终状态。真实报告含本机路径和使用痕迹，不应上传到公开仓库。

详细规则见[安全策略](safe-space-cleaner/references/safety-policy.md)和[清理类别与官方依据](safe-space-cleaner/references/windows-cleanup-categories.md)。

[MIT](LICENSE)
