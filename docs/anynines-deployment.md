# mmcen/hermes-anynines 部署文档（anynines PaaS）

> 最后更新：2026-08-27
> 部署账号：anyuan22@auaa.ccwu.cc（agent: Unorouter）
> 状态：✅ 已部署并验证通过（四服务全绿 + Telegram 已连通）

---

## 1. 概览

| 项 | 值 |
|---|---|
| 应用名 | `hermes-agent-docker` |
| 平台 | anynines (a9s PaaS, CloudFoundry 兼容) |
| CF API | `https://api.de.a9s.eu` |
| 组织 | `anyuan22_auaa_ccwu_cc` |
| 空间 | `production` |
| 镜像 | `mmcen/hermes-anynines`（Docker Hub，~982MB） |
| 部署方式 | CloudFoundry Docker 生命周期（diego_docker） |
| 实例规格 | 1024M 内存 / 4G 磁盘 / 1 实例 |
| 健康检查 | `process` 类型（gateway 不监听 HTTP 8080） |
| Route | 无（`no-route: true`，服务出站走 Cloudflare Tunnel） |

### 镜像 tag 语义

| tag | 含义 | 何时用 |
|---|---|---|
| `:latest` | 当前可直接部署的 **wrapper**（含 anynines 入口） | ✅ 日常部署 |
| `:anynines` | wrapper（与 latest 同内容，历史可追溯） | 推荐显式固定 |
| `:anynines-<sha>` | wrapper 的 commit 溯源 | 回滚/审计 |
| `:base` / `:base-<sha>` | 底层 Hermes 镜像（无 wrapper） | 不要直接部署 |

> ⚠️ 历史教训：`mmcen/hermes-anynines:latest` 早期曾是 base（无 wrapper、无执行位），
> 部署会 `Permission denied`。2026-08-27 已通过 workflow 重构修复 —— 现在
> `:latest` = wrapper，可直接部署。主仓库 `mmcen/hermes-agent` 只保留
> `latest`/`main`，anynines 相关 tag 已全部清理。

---

## 2. 为什么需要专用镜像 wrapper

CF 的 diego/garden 会把容器 PID 1 固定为 `/tmp/garden-init`，镜像入口
`entrypoint-dispatch.sh` 永远拿不到 PID 1（`[ "$$" -eq 1 ]` 永不成立），
官方 s6 监督树不会启动 → cloudflared / dashboard / sshd 全部被跳过。

**专门构建的 `mmcen/hermes-anynines` 镜像**（仓库 `mmcen/hermes-anynines`）
提供了 CF 专用入口 `docker/entrypoint-anynines.sh`：

```sh
if [ "$$" -eq 1 ]; then
    exec /init /opt/hermes/docker/main-wrapper.sh "$@"   # 正常 Docker：走 s6
fi
# CF fallback（非 PID 1）：手动后台拉起三个 side service，再 exec gateway
```

**镜像内置的两项关键修复**（2026-08-27 合入）：

1. **`S6_KEEP_ENV=1`**：CF fallback 下 `/init` 没跑，`/run/s6/container_environment`
   近似为空，`with-contenv` 会清空并重灌环境 → 侧服务全部读到空变量而 disabled。
   现在 wrapper 内置 `export S6_KEEP_ENV=1`，**manifest 无需再加前缀**。
2. **cloudflared 降权修复**：原 `s6-rc.d/cloudflared/run` 的 `set -- s6-setuidgid`
   未实际生效，tunnel 以 root 跑；已改为与 dashboard 相同的显式二选一 exec，
   现在以 `hermes` 用户运行。

---

## 3. 容器内服务结构

| 服务 | 进程 | 用户 | 依赖环境变量 |
|---|---|---|---|
| `gateway` | `hermes gateway run` | hermes | — |
| `cloudflared` | Cloudflare Tunnel（出站） | **hermes** | `TUNNEL_TOKEN` |
| `dashboard` | Hermes Web UI（:9119） | hermes | `HERMES_DASHBOARD=1` |
| `sshd` | SSH（:22，需 root） | root | `SSH_ENABLED=true`, `SSH_PUBLIC_KEY` |

SSH 授权公钥双写：`/root/.ssh/authorized_keys` + `/opt/data/.ssh/authorized_keys`。

---

## 4. 环境变量清单

