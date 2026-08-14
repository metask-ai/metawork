# AI UI Components

This directory is MetaWork's AI UI layer. It sits on top of the existing
Foundation UI (`components/ui`) and is consumed by product features; it does
not own Task, Run, Workspace, Bridge, capability, or AgentCore semantics.

## AI Elements baseline

The following components are adapted directly in this directory from Vercel
AI Elements `1.9.0` (Apache-2.0):

- `Conversation.tsx` — conversation log/content/empty state
- `Message.tsx` — message/content/actions/response
- `Tool.tsx` — tool disclosure/header/content/field
- `Reasoning.tsx` — reasoning disclosure/trigger/content

Upstream registry sources:

- <https://elements.ai-sdk.dev/api/registry/conversation.json>
- <https://elements.ai-sdk.dev/api/registry/message.json>
- <https://elements.ai-sdk.dev/api/registry/tool.json>
- <https://elements.ai-sdk.dev/api/registry/reasoning.json>

The files are source-level components, not a second product design system.
Their imports are adapted to MetaWork's Foundation UI and design tokens. The
AI SDK runtime, provider transport, `useChat`, Streamdown, and scrolling helper
are intentionally not dependencies of this layer. Product code passes decoded
MetaWork projections into these presentation components.

`Markdown.tsx` is the product-owned assistant response renderer. It supports
CommonMark and GFM through `react-markdown` and `remark-gfm`, disables raw HTML,
and passes links through a safe protocol boundary. It does not add an AI SDK
transport or provider runtime.

`CodeBlock.tsx` is a leaf presentation primitive: it renders bounded code or
tool output and never owns a visible field label. `ToolField` is the semantic
label owner for tool details. Feature-level compositions such as
`AgentWorkSurface` decide whether a `Tool` is shown as a compact activity row
or an expanded detail surface; the AI primitives do not decide product
visibility policy.

`index.ts` is the only public import surface for feature code. Foundation UI
remains the lower-level dependency and product semantics remain in
`features/`.
