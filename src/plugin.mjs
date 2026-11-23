/**
 * 定位并加载 dsh-codearts 插件产物。
 *
 * 这个网关不重新实现签名，而是直接复用插件导出的：
 *   CodeArtsAccountStore / CodeArtsCatalog / createCodeArtsShim / refreshCatalog
 * 所以它必须能找到插件包目录（含 lib/index.mjs），并且那个目录能解析
 * @deepseek-ai/schemastery、dsh-llm、dsh-llm-pi-ai、dsh-settings 四个依赖。
 *
 * 查找顺序：
 *   1. CODEARTS_PLUGIN_DIR（显式指定）
 *   2. <repo>/vendor/dsh-codearts（scripts/setup-vendor.ps1 生成，自带依赖）
 *   3. ~/.dsh/profiles/<任意 profile>/node_modules/dsh-codearts
 */
import { existsSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const REQUIRED_EXPORTS = [
  'CodeArtsAccountStore',
  'CodeArtsCatalog',
  'createCodeArtsShim',
  'refreshCatalog',
  'codeartsAccountsPath',
  'codeartsAuthPath',
]

/** @returns {string[]} 候选插件目录（存在的才返回） */
export function pluginCandidates(explicitDir, root) {
  const list = []
  if (explicitDir !== undefined) list.push(explicitDir)

  list.push(join(root, 'vendor', 'dsh-codearts'))

  const profilesRoot = join(homedir(), '.dsh', 'profiles')
  if (existsSync(profilesRoot)) {
    for (const profile of readdirSync(profilesRoot, { withFileTypes: true })) {
      if (!profile.isDirectory()) continue
      list.push(join(profilesRoot, profile.name, 'node_modules', 'dsh-codearts'))
    }
  }

  return list.filter((dir) => existsSync(join(dir, 'lib', 'index.mjs')))
}

/**
 * @param {string|undefined} explicitDir CODEARTS_PLUGIN_DIR
 * @param {string} root 仓库根目录
 * @returns {Promise<{ dir: string, mod: Record<string, unknown> }>}
 */
export async function loadPlugin(explicitDir, root) {
  const candidates = pluginCandidates(explicitDir, root)
  if (candidates.length === 0) {
    throw new Error(
      '找不到 dsh-codearts 插件产物。先装插件（DSH 里安装 dsh-codearts），' +
      '再运行 scripts/setup-vendor.ps1；或用 CODEARTS_PLUGIN_DIR 直接指定包目录。',
    )
  }

  const errors = []
  for (const dir of candidates) {
    try {
      const mod = await import(pathToFileURL(join(dir, 'lib', 'index.mjs')).href)
      const missing = REQUIRED_EXPORTS.filter((name) => mod[name] === undefined)
      if (missing.length > 0) {
        errors.push(`${dir}: 缺少导出 ${missing.join(', ')}（插件版本太旧？）`)
        continue
      }
      return { dir, mod }
    } catch (error) {
      errors.push(`${dir}: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  throw new Error(`候选插件目录都加载失败：\n  ${errors.join('\n  ')}`)
}
