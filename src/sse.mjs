/**
 * 把上游 SSE 聚合成一个 chat.completion。
 *
 * 为什么需要：CodeArts 上游只出增量流，插件 shim 也只转流；但 OpenAI 客户端在
 * `stream:false`（默认）时只认单个 JSON 对象，直接回 SSE 会解析失败、content 为空。
 */
import { randomBytes } from 'node:crypto'

/**
 * @param {string} text 完整的 SSE 文本（含 `data: ...` 行与 `data: [DONE]`）
 * @returns {object} OpenAI ChatCompletion
 */
export function aggregateSse(text) {
  const acc = {
    id: undefined,
    created: Math.floor(Date.now() / 1000),
    model: undefined,
    content: '',
    reasoning: '',
    toolCalls: new Map(),
    finishReason: null,
    usage: undefined,
  }

  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed.startsWith('data:')) continue
    const payload = trimmed.slice(5).trim()
    if (payload === '' || payload === '[DONE]') continue

    let frame
    try { frame = JSON.parse(payload) } catch { continue }

    acc.id ??= frame.id
    acc.created = frame.created ?? acc.created
    acc.model ??= frame.model
    if (frame.usage !== undefined) acc.usage = frame.usage

    const choice = frame.choices?.[0]
    if (choice === undefined) continue

    const delta = choice.delta ?? {}
    if (typeof delta.content === 'string') acc.content += delta.content
    if (typeof delta.reasoning_content === 'string') acc.reasoning += delta.reasoning_content

    for (const call of delta.tool_calls ?? []) {
      const index = call.index ?? 0
      const current = acc.toolCalls.get(index) ?? {
        id: call.id,
        type: 'function',
        function: { name: '', arguments: '' },
      }
      if (call.id !== undefined) current.id = call.id
      if (call.function?.name !== undefined) current.function.name += call.function.name
      if (call.function?.arguments !== undefined) current.function.arguments += call.function.arguments
      acc.toolCalls.set(index, current)
    }

    if (choice.finish_reason !== null && choice.finish_reason !== undefined) {
      acc.finishReason = choice.finish_reason
    }
  }

  const message = { role: 'assistant', content: acc.content }
  if (acc.reasoning !== '') message.reasoning_content = acc.reasoning
  if (acc.toolCalls.size > 0) {
    message.tool_calls = [...acc.toolCalls.entries()]
      .sort(([a], [b]) => a - b)
      .map(([, value]) => value)
  }

  return {
    id: acc.id ?? `chatcmpl-${randomBytes(12).toString('hex')}`,
    object: 'chat.completion',
    created: acc.created,
    model: acc.model,
    choices: [{ index: 0, message, finish_reason: acc.finishReason ?? 'stop' }],
    usage: acc.usage ?? { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  }
}
