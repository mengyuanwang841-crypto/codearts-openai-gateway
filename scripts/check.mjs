/**
 * 本地/CI 自检：语法 + SSE 聚合单测。不需要插件、不需要登录、不联网。
 * 用法：node scripts/check.mjs
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { aggregateSse } from '../src/sse.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')

// 1. 语法检查每个源文件（gateway.mjs 会在 import 时起服务，所以只做 --check）
const srcFiles = readdirSync(join(root, 'src')).filter((name) => name.endsWith('.mjs'))
for (const file of srcFiles) {
  execFileSync(process.execPath, ['--check', join(root, 'src', file)], { stdio: 'inherit' })
}
console.log(`syntax ok: ${srcFiles.length} file(s)`)

// 2. SSE 聚合
const sse = [
  'data: {"id":"chatcmpl-1","created":1700,"model":"glm-5.3-flash","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"想"}}]}',
  'data: {"id":"chatcmpl-1","created":1700,"model":"glm-5.3-flash","choices":[{"index":0,"delta":{"reasoning_content":"一下"}}]}',
  'data: {"id":"chatcmpl-1","created":1700,"model":"glm-5.3-flash","choices":[{"index":0,"delta":{"content":"你好"}}]}',
  'data: {"id":"chatcmpl-1","created":1700,"model":"glm-5.3-flash","choices":[{"index":0,"delta":{"content":"，世界"}}]}',
  'data: {"id":"chatcmpl-1","created":1700,"model":"glm-5.3-flash","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":7,"total_tokens":16}}',
  'data: [DONE]',
  '',
].join('\n')

const completion = aggregateSse(sse)
assert.equal(completion.object, 'chat.completion')
assert.equal(completion.id, 'chatcmpl-1')
assert.equal(completion.model, 'glm-5.3-flash')
assert.equal(completion.choices[0].message.content, '你好，世界')
assert.equal(completion.choices[0].message.reasoning_content, '想一下')
assert.equal(completion.choices[0].finish_reason, 'stop')
assert.equal(completion.usage.total_tokens, 16)
console.log('aggregate sse: text + reasoning ok')

// 3. 工具调用拼接
const toolSse = [
  'data: {"id":"c2","model":"glm-5.3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_","arguments":"{\\"ci"}}]}}]}',
  'data: {"id":"c2","model":"glm-5.3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"weather","arguments":"ty\\":\\"北京\\"}"}}]}}]}',
  'data: {"id":"c2","model":"glm-5.3","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
  'data: [DONE]',
  '',
].join('\n')

const toolCompletion = aggregateSse(toolSse)
const call = toolCompletion.choices[0].message.tool_calls[0]
assert.equal(call.id, 'call_1')
assert.equal(call.function.name, 'get_weather')
assert.equal(call.function.arguments, '{"city":"北京"}')
assert.equal(toolCompletion.choices[0].finish_reason, 'tool_calls')
console.log('aggregate sse: tool_calls ok')

// 4. 空流也要给出结构化结果（不能让客户端拿到 undefined）
const empty = aggregateSse('data: [DONE]\n')
assert.equal(empty.choices[0].message.content, '')
assert.equal(empty.choices[0].finish_reason, 'stop')
console.log('aggregate sse: empty stream ok')

console.log('all checks passed')
