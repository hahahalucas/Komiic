# 0.9.0 验证记录

当前源码为 **0.9.0（build 9）**，基于已验证的 0.8.0。

- 竖屏整话只使用一个原生缩放画布，所有页面共同缩放；横屏两页共用一个画布，保留左右阅读顺序和奇数末页。最小 1 倍、最大 5 倍、无缩放回弹，换页/换话/旋转恢复原比例。
- 根据画布中的实际可见范围只创建可见页及附近图片，放大时仍能在整话上下移动；保留原图缓存、离线下载及整话预加载。
- 顶部控制条从未忽略安全区域的外层读取顶部安全间距，再增加 8 点；图片在内层继续铺满屏幕。
- 首页缓存按分区、账号会话、列表及筛选隔离，保存最多 90 部漫画及续页位置。重启读缓存，下拉刷新重新请求。
- 账号、官网收藏/历史/书柜/屏蔽的快照按会话和分区保存；账号变化取消旧请求，旧响应不能覆盖新账号。缓存失效/损坏回退网络，网络失败保留已显示内容。
- Session-only 官网 Cookie 使用本机 Keychain 保存，尊重显式到期日；访问 Cookie 缺失但仍有刷新 Cookie 时可以续期。原生请求共用连接池，同步官网 Cookie 的并发操作合并，退出登录期间拒绝旧会话回写。

以 21 项画布、持久化及会话测试替换 0.8.0 的 5 项单张图片缩放测试，并新增缺失访问 Cookie 的续期、退出登录并发保护测试。合计 118 项/设备。Windows 工程结构与严格 Swift 语法检查已通过；本版 Xcode 编译、iPhone/iPad XCTest 和 IPA 校验待云端执行。

真机验收项目：竖屏从任意页双指放大并继续上下阅读；横屏检查两页一起放大和两种阅读方向；收拢到原比例停止；隐藏/显示控制条，确认灵动岛下方可点击；杀掉重开 App 确认首页、账号和书柜立即恢复；下拉刷新及退出/切换账号核对隔离。当前未进行真机手势和真实账号人工验收。

# 0.8.0 验证记录

当前源码版本 **0.8.0（build 8）**，基于已验证的 0.7.0。

- 阅读图片使用 `UIScrollView` 原生双指缩放和拖动，`minimumZoomScale = 1`、`maximumZoomScale = 5`、`bouncesZoom = false`；原始适配尺寸为下限。翻页、换话、切换阅读方式及屏幕尺寸变化时重置，保持原图分辨率和既有图片缓存流程。
- 原比例时图片不拦截单指滚动/翻页；放大后由图片接收拖动，外层滚动和章节末尾上拉跳转暂停。父级翻页手势只处理单指拖动。
- 书柜通过 `BookshelfRoute` 加入根 `NavigationPath`，漫画继续使用 `Comic` 值导航，避免混用视图目标和路径目标造成详情被书柜遮住。
- 最近阅读移除直接打开阅读器的 action 和全屏呈现，改为普通漫画详情导航，主页「继续阅读」继续使用原进度。

新增 5 项 UIKit XCTest，覆盖缩小下限、放大拖动与还原后的滚动、普通更新保持缩放、换页/旋转/换图重置，以及嵌套滚动手势配置。现有 95 项保留，共 100 项/设备。

