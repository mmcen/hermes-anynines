# mmcen/hermes-anynines 部署文档（anynines PaaS）

> 最后更新：2026-09-15
> 状态：✅ 已部署并验证（s6 监督 + 崩溃自愈 + Telegram 连通）
> 适用账号：`anyuan33@auaa.ccwu.cc`（历史：anyuan22 → anyuan33）

---

## 1. 概览

| 项 | 值 |
|---|---|
| 应用名 | `hermes-agent-docker` |
| 平台 | anynines (a9s PaaS, CloudFoundry 兼容) |
| CF API | `https://api.de.a9s.eu` |
| 组织 | `anyuan33_auaa_ccwu_cc` |
| 空间 | `production` |
| 镜像 | `mmcen/hermes-anynines:latest`（~984MB） |
| 部署方式 | CloudFoundry Docker 生命周期（diego_docker） |
| 实例规格 | 1024M 内存 / 4G 磁盘 / 1 实例 |
| 持久层 | **无**（重启/重推即清空，日志在启动时按大小截断） |
| 健康检查 | `process`（主进程 = s6-svscan） |
| Route | 无（`no-route: true`；对外走 Cloudflare Tunnel 出站） |

### 镜像 tag 语义（重要）

| tag | 含义 | 用途 |
|---|---|---|
| `:latest` | 当前可直接部署的 **wrapper**（s6 监督 + `s6` 菜单） | ✅ 部署用这个 |
| `:anynines` | 同上（内容一致，命名更显式） | 显式固定 |
| `:anynines-<sha>` | wrapper 的 commit 溯源 | 回滚/审计 |
| `:main` | base 镜像（主 Dockerfile，无 wrapper） | ❌ 不要部署 |
| `:base` / `:base-<sha>` | 底层镜像 | 构建中间产物 |

> ⚠️ 历史事故（已修复）：主 workflow `docker.yml` 曾在每次 main push 时也把 base 打成
> `:latest`，覆盖 wrapper 导致 CF 拉到无执行位镜像而 crash（`Permission denied`, exit 126）。
> 现已限定 `:latest` 只属于 wrapper；`:main` 归 base。

---

## 2. 架构：CF 下用 s6 监督全部服务

### 为什么需要 wrapper

CF 的 diego/garden 把容器 PID 1 固定为 `/tmp/garden-init`，镜像入口永远拿不到 PID 1 →
s6-overlay 的 `/init` 无法运行。因此 `mmcen/hermes-anynines` 提供 CF 专用入口
`docker/entrypoint-anynines.sh`：

```
PID 1（普通 Docker） → exec /init …            （官方 s6-overlay 路径，不变）
CF（非 PID 1）       → stage2 bootstrap → 组装 scan 目录 → s6-svscan 作为主进程
```

### 进程树（实测）

```
PID 1   /tmp/garden-init                      ← 平台占有，不可替换
 └─ sh -c entrypoint-anynines.sh gateway run
     └─ s6-svscan /run/s6-anynines/service    ← 容器主进程
         ├─ s6-supervise gateway   → hermes gateway run        (hermes)
         ├─ s6-supervise cloudflared → cloudflared tunnel …     (hermes)
         ├─ s6-supervise dashboard → hermes dashboard …         (hermes)
         └─ s6-supervise sshd      → /usr/sbin/sshd -D -p 22    (root)
```

要点：
- **全部服务都被监督**：崩溃后 s6 自动拉起（实测 kill -9 dashboard/cloudflared → 2-3 秒内新 PID 恢复）
- **gateway 也是被监督的服务**（不再独占主进程），崩溃就地重启，s6 自带 1 次/秒节流
- **SIGTERM 优雅关停**：`cf stop` 时先逐个 `s6-svc -d` 停服务再退出，不留孤儿
- svscan 自身若退出 → 容器退出，平台可感知异常
- 服务开关由 env 决定：`TUNNEL_TOKEN`（cloudflared）、`HERMES_DASHBOARD`、`SSH_ENABLED`

### 内置的两个关键修复

1. **`S6_KEEP_ENV=1`**：CF 下 `/run/s6/container_environment` 近乎为空，
   `with-contenv` 会把进程环境清空重灌 → 侧服务读到空变量而自我禁用。
   wrapper 内置该变量，让 with-contenv 保留 CF 注入的环境。
2. **cloudflared 降权修复**：原 `s6-rc.d/cloudflared/run` 的 `set -- s6-setuidgid`
   未实际生效（exec 行没用 `$@`），tunnel 曾以 root 运行；现已改为与 dashboard
   相同的显式降权，实测以 `hermes` 运行。

---