| 变量 | 值（示例） | 用途 |
|---|---|---|
| `HERMES_DASHBOARD` | `1` | 启用 dashboard |
| `HERMES_DASHBOARD_HOST` | `0.0.0.0` | dashboard 监听地址 |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `admin` | dashboard 登录名 |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | `<password>` | dashboard 密码 |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `<secret>` | 基本认证签名密钥 |
| `SSH_ENABLED` | `true` | 启用 sshd |
| `SSH_PORT` | `22` | 容器内 sshd 端口（默认 22；2222 是 CF 平台 diego-sshd） |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA...` | 授权公钥（root + hermes 双写） |
| `TUNNEL_TOKEN` | `eyJh...` | Cloudflare Tunnel token（出站） |
| `TELEGRAM_BOT_TOKEN` | `8929003782:AAH...` | Telegram bot token |
| `TELEGRAM_ALLOWED_USERS` | `8019081926` | Telegram 允许用户（白名单） |
| `NOUS_API_KEY` | （未配置 ⚠️） | Nous Portal 推理凭据（缺失时 gateway 报 no provider） |

---

## 5. 完整部署 manifest（`manifest-anynines.yml`）

```yaml
applications:
- name: hermes-agent-docker
  docker:
    image: mmcen/hermes-anynines:latest
  memory: 1024M
  no-route: true
  disk_quota: 4G
  health-check-type: process
  command: /opt/hermes/docker/entrypoint-anynines.sh gateway run
  env:
    HERMES_DASHBOARD: "1"
    HERMES_DASHBOARD_HOST: "0.0.0.0"
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME: "admin"
    HERMES_DASHBOARD_BASIC_AUTH_PASSWORD: "<你的密码>"
    HERMES_DASHBOARD_BASIC_AUTH_SECRET: "<你的secret>"
    SSH_ENABLED: "true"
    SSH_PORT: "22"
    SSH_PUBLIC_KEY: "ssh-ed25519 AAAA..."
    TUNNEL_TOKEN: "eyJh..."
    TELEGRAM_BOT_TOKEN: "8929003782:AAH..."
    TELEGRAM_ALLOWED_USERS: "8019081926"
```

command 一行即可 —— 侧服务启动逻辑全在 wrapper 里，**不要**再手写
`export S6_KEEP_ENV=1 &&` 前缀（已内置），也不要像旧部署那样手写一大段
nohup/s6-setuidgid 启动脚本。

---

## 6. 部署步骤

**前置**：CF CLI v8+，登录凭据。

```sh
# 1. 配置 API 并登录
cf api https://api.de.a9s.eu --skip-ssl-validation
cf login -u anyuan22@auaa.ccwu.cc -p '<密码>' \
  -o anyuan22_auaa_ccwu_cc -s production --skip-ssl-validation
```

> 💡 若 `cf login` 在本环境超时卡死（UAA/login 端点其实正常）：
> 用 UAA password grant 手动拿 token 写 `~/.cf/config.json`，见第 9 节。

```sh
# 2.（仅当重复部署）配额 1G：先 stop 释放 staging 额度
cf stop hermes-agent-docker

# 3. 部署（镜像、env、command 全部由 manifest 管理）
cf push -f manifest-anynines.yml

# 4. 确认
cf app hermes-agent-docker
```

**首次登录新账号的坑**：默认 org quota 只有 `default`（total memory 1G），
三个 space（production/staging/test）都空，直接 push 即可；
若空间配额不足会报 `organization's memory limit exceeded`，先 `cf stop` 再 push。

---

## 7. 验证 & 运维

**四个进程**：

```sh
cf ssh hermes-agent-docker -c \
  "ps aux | grep -E 'gateway|cloudflared|dashboard|sshd' | grep -v grep"
```

预期输出（注意 cloudflared 应为 **hermes** 用户）：

```
hermes  ... hermes gateway run
hermes  ... cloudflared tunnel --no-autoupdate ...
hermes  ... hermes dashboard
root    ... sshd: /usr/sbin/sshd -D -p 22
```

**关键日志**：

```sh
cf logs hermes-agent-docker --recent                                # CF 聚合
cf ssh hermes-agent-docker -c "tail -20 /opt/data/logs/cloudflared.log"
cf ssh hermes-agent-docker -c "tail -20 /opt/data/logs/dashboard.log"
cf ssh hermes-agent-docker -c "tail -20 /opt/data/logs/sshd.log"
cf ssh hermes-agent-docker -c "tail -20 /opt/data/logs/gateway.log"
```

**确认输出**：
- gateway：`✓ telegram connected` / `✓ api_server connected` / `set_my_commands OK`
- cloudflared：`INF precheck complete ... status=pass`
- dashboard：`HERMES_DASHBOARD_READY port=9119`
- sshd：`Server listening on 0.0.0.0 port 22.`

