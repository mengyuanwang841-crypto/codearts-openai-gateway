# CodeArts OpenAI Gateway

[![ci](https://github.com/mengyuanwang841-crypto/codearts-openai-gateway/actions/workflows/ci.yml/badge.svg)](https://github.com/mengyuanwang841-crypto/codearts-openai-gateway/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![node](https://img.shields.io/badge/node-%3E%3D20.11-informational.svg)](package.json)

把华为云 **CodeArts** 的模型（GLM-5.2/5.3、DeepSeek-V4.1、Kimi-K3、盘古 …）包成一个标准
**OpenAI `/v1` 接口**，给任何客户端用：Cherry Studio、ChatBox、Cline、Cursor、OpenAI SDK、你自己的脚本。

不重写签名。直接复用 [dsh-codearts](https://github.com/elegant01/dsh-codearts) 插件的
`AK/SK SDK-HMAC-SHA256` 签名、STS token 注入、2 小时自动续期、多账号轮转、每账号并发槽位，
本项目只补“对外”这一层。

```
客户端 (OpenAI SDK / 任意 OpenAI 兼容 App)
   │  POST /v1/chat/completions      Authorization: Bearer <你的 key>
   ▼
gateway  (本仓库, 0.0.0.0:8787)      ← 鉴权 / 非流式聚合 / Host 改写 / 目录刷新
   │  Bearer <shim 进程内随机密钥>
   ▼
dsh-codearts shim  (127.0.0.1:随机)   ← 插件自己起，只认 loopback + 随机密钥
   │  x-auth-token: <STS security_token> + AK/SK 签名
   ▼
CodeArts  /api/v2/chat/completions
```

## 为什么需要这一层

插件内部的 shim 有三重守卫，只服务插件自己：

| 守卫 | 行为 | 本项目的处理 |
|---|---|---|
| `Host` 必须 loopback | 否则 `403 host_not_allowed` | 转发时改写 `Host: 127.0.0.1:<shim 端口>` |
| `Origin` 必须 loopback | 否则 `403 origin_not_allowed` | 根本不发 `Origin` |
| `Bearer` 是进程内 `randomBytes(32)` | 否则 `401 unauthorized` | 自己起 shim，拿到 `shim.token()` |

所以“直接反代 shim 端口”是走不通的 —— 第三重你无法伪造。正确做法是自己起一个 shim
（因此拿到 token），外面套自己的鉴权，这个仓库就是那一层。

## 特性

- **零签名代码** —— 签名、token、续期、轮转全部来自插件，升级插件即升级协议
- **OpenAI 兼容** —— `/v1/models`、`/v1/chat/completions`、`stream` 流式、`tools` 工具调用
- **非流式聚合** —— 上游只出 SSE，`stream:false` 时自动拼成单个 `chat.completion`（含 `reasoning_content` / `tool_calls` / `usage`）
- **自带鉴权** —— 一套 API Key，支持 `Authorization: Bearer` 与 `x-api-key`
- **密钥不丢** —— 首次启动生成 `.gateway-key`（0600，已 gitignore），重启不换 key
- **多账号轮转** —— 读插件的账号文件，登录几个就用几个，槽位满了自动换号
- **模型目录自刷新** —— 启动拉一次，之后每小时一次，失败不影响服务
- **SSE 友好** —— 响应带 `x-accel-buffering: no`，断开即 abort 上游

## 前置条件

1. 已安装 [DeepSeek Harness](https://deepseek.com) 与 **dsh-codearts** 插件
2. 已在插件里**登录过华为云账号**（账号文件：`%USERPROFILE%\.dsh\.codearts-accounts.json`）
3. Node.js **>= 20.11**（本仓库零 npm 依赖，不需要 `npm install`）

## 快速开始

### Windows

```powershell
git clone https://github.com/mengyuanwang841-crypto/codearts-openai-gateway.git
cd codearts-openai-gateway

# 1. 把已安装的插件产物与它依赖的 @deepseek-ai 包接进来（生成 vendor/，不进仓库）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-vendor.ps1

# 2. 起服务
scripts\start.cmd
```

Windows 上没有 `node` 在 PATH 也能跑：`start.cmd` 会退回到 DSH 自带的那份 Node。

### Linux / macOS

```bash
git clone https://github.com/mengyuanwang841-crypto/codearts-openai-gateway.git
cd codearts-openai-gateway
bash scripts/setup-vendor.sh
node src/gateway.mjs
```

### 验通

```bash
curl -s http://127.0.0.1:8787/healthz
# {"ok":true,"version":"1.0.0","signedIn":true,"accounts":[{"userName":"...","stale":false}],"models":12}

curl -s http://127.0.0.1:8787/v1/models -H "Authorization: Bearer $(cat .gateway-key)"
```

第一行 `signedIn:false` 就是还没登录，回 DSH 里登录 CodeArts 卡片再重试。

`/healthz` **不需要鉴权**，因此只返回最小信息（`ok` / `signedIn` / 模型数），
不暴露账号 id 与用户名。要看账号细节得带 key 并显式加 `?detail=1`：

```bash
curl -s "http://127.0.0.1:8787/healthz?detail=1" -H "Authorization: Bearer $(cat .gateway-key)"
```

## 配置

优先级：**环境变量 > `.env` > 默认值**。把 `.env.example` 复制成 `.env` 改就行。

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8787` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址；只给本机用就设 `127.0.0.1` |
| `CODEARTS_GATEWAY_KEY` | 自动生成 | 对外 API Key；不设时读 `.gateway-key`，没有就生成并写回 |
| `CODEARTS_PLUGIN_DIR` | 自动查找 | dsh-codearts 包目录（含 `lib/index.mjs`） |
| `DISCOVERY_INTERVAL_MS` | `3600000` | 模型目录刷新周期 |
| `BODY_LIMIT_BYTES` | `33554432` | 单请求体上限（长上下文/图片要够大） |
| `ACCESS_LOG` | `1` | 设 `0` 关掉逐请求日志 |

## 客户端接入

| 字段 | 值 |
|---|---|
| Base URL / 接口地址 | `http://<主机>:8787/v1` |
| API Key | `.gateway-key` 里的那串 |
| Model | `glm-5.3-flash` 等，照 `/v1/models` 抄，**大小写敏感** |

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8787/v1", api_key=open(".gateway-key").read().strip())
resp = client.chat.completions.create(
    model="glm-5.3-flash",
    messages=[{"role": "user", "content": "你好"}],
)
print(resp.choices[0].message.content)
```

```bash
curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H "Authorization: Bearer $CODEARTS_GATEWAY_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"你好"}],"max_tokens":512}'
```

GUI 客户端（Cherry Studio / ChatBox / NextChat / LobeChat）：新增“OpenAI 兼容”供应商，
填上面两个字段，模型名手填（这类客户端不一定自动拉 `/v1/models`）。
Cline / Roo Code / Continue：Provider 选 `OpenAI Compatible`，其余同上，工具调用可直通。

## 暴露到公网

见 [docs/DEPLOY.md](docs/DEPLOY.md)：frp、Caddy、Cloudflare Tunnel、nginx 四种配置。
两条硬要求：**边界必须 TLS**、**必须关掉响应缓冲**（`flush_interval -1` / `proxy_buffering off`），
否则流式会被攒着发。

## 开机自启

```powershell
# 只启动网关（默认用法：自己电脑上用）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-autostart.ps1 -NoTunnel

# 网关 + 隧道一起随登录启动（如果你想长期挂个公网地址）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-autostart.ps1
```

触发时机是**登录时**而不是开机时：凭证在 `%USERPROFILE%\.dsh\.codearts-accounts.json`，
SYSTEM 账户读不到，开在 boot 阶段会直接 `signedIn:false`。

脚本按顺序尝试两种机制：

1. `schtasks /sc onlogon` —— 若被组策略拒绝（`ERROR: Access is denied.`），
2. 自动退回**启动文件夹**里放一个隐藏窗口的 VBS：
   `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\CodeArts-Gateway.vbs`

`boot.ps1` 是幂等的：端口已在监听、`cloudflared` 已在跑，就什么都不做，不会起第二份。

```powershell
powershell -File scripts\boot.ps1 -WithTunnel   # 手动跑一次（等同开机时的行为）
powershell -File scripts\uninstall-autostart.ps1  # 取消自启
```

## 分享给别人用

默认 `.env` 里 `HOST=127.0.0.1`：只有本机能访问，局域网和公网都进不来。
偶尔要给朋友/别的机器用时，临时开一条隧道，用完关掉：

```powershell
scripts\share.cmd        # 或 powershell -File scripts\share.ps1
```

它会：起网关（若没起）→ 开 Cloudflare 临时隧道 → 把「Base URL / API Key / 模型 / curl 示例」
**打印出来并复制到剪贴板**，你直接粘给对方。

```powershell
scripts\unshare.cmd      # 关隧道，公网地址立即失效
```

隧道地址每次都不一样，这在这里正好：不分享的时候外面根本不存在这个地址。

分享完想收回对方的访问权（例如对方把 key 漏出去了）：

```powershell
powershell -File scripts\rotate-key.ps1   # 生成新 key 并重启网关
```

也可以换成对方只在局域网里用 —— 把 `.env` 的 `HOST` 改成 `0.0.0.0` 重启，然后给
`http://<你的内网IP>:8787/v1`（路由器会挡住外网，安全性和公网完全不同）。

## 固定公网地址（一般不需要）

`scripts/tunnel.ps1` 用的是 Cloudflare **quick tunnel**，免费、不用账号，但**每次启动域名都会变**
（`https://随机词-随机词-….trycloudflare.com`）。当前地址随时写在仓库根的 `current-url.txt`。

只有当你需要「一个永久地址天天挂」时，才值得绑域名（Cloudflare 免费计划即可）：


```powershell
# 1. 一次性：浏览器里登录 Cloudflare
tools\cloudflared.exe tunnel login

# 2. 建命名隧道 + 绑域名 + 写 config.yml
powershell -File scripts\setup-named-tunnel.ps1 -Hostname api.example.com

# 3. 装成 Windows 服务（需要管理员终端），以后开机自动连，地址永远不变
tools\cloudflared.exe --config "$env:USERPROFILE\.cloudflared\config.yml" service install
Start-Service cloudflared
```

之后客户端就用 `https://api.example.com/v1`，与重启无关。
没有域名的话，另一条等价路线是 VPS + frp（见 [docs/DEPLOY.md](docs/DEPLOY.md)）。


## 已知限制

| 项 | 说明 |
|---|---|
| 并发 | 上游每账号 3 个会话槽，插件默认留 1 个给网页端 → 实用 2 并发；**停止生成也占约 1 分钟**。要更多并发就再登录一个账号 |
| TPM | 免费档有每分钟 token 上限，超了 429/排队；换号由插件内部处理，网关不重试 |
| 凭证 | STS 约 2 小时，网关自动续；`refresh_token` 是一次性的，**多机别共享同一份账号文件** |
| max_tokens | 上游标称 393216，实测 >65536 报 `InferHub.001001005.400`；插件下发前钳到 65536（GLM-5.2 可 131072）。**给 300 以上**，否则 GLM 系列会在思考阶段被截断、`content` 为空 |
| 上下文 | 免费档真实窗口可能远小于标称，插件会在本地拦“装不下”并回 400 `context_overflow` |
| 非流式 | 上游只出 SSE，聚合后 `usage` 有就带、没有就补 0 |
| 单机 | 本机进程，不是多租户服务；多机部署＝每台各登录一份账号 |
| 模型名 | 大小写敏感：`GLM-5.2` ≠ `glm-5.2` |

## 排错

```bash
# 插件侧是否正常（绕开本网关）
node "$HOME/.dsh/profiles/desktop/node_modules/dsh-codearts/lib/bin.mjs" status
node "$HOME/.dsh/profiles/desktop/node_modules/dsh-codearts/lib/bin.mjs" models

# 网关自检
curl -s http://127.0.0.1:8787/healthz
```

| 现象 | 原因 |
|---|---|
| `401 unauthorized` | API Key 不对（看启动日志里打印的 key） |
| `403 host_not_allowed` / `origin_not_allowed` | 有人改了 `Host` 头或加了 `Origin`，或你绕过网关直连了 shim |
| `502` / `gateway_error` | shim 没起来，看启动日志 |
| `signedIn:false` | 账号文件没登录或已登出，回 DSH 登录 |
| `content` 为空、`finish_reason:length` | `max_tokens` 太小，思考吃满了 |
| `Cannot find package '@deepseek-ai/...'` | `setup-vendor` 的 junction 失效（升级过 DSH），重跑一次 |
| 流式卡住不吐字 | 反代开了缓冲，见 [docs/DEPLOY.md](docs/DEPLOY.md) |

## 目录结构

```
.
├── src/
│   ├── gateway.mjs     # HTTP 服务：鉴权、路由、流式/非流式
│   ├── config.mjs      # .env / 环境变量 / key 持久化
│   ├── plugin.mjs      # 定位并加载 dsh-codearts 产物
│   └── sse.mjs         # SSE → chat.completion 聚合
├── scripts/
│   ├── setup-vendor.ps1 / .sh   # 生成 vendor/（插件副本 + 依赖链接）
│   ├── check.mjs                # 语法 + 聚合单测（CI 用）
│   ├── start.cmd / stop.cmd     # Windows 启停
├── docs/DEPLOY.md
├── .github/workflows/ci.yml
└── vendor/            # setup 生成，gitignore
```

## 致谢

- [dsh-codearts](https://github.com/elegant01/dsh-codearts)（MIT）—— 签名、续期、账号池、shim 全部来自它
- [dsh-codebuddy-cli](https://github.com/fu827707013/dsh-codebuddy-cli)（MIT）—— 插件结构参考

## 免责

本项目只驱动**你自己的**华为云账号在本机调用，与华为、DeepSeek、智谱等均无关联。
使用需遵守华为云与 CodeArts 的服务条款；产生的任何后果由使用者自行承担。
