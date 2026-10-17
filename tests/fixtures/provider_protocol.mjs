// Deterministic protocol replies for real Core integration tests.
export function protocolTextSse(protocol, answer) {
  let events;
  if (protocol === "chat")
    events = [
      {
        choices: [
          { index: 0, delta: { content: answer }, finish_reason: null },
        ],
      },
      { choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      "[DONE]",
    ];
  else if (protocol === "responses")
    events = [
      {
        type: "response.created",
        response: { id: "resp_switch", status: "in_progress" },
      },
      {
        type: "response.output_item.added",
        output_index: 0,
        item: {
          type: "message",
          id: "msg_switch",
          role: "assistant",
          content: [],
        },
      },
      {
        type: "response.content_part.added",
        output_index: 0,
        content_index: 0,
        part: { type: "output_text", text: "", annotations: [] },
      },
      {
        type: "response.output_text.delta",
        output_index: 0,
        content_index: 0,
        delta: answer,
      },
      {
        type: "response.completed",
        response: {
          id: "resp_switch",
          status: "completed",
          output: [
            {
              type: "message",
              id: "msg_switch",
              role: "assistant",
              content: [{ type: "output_text", text: answer, annotations: [] }],
            },
          ],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
        },
      },
    ];
  else if (protocol === "anthropic")
    events = [
      {
        type: "message_start",
        message: {
          id: "msg_switch",
          role: "assistant",
          model: "fixture",
          usage: { input_tokens: 1, output_tokens: 0 },
        },
      },
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "text", text: "" },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "text_delta", text: answer },
      },
      { type: "content_block_stop", index: 0 },
      {
        type: "message_delta",
        delta: { stop_reason: "end_turn" },
        usage: { output_tokens: 1 },
      },
      { type: "message_stop" },
    ];
  else
    events = [
      {
        candidates: [
          {
            content: { role: "model", parts: [{ text: answer }] },
            finishReason: "STOP",
          },
        ],
        usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
      },
    ];
  return events
    .map(
      (event) =>
        `${typeof event === "object" && event.type ? `event: ${event.type}\n` : ""}data: ${typeof event === "string" ? event : JSON.stringify(event)}\n\n`,
    )
    .join("");
}

export function protocolToolSse(protocol, id, name, args) {
  const callId = `switch_read_${id}`;
  let events;
  if (protocol === "chat")
    events = [
      {
        choices: [
          {
            index: 0,
            delta: {
              tool_calls: [
                {
                  index: 0,
                  id: callId,
                  type: "function",
                  function: { name, arguments: JSON.stringify(args) },
                },
              ],
            },
          },
        ],
      },
      { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      "[DONE]",
    ];
  else if (protocol === "responses") {
    const item = {
      type: "function_call",
      id: `fc_${id}`,
      call_id: callId,
      name,
      arguments: JSON.stringify(args),
    };
    events = [
      {
        type: "response.created",
        response: { id: `tool_resp_${id}`, status: "in_progress" },
      },
      {
        type: "response.output_item.added",
        output_index: 0,
        item: { ...item, arguments: "" },
      },
      {
        type: "response.function_call_arguments.delta",
        output_index: 0,
        item_id: item.id,
        delta: item.arguments,
      },
      {
        type: "response.function_call_arguments.done",
        output_index: 0,
        item_id: item.id,
        arguments: item.arguments,
      },
      { type: "response.output_item.done", output_index: 0, item },
      {
        type: "response.completed",
        response: {
          id: `tool_resp_${id}`,
          status: "completed",
          output: [item],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
        },
      },
    ];
  } else if (protocol === "anthropic")
    events = [
      {
        type: "message_start",
        message: {
          id: `tool_msg_${id}`,
          role: "assistant",
          model: "fixture",
          usage: { input_tokens: 1, output_tokens: 0 },
        },
      },
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "tool_use", id: callId, name, input: {} },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: JSON.stringify(args) },
      },
      { type: "content_block_stop", index: 0 },
      {
        type: "message_delta",
        delta: { stop_reason: "tool_use" },
        usage: { output_tokens: 1 },
      },
      { type: "message_stop" },
    ];
  else
    events = [
      {
        candidates: [
          {
            content: {
              role: "model",
              parts: [{ functionCall: { name, args } }],
            },
            finishReason: "STOP",
          },
        ],
        usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
      },
    ];
  return events
    .map(
      (event) =>
        `data: ${typeof event === "string" ? event : JSON.stringify(event)}\n\n`,
    )
    .join("");
}
