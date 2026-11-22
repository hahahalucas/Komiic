# 验证记录

日期：2026-11-22（Asia/Shanghai）。

当前源码版本为 **3.0（build 3）**。本次在 2.0 基础上修复刷新及搜索，增加作者作品入口、色情程度与按实际阅读记录折叠的四列章节目录，保留其余导航和详情顶部布局。具体安装与自签要求见 [IPA 构建](IPA.md)。

## 3.0 验证状态

- 下拉刷新每次重新请求第一页，保持已有内容及可见加载状态；相同结果也完成刷新。旧请求不能覆盖新筛选结果，失败和取消后可重试。
- 点击搜索立即展开搜索栏；结果使用统一导航路由直接进入漫画详情，从漫画返回首页。
- 作者姓名保留原位置并作为作品入口。模型保存作者 ID，旧存档的姓名数组继续可读；缺少 ID 时可搜索作者并精确匹配姓名。
- 简介下增加五颗心的色情程度及官方说明，区分 0 级与暂无评级。
- 章节按卷、话等类型分组，每行四个方块。暗格只来自实际已读 ID；折叠位置按最后阅读章节确定，最多保留该章节及其紧邻上一章的两个已读暗格，未读间隔中断相邻关系。较早章节与其余已读章节以眼睛方块折叠，可展开查看。
- 已有进度的漫画在右下角显示 Liquid Glass 继续阅读按钮，恢复最后章节及页码，按钮位于系统标签栏上方。
- 本地 `python scripts/verify_project.py --require-swift-parser` 通过：工程引用、共享 scheme、资源及全部 26 个 Swift 源文件语法树无错误节点。`git diff --check` 通过。
- 当前共有 **36 项 XCTest 源码**：原有 18 项，加作者/分级及兼容性 5 项、章节目录 7 项、跳章持久化 1 项、刷新及取消 5 项。尚未执行 3.0 的 XCTest、Xcode 编译或 iOS 模拟器验证。
- 用户已确认公开上传与生成 IPA，云端完整流程使用 `codex/komiic-3.0` 独立分支。当前准备上传并执行构建，尚无 3.0 IPA；根目录的 2.0 与 0.1.0 历史包不能代表本次源码。

### 3.0 第一方接口只读验证（2026-11-22）

