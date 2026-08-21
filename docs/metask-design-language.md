# Metask Design Language

这份文档记录 MetaWork Renderer 使用 Metask 视觉语言时的治理规则。它约束
Foundation UI 的 token 和组件实现，不替代具体产品的页面布局与交互设计。

## Source of truth

- 设计师提供的 Metask 基础设定是不可修改的品牌 source of truth。
- MetaWork 标志的几何真源是
  [`assets/brand/logo-mark.svg`](../assets/brand/logo-mark.svg)。不同用途不得直接修改该路径，
  而应以独立画布、安全区、背景和必要的小尺寸调整形成用途母版。
- 基础颜色、状态色、Light / Dark 表面和字体的实现真源是
  [`frontend/src/styles/metask-tokens.css`](../frontend/src/styles/metask-tokens.css)。
- 不在产品 CSS、组件文件或其他文档中复制一套品牌色值。
- 现有产品 CSS 和组件表现只是迁移时的 consumer inventory，不是需要保留的视觉真源；
  重建设计语言时可以调整现有 hover、selected、danger 等表现。

## Brand assets

- `assets/brand/logo-mark.svg` 是唯一手工维护的 MetaWork 标志几何；其贴合内容的
  `viewBox` 用于品牌排版，不包含某个平台的背景或外框。
- `assets/icons/app-icon.svg` 是 1024 × 1024 应用图标母版，使用白色背景；品牌标志以画布中心
  缩放至 88%，使可见主体约占画布宽度 70%，并保留应用图标所需的安全区。
  它是 `app.zon.icons` 声明的单一打包真源，由 Native SDK 官方图标管线生成 macOS ICNS 和
  Windows 多尺寸 ICO；`assets/icons/app-icon.png` 只供当前未打包运行时的 `icon_path` 消费。
- 应用图标 SVG 和 PNG 是从品牌真源导出的设计资产；MetaWork 仓库只保存应用需要的交付文件，
  不拥有 SVG 栅格化工具链。
- `assets/icons/tray-icon.svg` 是透明背景的托盘用途母版，主体约占画布宽度 88%；macOS/Linux
  消费 64 × 64 PNG，Windows 消费包含 16、20、24、32、48 和 64 px 的 ICO。macOS 将该图像
  作为 template image 使用，Windows 保留品牌色。
- favicon 和其他平台图标只有出现真实 consumer 时才新增各自的用途资产；不同用途可以
  调整内容占比、视觉居中、背景和小尺寸细节，但继续复用品牌真源的基础几何。

## Token layers

Token 按三层组织：

1. `--metask-*` 是品牌 primitive。它们直接承载设计师给出的基础设定，值不可修改。
2. `--ui-*` 是 Foundation Semantic Token。它们表达 surface、content、action、
   status、focus 等组件语义，可以引用或基于 primitive 推导。
3. Tailwind `@theme inline` 是消费桥接层，只把上述 token 暴露为 utility 入口，
   不拥有新的视觉值。

Foundation 组件只应消费 `--ui-*` 语义 token；只有明确表达品牌本身的场景才可以
直接消费 `--metask-*` primitive。

## Allowed extensions

可以根据 Foundation 组件的真实需要扩展语义 token，但必须满足：

- 不修改任何设计师给出的 primitive 值；
- 优先通过已有 primitive、主题 surface 和 `color-mix()` 推导，不另起一套品牌色；
- Light / Dark 同时定义，不能让 Dark 主题回退到浅色值；
- 每个新增 token 都必须有当前组件 consumer；
- 文字、图标和控件边界需要经过可读性/对比度验证；
- 如果基础色不适合某种组件表现，调整组件变体，不修改基础色。

例如，异常状态色可以继续用于状态点；如果它不适合实心危险按钮，应使用
tonal 或 outline 变体，而不是替换异常状态色。

## Out of scope

以下内容不属于公司级 Design Language，除非具体产品另行确定：

- 页面布局、产品密度和业务模块间距；
- 页面或业务卡片的圆角、尺寸和阴影层级；
- Timeline、Workbench、MCP 等业务模块的专属视觉；
- AI 对话渲染和 AI Elements 视觉；
- 业务流程节点、连线和动效规则。

这些规则不能成为 Foundation token 的隐式默认值。

## Review gates

修改设计语言或 Foundation UI 时，至少检查：

- 基础 primitive 是否保持不变；
- `metask-tokens.css` 是否仍是唯一基础 token owner；
- Tailwind bridge 是否只做映射；
- Light / Dark 下 surface、content、border、focus 和 selected 状态是否成对；
- Foundation 组件是否仍有直接品牌色、固定白/黑或浅色回退；
- TypeScript check、Renderer build 和 `git diff --check` 是否通过。
