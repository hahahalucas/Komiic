# Komiic for iOS
基于 Komiic 网站实现的原生 SwiftUI 漫画客户端，适用于 iOS / iPadOS 17 及以上系统。项目使用 Apple 系统框架，采用液态玻璃布局，无第三方运行时依赖。

公开源码：[hahahalucas/Komiic](https://github.com/hahahalucas/Komiic)。

## 打开和运行

1. 将整个目录复制到 Mac，使用 **Xcode 26 或更新版本**打开 `Komiic.xcodeproj`。
2. 选择 `Komiic` scheme 和 iPhone / iPad 模拟器，点击运行。
3. 安装到真机时，在 **Signing & Capabilities** 中选择自己的开发团队，并将 `com.example.Komiic` 改为可用的 Bundle Identifier。
4. 首次打开即从 Komiic 获取公开漫画。点击右上角账号入口可在官方网页登录；完成后回到 App 使用官网会话。

工程采用文件夹同步分组，`Komiic/` 下新增 Swift 文件会自动加入 App target，`KomiicTests/` 下文件自动加入测试 target。真实 IPA 构建、签名和安装要求见 [IPA 构建说明](docs/IPA.md)。

## Liquid Glass 与设备适配

iOS / iPadOS 26 使用系统原生的 Liquid Glass 标签栏、导航栏和工具栏；阅读器使用 `glassEffect` 悬浮控制条，详情操作使用玻璃按钮。iOS 17 / 18 保留兼容外观，运行这些旧系统时不会显示 Liquid Glass。编译新 API 需要 Xcode 26+。

iPhone 与 iPad 均保留首页、喜爱、资料库三个标签，资料库包含书签与书柜。已移除漫画、离线独立入口及页面左上角的装饰图标，不再使用可切换侧栏的根导航。iPad 支持多任务窗口；方向跟随系统窗口。减少透明度时，自定义玻璃控制条改为不透明背景；墨水阅读模式始终使用清晰的白色控制条。

首页顶部的最近更新、当月最热、推荐漫画、最近阅读四个主分类等宽铺满一行；最近更新内保留最近更新 / 最近上架切换。内容区可按“最近更新 → 最近上架 → 当月最热 → 推荐漫画 → 最近阅读”的顺序左右滑动，页面随手势移动，点击分类也有切换动画。

2.0 已完成 Xcode 26.6 设备版编译，交付包为 `Komiic-2.0-iPhone-iPad-unsigned.ipa`（822,136 字节）。可从[成功构建的产物](https://github.com/hahahalucas/Komiic/actions/runs/44991028791/artifacts/14742335404)获取；云端包内文件使用默认名称，项目根目录的交付副本加入了版本号。它支持 iPhone 与 iPad，已在本机复核为真实 arm64 iOS 设备包，安装前需要自行签名。旧的 `Komiic-iPhone-iPad-unsigned.ipa` 仍是 0.1.0 历史构建。完整记录与 SHA-256 见 [验证记录](docs/Verification.md)。

## 已实现功能

| 入口 | 功能 |
| --- | --- |
| 首页 | 最近更新、最近上架、当月最热、推荐漫画、最近阅读五页滑动切换，内容分级筛选、下拉刷新、分页加载 |
| 搜索 | 关键词搜索、输入防抖、展示完整搜索结果、错误状态 |
| 漫画详情 | 封面、作者、简介、分类、浏览及收藏数量、章节目录、章节排序、继续阅读、下载、分享 |
| 喜爱 | 本机喜爱管理，按未读、在读、本章已读筛选 |
| 书签 | 保存具体章节和页码，从书签继续阅读、删除书签 |
| 书柜 | 创建、重命名、删除，加入及移出漫画，四宫格封面 |
| 阅读器 | 纵向滚动、横向翻页、页码滑杆、翻页按钮、隐藏工具栏、阅读进度、书签、图片重试 |
| 下载 | 详情中的章节下载、永久下载文件与已完成章节无网读取；2.0 移除了独立离线入口 |
| 账号 | 官网登录及退出会话，官网账号、收藏、书柜、书签和内容警告偏好入口 |
| 设置 | 浅色/深色/系统外观、阅读方式、缓存清理策略、灰阶墨水模式、iPhone 方向锁定、下载完成提醒、容量查看、导出与恢复、连接诊断 |

所有列表都有加载、空白或失败状态。截图中的账号、邮箱、阅读次数和漫画收藏没有作为预置用户数据写入项目。

## 本机资料与官网资料

喜爱、书签、书柜、屏蔽、阅读记录和统计保存在本机，**目前不与 Komiic 云端双向同步**。账号页明确区分本机资料和官网资料，并可打开官方对应页面管理云端数据。官网用户名、图片剩余额度、评论统计和关注书柜没有用模拟数值代替。

本机资料库保存在 `Application Support/Komiic/library.json`，采用原子写入；无法读取的旧资料会保留恢复副本。设置存入 App 自己的 `UserDefaults`。

永久下载保存在 `Documents/KomiicOffline/`，每个章节有独立清单和图片文件。在线缓存保存在 `Caches/KomiicPages/`，可设置不自动清除、离开阅读器后清除或 24 小时清理；清理缓存不会删除永久下载。iOS 也可能自行回收 Caches。

通过“文件”App 可以备份或拷入离线文件夹，再在设置中扫描恢复。设置提供文件夹导出；本版本不把永久储存位置迁移到外部云盘。扫描时会核对图片文件是否存在并可解码，缺页章节会标记为未完成。

下载在 App 运行期间执行。下载完成提醒是本地通知；未接入 APNs、服务器章节推送或后台持续下载。语言目前为简体中文；墨水模式是灰阶及减少动画的显示选项，自动模式在 iPhone / iPad 上保留普通显示。

## 连接方式

默认站点为 [Komiic 官网](https://komiic.cc/)，通过其第一方网页当前使用的 GraphQL 接口 `https://komiic.cc/api/query` 请求漫画和章节。图片使用官网的 `getImageTicket` / `X-Image-Ticket` 流程，过期后刷新一次；图片 CDN 请求不携带账号 Cookie。登录在 `WKWebView` 中完成，App 使用 Cookie 会话，不直接保存账号密码。

2026-11-18 已对公开列表、搜索、详情、章节、页面列表、图片票据和一张实际 WebP 图片进行 HTTP 验证，记录在 [`docs/live-api.json`](docs/live-api.json)。这些是网站内部接口，可能随官网变更；登录后的账号流程仍需在 iOS 上实测。图片访问受官网权限、每日额度和限流约束，App 会显示对应错误。

本项目为独立客户端，与 Komiic 官方无隶属关系。

本项目采用 [MIT 许可证](LICENSE) 开源。

## 验证

本地开发环境为 Windows。2026-11-22，2.0 已通过本地工程结构、共享 scheme、资源文件及全部 21 个 Swift 源文件的语法检查，`git diff --check` 通过。[设备版构建](https://github.com/hahahalucas/Komiic/actions/runs/44991028791)已成功生成并校验交付 IPA；该任务使用 `--skip-tests`。同一 App 源码的[独立完整流程](https://github.com/hahahalucas/Komiic/actions/runs/44989974389)也已成功：iPhone、iPad 各 18 项测试通过、零失败，生成两种模拟器截图并完成设备版编译；[完整验证产物](https://github.com/hahahalucas/Komiic/actions/runs/44989974389/artifacts/14742196424)包含测试结果、截图和日志。实际滑动等界面交互和真机安装尚未验收。

本地结构检查：

```sh
python scripts/verify_project.py
```

可选安装开发检查工具并严格检查 Swift 语法：

```sh
python -m pip install --target .validation-packages -r scripts/requirements-validation.txt
python scripts/verify_project.py --require-swift-parser
```

在 Mac 上编译模拟器版本：

```sh
xcodebuild -project Komiic.xcodeproj -scheme Komiic -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

使用 Xcode 的 **Product → Test** 执行单元测试，或先查询可用模拟器后选定设备：

```sh
xcodebuild -project Komiic.xcodeproj -scheme Komiic -showdestinations
xcodebuild -project Komiic.xcodeproj -scheme Komiic -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

18 个单元测试覆盖响应解码、GraphQL/HTTP 错误、搜索结果不被截断、图片票据刷新、并发请求共用登录会话刷新、资料库持久化和恢复、离线文件恢复及无网读取。测试均使用隔离目录或模拟网络，不需要 Komiic 账号。详细状态及设备验收步骤见 [`docs/Verification.md`](docs/Verification.md)。

## 主要文件

```text
Komiic/
  App/          应用入口、首页/喜爱/资料库原生标签导航、通知协调
  Core/         数据模型、接口、本机资料库、离线文件、阅读设置
  Features/     目录、搜索、详情、阅读器、喜爱/书签/书柜、账号及设置
  UI/           通用外观、漫画卡片、封面载入
  Assets.xcassets/
  PrivacyInfo.xcprivacy
KomiicTests/    XCTest 单元测试
docs/          接口验证记录和验收说明
scripts/       跨平台静态检查
```
