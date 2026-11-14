# 视觉与交互规范

本文件定义界面设计的原则与交互契约。品牌定位为暮色、宁静、沉浸、精致，以薰衣草紫作为识别色。完整全屏播放界面的视觉与控制布局暂不定义；标题/导航区域的紧凑播放条及系统 PiP 属于范围，应用内可拖动小窗不属于范围。

## 品牌视觉定位

以暮色为灵感，以紫色作为品牌识别，结合柔和的界面层次、原生系统材质与沉浸式播放体验。

`Twilight-inspired · Refined Violet · Native · Immersive`

## 色彩系统

颜色应以语义命名和使用，不在各个 View 中硬编码 HEX。以下颜色为设计 token；落地到 `Assets.xcassets` 时，应为支持外观切换的 Color Set 配置 Any Appearance 与 Dark Appearance，由系统根据当前 appearance 选择。

### 品牌色

| Token | Light Appearance | Dark Appearance | 用途 |
|---|---|---|---|
| VesperAccent | `#6958C8` | `#A99BFF` | 主强调色、播放进度 |
| VesperAccentPressed | `#5545AE` | `#8E7DEB` | 按下状态 |
| VesperAccentSoft | `#EAE6FC` | `#302B50` | 柔和强调背景、选中区域 |
| 强调色前景 | `#FFFFFF` | `#171426` | 强调色按钮或区域上的内容 |

### 应用界面语义色

| Token | Light Appearance | Dark Appearance | 用途 |
|---|---|---|---|
| VesperBackground | `#F5F4F8` | 系统 `systemBackground` | 页面主背景 |
| VesperSecondaryBackground | `#EDECF2` | `#191C2D` | 次级背景、分组区域 |
| VesperSurface | `#FFFFFF` | `#20243A` | 卡片、内容容器 |
| VesperElevatedSurface | `#FFFFFF` | `#292D45` | 弹出层、悬浮面板 |
| VesperPrimaryText | `#222131` | `#F4F2FA` | 标题、主要文字 |
| VesperSecondaryText | `#727181` | `#B7B5C7` | 副标题、辅助说明 |
| VesperTertiaryText | `#A09EAD` | `#85849B` | 占位符、弱化文字 |
| VesperSeparator | `#E3E1E9` | `#34364B` | 分割线、边框 |

### 播放器专用色

全屏播放器控制层（后续定义）不随 App 的浅色/深色 appearance 改变，始终使用独立的深色半透明控制层。播放器内颜色作为专用 token 管理，不复用会随系统外观改变的页面语义色。紧凑播放条使用应用的语义色和原生控件；PiP 外观及其系统控制遵循 iOS，不自行绘制系统 PiP 窗口。

| Token / 元素 | 色值 | 用途 |
|---|---|---|
| 播放按钮背景、已播放进度 | `#A99BFF` | 播放/暂停按钮背景、播放进度 |
| 播放按钮图标 | `#171426` | 播放、暂停图标 |
| 缓冲进度 | `#77718F` | 已缓冲但尚未播放的部分 |
| 未播放轨道 | `#FFFFFF`，25% opacity | 进度条背景 |
| 控制文字 | `#FFFFFF` | 播放时间、按钮文字 |
| VesperPlayerControlBackground | `#111321`，65% opacity | 播放控制区域背景 |
| 字幕背景 | `#000000`，65% opacity | 字幕底色 |
| 字幕文字 | `#FFFFFF` | 字幕内容 |

播放器已播放进度可使用 `VesperPlaybackProgress` 命名；缓冲进度使用 `VesperBufferedProgress`。字幕和按钮图标颜色如需跨多个组件复用，可在实现时建立对应的播放器专用资源。本阶段不定义完整全屏播放控制 UI；紧凑播放条沿用应用语义色，系统 PiP 遵循系统外观。

### 色彩使用原则

- 使用 Vesper Violet 建立品牌识别；深色外观使用 Vesper Glow 保持强调状态清晰。
- 浅色页面背景使用柔和灰白色；深色页面主背景使用系统 `systemBackground`。
- 强调色限用于重要交互、选中状态和关键视觉元素，避免大面积铺色造成干扰。
- 保证文本、图标和交互状态在对应背景上清晰可辨；状态不能只依赖颜色表达。
- 优先使用 SwiftUI 原生材质和 Liquid Glass；不要自行模拟系统已有的玻璃材质。仅在目标 OS 支持且适合该交互场景时使用，材质不可用时提供清晰的实色背景回退。
- 全屏播放界面以视频内容为核心，控制层使用深色半透明表面；控制层不跟随 App appearance 切换。

