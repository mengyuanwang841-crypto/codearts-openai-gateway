#!/usr/bin/env node
/**
 * CodeArts → OpenAI 兼容网关
 *
 * 把华为云 CodeArts 的模型包成一个标准 OpenAI /v1 接口，供任意客户端使用。
 * 签名（AK/SK SDK-HMAC-SHA256）、STS token 注入、2 小时自动续期、多账号轮转、
 * 每账号并发槽位、max_tokens 钳制、上下文窗口守卫 —— 全部复用 dsh-codearts 插件；
 * 本进程只负责：对外的鉴权、loopback 守卫改写、非流式聚合、目录刷新。
 *
 * 端点：
 *   GET  /healthz              健康检查（无需鉴权）
 *   GET  /v1/models            模型清单
 *   POST /v1/chat/completions  Chat Completions（stream 可选）
 */
import { createServer } from 'node:http'
import { config } from './config.mjs'
import { loadPlugin } from './plugin.mjs'
import { aggregateSse } from './sse.mjs'

const VERSION = '1.0.0'

const argv = process.argv.slice(2)
if (argv.includes('--help') || argv.includes('-h')) {
  console.log(`codearts-openai-gateway ${VERSION}

用法: node src/gateway.mjs [选项]

环境变量 (也可写进 .env):
  HOST                        监听地址，默认 0.0.0.0
  PORT                        监听端口，默认 8787
  CODEARTS_GATEWAY_KEY        对外 API Key；不设则用 .gateway-key，再没有就自动生成
  CODEARTS_PLUGIN_DIR         dsh-codearts 包目录；默认自动查找
  DISCOVERY_INTERVAL_MS       模型目录刷新周期，默认 3600000
  ACCESS_LOG                  设为 0 关闭逐请求日志

端点:
  GET  /healthz
  GET  /v1/models
  POST /v1/chat/completions`)
  process.exit(0)
}
if (argv.includes('--version') || argv.includes('-v')) {
  console.log(VERSION)
  process.exit(0)
}

// ── 装配 ──────────────────────────────────────────────────────────
const { dir: pluginDir, mod } = await loadPlugin(config.pluginDir, config.root)
const {
  CodeArtsAccountStore,
  CodeArtsCatalog,
  createCodeArtsShim,
  refreshCatalog,
  codeartsAccountsPath,
  codeartsAuthPath,
} = mod

const accountsPath = codeartsAccountsPath()
const store = new CodeArtsAccountStore(accountsPath, codeartsAuthPath())
const catalog = new CodeArtsCatalog()

const shim = createCodeArtsShim({
  store,
  catalog,
  logger: {
    warn: (...args) => console.warn('[shim]', ...args),
    error: (...args) => console.error('[shim]', ...args),
  },
})
await shim.ready
const upstreamPort = new URL(shim.baseUrl()).port

console.log(`[gateway] version:  ${VERSION}`)
console.log(`[gateway] plugin:   ${pluginDir}`)
console.log(`[gateway] accounts: ${accountsPath}`)
console.log(`[gateway] shim:     ${shim.baseUrl()}`)

async function discover(label) {
  try {
    const outcome = await refreshCatalog(store, catalog)
    console.log(`[gateway] ${label} discovery: ${catalog.current().length} model(s)`)
    if (Array.isArray(outcome?.failures) && outcome.failures.length > 0) {
      console.warn('[gateway] discovery warnings:', outcome.failures)
    }
  } catch (error) {
    console.warn(`[gateway] ${label} discovery failed: ${String(error)}`)
  }
}
await discover('startup')

const discoveryTimer = setInterval(() => { void discover('scheduled') }, config.discoveryIntervalMs)
discoveryTimer.unref?.()

// ── HTTP ─────────────────────────────────────────────────────────
function authorized(req) {
  const header = req.headers.authorization
  const bearer = typeof header === 'string' && /^Bearer\s+(.+)$/i.test(header.trim())
    ? /^Bearer\s+(.+)$/i.exec(header.trim())[1]
    : undefined
  const presented = bearer ?? req.headers['x-api-key']
  return typeof presented === 'string' && presented === config.apiKey
}