**重启 / 更新 env**：改 manifest 后 `cf stop hermes-agent-docker && cf push -f manifest-anynines.yml`

---

## 8. 镜像更新流程

**代码 → CI → Docker Hub → CF 三步**：

```sh
# 1. 在 mmcen/hermes-anynines 仓库改代码后推送
git add -A && git commit -m "..." && git push origin main
#    触发 GitHub Actions：build-base → build-anynines，自动推
#    :latest / :anynines / :anynines-<sha> / :base / :base-<sha>

# 2. 等 CI 完成（Actions 页确认 success，约 5-8 分钟）

# 3. 重推 CF（quota 1G 先 stop）
cf stop hermes-agent-docker && cf push -f manifest-anynines.yml
```

仓库 `mmcen/hermes-anynines` 的 workflow（`.github/workflows/docker-anynines.yml`）
是**自包含两阶段**：`build-base` 用主 `Dockerfile` 构建底层镜像，按 **digest**
传递给 `build-anynines`（`--build-arg BASE_IMAGE=...@sha256:...`），wrapper
`FROM <digest>` 永不漂移。触发路径：`docker/entrypoint-anynines.sh`、
`docker/s6-rc.d/cloudflared/run`、`Dockerfile.anynines`、workflow 自身。

---

## 9. 常见问题

| 症状 | 原因 | 处理 |
|---|---|---|
| `organization's memory limit exceeded` | org quota 1G，实例 + staging 叠加超限 | 先 `cf stop` 再 push |
| `Permission denied` (exit 126) | 用了旧 `:latest`（base，无执行位） | 拉取新镜像后重新 push；只用当前 `:latest`/`:anynines` |
| 只有 gateway 在跑，tunnel/dashboard 没了 | wrapper 没内置 S6_KEEP_ENV（旧镜像） | 确保用 `d709df57` 之后的镜像；manifest 不加前缀 |
| cloudflared 以 root 运行 | 旧 `cloudflared/run` 降权 bug | 用 `51909e385` 之后的镜像 |
| `No messaging platforms enabled` | 没配 TELEGRAM_* 等通道变量 | 加 `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_USERS` |
| `No inference provider configured` | 没配 LLM API key | 加 `NOUS_API_KEY`（Nous Portal）/ `OPENROUTER_API_KEY` / `OPENAI_API_KEY` 等 |
| `cf login` 卡死/超时 | CLI 交互异常（UAA 正常） | UAA 手动 token，见下方 |
| `Routes cannot be mapped to destinations in different spaces` | 默认 route 跨空间冲突 | `no-route: true`（无需 HTTP route） |

### cf login 卡死 workaround（UAA 手动登录）

```sh
# 1. 直接向 UAA 请求 token（client_id=cf）
TOKEN=$(curl -s -X POST "https://uaa.de.a9s.eu/oauth/token" \
  -H "Accept: application/json" -u "cf:" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=<user>" \
  --data-urlencode "password=<pass>" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['access_token'])")

# 2. 写进 ~/.cf/config.json（备份原有再改）：
#    Target=https://api.de.a9s.eu
#    AccessToken=bearer <TOKEN>
#    SSLDisabled=true
#    UAA endpoints 同 login.de.a9s.eu / uaa.de.a9s.eu
# 3. cf target -o <org> -s production
```

---

## 10. 相关仓库 / 凭据备忘

- GitHub 仓库：`mmcen/hermes-anynines`（镜像构建源，main 分支）
- 主仓库：`mmcen/hermes-agent`（上游 Hermes，仅保留主镜像 latest/main）
- Docker Hub：`mmcen/hermes-anynines`（5 tags：latest/anynines/anynines-<sha>/base/base-<sha>）
- CF：`api.de.a9s.eu` / org `anyuan22_auaa_ccwu_cc` / space `production`
- 本地工作区：`workspaces/Unorouter/hermes-anynines/`（已同步 main）、
  `manifest-anynines.yml`、`anynines-improvements.patch`（历史补丁备份）

---

## 11. 当前已知遗留

- ⚠️ **`NOUS_API_KEY` 未配置**：gateway 能跑、Telegram 能收发，但 LLM 请求
  “No inference provider configured”，回复为配置提示。补上 `NOUS_API_KEY`
  后 `cf stop && cf push` 即可用 Nous Portal 模型（旧栈用过
  `model: nous:deepseek-v3.2`，base_url `https://inference-api.nousresearch.com/v1`）。