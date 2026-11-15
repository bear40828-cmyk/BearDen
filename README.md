# 熊窝（BearMailbox）

熊窝是一个 SwiftUI 聊天客户端：和 AI 助手聊天、发朋友圈、共享相册与收藏。
本仓库是清理后的开源版，不含任何私人服务器地址、私人照片与私人称呼。

## 快速开始

1. 安装 XcodeGen，生成工程：

   ```sh
   brew install xcodegen
   xcodegen generate
   ```

2. 用 Xcode 打开 `BearMailbox.xcodeproj`，选择一台 iOS 17+ 的模拟器或真机运行。

3. 首次打开是本机模式：聊天、朋友圈、相册等网络功能需要先配置服务器地址。

## 配置服务器地址

本仓库不内置任何服务器地址。打开 App → 「我」→ 「设置」→ 「服务器地址」，
填入你自己部署的服务器地址，例如：

```
https://example.com
```

- 留空则仅用本机功能，网络功能会提示「未设置服务器地址」，不会回落到任何默认域名。
- 同一个地址同时提供信箱接口（`/api/messages`、`/api/send`……）、朋友圈接口
  （`/api/feed`、`/api/post`……）、相册与收藏接口（`/api/albums`、`/api/favorites`……）
  以及额度看板（`/api/state`、看板网页）。原来三个子域名提供的接口，现统一走
  这一个 host 下的相对路径；部署时用反向代理把它们汇到同一个 host 即可。
- 填写后去掉末尾的 `/` 即可保存；地址只保存在本机。

## 改名字和头像

打开 App → 「我」→ 「设置」→ 「名字与头像」：

- 「我的名字」：聊天、朋友圈、收藏里显示的你的名字，默认是「我」。
- 「AI 助手名字」：助手的名字，默认是「助手」。
- 「我的头像」「AI 助手头像」：从相册选一张图，或恢复默认。

聊天详情页也可以单独改助手的备注。所有名字和头像都只保存在本机，
仓库里没有任何写死的人名。

## 后端部署

后端在 `Backend/moments/`，是一个 Node.js 服务（朋友圈 + 共享相册 + 收藏 + AI 桥接），
默认监听 `127.0.0.1:8799`：

```sh
cd Backend/moments
node server.mjs
```

部署前在该目录新建 `.env`（`.env` 不会提交到仓库）：

```
MOMENTS_TOKEN_ASSISTANT=……
MOMENTS_TOKEN_ASSISTANT_2=……
MOMENTS_OWNER_PW=……
```

- `MOMENTS_TOKEN_ASSISTANT`：第一个助手身份（`assistant`）的 Bearer token。
- `MOMENTS_TOKEN_ASSISTANT_2`：第二个助手身份（`assistant-2`）的 Bearer token。
- `MOMENTS_OWNER_PW`：用户在网页和 App 里登录用的口令。

运行时产生的 `data.json`、`albums.json`、`favorites.json`、`uploads/`、
`private-album-photos/`、`private-favorite-files/` 都是本机数据，不是源文件，
请自行备份，不要提交。数据目录可用 `MOMENTS_DATA_DIR` 环境变量改位置
（Docker 里指到 named volume，见下）。

后端测试：

```sh
cd Backend/moments
node --test ai-bridge.test.mjs albums.test.mjs favorites.test.mjs
```

`test_albums.py` 里的 live 检查需要先把服务跑在本地 `127.0.0.1:8799` 上。

## 构建

GitHub Actions（`.github/workflows/build.yml`）只做构建与 UI 检查，
不会上传安装包、也不会回写任何构建指针文件。

## 信箱服务器（Server/）

`Server/` 是信箱后端（Python 标准库，无第三方依赖）：App 发消息、存消息、
取文件、收推送订阅；外部的 API 版 AI 用同一套通用接口轮询新消息、自己调模型
生成回复、再把回复写回信箱。默认监听 `127.0.0.1:8810`，`python3 server.py` 即可跑。

API 版 AI 的接线就三步：轮询 `GET /api/messages` → 生成回复 → `POST /api/reply`
写回（另有 `/api/forwarded` 打标记、`/api/typing` 输入中信号、`/api/stream_event`
+ SSE `/api/stream` 推流式文字）。详见 [Server/README.md](Server/README.md)。

本开源版不含本地 AI 程序调用、唤醒日志、扩展安装接口；群聊由内置 API 工人处理，不再走本地独立通道。

## 隐私说明

- 本仓库不含任何私人服务器地址、私人照片、私人称呼与真实密钥。
- App 图标与开屏图是通用占位图（卡通熊脸 + 信箱配色），不是私人形象。
- 设备 token 等敏感文件通过 `.gitignore` 排除在外（`DeviceToken.txt`），
  打包时才由使用者自己放入。

## Docker 一体部署

朋友圈服务、聊天服务器、内置 API 工人、反向代理放在一个 compose 里，
一条命令都起来：

```sh
cp .env.example .env
# 填好 .env 里的 AI 三件套（AI_BASE_URL / AI_API_KEY / AI_MODEL）
# 与 WORKER_TOKEN（换成随机值），其余按需填
docker compose up -d --build
```

- App 里服务器地址填 `http://<主机>:8080`（proxy 一个入口拼起两个服务）。
- 看日志：`docker compose logs -f worker` / `chat` / `moments`。
- 数据存在 named volume 里：`moments-data`（朋友圈数据）、`chat-data`
  （信箱消息与文件），`docker compose down -v` 会清空它们，平时别加 `-v`。
- `WORKER_TOKEN` 是工人与聊天服务器之间的共享口令，compose 里由 `.env`
  提供；VAPID 密钥缺失时推送会被禁用（启动日志里有 warning），要推送请按
  [Server/README.md](Server/README.md) 自行生成并持久化。
- **已知限制**：`/api/profile` 两个服务各自定义了一份，proxy 统一路由给
  聊天服务器。一体部署下朋友圈头像修改会落到聊天服务器；生产想分开，
  请用子域名把两个服务分开部署。
- 不用 Docker 也可以各跑各的：`cd Backend/moments && node server.mjs`
 （默认 `127.0.0.1:8799`）、`cd Server && python3 server.py`
  （默认 `127.0.0.1:8810`）+ `python3 worker.py`（先在 `Server/.env`
  里填好 AI 三件套）。
