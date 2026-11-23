/**
 * 配置：读 .env / 环境变量，缺 API Key 就生成一个并落到 .gateway-key。
 *
 * 优先级：进程环境变量 > .env 文件 > 默认值
 * 没有 CODEARTS_GATEWAY_KEY 时：读 .gateway-key，没有就生成并写回 —— 重启不换 key，
 * 客户端不用重配。
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function loadDotEnv(path) {
  if (!existsSync(path)) return {}
  const out = {}
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue
    const eq = trimmed.indexOf('=')
    if (eq <= 0) continue
    const key = trimmed.slice(0, eq).trim()
    let value = trimmed.slice(eq + 1).trim()
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
    }
    out[key] = value
  }
  return out
}

const fileEnv = loadDotEnv(join(ROOT, '.env'))
const env = { ...fileEnv, ...process.env }

const KEY_FILE = join(ROOT, '.gateway-key')

function resolveApiKey() {
  if (typeof env.CODEARTS_GATEWAY_KEY === 'string' && env.CODEARTS_GATEWAY_KEY.trim() !== '') {
    return { key: env.CODEARTS_GATEWAY_KEY.trim(), source: 'env' }
  }
  if (existsSync(KEY_FILE)) {
    const stored = readFileSync(KEY_FILE, 'utf8').trim()
    if (stored !== '') return { key: stored, source: 'file' }
  }
  const generated = `sk-${randomBytes(24).toString('base64url')}`
  writeFileSync(KEY_FILE, `${generated}\n`, { mode: 0o600 })
  return { key: generated, source: 'generated' }
}

const apiKey = resolveApiKey()

function num(value, fallback) {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

export const config = {
  root: ROOT,
  host: env.HOST ?? '0.0.0.0',
  port: num(env.PORT, 8787),
  apiKey: apiKey.key,
  apiKeySource: apiKey.source,
  /** 显式指定的插件目录；空则由 plugin.mjs 自己找 */
  pluginDir: env.CODEARTS_PLUGIN_DIR ?? undefined,
  /** 目录刷新周期，默认 1 小时，和插件同频 */
  discoveryIntervalMs: num(env.DISCOVERY_INTERVAL_MS, 60 * 60 * 1000),
  /** 单次请求体上限 */
  bodyLimitBytes: num(env.BODY_LIMIT_BYTES, 32 * 1024 * 1024),
  /** 是否打印每个请求一行日志 */
  accessLog: env.ACCESS_LOG !== '0',
}
