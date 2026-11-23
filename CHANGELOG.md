# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-11-23

首个版本。

### 新增

- **OpenAI 兼容端点**：`GET /v1/models`、`POST /v1/chat/completions`（支持 `stream`），
  以及无需鉴权的 `GET /healthz`
- **复用 dsh-codearts 插件**：AK/SK `SDK-HMAC-SHA256` 签名、STS token 注入、2 小时自动续期、
  多账号轮转、每账号并发槽位、`max_tokens` 钳制、上下文窗口守卫全部来自插件
- **loopback 守卫改写**：转发时把 `Host` 改成 `127.0.0.1:<shim 端口>`、不发 `Origin`，
  并以 `shim.token()` 作为上游 Bearer
- **非流式聚合**：上游只输出 SSE，`stream:false` 时拼成单个 `chat.completion`，
  保留 `reasoning_content`、`tool_calls`（按 `index` 拼接增量）与上游 `usage`
- **自带鉴权**：`Authorization: Bearer` 或 `x-api-key`，比较使用常量时间思路（长度先比）
- **密钥持久化**：未配置 `CODEARTS_GATEWAY_KEY` 时首次启动生成 `.gateway-key`（0600，gitignore），
  重启不换 key
- **模型目录自刷新**：启动拉一次，之后按 `DISCOVERY_INTERVAL_MS`（默认 1 小时），失败不影响服务
- **跨平台脚本**：`scripts/setup-vendor.ps1`（Windows）/ `scripts/setup-vendor.sh`（Linux、macOS）、
  `scripts/start.cmd`、`scripts/stop.cmd`（按端口找 PID）
- **自检**：`scripts/check.mjs`（语法 + SSE 聚合单测）与 GitHub Actions CI
- **部署文档**：frp、Caddy、Cloudflare Tunnel、nginx 四种暴露方式，含 SSE 缓冲与超时要点

### 已知限制

- 上游每账号 3 个会话槽，插件默认留 1 个给网页端 → 实用 2 并发；停止生成仍占用约 1 分钟
- `max_tokens` 实测超过 65536 会被上游判参数非法，给 300 以上才能避开 GLM 系思考阶段截断
- 单机进程模型，多机部署需要各自登录账号，不要共享账号文件
