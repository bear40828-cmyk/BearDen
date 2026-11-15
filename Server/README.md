# 信箱服务器（Server）

一个很小的 Python 信箱后端（标准库 `http.server`，无第三方依赖）：App 发消息、存消息、取文件、收推送订阅；外部的 API 版 AI 用同一套通用接口轮询新消息、自己调模型生成回复、再把回复写回信箱。

本开源版不含本地 Claude 程序调用、唤醒日志、Extras 安装接口；群聊由内置 API 工人处理（见下），不再走本地独立通道。

## 怎么跑

```sh
python3 server.py
```

默认监听 `127.0.0.1:8810`。环境变量：

- `CHAT_PORT`：端口，默认 `8810`。
- `CHAT_DATA_DIR`：数据目录，默认 `./data`（不存在会自动建）。

只绑本机地址：想从外网访问请自己在前面架反向代理（并在代理层做鉴权，见下）。

## 首次部署要自己生成的文件

这些文件放在 `server.py` 同目录，不会提交到仓库。缺了也能启动：token 类现场生成随机值（重启后失效），VAPID 缺失则禁用推送并打一行 warning 日志；生产部署建议自己生成并持久化：

| 文件 | 用途 |
| --- | --- |
| `.chat-pass` | 预留的口令文件（见下） |
| `.upload-token` | `PUT /_upload/...` 的上传口令 `?t=...` |
| `.vapid-public` | Web Push 公钥（`GET /api/push/key` 返回它） |
| `.vapid-private.pem` | Web Push 私钥（VAPID） |

生成示例：

```sh
head -c 32 /dev/urandom | base64 > .chat-pass
head -c 32 /dev/urandom | base64 > .upload-token
# VAPID 密钥对可用任意 VAPID 工具生成，公钥放 .vapid-public，私钥放 .vapid-private.pem
```

注意：本版沿用原有行为，不做口令校验（`X-Pass` 头会被忽略）；群聊鉴权文件已随群聊功能删除，不再需要。如需鉴权，请在反向代理层自行加。

推送通知里的 `mailto:push@example.com` 只是占位，部署时改成自己的联系邮箱。

数据都在数据目录里：`messages.jsonl`（消息）、`files/`（上传的文件）、`reactions.json`（表情回应）、`events.jsonl`（事件流）、`profile.json`（备注和头像）、`push-subs.json`（推送订阅）。请自行备份，不要提交。

## API 版 AI 怎么接

只留了这一条路：服务器本身不调任何模型、不执行本地 AI 程序。AI 跑在另外一台（或同一台）机器上，用下面这套接口接线：

1. 轮询新消息：`GET /api/messages?since=<id>`，返回 `id` 更大的消息，`from` 是 `"me"`（用户）或 `"claude"`（助手；这是协议值，界面上显示为「助手」，不要改成 `assistant`，否则已部署的公开版客户端连旧服务器会对不上）。
2. 看哪些已交出：`GET /api/forwarded?since=<id>`，返回已交给助手的消息 id；取走一批后 `POST /api/forwarded {"ids": [...]}` 打标记（仅本机可调；打过标记的消息用户不能再撤回）。
3. 生成回复后写回：`POST /api/reply {"text": "...", "response_id": "...", "bubble_index": 0}`（仅本机可调）。`response_id` + `bubble_index` 相同的气泡只存一次，重发不会重复。
4. 输入中信号：`POST /api/typing {"who": "claude", "active": true}`（仅本机可调）；`GET /api/typing` 返回 `{"at": ..., "claude_at": ..., "now": ...}`。助手输入中信号字段是 `claude_at`（协议值，界面显示为「助手」）。
5. 流式输出：生成中 `POST /api/stream_event` 推事件（仅本机可调），App / 网页用 `GET /api/stream`（SSE）收。事件见下。

其中仅本机可调的接口（`/api/reply`、`/api/forwarded` 的 POST、`/api/stream_event`、`/api/typing` 的助手侧、`/api/groups/pending`、`/api/groups/deliver`）要求请求来自 `127.0.0.1`，或者带上 `X-Worker-Token` 头（与 `WORKER_TOKEN` 环境变量相符；`WORKER_TOKEN` 未设置时只认本机）。API 版 AI 需要和服务器跑在同一台机器上、同一 Docker 网络里（工人容器），或者走本机隧道。`WORKER_TOKEN` 是工人与聊天服务器之间的共享口令，生产部署要换成随机值。

## 内置 API 工人（worker.py）

`server.py` 本身不调任何模型。删掉本地 Claude 程序调用之后，由这个工人替它干活，
否则别人装好了发消息永远没人回。只用 Python 标准库，不调本地 AI 程序。

```sh
python3 worker.py
```

配置（读同目录 `.env`，环境变量优先，缺 `.env` 也不崩溃）：