Windows 本地工程结构及严格 Swift 语法检查通过（43 个 Swift 文件）。2026-11-26（Asia/Shanghai）[完整云端构建 45655410195](https://github.com/hahahalucas/Komiic/actions/runs/45655410195)成功：Xcode 26.6 / iOS SDK 26.5 的设备 Release 编译及 IPA 校验通过，iPhone、iPad 各 **100 项 XCTest** 全部通过，共 **200 项、零失败**。五项新增缩放测试在两种设备上均通过，日志分别包含两次 `TEST SUCCEEDED` 和一次设备版 `BUILD SUCCEEDED`。

- 基于 0.7.0 最终记录提交 `6baa1d71d1a598a4bc35f2564a96b5a6811756a7`，构建分支为 [`codex/komiic-0.8.0`](https://github.com/hahahalucas/Komiic/tree/codex/komiic-0.8.0)，实际 App 构建提交为 [`edb576bb508fd1b9fab3f4b6911724ce7bfc2f48`](https://github.com/hahahalucas/Komiic/commit/edb576bb508fd1b9fab3f4b6911724ce7bfc2f48)。上传时全部 43 个 Swift 源文件的 Git blob 散列与本地工作区一致。
- [下载 0.8.0 IPA 及完整验证资料](https://github.com/hahahalucas/Komiic/actions/runs/45655410195/artifacts/15043018905)，包含 `Komiic-iPhone-iPad-unsigned.ipa`、两份 XCTest 结果、iPhone/iPad 首页截图和构建日志。ZIP 共 129,933,354 字节，GitHub 提供的 ZIP SHA-256 为 `41b400f7a0352e91189a1be9f3568d2edda9d15d42ee469c3d0590da64ac809c`，保留至北京时间 2026-12-03 00:53:18。
- 云端直接检查 IPA 的版本为 `0.8.0`、arm64 iOS 设备代码、iPhone/iPad 支持、最低系统 17.0、iOS SDK 26.5，且无签名结构。IPA SHA-256：`5886494138e4c694b10e45a9c30e9b46420b07fec76e6c89a6c5f9c7dbc9afba`。安装前需自签。
- 普通及 H 两个官网的首页、合并详情与公开封面共 6 项检查全部通过，见 [0.8.0 接口记录](v0.8.0-api.json)；记录保留原检查脚本的版本字段，并用 `appVersion` 标注本次 App 版本。结构化构建证据见 [0.8.0 构建记录](v0.8.0-build.json)。
- 本地执行环境在源码上传后断开，因此未进行本机二次解包校验或独立重算 Artifact ZIP 散列；上述 IPA 检查由云端构建脚本执行。未进行真机双指手势和导航的人工验收。

交互验收：分别在纵向滚动、横向翻页和 iPad 横屏双页模式下双指放大、平移并收拢至原比例；确认不可继续缩小，放大拖动不跳页/跳话，还原后滚动正常。进入书柜再打开漫画应直接显示漫画详情，返回一次回到同一书柜；最近阅读先进入漫画主页，再点击「继续阅读」恢复原位置。

# 0.7.0 历史验证记录

当前源码版本 **0.7.0（build 7）**。基于已验证的 0.6.0，优化官网接口与图片加载：

- `DownloadStore` 使用官网 API 的共享会话获取图片票据，复用首页与详情已有的连接池。私有图片仍使用独立的无 Cookie 图片会话及官方票据。
- 详情页通过一个 GraphQL 查询同时读取漫画信息与章节目录，保留原有作者、分级、域名归一化与章节排序。
- 封面和阅读图片通过 Image I/O 在后台解码；封面最长边为 640 像素，原图保留原始分辨率及 EXIF 方向。实现依据 [Apple 的 Image I/O 解码说明](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)。
- 在线缓存的读取、校验及原子写入移到专用文件队列。每次写入只增量更新字节数；启动及明确的缓存维护才扫描目录。文件队列内校验缓存代次，防止清理后旧请求重新创建缓存；快照序号防止过时统计覆盖新值。
- 预加载并发上限保持 3，后续页面顺序随当前阅读位置改变，不重启已完成或正在执行的请求；遇到登录、限额及限流停止后台流量。

新增 12 项 XCTest，覆盖单次详情请求及不存在的漫画、原图与缩略图尺寸、无效数据、EXIF 方向、并发封面复用、缓存覆盖计数、旧代次写入、分章节清理与新代次、过期缓存、跳页优先级及额度中止。原有 83 项继续保留。

2026-11-23（Asia/Shanghai）Windows 本地工程结构及严格 Swift 语法检查通过，41 个 Swift 文件无语法错误。首次沙箱网络检查受到限制；获得网络访问后，对普通及 H 两个官网各检查首页、合并详情与公开封面，共 6 次请求均返回 HTTP 200。云端再次完成相同 6 项检查并通过，见 [0.7.0 接口记录](v0.7.0-api.json)。

2026-11-24（Asia/Shanghai）[完整云端构建 45208173469](https://github.com/hahahalucas/Komiic/actions/runs/45208173469)成功：Xcode 26.6 / iOS SDK 26.5 设备 Release 编译及 IPA 校验通过，iPhone 和 iPad 各 **95 项 XCTest** 全部通过，共 **190 项、零失败**。两份设备测试日志均包含 `TEST SUCCEEDED`，设备编译日志包含 `BUILD SUCCEEDED`。

- 源码基于已验证的 0.6.0 提交 `955824db16bc28b806ab4e652eaf1aba9191d222`，构建分支为 [`codex/komiic-0.7.0`](https://github.com/hahahalucas/Komiic/tree/codex/komiic-0.7.0)，实际构建提交为 [`bc4bfde7270bd21d40a99e083b3d860af9b85518`](https://github.com/hahahalucas/Komiic/commit/bc4bfde7270bd21d40a99e083b3d860af9b85518)。全部 41 个 Swift 源文件的 Git blob 散列与本地工作区一致。
- [下载 0.7.0 IPA 及完整验证资料](https://github.com/hahahalucas/Komiic/actions/runs/45208173469/artifacts/14835749218)，包含 IPA、两份 XCTest 结果、iPhone/iPad 首页截图和设备编译日志。Artifact 保留至北京时间 2026-12-01 00:02:22。
- 完整产物 ZIP 为 125,387,701 字节，SHA-256：`133bfac976fd02602569fcd61612bf2d087b137f0a9c475d5979c9fa3227a010`，本地核对与 GitHub Artifact digest 一致。
- 交付文件 `Komiic-0.7.0-iPhone-iPad-unsigned.ipa` 已保存至项目根目录，1,321,336 字节；版本 0.7.0、build 7、arm64 iOS 设备平台、最低 iOS 17、iPhone/iPad 支持、SwiftUI 链接及未签名结构本地再次校验通过。IPA SHA-256：`67b0939a743c8ca6c256d6844d46428f1b80fd8f06eab190feb945e84c0139ac`，与云端报告一致；安装前需自签。
- 完整记录见 [`v0.7.0-build.json`](v0.7.0-build.json)，本地精简验证资料位于 `build/v0.7.0-verified-artifacts/`，完整归档为 `build/Komiic-0.7.0-full-verification.zip`。
- 已检查 iPhone 首页截图，确认官网漫画和封面正常显示。真机安装、受保护漫画的真实账号读取及手机端速度测量尚未执行；现有结果不代表这些验收已经完成。

接口检查脚本 `scripts/verify_loading_api.py` 仅发送公开只读查询与封面请求，不携带 Cookie、不获取图片票据、不写入账号数据。脚本跟随官方 CDN 重定向，并识别以 `application/octet-stream` 返回的真实 JPEG 封面；App 原有封面解码同样支持这种响应。报告的耗时仅代表执行环境的网络，不能当成手机端提速百分比。

---

# 0.6.0 验证记录

当前源码版本 **0.6.0（build 6）**。打开章节后自动进行整话预加载，优先当前阅读位置，最多同时预加载 3 页；页面显示、预加载与离线下载复用图片请求。切章、退出与清理缓存会停止旧预加载，后台单页失败不阻塞其余页面。

阅读器持续隐藏系统状态栏，显示控制条不会重新显示时间、电量或 Wi-Fi；控制条及按键位置保持 0.5.0 原样。底部在线阅读/自动缓存提示行已删除。

2026-11-23（Asia/Shanghai）本地检查通过：`python scripts/verify_project.py --require-swift-parser`、`git diff --check`，38 个 Swift 文件无语法错误。新增 6 项 XCTest，覆盖整话缓存、并发请求合并、失败重试、取消加载、清理期间的旧请求及离线下载复用。

[完整云端构建 45184721681](https://github.com/hahahalucas/Komiic/actions/runs/45184721681)成功；Xcode 26.6 / iOS SDK 26.5 的设备 Release 编译与 IPA 校验通过。iPhone 和 iPad 各 83 项 XCTest 全部通过，共 166 项、零失败，两次 `TEST SUCCEEDED` 及一次设备版 `BUILD SUCCEEDED` 均有日志。

- 源码基于已验证的 0.5.0 提交 `ae33bc55db285059038b9ee8afae908a1ec6afc6`，仅修改 8 个发布相关文件。
- 构建分支为 [`codex/komiic-0.6.0`](https://github.com/hahahalucas/Komiic/tree/codex/komiic-0.6.0)，构建提交为 [`00c6ff0301a5acaa3da3843ad599d38f22439509`](https://github.com/hahahalucas/Komiic/commit/00c6ff0301a5acaa3da3843ad599d38f22439509)。
- [下载 0.6.0 IPA 及完整验证资料](https://github.com/hahahalucas/Komiic/actions/runs/45184721681/artifacts/14824662819)，包括 IPA、两份 XCTest 结果、两种设备的首页截图、设备编译日志及 IPA 检查报告。Artifact 保留至北京时间 2026-11-30 21:55:42。
- 完整产物 ZIP 为 139,398,065 字节，SHA-256：`974be23639f1ac3eabd6a94f40b89651fc841cca6f69a5db8abf402874ffd58f`。
- 交付文件为项目根目录的 `Komiic-0.6.0-iPhone-iPad-unsigned.ipa`，1,294,042 字节。本机再次校验版本 0.6.0、build 6、arm64 iOS 设备代码、iPhone / iPad 支持、最低 iOS 17、SwiftUI 链接与未签名结构，均通过。
- IPA SHA-256：`28bfab59da9d2281704ca09ecae45b4383a9d29284c6ae744de518ace08d0d3e`，与云端报告一致；安装前需自签。完整构建、测试及包信息见 [`v0.6.0-build.json`](v0.6.0-build.json)，本机验证资料位于 `build/v0.6.0-verified-artifacts/`。
- 模拟器截图为首页；阅读器状态栏与关闭按钮的实际触控、横竖屏交互及真机安装尚未人工验收。

以下 0.5.0 及更早记录仅属于历史版本。

---

# 0.5.0 验证记录

源码版本 **0.5.0（build 5）**。本地 Windows 工程结构及 Swift 语法检查通过；Xcode 26.6 / iOS SDK 26.5 的设备 Release 编译及 IPA 校验通过。iPhone 和 iPad 各 77 项 XCTest 通过、零失败，两种模拟器截图及完整流程的设备编译均成功。

[下载 0.5.0 IPA 产物](https://github.com/hahahalucas/Komiic/actions/runs/45043225501/artifacts/14761494948)，ZIP 内为 `Komiic-iPhone-iPad-unsigned.ipa`。包内版本 0.5.0，App 工程 build 5，arm64 iOS 设备代码、iPhone/iPad 支持、最低 iOS 17 与未签名结构校验通过。IPA SHA-256：`ec5383b66af30fb4e0975634426792f38c66a91cdbbfcf07a61fe3338fe79933`。

设备包提交 `442501291a0f37d8054a20a259289891ea813180` 和模拟器提交 `92a4226de3e6e7cc8fc090166ac393869c184df2` 仅工作流不同，App 源码完全一致。完整构建信息见 [0.5.0 构建记录](v0.5.0-build.json)。

新增回归覆盖：官网书柜/屏蔽的读写、删除与退出恢复、本机待重试操作的账号隔离；首页/账号首次加载与主动刷新；双页顺序、奇数尾页、步长；附近五话边界及按话数切换；警告封面显示状态与完全隐藏优先级。

2026-11-22T16:08Z 云端只读核验了两个官网域名的 schema 和第一方客户端脚本，确认 `folders`、`folderComicIds`、`createFolder`、`removeFolder`、`addComicToFolder`、`removeComicToFolder`、`updateFolderName`、`blockedComicIds`、`blockComic`、`unblockComic` 的操作名、参数和返回类型，见 [0.5.0 接口记录](v0.5.0-api.json)。App 直接使用这些已确认的操作；失败保留快照及待重试操作。脚本 `scripts/inspect_collections_api.py` 仅检查公开协议，不登录或发送 mutation。

实际登录账号的双向同步、iPad 真机双页和章节末尾手势仍需实际设备验收。测试源码与静态语法检查不等于这些验收已通过。

---

# 历史验证记录

日期：2026-11-22（Asia/Shanghai）。

当前源码版本为 **0.4.0（build 4）**，基于本工作区 v3.0 升级。当前仅完成源码与 Windows 静态验证；未生成或交付 0.4.0 IPA，未将历史构建视为本次版本通过的证据。

## 0.4.0 更新与验证

- 搜索入口为居中弹窗，保留背景页面；提交后沿用完整结果、防抖和点入详情后返回首页的路由。
- 移除通知按钮和动态页。右上角菜单保留屏蔽、内容警告偏好、模式和主题四项；账号移到底部第四个标签，通用设定页移除。
- 账号卡片从官网读取真实资料、阅读/图片/评论统计及常读分类；未登录与网络错误有独立状态。
- 内容警告匹配官网 11 个标签，SHOW/WARN/HIDE 对应显示/模糊/隐藏；SHOW mutation 发送 null 以移除覆盖设置。偏好立即持久化，失败保留待重试项。
- 普通/H 模式分别使用 komiic.cc 与 h.komiic.cc，推荐还显式传入 adult 和 contentType；列表、搜索、作者、详情、阅读、图片票据和分享链接使用对应域名。
- 已联网验证两种模式的更新、上架、热门、推荐八组公开请求：均 HTTP 200、无 GraphQL 错误，类型全部符合所选模式。未登录账号查询的 no token 响应已映射为未登录，见 [接口证据](v0.4.0-api.json)。可使用 scripts/verify_live_api.py 重复公开只读探测，不需要用户账号。
- 本机存档升级为分区存储，旧 v3 资料迁移到普通区；H 区独立。模式启动时直接打开相应存档，异步回填与阅读器结束保存捕获原模式。
- 官网喜爱和最近阅读使用按模式的官方接口；写入合并并持久化待重试队列。账号身份和模式校验避免将待重试操作发给另一个账号。登录后的喜爱和历史以官网快照为准并叠加待同步编辑；官网删除后刷新即消失。快照与本机存档分开，退出时恢复独立本机资料。
- 新增测试源码覆盖模式隔离/重启/旧档迁移、捕获模式的异步写入、官网请求形状、真实统计解码、警告偏好持久化与优先级、云端同步与重试。测试运行仍需 macOS/Xcode。
- Windows 验证：全部 **32 个 Swift 源文件**通过工程结构及严格语法检查，git diff --check 通过。当前共有 **61 项 XCTest 源码**，其中本次增加 25 项；未执行测试。Swift 语法树检查不进行类型检查，不等同于 Xcode 编译或 XCTest 通过。

### 0.4.0 必须在 Mac / 设备验收

1. 使用 Xcode 26+ 构建并执行全部 XCTest，在 iPhone 与 iPad 上运行；核对版本 0.4.0、build 4。
2. 确认四个底部入口；右上无通知、无巨大的账号/设置 sheet。菜单中不再列出账号和设定；黑白主题可立即来回切换并跨重启保留。
3. 从任意底部标签打开搜索，确认中央弹窗和背景遮罩；取消停留原页，提交进入结果，选择漫画进入详情，返回首页。测试长关键词、无结果、断网和键盘布局。
4. 使用真实官网账号登录：核对头像/姓名/邮箱/加入日期、阅读/图片/评论统计、常读分类及四项收藏统计；官网资料入口打开正确的模式和官方路由。退出后不残留官网用户资料。
5. 在官网及 App 中分别修改内容警告，验证 SHOW/WARN/HIDE、多个标签的隐藏优先级、退出重开、断网后重试；在首页/搜索/作者/喜爱/最近阅读/书签/书柜核对封面及隐藏行为。
6. 依次切换一般/H：所有四类首页重新请求并只显示对应内容；快速反复切换与重启也不得短暂显示上一模式的收藏/历史。测试作者、详情、阅读、下载和分享使用对应官方域名。
7. 分别在两个模式加入不同喜爱、阅读不同章节，核对官网及 App 中互相隔离；另在官网增删喜爱/更新进度，回到 App 刷新后核对。验证断网写入、恢复网络、退出并切换账号后待重试操作不会发给新账号。
8. 用 v3 存档升级，核对原喜爱/书柜/书签/阅读进度完整保留在一般区；H 区独立。屏蔽漫画显示可识别名称/封面，旧 ID 可补查，解除后可见。
9. 回归 v3 目录折叠、真实已读、继续阅读、横竖阅读、图片额度与离线阅读功能。

以下均为 **3.0、2.0 和 0.1.0 历史记录**。其中当时的待确认状态未在本次回查，不代表 0.4.0 的编译、测试或交付状态。

## 3.0 验证状态

- 下拉刷新每次重新请求第一页，保持已有内容及可见加载状态；相同结果也完成刷新。旧请求不能覆盖新筛选结果，失败和取消后可重试。
- 点击搜索立即展开搜索栏；结果使用统一导航路由直接进入漫画详情，从漫画返回首页。
- 作者姓名保留原位置并作为作品入口。模型保存作者 ID，旧存档的姓名数组继续可读；缺少 ID 时可搜索作者并精确匹配姓名。
- 简介下增加五颗心的色情程度及官方说明，区分 0 级与暂无评级。
- 章节按卷、话等类型分组，每行四个方块。暗格只来自实际已读 ID；折叠位置按最后阅读章节确定，最多保留该章节及其紧邻上一章的两个已读暗格，未读间隔中断相邻关系。较早章节与其余已读章节以眼睛方块折叠，可展开查看。
- 已有进度的漫画在右下角显示 Liquid Glass 继续阅读按钮，恢复最后章节及页码，按钮位于系统标签栏上方。
- 本地 `python scripts/verify_project.py --require-swift-parser` 通过：工程引用、共享 scheme、资源及全部 26 个 Swift 源文件语法树无错误节点。`git diff --check` 通过。
- 当前共有 **36 项 XCTest 源码**：原有 18 项，加作者/分级及兼容性 5 项、章节目录 7 项、跳章持久化 1 项、刷新及取消 5 项。3.0 云端编译与测试已启动，结果尚未确认；模拟器交互及真机安装仍待验收。
- 源码已上传至 [`codex/komiic-3.0`](https://github.com/hahahalucas/Komiic/tree/codex/komiic-3.0) 独立分支，提交 [`9e9e97414bfaf017e0658f565c748a3b018d40c7`](https://github.com/hahahalucas/Komiic/commit/9e9e97414bfaf017e0658f565c748a3b018d40c7)，并启动 [Mac 云端构建 44999974479](https://github.com/hahahalucas/Komiic/actions/runs/44999974479)。测试与 IPA 仍待结果，尚无已验证的 3.0 交付包；根目录的 2.0 与 0.1.0 历史包不能代表本次源码。

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