### Xcode Color Set 组织

在 `Assets.xcassets` 中按下列语义创建 Color Set；播放器颜色保持专用命名空间。支持动态外观的资源配置 Any Appearance 与 Dark Appearance。固定沉浸式播放器颜色不应错误地随 appearance 改变。

| 分组 | Color Set |
|---|---|
| Brand | `VesperAccent`、`VesperAccentPressed`、`VesperAccentSoft` |
| Background | `VesperBackground`、`VesperSecondaryBackground`、`VesperSurface`、`VesperElevatedSurface` |
| Text | `VesperPrimaryText`、`VesperSecondaryText`、`VesperTertiaryText` |
| Separator | `VesperSeparator` |
| Player | `VesperPlaybackProgress`、`VesperBufferedProgress`、`VesperPlayerControlBackground` |

`VesperPlaybackProgress` 在页面 appearance 下可对应主强调色；播放器内则应使用固定的深色外观变体/专用值 `#A99BFF`，不能因系统 appearance 变化而切换成浅色主强调色。

SwiftUI 优先通过语义化资源使用颜色：

```swift
Color("VesperAccent")
Color("VesperBackground")
Color("VesperPrimaryText")
Color("VesperPlaybackProgress")
```

视图中不得散落 HEX 常量；颜色资源集中维护，便于主题调整、外观适配和测试。

## 信息层级

- 四个一级页面分别显示“媒体”“来源”“记录”“设置”。VesperLargeTitle 位于 ScrollView/List 内容顶部，始终使用系统 largeTitle 字号及 VesperPrimaryText，不使用系统 Large Title 转 Inline Title 的行为，不使用固定 overlay，不覆盖页面内容。标题背景透明，文字由 SwiftUI 直接渲染，不使用截图、Core Image、自定义高斯模糊或材质背景。
- 顶部使用 iOS 26 原生 `.scrollEdgeEffectStyle(.soft, for: .top)`，并保留顶部 edge effect 可见。滚动视口延伸至顶部安全区，初始内容通过 NavigationStack 外测量的顶部 safeAreaInsets 设置 scrollContent 顶部 margin，仅避让状态栏，不额外预留空导航栏高度；滚动时内容可经过顶部系统边缘效果。ContentHost 约束保持原样，不使用固定状态栏高度或缩短 Host 避让。唯一全屏 VesperBackground 延伸至安全区，状态栏不另加 UIVisualEffectView、Material 或纯色覆盖。原生边缘模糊与标题动画独立管理，不把标题整体高斯模糊当作系统效果。
- 每个一级页面独立管理 expanded、collapsing、collapsed、expanding。onScrollGeometryChange 观测相对顶部的偏移，仅驱动标题逐渐淡出及顶部恢复；2 pt 顶部容差外开始淡出，48 pt 达到完全透明，48 pt 不是独立动画触发阈值。手指拖动及惯性滚动期间标题仅随 ScrollView 自然移动，不触发独立收起；onScrollPhaseChange 进入 idle 后读取实时 ScrollGeometry，只有已离开顶部才执行独立向上移出与淡出。自然滚动与自有 offset 分离，标题布局高度不随动画改变。
- 标题收起后，中途向下滚动保持隐藏，仅回到顶部（2 pt 容差）才恢复。用 SwiftUI 动画 completion 完成状态转换，忽略过期回调，不用固定延迟。默认动画 0.30 秒；Reduce Motion 开启时取消独立位移，仅用 0.18 秒淡入淡出。各标签独立保留标题状态。
- 一级和二级页面均保持系统导航栏显示，统一使用 inline、automatic 背景和原生返回配置。一级导航栏中央视觉为空，不添加操作按钮；自定义大标题仍位于滚动内容顶部，内容延伸到空导航栏下方。一级与二级转场不再切换导航栏显隐，但导航栏仍参与系统布局，不能承诺转场期间按钮屏幕坐标完全固定。二级及更深页面中央不显示标题，使用 inline 模式、原生返回图标和边缘滑动返回；导航栏背景交给系统 automatic，不强制 regularMaterial、纯色或不透明 appearance，不自行绘制返回按钮。每个标签的 NavigationStack 独立管理历史，不承诺原生返回图标在转场期间固定于同一屏幕坐标。日志导出和清空仍位于原生导航栏右侧。
- 一级及二级页面必须保留真实、已国际化的 navigationTitle，供系统长按返回菜单识别历史页面名称；不能用空字符串隐藏标题。统一用透明的 principal ToolbarItem 只替换中央可见标题，并隐藏该占位项自身的玻璃背景和辅助功能元素。返回图标、历史菜单及跳转行为仍由系统生成，不自行绘制或维护返回菜单。
- 搜索页面保留原生 Search Tab、searchable、现有手动激活和退出流程，不接入一级标题组件，不增加重复导航栏。
- ContentHost 及持久页面 Host 四边贴合父视图，不使用缩短高度、额外固定偏移或裁剪来避让系统栏。底部内容安全区根据原生标签栏的实际 window 坐标计算，页面内部仍由 NavigationStack/List/Form 处理安全区。

