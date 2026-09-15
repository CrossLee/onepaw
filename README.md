<p align="center">
  <img src="docs/assets/onepaw-brand.png" alt="一爪 OnePaw · 电脑小事，一爪搞定" width="820">
</p>

<p align="center">
  截图、OCR、图片压缩、录屏、取色、翻译与局域网分享。<br>
  一个本地优先、不需要注册账号的桌面工具箱。
</p>

<p align="center">
  <a href="#下载">下载安装</a> ·
  <a href="#截图之后接着把事做完">界面预览</a> ·
  <a href="#常用工具一处就够">主要功能</a> ·
  <a href="https://github.com/CrossLee/onepaw/releases">更新记录</a> ·
  <a href="https://github.com/CrossLee/onepaw/issues">问题反馈</a>
</p>

## 下载

| 平台 | 最新已发布版本 | 安装包 | 发布状态 |
| :--- | :--- | :--- | :--- |
| macOS 14+ · Apple Silicon / Intel | [0.6.7](https://github.com/CrossLee/onepaw/releases/tag/v0.6.7) | **[下载 DMG](https://github.com/CrossLee/onepaw/releases/download/v0.6.7/OnePaw-0.6.7-macos-universal2.dmg)** | Developer ID 签名 · Apple 公证 |
| Windows 11 · x64 / ARM64 | [0.1.29.0](https://github.com/CrossLee/onepaw/releases/tag/windows-v0.1.29.0-preview) | **[下载 EXE](https://github.com/CrossLee/onepaw/releases/download/windows-v0.1.29.0-preview/OnePaw-Windows-0.1.29.0-Setup.exe)** | 预览版 · 尚未签名 |

Mac 备用安装方式：[PKG](https://github.com/CrossLee/onepaw/releases/download/v0.6.7/OnePaw-0.6.7-macos-universal2.pkg) · [ZIP](https://github.com/CrossLee/onepaw/releases/download/v0.6.7/OnePaw-0.6.7-macos-universal2.zip)。版本信息更新于 **2026-09-15**。

Windows 安装器可直接双击，自动选择架构，不需要操作 PowerShell。当前仍是未签名预览版，可能出现“未知发布者”提示，部分设备策略会阻止安装；不要关闭安全保护来绕过限制。[签名进度与说明](docs/windows-signing.md)

macOS 0.6.6 是首个以“一爪.app”正式发布的 Mac 版本；Windows 新版仍按独立流水线验证并发布为未签名预览版。两端既有安装身份和数据目录继续保留。[更名与升级兼容说明](docs/branding.md)

GitHub 的 “Source code” 是源码，不是安装包。

## 截图之后，接着把事做完

选区域、选窗口，或截一张长图。截图完成就自动复制原图；需要时继续标注、识别文字，或钉在屏幕上边看边操作。

<p align="center">
  <img src="docs/assets/macos-capture.jpg" alt="macOS 实际截图工具页，包含区域、窗口、全屏、延时、带壳、多窗口和长截图入口" width="1040">
</p>

<p align="center"><sub>真实 macOS 界面，采集自本地 0.6.6（47）开发构建，非正式发行包。截图页展示首次授权状态；快捷键以你的设置为准。</sub></p>

## 常用工具，一处就够

- **截图、标注、识字** — 画笔、箭头、矩形、马赛克；Mac 使用本机 Vision 自动 OCR。在截图编辑器中按 `S` 把当前截图变成置顶小贴图，滚轮缩放，`Esc` 关闭。
- **图片压缩** — 本地批量处理，兼顾清晰度与体积，不覆盖原图。Mac 的 Finder“打开方式 → 一爪”可自动压缩 PNG、JPEG/JFIF、HEIC、TIFF，保持原格式和后缀，完成后定位结果。
- **屏幕录制** — 录屏幕、窗口或指定区域，按需保留系统声音和鼠标指针。Mac 当前不采集麦克风，成片默认只保存在本机。
- **屏幕取色** — 提取标准 sRGB 颜色，复制 HEX、RGB 或 HSL，保存最近使用的颜色。
- **本机翻译** — 双栏翻译，也可为选中文字设置快捷中英互译。Mac 需要 macOS 15+；两平台首次准备语言模型可能需要联网。
- **局域网分享** — 分享文件、图片、文字和链接。其他人用浏览器即可查看、下载、上传，不需要安装客户端；Mac 和 Windows 默认使用 10 位随机访问码，也可改成 6–24 位自定义访问码。换码后旧链接立即失效，你也随时可以停止共享。

此外还提供自定义全局快捷键、登录时启动，以及文件/文件夹的右键复制路径。Mac 的复制路径位于 Finder“服务”菜单，后台完成，不弹主界面。

以上为产品主要能力。Windows 正在持续完善，安装、启动和自动测试通过不代表全部功能已完成实机验收，也不代表已与 Mac 完全一致。[Windows 功能与验证范围](windows/README.md)

### 颜色，随手就能带走

<p align="center">
  <img src="docs/assets/macos-color-picker.jpg" alt="macOS 实际取色页面，显示 HEX、RGB、HSL 与最近颜色" width="1040" loading="lazy">
</p>

<p align="center"><sub>同一 macOS 开发构建实拍。图片未重绘，未替换界面文字。</sub></p>

## 安装与第一次使用

<details>
<summary><strong>macOS · 新安装与旧名称升级</strong></summary>

1. 安装前先退出旧版。首次安装可打开 DMG，将其中的 App 拖入“应用程序”。
2. 从“应用程序”启动；它常驻菜单栏，不在 Dock 或 `Command+Tab` 中常驻。需要主界面时从菜单栏打开。
3. 首次截图、录屏按提示授予屏幕录制权限；快捷翻译读取其他 App 选中文字时才需要辅助功能权限。

Universal 2 同时支持 Apple Silicon 与 Intel，无需 Rosetta。macOS 14 可用除本机翻译以外的其他功能；本机翻译需要 macOS 15+。

**从旧名称升级到一爪，请下载 0.6.7 的 PKG。** PKG 会先校验和备份原应用，再归档旧名称实体；请勿提前删除旧应用或用户数据。DMG/ZIP 不自动迁移旧名称，直接拖入可能留下两个应用目录。

安装并打开一次后，系统才会注册 Finder 服务；若“复制路径”未显示，可检查系统键盘快捷键中的“服务”。

</details>

<details>
<summary><strong>Windows · 双击中文安装程序</strong></summary>

1. 使用自己的、具有管理员权限的 Windows 账户；升级前先退出旧版。
2. 双击下载的 `Setup.exe`，确认系统管理员授权，按向导点击“安装”“完成”。新版文件名为 `OnePaw-Windows-版本号-Setup.exe`。
3. 从开始菜单打开应用，或在安装完成页选择立即打开；更名版开始菜单显示“一爪”。

需要 Windows 11 build 22000 或更高版本，支持 x64 / ARM64，安装包包含运行所需组件。安装本身无需联网；首次下载翻译模型需要联网。

当前包尚未签名。如果设备策略阻止运行，请联系管理员，不要关闭安全功能。预览版转正式签名版将涉及包身份与数据迁移，正式迁移方案尚未发布，请先保留旧安装与数据。

</details>

## 本地优先，边界清楚

- **内容留在本机。** 截图 OCR、图片压缩和翻译处理不上传到 OnePaw 自建云服务。首次语言模型下载与内容处理是两回事。
- **分享由你决定。** 自动复制截图、OCR 识字、录屏和翻译不会把内容自动加入共享区。
- **面向局域网分享。** 不内置公网穿透或云端中继，请勿将服务端口映射到公网。访问码会明文包含在链接、二维码和浏览器历史中，它用于限制误访问，不等同于加密密码。能访问服务且持有当前分享链接的人可以查看、下载和上传，请只发给可信参与者；需要撤销旧链接时可立即更换访问码或停止共享。
- **保留原文件。** 压缩只在结果确实更小时保存新文件，不承诺所有图片都能达到指定体积，也不把有损压缩称为无损。

Mac 兼容数据目录为 `~/Library/Application Support/crosstool`。浏览器上传单文件上限为 256 MB；本地网络、屏幕录制和辅助功能权限均按使用场景申请。

## 从源码构建

<details>
<summary><strong>macOS · Swift / SwiftUI</strong></summary>

需要 Xcode 26 或更高版本（包含 macOS 26 SDK）。这是源码构建要求，应用运行最低系统仍为 macOS 14。在 Mac 上运行：

```bash
git clone https://github.com/CrossLee/onepaw.git
cd onepaw
swift test
./scripts/build-app.sh
```

开发 App 输出到 `dist/development.noindex/一爪.app`。开发脚本优先使用 Apple Development 证书，没有证书时使用 ad-hoc 签名；这不等于正式发行签名。输出目录避免被系统索引成重复应用。

正式 DMG、PKG、ZIP 需要 Developer ID 证书及 `notarytool` 钥匙串 profile：

```bash
CROSSTOOL_NOTARY_PROFILE=<profile> ./scripts/build-release.sh
```

安装身份 `com.cross.crosstool`、PKG receipt 与既有数据路径均为兼容标识，不随仓库改名变更。

</details>

<details>
<summary><strong>Windows · .NET / WinUI 3</strong></summary>

macOS 与 Windows 现统一在 `main` 维护。Windows 原生代码、测试和安装器位于 [`windows/`](windows/)，macOS 保留现有 Swift 工程结构；两端独立构建、独立发布。

请按 [Windows 构建文档](windows/README.md) 准备开发环境。可信发布的身份、证书、安装器签名与旧预览迁移要求见 [Windows 签名说明](docs/windows-signing.md)。

</details>

代码合并和日常推送只触发验证，不会自动发布安装包。两端共用品牌与浏览器页面资源；修改公共网页时会同时触发 Mac 和 Windows 检查。详见[仓库结构与发布约定](docs/platform-workflow.md)。

## 下载校验与反馈

每个发布页都附有 `SHA256SUMS.txt`。Mac 安装包可在同目录运行 `shasum -a 256 -c SHA256SUMS.txt`；Windows 可在开发者工具中计算 SHA-256 后比对。普通用户不需要执行命令才能安装。

遇到问题，欢迎在 [Issues](https://github.com/CrossLee/onepaw/issues) 留下系统版本、处理器架构、App 版本与复现步骤。截图前请遮住私人内容，不要提交分享令牌、证书私钥或密码。

<p align="center"><sub>一爪 OnePaw · 电脑小事，一爪搞定</sub></p>
