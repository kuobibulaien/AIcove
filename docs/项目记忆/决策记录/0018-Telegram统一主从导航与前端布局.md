# 0018 · Telegram统一主从导航与前端布局

- 日期：2026-09-11
- 状态：superseded，由 [ADR0019](0019-Mac基准与全端共用界面架构.md) 取代当前架构要求；本文件保留已完成批次的实现与验证记录。
- 现行规则：[全端共用界面架构与布局规范](../../../apps/aicove_flutter/docs/界面布局说明.md)。下文桌面专属样式、手机另行改版及渐变首字头像均为历史事实，不作为后续开发要求；当前默认头像为空白。
- 授权：用户明确要求完全重写前端、丢弃旧宽屏布局；随后明确联系人单列且不需要“全部／未读”。本次请求取代 ADR0016 回退时的局部修改范围。

## 背景与参考

原首页按宽度创建 MainPage 或 SplitChatPage，两套页面和导航逻辑分离；一级设置与聊天详情不能稳定共存，跨断点还会重建页面。

参考 Telegram 的主从导航、列表、标题栏与消息呈现，自行使用 Flutter 实现，没有复制上游源代码或引入 Telegram 依赖：

- [Telegram Web A 主布局](https://github.com/Ajaxy/telegram-tt/blob/master/src/components/main/Main.scss)
- [Telegram Web A 左栏](https://github.com/Ajaxy/telegram-tt/blob/master/src/components/left/LeftColumn.scss)
- [Telegram Desktop 自适应实现](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/window/window_adaptive.cpp)
- [Telegram macOS 客户端](https://github.com/overtake/TelegramSwift)
- 用户提供的 Telegram macOS 联系人截图：一级单列列表、底部导航，右侧显示选中会话。

## 决定

1. `MoeAdaptiveShell` 统一承载 MainPage 和一个持久的详情 Navigator。小于900逻辑像素时按单栏进退；达到900时左栏默认360，允许320–440之间拖动，右栏保留至少460。双击分隔条恢复默认宽度。
2. 一级导航只有聊天、角色、设置；手机界面直接作为宽屏左栏。联系人始终一列，保留搜索、新建、置顶、静音和删除，不加“全部／未读”筛选。角色入口也使用垂直列表。
3. 二级及更深页面统一进入详情 Navigator。一级页使用 `MoeWorkspace.open`，已有详情页可以继续 `Navigator.of(context).push`。声明式聊天路径用 `MoeWorkspace.openLocation`：宽屏可替换当前聊天，但只要栈内存在 PopScope 保护的编辑页，就改为入栈，返回可恢复编辑内容。
4. 跨断点不更换 Navigator 和一级页的元素身份，保留草稿、导航栈、搜索和标签状态。窄屏退出完成前保持详情层挂载，等待 `TransitionRoute.completed`；隐藏状态在下一帧通知，并主动申请帧。
5. 统一白色／深蓝标题栏、蓝色选中行、圆形头像、灰色搜索输入、浅绿／深蓝消息背景。Mac 原生窗口按钮只由窗口左缘所在面板避让；右侧详情不重复留白。编辑页使用固定标题栏，表单继续延迟挂载。
6. 删除旧 SplitChatPage。历史皮肤ID保持 `moetalk`，默认显示外观改为 Telegram；缺省主题色为蓝色，已保存的用户主题色（包括粉色）和自定义聊天背景继续保留，不改写设置。无数据库、业务端口、模型协议或依赖升级。

## 备选与代价

- 继续维护宽窄两套页面：改动较少，但不符合一级界面左置的要求，缩放丢状态问题仍存在。
- 为所有设置重写独立桌面版本：重复业务和导航，不采用。
- 采用统一主从壳：需要一级入口定向到详情 Navigator；详情弹窗的默认作用域跟随所属 Navigator。未保存的编辑页在聊天下面保留，会暂时增加栈深度。
- 此次重写统一布局、主入口与公共视觉组件，复用既有功能表单及消息业务；不是逐像素复制截图中的壁纸素材。

## 验证与边界

`flutter pub get` 成功；31个相关源码／测试项静态检查无问题；114项相关回归通过，覆盖真实首页搜索、聊天、模型管理、角色编辑、320–1280宽度、1.0–2.0字号、连续进退、草稿、模型选择、附件和消息布局。原生画面发现空白页缺少 Material 导致黄色下划线，先补失败回归，再修复；最后9项导航／真实页面复测通过。

macOS Debug 编译与 `flutter run --no-resident -d macos` 成功，实际检查1250×850与420×820窗口。测试未发送真实模型请求；手机日志采集缺少本机读取凭证，未重装手机或宣称手机验收。Windows、Android、iOS未做平台实机验证。第三方Pod仍有旧最低系统版本构建警告；一次调试运行出现Flutter HardwareKeyboard重复Space KeyDown断言，未将其归因为业务布局，未更换框架或屏蔽断言。

## 回滚

工作树开工时已有大量未提交修改，禁止按HEAD整体恢复。此次源文件前镜像位于 `.codex-temp/telegram-frontend/before.tar.gz`，SHA记录与范围差异在同目录。仅对 `changed-files.json` 所列本次文件逐项恢复；归档内可能包含开工前已有的用户修改。新增文件可移至临时目录，原文件从归档恢复；不要覆盖后续并行编辑。测试原件另存 `*.before.dart`。未提交仓库。最终Release 99.9MB已更新到 `/Applications/AIcove.app` 并独立启动；安装二进制与构建产物SHA一致，codesign严格验证通过。旧安装版备份为 `.codex-temp/telegram-frontend/installed-before/AIcove.app`，需要回退时退出本轮安装版后从该目录恢复。


## 追加：桌面悬浮样式（2026-09-11）

用户追加要求精致化并参考截图中的悬浮菜单，手机端大改安排后续。桌面端采用独立资料胶囊、操作胶囊和悬浮输入区，沿用真实话题整理与聊天操作；联系人仍一列且没有全部／未读。默认背景为Flutter绘制的淡色渐变线稿，不复制上游图片。已有自定义头像和聊天背景优先，空头像使用确定性的渐变首字。

`MoePopupMenu` 在桌面默认显示锚定按钮的纵向圆角菜单，沿用所属Navigator与Flutter菜单的滚动、键盘、边界约束。聊天右上菜单提供搜索、资料、置顶、免打扰、设置和宽屏关闭聊天；设置中原有编辑、背景、插件等功能保留。资料胶囊高度根据系统字号和实际行高计算，避免固定56高度在1.8倍字号溢出。模糊仅用于裁剪后的三块控制区域，背景纹理无动画并隔离重绘。

此次同时纠正首轮默认色处理：缺少accent_color时默认3390EC，异步加载回退一致；直接尊重已保存的颜色，不在显示层把用户粉色强制转蓝。不做配置迁移。

验证：119项相关回归通过，包含长菜单／窗口边缘／大字号／浅深色／Escape关闭、真实页面菜单到设置、草稿与连续中断；原生离线内存数据库会话已检查1250×850和420×820窗口，未调用真实模型。截图证据为 `.codex-temp/telegram-frontend/refinement-menu-verified.png`、`refinement-narrow.png`。临时离线入口已移出应用源码。

本次追加前镜像为 `.codex-temp/telegram-frontend/refinement-before.tar.gz`，追加前安装包备份为 `installed-before-refinement/AIcove.app`。回滚仍按文件差异恢复，不能覆盖开工前或后续用户改动。

追加最终交付：38项静态检查无问题；标准lib/main.dart的macOS Release构建99.9MB，已替换并独立启动 `/Applications/AIcove.app`。安装与构建的App.framework SHA256均为 `eccf6ef2ec515810b6102275005d572e95170535102ca1afd3058d2f93b7e198`，codesign严格验证通过；正式安装版宽窄首页再次检查并恢复宽窗口。未安装手机端。


## 追加：左侧整机悬浮（2026-09-11）

用户纠正：左侧不是贴边分栏，而应像电脑上的手机远控窗口，整块手机界面悬浮于整个页面上。统一壳增加12px留白、28px整体圆角与阴影，保留完整一级底栏；详情默认起点从360改为384。间隙提供拖宽度热区，不再绘制分割线。跨断点通过同级key保留两棵页面树，窄屏绘制顺序仍允许详情在一级界面上滑入／滑出。

`MoeWorkspaceBackground`将聊天纯背景交给详情路由观察器，在宽屏绘制一次贯穿整个工作区；窄屏继续本地绘制，消息与业务页面不搬到背景层。背景跟随最上层PageRoute，弹窗不切换，退栈等待视觉完成。普通详情采用中性底色。桌面透明聊天禁用Cupertino的全页暗色遮罩，避免左侧外围与右侧背景色阶不一致；原动画轨迹与中断实现不变。

本批62项回归通过，7项静态检查无问题；覆盖12px外围、圆角、局部MediaQuery高度、拖动、搜索／草稿跨断点保留、背景路由选择与退出、真实入口／菜单／设置以及连续进退。Mac原生离线聊天已检查，缩放后标准窗口按钮须在AppKit完成布局后重新对齐。源文件前镜像和安装版备份位于 `.codex-temp/telegram-frontend/floating-primary/`，本次文件清单为该目录的changed-files.json；concurrent-files.json中的媒体修改来自其它工作，未编辑或回退。


### 同批追加：桌面窄窗口两行顶部

用户再次明确窄屏可增加顶部导航行，避免原生按钮挤占聊天控件。桌面小于900时新增40px独立应用标题行；页面内容及局部MediaQuery高度扣除此行，原生按钮独占上行。下行返回使用独立圆形表面，资料与操作胶囊获得余下全宽。该要求取代此前对桌面窄窗口不加通栏标题的限制；宽屏仍维持左侧面板原生按钮，手机不增加桌面栏。最终62项回归通过，8项静态检查无问题。


本批最终交付：原生离线聊天在420×820窄窗口及1250宽窗口确认两行顶部、独立返回和整块悬浮面板；标准lib/main.dart的macOS Release99.9MB已更新并独立启动 `/Applications/AIcove.app`。473项构建输入在构建期间未变，安装与构建App.framework SHA256均为 `545b8560db25636abebc7ae1e039fd9dd709bd48ea6c468984ea0d4e465b0964`，codesign严格验证通过；正式安装版窄宽首页再次检查。证据为本批目录compact-narrow.png、compact-wide.png、installed-narrow.png、installed-wide.png、installation.json和build-input-check.json；最新替换前安装包另备份为installed-before-final/AIcove.app。临时预览入口已移出应用源码，未安装手机、未调用模型。


## 追加：手机共用Mac窄屏布局和操作（2026-09-11）
用户明确要求手机界面与Mac窄屏一致，排除Mac原生窗口按钮／独立应用标题行；本次授权取代此前手机大改后续安排。聊天头部和输入区移除桌面视觉分支，首页只保留共同底部导航，消息／媒体长按默认纵向菜单。状态栏样式与SafeArea保留手机能力，软键盘高度仍由原控制器同步；只把键盘占位从输入玻璃面移到相邻布局节点，更多面板单独绘制同款浮层。未更改发送、生成、媒体工具和持久化业务，无数据库或依赖升级。

回滚按`.codex-temp/telegram-frontend/mobile-parity/changed-files.json`逐项对照同目录before.tar.gz及task.diff，不能按HEAD恢复或覆盖其它任务改动；手机升级前APK另存installed-before.apk。91项相关回归通过；Android／iOS仿真平台下的手机状态栏、键盘、菜单与大字号包含在内，实机交付结果另记需求日志。