- 页面优先采用目标 Apple 平台的原生组件与原生交互逻辑，包括导航、列表、表单、菜单、搜索、确认、焦点和辅助功能行为。
- 除非原生组件无法满足明确的产品需求，不重新绘制系统控件或复制系统已有交互；自定义样式应基于原生组件能力，并保留平台惯例。
- 二级及更深页面导航栏材质交由系统 automatic；标签栏保留原生 Liquid Glass，不叠加自绘背景或模糊层。确保文字和图标在滚动、不同内容背景及浅/深色外观下清晰，并正确处理安全区。
- 根级只保留统一全屏背景，顶部使用系统 Scroll Edge Effect，底部手势区域延续页面背景，不叠加独立色块或整页模糊。TabView 普通标签使用透明占位；独立系统 TabView 层位于页面层上方，空白区域触摸穿透，仅原生标签栏与搜索控件接收触摸。标签栏保留原生 Liquid Glass 及现有收起行为，不配置自定义 UITabBarAppearance 背景，不覆盖 standardAppearance/scrollEdgeAppearance。
- 设置页保留原生 insetGrouped 分组卡片。标题 Section 只清除水平和底部额外 margin，顶部避让由统一一级页面滚动组件处理。保留 SectionHosts、ContentHost、持久 UIHostingController/NavigationStack、currentPage、tabSelection、selectTab、搜索和多功能手势逻辑，仅移除过时的标题快照与状态栏材质诊断代码。
- 外观设置的主题模式继续使用 menu Picker；主题色使用系统 ColorPicker 调色盘，禁止透明度选择，实时更新并持久保存到 appearance.accent。自选颜色按 sRGB HEX 保存，已选旧预设保持可读；修改后显示“恢复默认颜色”，恢复随 Light/Dark Appearance 适配的 VesperAccent。页面中不新增散落色值。
- 运行日志按时间倒序，每批 100 条；滚动接近列表底部时自动追加下一批，不显示手动加载行。导出继续使用完整本地日志文件，不受当前已加载条数限制。
- 标签设置保留拖动排序和显隐开关；“恢复默认”必须先确认，仅恢复标签顺序与显示状态。原列表中的多功能开关及手势入口移除，导航栏右侧使用 square.grid.2x2 原生 Menu：首项是启用开关，启用时第二项为“手势与动作”，以系统 sheet 展示，默认 medium，可展开到 large，并保留原生拖动指示条和完成按钮。试验阶段提示移至标签列表 footer。
- 原生效果参考：[ScrollEdgeEffectStyle](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle)、[scrollEdgeEffectStyle(_:for:)](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:))、[ignoresSafeArea(_:edges:)](https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:))。

- 底部使用 SwiftUI 原生 `TabView`；媒体、来源、记录、设置放入 `TabSection("主要功能")`，内部逻辑标识为 `primaryTabs`。多功能项位于组外，使用 `.search` 角色及网格 SF Symbol `square.grid.2x2`，始终保留。
- 通过 `TabSection.hidden(_:)` 控制整组显隐，不使用 `if` 删除整个分组，也不使用面向自定义布局的 `defaultVisibility` 作为 iPhone 动态显隐开关。
- 默认仅显示多功能项。默认单击展开或收起主要功能组，长按进入搜索；手势与动作可在设置中通过两列拖动重新配对。点击普通内容不触发收起，选择普通标签也不自动收起。
- 标签显隐不启用自定义动画。`currentPage` 与 `tabSelection` 分离：前者控制外部 ContentHost 的页面显示，后者只控制原生标签选中态。收起时可选中多功能项，但不由它承载普通页面；展开时恢复对应区域选中态。每个区域只有一个持久的页面控制器与 NavigationStack，禁止多份导航栈共享同一个 path binding。
- 设置页提供区域标签显示开关和拖动排序，持久化保存；隐藏仅影响入口，不删除数据。多功能入口和设置标签不允许单独隐藏；设置标签可排序，整组收起时随组隐藏。
- 搜索使用原生 `UISearchBar`，范围为当前媒体来源；真实数据接入前明确显示不可搜索状态。搜索页不提供标签设置入口。
- 原生 TabView 负责标签布局和选择；UIKit 桥接仅处理多功能项的自定义单击/长按和关闭自动搜索激活，不替换 TabView 的 delegate、不遍历私有 UIKit view 类型。