## 3. `s6` 管理菜单（容器内命令）

注册在 `/usr/local/bin/s6`，`cf ssh` 进去直接可用：

```
s6                      中文交互菜单
s6 status               状态总览（含 provider key 检查）
s6 start   <svc|all>    启动服务        svc: gateway|cloudflared|dashboard|sshd
s6 stop    <svc|all>    停止服务（保持 down，直到 start）
s6 restart <svc|all>    重启服务
s6 logs    <svc> [-n N] [-f]
                        查看日志；也支持 errors（hermes 错误日志）
s6 conf                 查看生效配置（密钥脱敏）
s6 set     KEY=VALUE    添加/修改配置 → 写入 $HERMES_HOME/.env
s6 unset   KEY          删除配置
s6 apply                应用配置（重启 gateway 使其生效）
s6 doctor               体检：PID 1 / svscan / 服务 / 权限 / provider key / 磁盘 / 崩溃记录
s6 help                 帮助
```

行为说明：
- `s6 stop` 会标记 wanted-down（不会被自动拉起），`s6 start` 恢复
- 崩溃记录写入 `$HERMES_HOME/logs/gateway-crash.log`
- **镜像更新不在容器内做**：推新镜像 tag 后用 `cf push` 重新部署

---

## 4. 环境变量清单

| 变量 | 值（示例） | 用途 |
|---|---|---|
| `PATH` | `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/command:/opt/hermes/.venv/bin` | 让 `s6`/`hermes` 在 `cf ssh` 里可直接调用 |
| `HERMES_DASHBOARD` | `1` | 启用 dashboard |
| `HERMES_DASHBOARD_HOST` | `0.0.0.0` | dashboard 监听地址 |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `admin` | dashboard 登录名 |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | `<password>` | dashboard 密码 |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `<secret>` | 基本认证签名密钥 |
| `SSH_ENABLED` | `true` | 启用 sshd |
| `SSH_PORT` | `22` | 容器内 sshd 端口（2222 属平台 diego-sshd） |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA...` | 授权公钥（root + hermes 双写） |
| `TUNNEL_TOKEN` | `eyJh...` | Cloudflare Tunnel token（出站） |
| `TELEGRAM_BOT_TOKEN` | `<bot token>` | Telegram bot |
| `TELEGRAM_ALLOWED_USERS` | `8019081926` | Telegram 白名单 |
| `NOUS_API_KEY` | （需自备） | 推理 provider（缺失则 gateway 无法回消息） |

### ⚠️ HERMES_HOME 不要设成 `/root/.hermes`

- 镜像默认 `HERMES_HOME=/opt/data`，**保持默认即可**。
- `/root` 是 `0700 root`，而 gateway / dashboard 以 `hermes`(uid 10000) 运行，
  **写不进去**（实测 `Permission denied`）。
- 若确实想用 root 跑（不推荐）：需 `HERMES_ALLOW_ROOT_GATEWAY=1` **且** 让 gateway
  与 dashboard 都绕过降权（`main-wrapper.sh` 会自动降权到 hermes），并接受
  root 属主文件与官方镜像设计冲突的风险。本平台无持久层，收益几乎为零。

---

## 5. 部署 manifest（`manifest-anyuan33.yml`）

```yaml
applications:
- name: hermes-agent-docker
  docker:
    image: mmcen/hermes-anynines:latest
  memory: 1024M
  disk_quota: 4G
  no-route: true
  health-check-type: process
  command: /opt/hermes/docker/entrypoint-anynines.sh gateway run
  env:
    PATH: /usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/command:/opt/hermes/.venv/bin
    HERMES_DASHBOARD: "1"
    HERMES_DASHBOARD_HOST: "0.0.0.0"
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME: "admin"
    HERMES_DASHBOARD_BASIC_AUTH_PASSWORD: "<你的密码>"
    HERMES_DASHBOARD_BASIC_AUTH_SECRET: "<你的secret>"
    SSH_ENABLED: "true"
    SSH_PORT: "22"
    SSH_PUBLIC_KEY: "ssh-ed25519 AAAA..."
    TUNNEL_TOKEN: "eyJh..."
    TELEGRAM_BOT_TOKEN: "..."
    TELEGRAM_ALLOWED_USERS: "8019081926"
```

command 一行即可——侧服务与监督逻辑全在镜像内，**不要**再手写 nohup/s6-setuidgid 脚本。

---

## 6. 部署步骤

```sh
# 1. 登录（cf login 在本平台可能超时；UAA 手动方式见第 9 节）
cf api https://api.de.a9s.eu --skip-ssl-validation
cf target -o anyuan33_auaa_ccwu_cc -s production

