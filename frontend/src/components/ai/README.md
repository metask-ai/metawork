# AI UI Components

This directory defines MetaWork's shared rendering language for the central AI
conversation surface. Every visible conversation path composes the same seven
primitives:

- `Conversation` owns the reading surface, viewport, content measure, and jump
  to latest affordance.
- `Message` renders user and assistant speech without inventing system, tool,
  or reasoning speakers.
- `Activity` renders the one current activity or a necessary terminal state at
  lower visual priority than speech.
- `Intervention` renders the temporary surface for permission and other genuine
  user decisions; settled decisions do not remain as full forms.
- `Composer` is the shared input surface for new and existing conversations.
- `Markdown` renders assistant rich text through a safe CommonMark/GFM boundary.
- `CodeBlock` renders bounded code content.

The set is deliberately small. A protocol event, tool name, or hypothetical
future capability does not justify a component. New primitives require a real
visible semantic that cannot be expressed by the existing composition.

These components own rendering semantics only. Product features supply copy,
choices, actions, and already-decoded state. Foundation controls remain in
`components/ui`; provider transports, AI SDK runtimes, Task state, and Host
contracts are not dependencies of this layer. `index.ts` is the only public
import surface for feature code.
