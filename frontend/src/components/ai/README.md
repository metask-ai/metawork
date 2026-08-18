# AI UI Components

This directory is MetaWork's AI UI layer. It sits on top of the existing
Foundation UI (`components/ui`) and is consumed by product features; it does
not own Task, Run, Workspace, Bridge, capability, or AgentCore semantics.

This layer contains only leaf renderers and Composer primitives. It is not a
conversation framework, work-surface abstraction, or second product design
system. The AI SDK runtime, provider transport, `useChat`, Streamdown, and
scrolling helpers are intentionally not dependencies of this layer.

`Markdown.tsx` is the product-owned assistant response renderer. It supports
CommonMark and GFM through `react-markdown` and `remark-gfm`, disables raw HTML,
and passes links through a safe protocol boundary. It does not add an AI SDK
transport or provider runtime.

`CodeBlock.tsx` is a leaf presentation primitive: it renders bounded code or
tool output and never owns product visibility policy. Product features decide
whether bounded content is relevant to a user action; the existence of a Host
Tool record never makes it default-visible Renderer content.

`index.ts` is the only public import surface for feature code. Foundation UI
remains the lower-level dependency and product semantics remain in
`features/`.