# 2. 若已有实例：org 配额 1G，先停以释放 staging 额度
cf stop hermes-agent-docker

# 3. 部署
cf push -f manifest-anyuan33.yml

# 4. 验收
cf app hermes-agent-docker
cf ssh hermes-agent-docker -c "s6 status"
```

---

## 7. 验证 & 运维

```sh
# 服务状态
cf ssh hermes-agent-docker -c "s6 status"
# 体检
cf ssh hermes-agent-docker -c "s6 doctor"
# 常见日志
cf ssh hermes-agent-docker -c "s6 logs gateway 40"
cf ssh hermes-agent-docker -c "s6 logs cloudflared 20"
# CF 聚合日志（gateway 的 stdout 仍会流到 cf logs）
cf logs hermes-agent-docker --recent
# 重启单个服务 / 全部
cf ssh hermes-agent-docker -c "s6 restart gateway"
cf ssh hermes-agent-docker -c "s6 restart all"
```

预期关键日志：
- gateway：`✓ telegram connected` / `✓ api_server connected`
- cloudflared：`precheck complete … status=pass`
- dashboard：`HERMES_DASHBOARD_READY port=9119`
- sshd：`Server listening on 0.0.0.0 port 22.`

---

## 8. 镜像更新流程

```sh
# 1. 改 mmcen/hermes-anynines 仓库代码 → push main
#    触发 CI：build-base → build-anynines
#    产物：:latest / :anynines / :anynines-<sha> / :base / :base-<sha>
git add -A && git commit -m "..." && git push origin main

# 2. 等 CI 成功（Actions 页，约 5-8 分钟）

# 3. 重推 CF（配额 1G：先 stop）
cf stop hermes-agent-docker && cf push -f manifest-anyuan33.yml
```

CI 触发路径：`docker/entrypoint-anynines.sh`、`docker/s6-anynines/**`、
`docker/s6-rc.d/cloudflared/run`、`Dockerfile.anynines`、workflow 自身。
workflow 为自包含两阶段：base 按 **digest** 传给 wrapper（`--build-arg BASE_IMAGE=…@sha256:…`），永不漂移。

---

## 9. 常见问题

| 症状 | 原因 | 处理 |
|---|---|---|
| `organization's memory limit exceeded` | org 配额 1G，实例+staging 叠加 | 先 `cf stop` 再 push |
| `Permission denied` (exit 126) | `:latest` 被 base 覆盖（历史事故） | 确认 `:latest` 是 wrapper；必要时手动 dispatch anynines workflow 重建 |
| 服务没有自动重启 | 用的是旧镜像（无 s6 监督） | 用含 s6 监督的镜像（`e1e56ec4` 之后） |
| 只有 gateway 在跑 | `S6_KEEP_ENV` 未生效（旧镜像） | 升级镜像；不要自己拼 command |
| cloudflared 以 root 运行 | 旧 `cloudflared/run` 降权 bug | 升级镜像 |
| `No inference provider configured` | 缺 LLM key | `s6 set NOUS_API_KEY=...` 然后 `s6 apply` |
| `cf login` 卡死 | CLI 交互异常（UAA 正常） | 用 UAA password grant 手动写 `~/.cf/config.json` |
| `Routes cannot be mapped…` | 默认 route 跨空间冲突 | `no-route: true` |

### cf login 卡死 workaround

```sh
TOKEN=$(curl -s -X POST "https://uaa.de.a9s.eu/oauth/token" \
  -H "Accept: application/json" -u "cf:" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=<user>" --data-urlencode "password=<pass>" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
# 写入 ~/.cf/config.json：Target / AccessToken(bearer …) / SSLDisabled=true / Login & UAA 端点
cf target -o <org> -s production
```

---

## 10. 相关资源

- GitHub：`mmcen/hermes-anynines`（镜像构建源，main）
- Docker Hub：`mmcen/hermes-anynines`
- CF：`api.de.a9s.eu` / org `anyuan33_auaa_ccwu_cc` / space `production`
- 关键文件：`docker/entrypoint-anynines.sh`、`docker/s6-anynines/service/*`、
  `docker/s6-anynines/bin/s6`、`Dockerfile.anynines`

## 11. 已知遗留

- ⚠️ **未配置推理 provider**：gateway 能收发 Telegram 消息，但回不了模型内容
  （`s6 doctor` 会提示 "provider keys: NONE"）。添加方式：
  `s6 set NOUS_API_KEY=xxx` → `s6 apply`；或走 CF env：
  `cf set-env hermes-agent-docker NOUS_API_KEY xxx && cf restage`。
- 无持久层：会话/技能/配置在重启或 re-push 后重置。
