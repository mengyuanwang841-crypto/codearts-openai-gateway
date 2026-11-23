# 部署与对外暴露

网关默认就监听 `0.0.0.0:8787`，同一局域网可直接用 `http://<内网IP>:8787/v1`。
要把服务放到公网，下面四种任选其一。

**两条硬要求**（无论哪种方式）：

1. **边界必须 TLS** —— API Key 明文过公网等于没有密钥
2. **必须关掉响应缓冲** —— 否则 SSE 被攒着发，首字延迟从 200ms 变成好几秒

---

## 1. frp（有公网 VPS，最省事）

VPS 上 `frps.toml`：

```toml
bindPort = 7000
vhostHTTPSPort = 443
```

本机 `frpc.toml`：

```toml
serverAddr = "1.2.3.4"
serverPort = 7000

[[proxies]]
name = "codearts"
type = "https"
customDomains = ["api.example.com"]
localIP = "127.0.0.1"
localPort = 8787
```

HTTPS 证书在 VPS 侧的 Caddy/nginx 上配，转发到 frp 的 vhost 端口。

懒人 TCP 版（不配 vhost）：

```toml
[[proxies]]
name = "codearts"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8787
remotePort = 18787
```

VPS 上用 nginx `proxy_pass http://127.0.0.1:18787;`（记得下面 nginx 那节的缓冲设置）。

---

## 2. Caddy（本机直接对外，自动 HTTPS）

```caddyfile
api.example.com {
    encode zstd gzip

    reverse_proxy 127.0.0.1:8787 {
        flush_interval -1          # SSE 关键：不要缓冲
        transport http {
            read_timeout 600s
        }
    }

    # 边缘再叠一层白名单（可选）
    @nokey not header Authorization "Bearer sk-edge-key"
    respond @nokey 401
}
```

`flush_interval -1` 是必须的。Caddy 默认会攒一点再 flush，流式体验会明显变差。

---

## 3. Cloudflare Tunnel（不想开端口）

```bash
cloudflared tunnel login
cloudflared tunnel create codearts

# ~/.cloudflared/config.yml
# tunnel: <tunnel-id>
# credentials-file: /path/to/<tunnel-id>.json
# ingress:
#   - hostname: api.example.com
#     service: http://127.0.0.1:8787
#   - service: http_status:404

cloudflared tunnel route dns codearts api.example.com
cloudflared tunnel run codearts
```

临时试用可以直接 `cloudflared tunnel --url http://127.0.0.1:8787`，拿一个随机域名。
注意 Cloudflare 免费档对长连接有 100 秒左右的空闲上限，超长生成建议上 `stream: true`。

---

## 4. nginx（已有反代机器）

```nginx
server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/ssl/api.example.com.pem;
    ssl_certificate_key /etc/ssl/api.example.com.key;

    client_max_body_size 32m;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";

        proxy_buffering off;        # SSE
        proxy_cache off;
        chunked_transfer_encoding on;

        proxy_read_timeout 600s;    # 长回答 / 排队别被掐
        proxy_send_timeout 600s;
    }
}
```

---

## 常驻运行（Windows）

```powershell
# 开机自启（当前用户，不弹窗，日志落盘）
schtasks /create /tn "CodeArtsGateway" /sc onstart /rl highest /f /tr ^
  "powershell -NoProfile -WindowStyle Hidden -Command ""Set-Location 'C:\path\to\codearts-openai-gateway'; node src\gateway.mjs *>> gateway.log"""
```

或者用 [NSSM](https://nssm.cc/) / [winsw](https://github.com/winsw/winsw) 包成服务（推荐，能自动重启）。

## 常驻运行（Linux）

```ini
# /etc/systemd/system/codearts-gateway.service
[Unit]
Description=CodeArts OpenAI Gateway
After=network-online.target

[Service]
WorkingDirectory=/opt/codearts-openai-gateway
Environment=PORT=8787
Environment=HOST=127.0.0.1
ExecStart=/usr/bin/node src/gateway.mjs
Restart=always
RestartSec=5
User=codearts

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now codearts-gateway
journalctl -u codearts-gateway -f
```

---

## 安全清单

- `HOST=127.0.0.1` + 反代是更稳的组合（网关本身不直接对公网）
- API Key 用 `sk-` + 32 位以上随机串；`CODEARTS_GATEWAY_KEY` 写进服务环境变量，别写进仓库
- 流量大的话在边缘加限流（Caddy `rate_limit` / nginx `limit_req`）
- 日志里不要打印请求体（本项目默认只打方法、路径、状态码、耗时）
- 账号文件（`~/.dsh/.codearts-accounts.json`）里有 refresh_token + DPoP 私钥，等同密码，别外传