function sendJson(res, status, value) {
  const body = JSON.stringify(value)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  })
  res.end(body)
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('request body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

/** 打到 shim：Host 必须是 loopback，Origin 直接不发，Bearer 换成 shim 的进程内密钥。 */
function callUpstream(path, body, signal) {
  return fetch(`http://127.0.0.1:${upstreamPort}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'text/event-stream',
      authorization: `Bearer ${shim.token()}`,
      host: `127.0.0.1:${upstreamPort}`,
      'user-agent': `codearts-openai-gateway/${VERSION}`,
    },
    body,
    signal,
  })
}

async function chatCompletions(req, res) {
  const raw = await readBody(req, config.bodyLimitBytes)

  let parsed
  try { parsed = JSON.parse(raw) } catch {
    sendJson(res, 400, { error: { type: 'invalid_request', message: 'body is not JSON' } })
    return
  }
  if (typeof parsed?.model !== 'string' || parsed.model === '') {
    sendJson(res, 400, { error: { type: 'invalid_request', message: 'model is required' } })
    return
  }

  const wantStream = parsed.stream === true
  const controller = new AbortController()
  res.on('close', () => { if (!res.writableEnded) controller.abort() })

  const reply = await callUpstream('/v1/chat/completions', raw, controller.signal)
  const contentType = reply.headers.get('content-type') ?? ''
  const isSse = contentType.includes('text/event-stream')

  if (!wantStream) {
    const text = await reply.text()
    if (!isSse) {
      res.writeHead(reply.status, { 'content-type': 'application/json; charset=utf-8' })
      res.end(text)
      return
    }
    if (reply.status >= 400) {
      res.writeHead(reply.status, { 'content-type': 'application/json; charset=utf-8' })
      res.end(text.startsWith('{') ? text : JSON.stringify({ error: { type: 'upstream_error', message: text } }))
      return
    }
    sendJson(res, 200, aggregateSse(text))
    return
  }

  res.writeHead(reply.status, {
    'content-type': isSse ? 'text/event-stream; charset=utf-8' : 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  })
  if (reply.body === null) { res.end(); return }

  const reader = reply.body.getReader()
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (!res.write(value)) await new Promise((r) => res.once('drain', r))
    }
  } catch {
    // 客户端断开或上游中断，收尾即可
  }
  res.end()
}

const server = createServer(async (req, res) => {
  const started = Date.now()
  const path = (req.url ?? '/').split('?')[0]

  if (config.accessLog) {
    res.on('finish', () => {
      console.log(`[req] ${req.method} ${path} → ${res.statusCode} ${Date.now() - started}ms`)
    })
  }

  try {
    if (path === '/healthz' || path === '/') {
      let accounts = []
      try { accounts = await store.list() } catch {}
      sendJson(res, 200, {
        ok: true,
        version: VERSION,
        signedIn: accounts.length > 0,
        accounts: accounts.map((account) => ({
          id: account.id,
          userName: account.userName,
          stale: account.stale,
        })),
        models: catalog.current().length,
      })
      return
    }

    if (!authorized(req)) {
      sendJson(res, 401, { error: { type: 'unauthorized', message: 'invalid API key' } })
      return
    }

    if (req.method === 'GET' && (path === '/v1/models' || path === '/v1/models/')) {
      sendJson(res, 200, {
        object: 'list',
        data: catalog.current().map((model) => ({
          id: model.id,
          object: 'model',
          created: 0,
          owned_by: 'codearts',
          context_window: model.contextWindow,
          max_tokens: model.maxTokens,
        })),
      })
      return
    }

    if (req.method === 'POST' && (path === '/v1/chat/completions' || path === '/v1/chat/completions/')) {
      await chatCompletions(req, res)
      return
    }

    sendJson(res, 404, { error: { type: 'not_found', message: `no such route: ${req.method} ${path}` } })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (!res.headersSent) sendJson(res, 500, { error: { type: 'gateway_error', message } })
    else res.end()
  }
})

server.listen(config.port, config.host, () => {
  console.log(`[gateway] listening on http://${config.host}:${config.port}`)
  console.log(`[gateway] api key:   ${config.apiKey} (${config.apiKeySource})`)
  console.log(`[gateway] probe:     curl -s http://127.0.0.1:${config.port}/healthz`)
})

const shutdown = async (signal) => {
  console.log(`[gateway] ${signal} → shutting down`)
  clearInterval(discoveryTimer)
  server.close()
  try { await shim.close() } catch {}
  process.exit(0)
}
process.on('SIGINT', () => { void shutdown('SIGINT') })
process.on('SIGTERM', () => { void shutdown('SIGTERM') })