| 变量 | 说明 |
| --- | --- |
| `AI_BASE_URL` | 模型接口地址（OpenAI 兼容，只填到 `/v1`，不要带 `/chat/completions`） |
| `AI_API_KEY` | 模型接口密钥 |
| `AI_MODEL` | 模型名：DeepSeek 用 `deepseek-chat`，Kimi 用 `kimi-k2.5`，GLM 用 `glm-4.6` |
| `AI_SYSTEM_PROMPT` | 可选，私聊默认提示，不填用内置通用提示 |
| `CHAT_SERVER_URL` | 聊天服务器地址，默认 `http://127.0.0.1:8810`（Docker 里由 compose 设成 `http://chat:8810`） |
| `WORKER_POLL_INTERVAL` | 轮询间隔秒数，默认 `2` |
| `WORKER_TOKEN` | 与聊天服务器之间的共享口令（本机直连可留空） |

两个循环，每轮先群聊后私聊：

- **私聊**：拉 `/api/messages` 找 `from=="me"` 且未 `forwarded` 的新消息，先 `POST /api/forwarded` 打标记再生成（避免重复处理），生成时先报 `typing`（`who: "claude"`），调 API 时带最近 20 条消息作上下文（`me`→user、`claude`→assistant），流式边收边推 `text_delta`（流式失败回落非流式），生成完按 `〰` 分气泡多次 `POST /api/reply`（同一个 `response_id`、递增的 `bubble_index`，只有第一个气泡推通知）。API 失败记日志、不崩溃，工人在内存里按批次重试，最多 3 次；3 次都失败则标记已处理并回一条通用短句“刚才没回上，你再发一次试试”，不把 API 报错原文发给用户。
- **群聊**：`GET /api/groups/pending` 取最旧一条未取走的请求（App 侧 `POST /api/groups/reply` 把请求放进队列，`member_id` 协议值必须是 `"claude"`，等工人投递，最多等约 60 秒，超时返回 502），用群聊专用提示生成（只输出要发进群里的一两句话，纯文本，不用 `〰` 分段），图片（最多 4 张）以 OpenAI vision 的 `image_url` 形式带上，API 拒收图片时重试一次纯文字版，结果经 `POST /api/groups/deliver` 交回（空回复则 `no_reply: true`）。

日志只打到 stdout：带时间与请求摘要，不打 API key、不打完整 prompt（摘要截断 100 字）。

## 流式分气泡

`GET /api/stream` 是 SSE 长连接，15 秒一个 `: ping`：

- `bubble_start`：`{"type", "response_id", "bubble_index"}`
- `text_delta`：`{"type", "response_id", "bubble_index", "delta", "text"}`，`text` 是当前气泡到目前为止的全文，直接整段替换即可
- `bubble_end`：`{"type", "response_id", "bubble_index", "text", "id"}`，这个气泡写完并已存成消息，`id` 是 `messages.jsonl` 里的 id
- `response_done`：`{"type", "response_id", "bubbles"}`

持久化：每个完成的气泡都是 `/api/messages` 里的一条普通消息，多两个字段 `response_id`、`bubble_index`（同一 `response_id` 同一 `index` 只存一次）。重进聊天、旧版 App 照常按 `/api/messages` 显示，就是多个气泡。App 收到 `bubble_end` 后，轮询拿到同 id 的消息时要替换掉流式占位，别显示两遍。

推送：一条回复只在第一个气泡时推一次。

断气泡由模型决定：模型单独写一行 `〰` 表示这里断开；代码块里不算。服务器不按字数切，App 也别再切。

## 其余接口

- `POST /api/send {"text": "...", "file": "..."}`：用户发消息（存为 `from: "me"`）。
- `POST /api/retract {"id": 12}`：撤回自己发的消息（已交给助手的不行）。
- `GET /api/reactions` / `POST /api/react {"id": 12, "emoji": "👍"}`：表情回应；本机请求算助手，其余算用户。
- `GET/POST /api/profile`：备注和头像。
- `POST /api/upload`（`X-Filename` 头）/ `GET /api/file/<name>`：上传与取文件，支持 Range。
- `GET /api/push/key` / `POST /api/push/subscribe`：Web Push 公钥与订阅。
- `PUT /_upload/<路径>?t=<上传口令>`：只能写 `public/`，用来更新网页前端。
- `GET /web`：宽屏网页版（`public/web.html`）；根路径是视觉体验版 demo（`public/index.html`，含假联系人列表，仅供看效果，真实消息只接助手那一条对话）。

## Docker 部署

见根目录 [docker-compose.yml](../docker-compose.yml) 与根 README 的 Docker 一节：
一条命令把朋友圈服务、聊天服务器、工人、反向代理都起来（`docker compose up -d`），
App 里服务器地址填 `http://<主机>:8080`。本地不用 Docker 也可以直接跑：

```sh
python3 server.py   # 终端一：聊天服务器，默认 127.0.0.1:8810
python3 worker.py   # 终端二：内置工人（先在同目录 .env 里填好 AI 三件套）
```
