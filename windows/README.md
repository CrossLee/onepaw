# 一爪 Windows

这里是一爪的 Windows 11 原生版本工程。电脑小事，一爪搞定。它复用 macOS 版的产品行为和验收标准，但所有系统能力都使用 Windows 原生 API 重新实现，不直接移植 SwiftUI/AppKit 代码。

## 普通用户安装

在 [GitHub 的 Windows 预览版发布页](https://github.com/CrossLee/onepaw/releases)下载 `一爪-Windows-版本号-Setup.exe`，双击后按中文向导点击“安装”和“完成”。不需要解压、不需要输入 PowerShell 命令，也不需要另装 .NET 或其他运行库。安装后从开始菜单打开“一爪”；卸载使用 Windows“设置 → 应用 → 已安装的应用”。

当前安装器和应用是未签名预览版，可能出现 Windows 未知发布者或安全提示，不代表已经有正式代码签名。安装需要管理员授权，不会导入信任证书或关闭系统安全功能。更多说明见 [TESTING.md](TESTING.md)。下文中的 PowerShell 命令仅供开发者构建和验证，不是用户安装步骤。

当前准备的品牌更名版本为 `0.1.21.0`：界面、开始菜单、通知区域、文件关联和安装器显示为“一爪”，新安装包使用上述中文前缀。是否已发布以及实际测试结果以对应 Release 和 Actions 记录为准，不以本文中的构建示例作为发布完成证据。历史版本的标签、安装包文件名和验收记录保留原样。

## 当前边界

已经落盘并接入工程的部分包括：

- WinUI 3 主程序、单实例激活、协议/文件/后台启动路由；
- 截图后立即复制原图、截图编辑器和置顶贴图的 Windows 模块；
- 3 秒倒计时的通用一爪设备壳截图、用户勾选可见顶层窗口的多窗口合成，以及 12 项可编辑全局快捷键（前三项截图快捷键默认必填，其余默认留空）；
- 图片压缩、压缩后在资源管理器定位、启动项和通知区域模块；
- Windows 本地 OCR、UI Automation 读取当前选中文本；
- Windows Graphics Capture 录制屏幕、区域或窗口，本机 H.264/AAC MP4、系统声音和鼠标指针开关，以及录制后的播放、定位与局域网分享入口；
- 局域网文件/文字共享服务：默认使用 10 位随机访问码，也可在共享页或“设置 → 共享服务”保存 6–24 位自定义访问码；换码后旧链接立即失效，端口和当前共享内容保持不变；
- 原生 `IExplorerCommand`：“复制路径”直接在资源管理器进程外的 COM surrogate 中完成，不弹一爪主界面；
- 图片文件关联：“打开方式 → 一爪”走后台压缩激活；
- 单项目 MSIX 清单、x64/ARM64 原生 DLL 打包、MSIXBundle 脚本和 Windows CI。

翻译入口已经接入真实 Marian ONNX 推理引擎和协调器。界面可一键下载固定 revision、逐文件校验大小与 SHA-256 后安装中英双向模型，也保留选择本地模型 ZIP 的高级入口。仓库与安装包不捆绑数百 MB 的模型权重；首次下载需要联网，安装后原文与推理全程留在本机。所需方向未安装模型时，界面会明确提示，而不是假装翻译成功。当前模型卡许可按方向区分：中文到英文（zh-en）是 `CC-BY-4.0`，英文到简体中文（en-zh）是 `Apache-2.0`。模型包格式、安全校验与许可字段见 `src/Crosio.Windows.Translation/MODEL_PACK_FORMAT.md`。

这仍是 Windows 预览版，不等于已完成全部桌面交互验收。开发机是 macOS，Windows 专属验证交给真实 Windows CI：x64 测试、WinUI/MSVC 编译、原生复制路径调用与主窗口启动，以及 Windows 11 ARM64 的 MSIX 安装和已注册应用启动。具体通过情况以对应版本的 Actions 记录为准；截图、录屏、OCR、多屏、资源管理器实际右键菜单等交互仍需在 Windows 11 x64 和 ARM64 桌面分别验收。

本次候选修复了“本机有任务栏图标，但远程桌面看不到主窗口”的捕获属性和窗口恢复链路。普通主窗口必须为 `WDA_NONE`；截图固定窗以及长截图边框/工具栏仍排除捕获。截图、取色和录屏前会隐藏主窗口并等待桌面合成，相关操作忙碌时也会阻止主窗口被重新打开。录屏期间主窗口保持隐藏，停止能力改由通知区域右键“停止并保存录屏”和同一录屏快捷键保持可达；能力检查或启动阶段可从该控制入口取消。完整行为、自动检查与 UU Remote / Windows 11 x64 真机边界见[主窗口远程可见性修复记录](../docs/windows-main-window-visibility-verification.md)。本轮没有发布或安装该候选。

## 工程结构

```text
windows/
├── Crosio.Windows.sln
├── scripts/
│   ├── verify-windows.ps1        # 测试、Windows 编译、unpackaged 测试构建
│   ├── Test-AppStartup.ps1       # 实际启动 unpackaged 主程序并验证可见主窗
│   ├── Test-MsixInstallation.ps1 # Windows 11 ARM64 安装、注册启动和隔离清理
│   ├── Test-PackageLayout.ps1    # 清单/CLSID/打包载荷静态一致性检查
│   ├── build-msix.ps1            # 单架构 MSIX
│   ├── build-msixbundle.ps1      # x64 + ARM64 MSIXBundle
│   ├── build-setup.ps1           # 包含完整 MSIXBundle 的中文 Setup.exe
│   └── Install-Crosio.ps1        # 内部源脚本；发行副本为“安装一爪.ps1”
├── src/
│   ├── Crosio.Windows.App/
│   ├── Crosio.Windows.Core/
│   ├── Crosio.Windows.Capture/
│   ├── Crosio.Windows.LongCapture/
│   ├── Crosio.Windows.Hotkeys/
│   ├── Crosio.Windows.Media/
│   ├── Crosio.Windows.Platform/
│   ├── Crosio.Windows.Intelligence/
│   ├── Crosio.Windows.Translation/
│   ├── Crosio.Windows.Ocr/
│   ├── Crosio.Windows.Accessibility/
│   └── Crosio.Windows.Sharing/
├── shell/Crosio.Windows.ShellExtension/
└── tests/
```

## Windows 开发环境

- Windows 11（build 22000 或更高，x64 或 ARM64）；
- Visual Studio 2022，安装“.NET 桌面开发”“Windows 应用 SDK C#”和“使用 C++ 的桌面开发”；
- .NET 8 SDK；
- Windows 10/11 SDK 与 MSVC v143。

主应用使用 Windows App SDK `1.8.260804001`。MSIX 同时包含匹配架构的 .NET 8、Windows App Runtime，以及录屏模块所需的 VC143 C++ 运行库，不要求用户另外预装这些运行时。构建脚本从 Visual Studio 的对应 x64/ARM64 redistributable 目录复制完整 `Microsoft.VC143.CRT` DLL 集合，并在解包后核对录屏 DLL、VC++ 依赖和 PE 架构。正式包清单在 `src/Crosio.Windows.App/Package.appxmanifest`，其中已经合并：

- 图片文件关联；
- `CrosioStartupTask`；
- `windows.comServer`；
- 文件和文件夹的 `windows.fileExplorerContextMenus`。

Explorer 扩展采用系统 COM surrogate：`com:SurrogateServer` 直接注册 DLL 的 `com:Class`，不声明进程外 `Executable`/`Arguments`；可选 `AppId` 目前也不需要。清单、原生 CLSID、菜单 Verb 和包内 DLL 路径由 `Test-PackageLayout.ps1` 交叉检查。

产品图标采用已确认的“一爪 OnePaw”猫咪伸爪拟物图。`Resources/Brand/OnePaw-AppIcon.png` 是未经修改的 1254×1254 生图原稿；`src/Crosio.Windows.App/Assets` 保存 Windows 所需的尺寸/格式导出，覆盖 MSIX 开始菜单与文件关联、应用 EXE、主窗口、通知区域及中文安装器。此次统一用户可见名称，不改变已确认的图标。

为保持旧版升级、系统注册和已有数据兼容，内部 `Crosio.Windows` Package Name、Publisher、包系列身份（PFN）、AUMID、`crosio:` 协议、COM GUID、启动任务标识及注册表键保持不变；`Crosio.exe`、程序集/命名空间、源文件路径、模型和设置等数据目录也保留原标识。这些兼容标识不是另一个产品，不能仅为消除旧名称而修改。升级不以卸载旧版或清空数据为前置步骤。

这些导出只通过系统工具进行等比尺寸转换与 ICO 容器封装，不重绘、抠图、换色或改变构图。开发者可在 macOS 执行 `node windows/scripts/export-approved-icons.mjs` 重现；Windows 构建直接使用已提交的资产，无需安装图片工具。`IconAssets.json` 记录原稿和每份导出的 SHA-256，`Test-PackageLayout.ps1` 严格检查图标来源、尺寸、ICO 目录及引用；真实包内图标继续在解包时核验。尺寸依据 [Microsoft Windows 图标说明](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction)。

## 验证与开发构建

在 Windows Developer PowerShell 中：

```powershell
.\scripts\verify-windows.ps1 -Configuration Release -Platform x64
```

该命令依次执行打包结构静态检查、所有测试项目、Windows 专属模块编译、x64 原生 Explorer 扩展编译、WinUI 编译，以及一个 unpackaged 自包含测试构建。它不会把 unpackaged 目录冒充安装包。

生成 x64 unpackaged 目录后，可在隔离的 Windows runner 上执行真实启动 smoke：

```powershell
.\scripts\Test-AppStartup.ps1
```

脚本实际启动 `artifacts\publish\win-x64\Crosio.exe`，在 30 秒总预算内要求标题为“一爪”的主窗口连续两次通过原生窗口与 UI Automation 验收：可见、非最小化、非 DWM cloaked、`WDA_NONE`、矩形为正且与活动显示器工作区相交，并能找到可见可用的“首页”关键元素。它仅终止自己通过 `Start-Process` 启动并持有句柄的进程，不搜索或结束其他一爪实例，也不操作注册表、配置和剪贴板。Windows App SDK 1.8 [支持 Windows Server 2022](https://learn.microsoft.com/windows/apps/windows-app-sdk/support)，因此该检查会在 GitHub `windows-2022` runner 上实际执行而不是跳过；但它只证明 unpackaged 主程序可以启动，一爪的发行与交互验收边界仍是 Windows 11 build 22000 以上。

只检查清单与 Explorer 扩展一致性：

```powershell
.\scripts\Test-PackageLayout.ps1
```

## 生成 MSIX / MSIXBundle

单独生成一个架构的包：

```powershell
.\scripts\build-msix.ps1 -Configuration Release -Architecture x64 -Version 0.1.21.0
.\scripts\build-msix.ps1 -Configuration Release -Architecture ARM64 -Version 0.1.21.0
```

一次生成 x64、ARM64 和组合安装包：

```powershell
.\scripts\build-msixbundle.ps1 -Configuration Release -Version 0.1.21.0
```

构建成功后的输出在 `windows\artifacts\release`。其中包括两个单架构 `.msix`、一个 `.msixbundle`、SHA-256 校验值、构建信息、安装脚本和 `THIRD_PARTY_NOTICES.md`；第三方声明也包含在每个 MSIX 及 unpackaged 测试目录内。

继续生成普通用户双击安装的 EXE（以下开关仅明确允许开发测试用的 unsigned MSIX，不允许坏签名）：

```powershell
.\scripts\build-setup.ps1 -Version 0.1.21.0 -AllowUnsignedTestPackage
```

图形安装器由 NSIS 构建，嵌入本次生成的组合包，在后台交给 Windows 包管理器注册，不额外制造第二个卸载条目。CI 必须在 Windows 11 ARM64 环境实际点击同一 `Setup.exe` 的安装与完成按钮，再核对注册内容并启动一爪；发布页只应提供通过该流程的 EXE 和对应 SHA-256。

例如版本 `0.1.21.0` 在无证书时生成：

- `一爪-Windows-0.1.21.0-x64-unsigned-test.msix`；
- `一爪-Windows-0.1.21.0-arm64-unsigned-test.msix`；
- `一爪-Windows-0.1.21.0-unsigned-test.msixbundle`；
- `一爪-Windows-0.1.21.0-Setup.exe`（继续运行 `build-setup.ps1` 后）。

有证书时前三个包文件把 `unsigned-test` 改为 `signed`。这不自动代表安装器 EXE 已签名；应分别核验应用包与 EXE 的签名状态。Actions 中对应的归档名称为 `一爪-windows-<版本>-unsigned-test` 或 `一爪-windows-<版本>-signed`，另有 `一爪-windows-x64-test-build` unpackaged 归档。

无证书时生成的是文件名、Actions artifact 名和 `build-info.json` 都明确标记为 `unsigned-test` 的 Windows 11 测试包。它的 Publisher 含微软规定的 `OID.2.25` 标记；管理员 PowerShell 可运行同目录的：

```powershell
.\安装一爪.ps1
```

脚本只会对真正未签名的包使用 `Add-AppxPackage -AllowUnsigned`。若包有无效或不受信任的签名，它会停止并提示处理证书，不会绕过签名错误。unsigned 包只用于开发测试；即使作为 GitHub prerelease 提供下载，也不是正式受信任的发行版。

有代码签名 PFX 时：

```powershell
.\scripts\build-msixbundle.ps1 `
  -Configuration Release `
  -Version 0.1.21.0 `
  -CertificatePath C:\secure\OnePaw.pfx `
  -CertificatePassword $env:CROSIO_CERT_PASSWORD
```

脚本从证书读取 Subject，在构建期间写入临时清单，构建结束即恢复仓库清单；之后用 SHA-256 签名单架构包和 bundle。签名证书必须具有代码签名用途。密码不应写进仓库或命令历史。

## GitHub Actions

Windows 源码已合入 `main` 的 `windows/` 目录，不再需要切换到平台专用开发分支。`.github/workflows/windows-ci.yml` 在 Windows 代码、共享网页、图标或流水线变更的 push/PR，以及手动触发时运行：

1. 固定使用带 VS 2022/v143 ARM64 工具的 Windows 2022 runner，完成测试及 x64 编译验证；
2. 构建 x64 与 ARM64 MSIX；
3. 用 `MakeAppx` 生成 MSIXBundle；
4. 生成“一爪”中文图形安装器，并上传 unpackaged 测试目录和未签名安装包；
5. 在 Windows 11 ARM64 环境通过界面完成首次和同版本重复安装，检查显示名；启动后验证主窗口原生状态与 UI Automation，再隐藏精确窗口并从同一 AUMID 再次激活，确认驻留主进程可靠恢复主窗口。

普通 push/PR 和默认手动运行**只验证，不发布**。在 GitHub Actions 选择 `Windows` → `Run workflow`，分支选 `main`，只有显式勾选 `publish_preview` 才会在本轮构建与 ARM64 安装全部通过后尝试公开预览版。其他分支即使勾选也不会发布。

发布只使用同一运行、同一提交的准确 artifact，复验文件清单和 SHA-256，先创建草稿并回下载核对，再公开 `windows-v…-preview`。它保持 prerelease，不覆盖 Mac stable 的 latest 标记。

当前 CI 与预览发布固定为 **unsigned-test**，不读取或导出仓库证书 secrets。上面的独立签名脚本仍保留，但不代表完整可信签名链路已配置；未来签名需建立单独受控流程，不能给任意开发分支提供私钥。版本号沿用该工作流的运行编号，超出 MSIX 数字范围时明确失败，不循环回旧版本。

## 安装后专项验收

Windows 真机至少需要逐项确认：

- UU Remote 连接 Windows 11 x64 时，主窗口内容可被远端逐像素看到，不是只出现任务栏图标；主窗口为 `WDA_NONE`，而截图固定窗、长截图边框和工具栏继续不进入截图/录屏内容；
- 截图、取色和录屏前主窗口隐藏帧已完成合成；操作忙碌期间从开始菜单、第二次启动或通知区域打开不会让主窗口混入画面，结束后窗口可以从最小化或屏幕外可靠恢复；
- 主窗口在录屏期间保持隐藏时，通知区域右键“停止并保存录屏”可用，能力检查/启动阶段可取消，同一录屏快捷键可停止，并能完成可播放 MP4 的安全封装；
- 右键文件/文件夹只出现一个“复制路径”，多选顺序和 Unicode 路径正确，主界面不弹出；
- 开始菜单、应用主窗口、通知区域、安装器及系统应用列表显示“一爪”，旧版升级后设置和模型仍可读取，没有重复安装条目；
- 图片“打开方式 → 一爪”立即后台压缩，后缀与真实编码不变，源文件不覆盖，并自动定位输出文件；
- 设置里的开机启动可启用/禁用，用户在系统设置禁用后不会被程序强行打开；
- 共享页和“设置 → 共享服务”都能显示、修改访问码；自定义访问码重启后保留，“恢复随机访问码”会立即换码，旧链接不能再查看、下载、上传或发送文字，新链接继续使用同一端口和已有共享内容；
- 截图先写入剪贴板再显示编辑器，`S` 贴图、滚轮按指针缩放、`Esc` 只关闭贴图；
- 带壳截图倒计时、设备壳尺寸和保存/剪贴板结果正确；多窗口 `PrintWindow` 合成需覆盖 Chromium、UWP 和传统 Win32 窗口验证；
- 12 项全局快捷键可编辑、冲突时整组回滚，前三项必填且其余项目可以清除；
- 录屏在 x64/ARM64 上均能启动和完成 MP4，包内 `ScreenRecorderLib.dll` 与 VC143 CRT 的架构正确；Windows N/KN 版本需要先启用系统的 Media Feature Pack；
- Explorer 重启后菜单和托盘恢复；
- x64 与 ARM64 包内分别包含同架构的 `ShellExtensions\Crosio.Windows.ShellExtension.dll`。

共享访问码允许 6–24 位英文字母、数字、`-` 和 `_`，并区分大小写。访问码会明文包含在共享链接和浏览器历史中，它用于减少误访问，不等同于账号密码或端到端加密；请只把链接发给可信的同一局域网参与者，也不要把共享端口映射到公网。