- 主导航包含“媒体、来源、记录、设置”四个标签。“媒体”仅显示当前选定的一个媒体来源，不呈现跨来源聚合总览。
- “来源”页负责配置来源与选择当前媒体来源；切换后更新“媒体”页内容，但不改变当前主标签结构。没有可用来源时，“媒体”页应提供清晰空状态及来源配置入口。
- “记录”页呈现最近播放、观看进度和历史；“设置”页放置播放器偏好、应用设置及服务账号连接管理。
- 媒体库中的筛选、排序、搜索和详情导航优先使用平台熟悉的原生模式；具体布局应随首发平台调整。
- 设置页优先采用原生分组列表、表单、开关、选择器和说明文案；播放器选项按类别组织，显示当前值和适用条件。

## 全屏播放器交互（完整 UI 暂不在范围内）

- 播放/暂停、进度拖动、前进/后退和退出播放应有明确的可发现入口。
- 进度拖动期间显示目标时间；提交跳转后区分正在缓冲与已恢复播放。
- 音轨、字幕、画面比例等选择项应显示当前值，并对不可用选项给出原因或禁用状态。
- 全屏与系统 PiP 属于需求，具体支持需在目标平台和 KSPlayer 后端确认后实现；外接播放能力暂不承诺。界面状态须与实际播放器状态一致。
- 手势不得成为唯一操作方式；提供可见控件以及目标平台适用的辅助输入路径。

## 紧凑播放与 PiP

- 离开全屏播放但仍留在 App 时，播放器可收缩为标题/导航区域附近的紧凑播放条。该区域是应用内固定布局，不是可拖动浮窗；应提供返回全屏和关闭/停止播放的明确操作。
- 收缩与展开应以同一播放内容和播放会话进行连续转场，不重建播放器、不重置进度。动画可用 SwiftUI/UIKit 原生动画 API 实现；“标题栏”指应用内导航/标题区域，不假定 iOS 提供专用的原生迷你播放器标题栏 API。
- 进入系统 PiP 后由 iOS 管理 PiP 窗口及其交互。PiP 结束后，应恢复到合理的应用内播放呈现。
- PiP 支持系统可提供的暂停、继续和时间跳转控制；具体可用命令由媒体时长、播放器后端和系统能力决定，控制状态须与同一播放会话同步。
- 不实现 App 内可拖动小窗；不得为模拟 PiP 而另做一套自由浮动播放器。

## 状态与反馈

所有主要流程需覆盖正常、加载、空内容、错误、受限和离线状态。提示文案简短说明发生了什么以及可采取的动作。可重试错误提供重试；不可恢复错误提供返回或更换资源等出口。

## 无障碍与适配

- 交互控件提供有意义的 accessibility label、trait 和当前值。
- 不仅依赖颜色表达状态；确保文本对比度、动态字体和系统辅助功能可用。
- 控件触达尺寸和布局遵循目标 Apple 平台规范，并针对安全区、横竖屏和不同窗口尺寸验证。
- 方向、键盘、遥控器和 VoiceOver 支持范围需随目标平台明确，并以真实设备或模拟器验收。

## 设计交付

每个主要流程至少说明入口、默认状态、操作反馈、失败/空状态和退出路径。交付中标注新增 token 或组件，并避免在单个页面中私自创造与已有系统冲突的样式。涉及颜色的交付需说明语义 token、Light/Dark 值及播放器是否使用固定沉浸式色值。播放器相关交付需覆盖全屏收缩/展开、PiP 进出和 PiP 控制同步；不要求本阶段完成全屏控制界面视觉稿。

多功能项始终留在原生标签栏中；仅四个目的地标签作为一组隐藏。

## 多功能按钮与系统搜索联动

“启用多功能按钮”替代旧的允许隐藏开关，默认开启。关闭时主要标签组常显，入口显示搜索图标，单击搜索、长按无动作；开启时入口显示网格图标（搜索期间为搜索图标），单击和长按按持久化手势映射执行。

展开组后，选择四个普通标签只切换区域，不收起组；多功能入口执行其模式与手势映射。搜索页内点击保持原生行为。普通内容点击同时执行原操作并收起组，仅启用多功能模式时收起，不拦截原点击。