- 读取 [Komiic 官网当前脚本](https://komiic.cc/assets/index-Qe6s1nt9.js)，核对 `getComicsByAuthor(authorId:)`、`searchComicsAndAuthors` 中的 `authors { id name }`，以及 `Comic.sexyLevel` / `sexyLevelReason`。
- 对 `https://komiic.cc/api/query` 发起公开只读 HTTP 请求：漫画 `1215` 返回 `sexyLevel: 0` 及分级说明，作者 `1480`（HERO）的作品查询返回 2 部漫画，均没有 GraphQL 错误。
- 作者搜索 `HERO` 返回包含作者 `1480` 的多个模糊匹配候选，确认旧存档补查需要按姓名精确匹配，不能直接使用第一条结果。
- 验证未使用用户账号或保存 Cookie/图片票据。上述证据仅证明接口当时可用，不等同于原生作者页面或阅读交互通过验收。

以下为 **2.0 与 0.1.0 历史验证记录**，不作为 3.0 的编译或测试结论。

## 2.0 验证状态

- iPhone 与 iPad 根导航统一为首页、喜爱、资料库三个入口，资料库仍包含书签与书柜。
- 移除左上角装饰图标和可切换侧栏的根导航。
- 首页最近更新、当月最热、推荐漫画、最近阅读四个主分类等宽铺满一行；最近更新内保留最近更新 / 最近上架切换。
- 内容区按“最近更新 → 最近上架 → 当月最热 → 推荐漫画 → 最近阅读”顺序支持左右滑动，拖动时页面随手势移动，点击分类时有切换动画。
- 2026-11-22 执行 `python scripts/verify_project.py --require-swift-parser`：工程结构、共享 scheme、资源文件及全部 21 个 Swift 源文件的语法检查通过。
- `git diff --check` 通过；仅出现预期的 LF 转 CRLF 提示。
- Xcode 26.6 / iOS SDK 26.5 的 Release 设备版编译与 IPA 校验成功；本机再次校验交付包通过。
- 独立完整流程已成功，iPhone、iPad 各 18 项 XCTest 通过、零失败，生成两种模拟器截图并完成设备版编译；截图生成不等同于实际滑动交互验收。
- 已人工检查 iPhone 截图及 iPad 缩放预览：确认三个导航入口（iPhone 底部、iPad 系统顶部）、左上角品牌及侧栏图标已移除、首页四个分类等宽铺满一行，且实际漫画列表已加载。
- 实际滑动等界面交互、真机安装及用户证书签名尚未验收。

## 2.0 云端构建与交付包（2026-11-22）

- 公开源码仓库：[hahahalucas/Komiic](https://github.com/hahahalucas/Komiic)，采用 [MIT 许可证](../LICENSE)。
- [设备版构建 44991028791](https://github.com/hahahalucas/Komiic/actions/runs/44991028791)：成功；环境为 macOS 26、Xcode 26.6、iOS SDK 26.5。
- 构建分支为 `codex/komiic-2.0-device`，提交 [`602fc8e57355a74c9fe7f12e5c3bf9423aa1ac56`](https://github.com/hahahalucas/Komiic/commit/602fc8e57355a74c9fe7f12e5c3bf9423aa1ac56)。它与主分支提交 [`0acf31893ffa933f5eb3b1c67cb1b2924d0ef7e9`](https://github.com/hahahalucas/Komiic/commit/0acf31893ffa933f5eb3b1c67cb1b2924d0ef7e9)相比仅调整构建工作流，设备打包使用 `--skip-tests`；App 源码完全一致。
- 交付 IPA 来自该设备版任务；该任务未运行模拟器测试或生成截图。同一 App 源码的[独立完整流程 44989974389](https://github.com/hahahalucas/Komiic/actions/runs/44989974389)已成功，iPhone、iPad 各 18 项 XCTest 通过、零失败（两次 `TEST SUCCEEDED`），生成两种模拟器截图，并完成设备版编译（`BUILD SUCCEEDED`）。
- [完整验证产物](https://github.com/hahahalucas/Komiic/actions/runs/44989974389/artifacts/14742196424)包含测试结果、截图、构建日志与独立重建的 IPA，保留至北京时间 2026-11-29 13:54:02。其 ZIP 为 123,949,022 字节，SHA-256：`e30cbbbf35ba530c62467ebc0ae419e0f250f8a4c546f75ec6af690bc75af1fc`；本机归档位置为 `build/Komiic-2.0-full-verification.zip`，提取的测试日志与截图位置为 `build/verified-artifacts-2.0/`。
- 本机已核对完整产物 ZIP 散列及两份测试日志（各 18 项、零失败，均含 `TEST SUCCEEDED`）；设备包与完整测试的合并证据摘要为 `build/verified-artifacts-2.0/build-summary.json`。
- 完整流程另一次重建的 IPA SHA-256 为 `006ddcfe1d4bf9333f4d39b4b343115c20d1d96e60996ee2485389237e612df8`，与下面交付副本属于不同构建产物；交付包仍取自已成功的设备版任务。
- [设备版云端产物](https://github.com/hahahalucas/Komiic/actions/runs/44991028791/artifacts/14742335404)包含默认名称的 IPA、构建日志和校验报告；本机保存至 `build/device-artifacts-2.0/`，并另存带版本号的交付副本 `Komiic-2.0-iPhone-iPad-unsigned.ipa`。
- 交付包：版本 **2.0**、build **2**，822,136 字节；SHA-256：`e5cede98818e5c1a5a2930fb7337292835159a1d88088db647cf5ca2bfab8615`。
- 云端及本机校验确认：真实 arm64 Mach-O、iOS 设备平台（platform 2）、SDK `iphoneos26.5`、最低系统 17.0、同时声明 iPhone 与 iPad、SwiftUI 链接及 unsigned 签名结构。未使用用户证书，安装前需要自行签名。

以下 2026-11-19 的云端记录和根目录旧包 `Komiic-iPhone-iPad-unsigned.ipa` 均属于 **0.1.0 历史版本**。

## 0.1.0 历史云端构建结果（2026-11-19）

- [GitHub 构建 44373961155](https://github.com/hahahalucas/pix-assistant/actions/runs/44373961155)：成功。
- 源码：独立分支 `komiic-ios-build`，提交 `2e398223fb5e0bbd2620bc2c8757a4f5ffefeb55`。
- 环境：macOS 26，Xcode 26.6，实际 iOS SDK 26.5。
- iPhone 与 iPad 各 18 项 XCTest，零失败；两次 `TEST SUCCEEDED`。
- Release 设备编译 `BUILD SUCCEEDED`，已实际启动两种模拟器并保存截图，确认首页加载官网漫画并显示原生玻璃导航。
- IPA：`Komiic-iPhone-iPad-unsigned.ipa`，856,014 字节，包含 arm64 iOS 设备可执行文件，支持 iPhone 与 iPad，最低系统 17.0；Liquid Glass 需要系统 26+。
- IPA SHA-256：`34d6a348c102c684cc7ae24625fd5e2f30137f45a5ad9b1946d80df31c5c3eee`。本机下载后再次校验通过，与云端一致。
- [云端产物](https://github.com/hahahalucas/pix-assistant/actions/runs/44373961155/artifacts/14460903224)包含 IPA、日志、测试结果及实际截图，保留至北京时间 2026-11-26 03:02。项目根目录已保存 IPA，`build/verified-artifacts/` 保存精简验证资料及截图。
- 任务运行 12 分 45 秒，按标准 macOS 每分钟 0.062 美元、分钟向上取整估算约使用 0.81 美元计算额度。这不是实际账单；连接无账号账单权限，无法读取剩余额度，另有产物存储用量。

## 0.1.0 历史验证记录

- 实际访问 Komiic 第一方页面及当前脚本，核对 GraphQL 操作、官网路由、Cookie 和图片票据流程。
- 实际 HTTP 请求验证最新更新、月热门、最近上架、推荐、搜索、漫画详情、章节、页面元数据和图片票据。
- 一次图片请求取得 HTTP 200、`image/webp`、256,378 字节。无票据或用户账号资料写入验证记录。见 [`live-api.json`](live-api.json)。
- `python scripts/verify_project.py --require-swift-parser`：工程 OpenStep 结构、引用目标、Debug/Release 配置、共享 scheme、资源文件和 Swift 语法树通过。
- 添加 18 个 XCTest 测试源码，覆盖网络错误分类、搜索完整结果、模型解码、图片票据过期刷新、并发会话刷新协调、资料库存储恢复、离线读取及缺页恢复。
- 隐私清单覆盖自身 `UserDefaults`、App 容器文件日期/大小、可用磁盘容量展示的访问理由；对应 [`Apple 文档`](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。

语法检查使用 `tree-sitter 0.26.1` 和 `tree-sitter-swift 0.7.4`，检查语法错误节点，不进行 Swift 类型检查或 Apple 框架可用性检查。

## 尚未完成的功能验证

以下各项尚未验证：

- 真实 iPhone / iPad 安装与设备上的全部界面交互、无障碍和方向切换。
- 真实账号登录、Cookie 持续刷新及退出。
- 完整章节的实际下载、退出 App 后恢复、飞行模式阅读。
- 通知授权、本地下载完成提醒、文件 App 导出/拷入恢复。

## Mac 验收步骤

1. 用 Xcode 26+ 打开工程，在 iOS 26+ iPhone 模拟器和 iPad 模拟器分别构建运行。确认版本为 3.0、build 3，根导航仅有首页、喜爱、资料库，左上角装饰图标与侧栏切换入口均已移除。检查资料库的书签与书柜、iPad 窄窗口、浅色/深色和字体放大后的布局。
2. 执行 `Product → Test`，确认 `KomiicTests` 的 36 项测试通过。测试不调用真实站点或修改用户的本机资料。
3. 确认首页四个主分类等宽铺满一行。依次左右滑动最近更新、最近上架、当月最热、推荐漫画、最近阅读，检查页面跟随手指移动、松手后的完成或回弹、首尾边界及分类选中状态；点击主分类和更新 / 上架分段时也应有切换动画。检查连续快速滑动、纵向滚动、返回首页以及减少动态效果设置。
4. 在不同目录页调整分级、连续刷新并载入更多，确认每次下拉均出现加载并请求，即使结果没有变化也正常结束。测试刷新期间切换分类/筛选、网络失败、取消后重试。点击搜索立即显示搜索栏；搜索超过 30 条结果，点入漫画应直接显示详情，返回首页而非搜索页。
5. 打开漫画，点击原位置的作者姓名，确认进入该作者全部作品并能打开漫画。检查简介下分级的 0 级、非零级、暂无评级及说明。切换卷、话等分组，验证每行四格、数值顺序及升降序；详情顶部和系统标签栏保持既有布局。
6. 仅阅读第 5 话后返回详情，确认只标暗第 5 话，眼睛展开后的第 1–4 话仍为未读；连续读第 10–12 话最多保留第 11–12 话暗格；第 11 话未读而第 12 话已读时只保留第 12 话暗格。先读较后章节再回读前章，关闭并重开详情，定位应跟随最后阅读章节。检查眼睛展开/收起及右下继续阅读按钮在 Liquid Glass 标签栏上方的位置，继续时恢复最后章节和页码。阅读器仍需检查滚动、翻页、跳页、书签、页码边界和阅读方式切换。
7. 创建书柜、添加漫画、重命名、移出、删除；添加喜爱、屏蔽/解除屏蔽，重启后核对本机资料恢复。
8. 在账号中登录真实 Komiic 账号并关闭网页，验证原生图片请求使用最新会话；官网退出后确认原生会话状态也更新。核对官网收藏入口和本机收藏的独立提示。
9. 从详情下载章节，测试断网失败和重试。完成后开启飞行模式，从相应漫画章节读取已完成下载的页面；清理在线缓存后仍可读取。2.0 已移除独立离线入口。
10. 删除一个离线图片再扫描恢复，章节应变为未完成；通过文件 App 备份/拷入恢复清单，验证损坏清单保留而不误报完成。
11. 验证 iPhone 方向锁定、iPad 可变窗口、灰阶墨水模式和柔和显示；检查原生液态玻璃与减少透明度设置；测试通知授权拒绝/允许后的下载完成提醒。
12. 验证 HTTP 401/403、402、429 以及 GraphQL 限额错误的用户提示。检查登录、额度、票据及任何私密 Cookie 不出现在日志和导出清单。

## 发布前

工程当前使用示例 Bundle Identifier，需要开发者设置签名及发布资料。发布前应完成以上 Mac/设备验证、核对官网接口使用条件，并针对实际发布版本填写 App Store 隐私信息；本次没有执行签名、分发或上架。
