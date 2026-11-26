# iPhone 与 iPad IPA 构建

此流程会使用 Apple 的真实设备编译器生成 arm64 App，再打包为 IPA。同一份 App 同时声明 iPhone 与 iPad 支持；iOS / iPadOS 26 使用 Liquid Glass，较旧系统使用代码中的兼容外观。最低系统保持 iOS / iPadOS 17。

iPad 不强制全屏，声明全部四个方向以支持系统多任务与可变窗口。窗口中的方向和大小以 iPadOS 的规则为准；阅读方向偏好不能覆盖系统对窗口场景的限制。

当前源码版本为 **1.0.2（build 15）**。[GitHub 构建列表](https://github.com/hahahalucas/Komiic/actions)

解压快速任务的产物，使用 `Komiic-iPhone-iPad-unsigned.ipa`。同一份包支持 iOS / iPadOS 17 及以上，安装前需自签。

0.1.0（build 11）的历史完整任务在 iPhone 与 iPad 模拟器各通过 122 项 XCTest，并保存源码、截图、日志和校验报告。[build 11 构建记录](https://github.com/hahahalucas/Komiic/actions/runs/45751647581)

以下为 **0.9.0（build 9）历史构建记录**。

[0.9.0 完整云端构建](https://github.com/hahahalucas/Komiic/actions/runs/45673560888)成功：iPhone、iPad 各 118 项 XCTest 通过，共 236 项、零失败，设备 Release 编译和 IPA 校验通过。[下载仅含 IPA 的小压缩包（约 1.4 MB）](https://github.com/hahahalucas/Komiic/actions/runs/45673560888/artifacts/15051453189)并解压，使用 `Komiic-iPhone-iPad-unsigned.ipa`；安装前需自签。包内版本为 0.9.0，同一份包支持 iPhone/iPad，最低 iOS/iPadOS 17。IPA SHA-256：`1373922c35696f6b097597b45807bf4fa63c1fd62bb43577ce96fe9b34f86261`。[完整验证资料](https://github.com/hahahalucas/Komiic/actions/runs/45673560888/artifacts/15051573065)另含测试结果、截图和日志。

以下为 **0.8.0 历史构建记录**。

[0.8.0 完整云端构建](https://github.com/hahahalucas/Komiic/actions/runs/45655410195)已成功：iPhone、iPad 各 100 项 XCTest 通过，共 200 项、零失败；Xcode 26.6 / iOS SDK 26.5 设备 Release 编译及 IPA 校验通过。[下载产物](https://github.com/hahahalucas/Komiic/actions/runs/45655410195/artifacts/15043018905)并解压，使用其中的 `Komiic-iPhone-iPad-unsigned.ipa`。包内版本为 0.8.0，同一份包支持 iPhone/iPad，最低 iOS/iPadOS 17，安装前需自签。IPA SHA-256：`5886494138e4c694b10e45a9c30e9b46420b07fec76e6c89a6c5f9c7dbc9afba`。完整证据见[验证记录](Verification.md)。

以下为 **0.7.0 历史构建记录**。

[0.7.0 完整云端构建](https://github.com/hahahalucas/Komiic/actions/runs/45208173469)已成功：iPhone、iPad 各 95 项 XCTest 通过，共 190 项、零失败；Xcode 26.6 / iOS SDK 26.5 的设备 Release 编译与 IPA 校验通过。[下载产物](https://github.com/hahahalucas/Komiic/actions/runs/45208173469/artifacts/14835749218)包含真实设备 IPA、测试结果、两种设备的首页截图和构建日志。项目根目录已保存 `Komiic-0.7.0-iPhone-iPad-unsigned.ipa`，本地再次核对版本 0.7.0、build 7、arm64 iOS 设备代码、iPhone/iPad 支持及未签名结构通过。IPA SHA-256：`67b0939a743c8ca6c256d6844d46428f1b80fd8f06eab190feb945e84c0139ac`；安装前需自签。完整证据见[验证记录](Verification.md)。

以下为 **0.6.0 历史构建记录**。

[0.6.0 完整云端构建](https://github.com/hahahalucas/Komiic/actions/runs/45184721681)已成功：iPhone、iPad 各 83 项 XCTest 通过，零失败；Xcode 26.6 / iOS SDK 26.5 的设备 Release 编译与 IPA 校验通过。[下载产物](https://github.com/hahahalucas/Komiic/actions/runs/45184721681/artifacts/14824662819)包含 `Komiic-iPhone-iPad-unsigned.ipa`、两种设备的测试结果、首页截图及构建日志。带版本号的交付副本为 `Komiic-0.6.0-iPhone-iPad-unsigned.ipa`，安装前需自签。

以下为 **0.5.0 历史构建记录**。设备版 [云端构建](https://github.com/hahahalucas/Komiic/actions/runs/45043225501) 已完成，Xcode 26.6 / iOS SDK 26.5 编译与 IPA 校验通过。[下载产物](https://github.com/hahahalucas/Komiic/actions/runs/45043225501/artifacts/14761494948)内包含 `Komiic-iPhone-iPad-unsigned.ipa`，下载后可另存为 `Komiic-0.5.0-iPhone-iPad-unsigned.ipa`。包内版本为 0.5.0，支持 iPhone / iPad，安装前需自签。相同 App 源码的 [完整模拟器流程](https://github.com/hahahalucas/Komiic/actions/runs/45042874177) 已在 iPhone/iPad 各通过 77 项 XCTest、零失败，并生成两种模拟器截图；具体证据见 [验证记录](Verification.md)。

以下为 **3.0 历史构建记录**。当时已完成本地静态检查，并上传至 [`codex/komiic-3.0`](https://github.com/hahahalucas/Komiic/tree/codex/komiic-3.0) 独立分支，提交 [`9e9e97414bfaf017e0658f565c748a3b018d40c7`](https://github.com/hahahalucas/Komiic/commit/9e9e97414bfaf017e0658f565c748a3b018d40c7)。[Mac 云端构建 44999974479](https://github.com/hahahalucas/Komiic/actions/runs/44999974479)已启动，设备编译、两种设备各 36 项 XCTest 与 IPA 仍待结果，当前尚无已验证的 3.0 交付包。生成后应核对包内版本与 build，再另存为 `Komiic-3.0-iPhone-iPad-unsigned.ipa`，不能将旧包改名作为新版本交付。

以下为 **2.0 历史构建记录**。2.0 已在 [Mac 云端设备版任务](https://github.com/hahahalucas/Komiic/actions/runs/44991028791)中完成编译，项目根目录已保存交付副本 `Komiic-2.0-iPhone-iPad-unsigned.ipa`（版本 2.0、build 2，822,136 字节）。[构建产物](https://github.com/hahahalucas/Komiic/actions/runs/44991028791/artifacts/14742335404)内的 IPA 使用默认文件名；下载后另存为带版本号的交付文件。设备版任务使用 `--skip-tests`，Xcode 26.6 / iOS SDK 26.5 编译与云端、本机 IPA 校验均通过。

同一 App 源码的[独立完整流程](https://github.com/hahahalucas/Komiic/actions/runs/44989974389)也已成功：iPhone 与 iPad 各 18 项测试通过、零失败，生成两种模拟器截图并完成设备版编译。[完整验证产物](https://github.com/hahahalucas/Komiic/actions/runs/44989974389/artifacts/14742196424)包含测试结果、截图和日志，本机证据位置为 `build/verified-artifacts-2.0/`。交付包仍来自上述设备版任务；两次构建的 App 源码完全一致，仅构建工作流有调整。未使用用户证书，安装前需要自行签名。实际滑动交互及真机安装尚未验收。源码、构建提交和 SHA-256 见[验证记录](Verification.md)。根目录原有的无版本号 IPA 是 0.1.0 历史包。

## 输出与安装

- 默认生成 `Komiic-iPhone-iPad-unsigned.ipa`。它包含真实 iOS 设备可执行代码，**没有 Apple 安装签名，不能直接安装**。用户需要使用自己的合法证书和对应设备描述文件完成签名。
- 可选签名构建生成 `Komiic-iPhone-iPad-signed.ipa`。必须提供现有的真实 Apple 证书、密码和描述文件；安装范围由这些资料决定。Ad Hoc / 开发描述文件需要覆盖目标 iPhone 和 iPad 的设备标识。
- 此流程不创建证书、不注册设备、不上传 App Store，也不把 App Store 描述文件误称为可直接安装的版本。

## 在 Mac 上生成

需要完整 Xcode 26+、iOS SDK 26+，以及已经安装的 iOS 26+ iPhone 和 iPad 模拟器。可以通过 `DEVELOPER_DIR` 选择 Xcode。

```sh
bash scripts/build_ipa.sh --unsigned
```

脚本依次验证工程、在 iPhone/iPad 模拟器执行 XCTest、退出测试宿主后启动正常 App 并截图，再构建设备 Release 版本、打包和检查 IPA。输出目录为本次独立的 `build/ipa.XXXXXX/artifacts/`，包含 IPA、SHA-256、检查报告、测试结果、截图及构建日志。

已有验证过的构建环境中可以明确跳过重复的模拟器测试：

```sh
bash scripts/build_ipa.sh --unsigned --skip-tests
```

该选项不会跳过真实设备编译或 IPA 检查，也不会生成截图。没有 Xcode 26+ 时脚本直接失败。

## GitHub 云端构建

`.github/workflows/build-ipa.yml` 支持手动运行，也会在推送到 `main`、`komiic-ios-build`、`codex/komiic-0.1.0` 等构建分支时自动运行。同一提交在两个 macOS runner 上独立编译。

- **Device IPA only** 跳过模拟器测试，编译设备 Release 版本并检查 IPA。成功后即可下载 `Komiic-IPA-<编号>`，解压后取得 IPA。
- **Full iPhone and iPad verification** 执行两种模拟器的 XCTest 并截图，编译和检查设备 IPA，在 `Komiic-full-verification-<编号>` 中提供源码、测试结果、截图及构建日志。

从仓库 **Actions → Build iPhone and iPad IPA → Run workflow** 可手动选择构建分支和签名模式。默认使用 `unsigned`，IPA 安装前需自签。两种产物各保留 7 天。[GitHub 仓库](https://github.com/hahahalucas/Komiic)

工作流使用 GitHub 的标准 `macos-26` runner。2026-11-19 查阅的[官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)列出 Xcode 26.6 为默认版本；[官方 runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)列出该标签。镜像会更新，因此脚本仍会验证实际 Xcode 和 SDK 版本。公开仓库使用标准 GitHub 托管 runner 的计算分钟免费，仍受并发、单次任务时长和存储限制，详见 [GitHub Actions 用量说明](https://docs.github.com/en/actions/concepts/billing-and-usage)。私有仓库的执行使用账户的 Actions 额度，超出部分按 GitHub 的账户设置计费。

## 可选签名构建

只有已经拥有签名资料时才选择 `signed`。在仓库 Actions Secrets 配置：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | 现有 Apple 签名证书与私钥导出的 p12，进行 Base64 编码 |
| `IOS_CERTIFICATE_PASSWORD` | 该 p12 的密码 |
| `IOS_PROVISIONING_PROFILE_BASE64` | 对应开发、Ad Hoc 或企业描述文件的 Base64 内容 |

运行时将 `bundle_id` 填为描述文件允许的 App Bundle Identifier。脚本会核对描述文件的有效期、App 标识及直接安装方式；缺少资料或不匹配时失败，不会静默降为 unsigned。

Mac 本地也支持同名环境变量，以及 `KOMIIC_BUNDLE_ID`，然后执行 `bash scripts/build_ipa.sh --signed`。不要把这些值写入仓库文件、命令记录或公开日志。脚本使用临时钥匙串，结束时恢复原钥匙串搜索列表并清理临时证书及本次安装的描述文件，不会删除此前已存在的同一描述文件。

## IPA 检查的范围

```sh
python3 scripts/verify_ipa.py path/to/Komiic-iPhone-iPad-unsigned.ipa --expected-signing unsigned
```

检查包括：

- ZIP 结构、唯一 App、Info.plist、可执行文件权限。
- `UIDeviceFamily` 同时包含 iPhone 和 iPad，支持平台为 `iPhoneOS`。
- 真实 64 位 arm64 Mach-O 可执行文件，平台为 iOS 设备，而非模拟器或 macOS。
- Mach-O 和 Info.plist 的 SDK 都为 iOS 26+，包含 SwiftUI 动态链接，不启用旧设计兼容开关。
- unsigned / signed 的签名结构与描述文件状态一致，并记录文件散列。

Python 检查不能证明 Apple 信任链有效，也不能证明所有界面交互正常。签名构建额外在 Mac 上执行 `codesign --verify --deep --strict`；最终是否可安装仍由设备及描述文件授权决定。Liquid Glass 视觉需结合真实 iOS 26 截图或设备运行验收。

检查器的内部回归检查可以在 Windows 执行：

```sh
python scripts/verify_ipa.py --self-test
```

这些测试只在内存中构造结构样本并验证拒绝逻辑，不会写出或交付示例 IPA。