搜索前记录标签组是否隐藏。隐藏时先展开并准备搜索控件；随后通过异步让出执行分步选中 Search Tab、显示搜索页并激活输入，不依赖固定延迟或就绪检测。搜索由 App 手动控制，普通页面由外部 ContentHost 保持导航状态；退出后恢复页面和标签组状态。

需真机验收两种模式、两种初始显隐状态、取消返回、二级导航及点击穿透；编译不代替交互验收。

冷启动时即使主要标签组默认收起，TabView selection 仍指向媒体（或当前可用的普通区域），绝不为了显示收起后的页面而选中 Search 角色；否则系统会在启动时展开搜索栏。

当前 iOS 26 继续使用 Search Tab role，但关闭其自动搜索联动；搜索由 App 显式控制。

搜索恢复为 App 手动控制：Search Tab 不自动激活；进入时保存页面、标签组和 selection，显示 Search 页面后通过 searchable(isPresented:) 与 searchFocused 请求激活和焦点；取消搜索或切换普通标签时由 App 清理输入状态并恢复快照。

搜索页面容器实验：Search Tab 占位内容使用统一页面背景并延伸至安全区；ContentHost 同级管理四个普通页面及独立 SearchPage hosting controller。搜索状态仅切换 ContentHost 内部子视图可见性，不替换 Search Tab 页面内容。用于验证系统取消搜索期间页面变化是否导致标签栏闪烁。

## 设置与标签重复点击

- 设置首页使用小尺寸主题色线性 SF Symbol 和圆角矩形描边；二级页面恢复普通文字行及原有 Label 图标；语言名称保持自称，不随界面语言转换。
- 媒体、来源、记录空状态只显示图标及“未选择媒体来源”“未配置来源”“无记录”，整体居中，不显示说明小字或前往来源操作。
- 再次轻点当前普通标签时，对 ContentHost 中该标签的 NavigationPath 返回一层；根页面不操作，不把程序化 selection 同步识别为点击。各标签 Host 和导航栈保持独立、持续存在，搜索和多功能手势不参与返回。

- 启用多功能按钮前弹出实验功能确认，取消不修改开关；关闭立即生效，页面内不重复显示实验提示。
- 标签设置主列表仅控制显隐，排序通过右上角更多菜单中的“调整标签顺序”半屏页进行，使用同一份 AppStorage 立即更新标签设置和系统标签栏。
- 手势配对半屏页显示“手势与动作”标题和完成按钮，不显示返回按钮。两列使用主题色圆角矩形描边卡片，卡片之间留白，不显示列名、拖动标识或分割线；使用页面内 DragGesture 排序，卡片跟随手指移动，同列邻项让位，不启动系统复制拖放会话；配对后立即保存，VoiceOver 提供上移、下移动作。

- 外观设置内直接显示“更换图标”分组，图标依次排列，当前图标以主题色边框标记，不再打开额外页面。
- 标签设置右上角依次放置多功能设置及更多菜单；更多菜单统一提供调整标签顺序和恢复默认，恢复默认仍需确认。
- 手势与动作半屏页使用居中的 principal 标题，保留右侧完成按钮。

- 日志导出从当前 UIKit 控制器直接 present UIActivityViewController，传入完整 `.log` 文件 URL，不经过 SwiftUI sheet；保留导出失败提示及取消处理。
- 标签显隐列表不显示始终保留的设置标签；排序半屏页仍包含该标签。排序页标题为“标签顺序”，隐藏返回按钮；排序与手势半屏页覆盖 editor toolbarRole，使用自动样式及居中 principal 标题。
- 手势排序卡片使用 VesperSurface 背景及主题色边框。外观中的“重置主题色”始终显示，默认颜色时禁用；图标不展示名称，但保留辅助功能名称和选中状态。
- 语言菜单依次为跟随系统、简体中文、繁体中文、English、Deutsch、Español、Français、日本語、한국어。

- 排序或重置顺序时，以 order 为原生 TabView 的视图身份，重建其 UIKit 标签项，避免位置复用留下旧图标；ContentHost、SectionHosts 和导航历史不重建。标签组显隐和搜索状态更新不触发这一重建。
- 标签顺序及手势与动作面板固定 360pt 高度，禁止下拉关闭，不显示拖动横条，右上角使用关闭图标；内容仍可滚动，卡片拖动排序保留。
- 手势卡片使用比浅色页面背景更深的 VesperSecondaryBackground；设置首页图标与标签设置一致，使用普通 Label，不绘制外框。
