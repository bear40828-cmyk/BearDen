# 聊天软件后端
# - 静态托管 public/
# - PUT /_upload/<路径>?t=<上传口令>        只能写 public/
# - POST /api/send      {"text": "..."}      用户发消息，头里带 X-Pass
# - GET  /api/messages?since=<id>&limit=<n>&before=<id>  拉取消息（她的和回复），头里带 X-Pass；limit 只取最后 n 条，before 只取该 id 之前的
# - POST /api/reply     {"text": "...", "file"?: "<data/files 里的文件名>"}   只接受本机，用来回复用户
# - POST /api/upload    原始文件体，头 X-Pass、X-Filename   存进 data/files/，返回 {"name"}
# - GET/POST /api/profile                   备注和头像：{"contacts": {id: {"name","avatar"}}, "me": {"avatar"}}
# - GET  /api/file/<name>?k=<口令>           取文件（图片要能直接放进 <img>，所以口令走查询参数）
# - GET  /api/push/key                     Web Push 公钥（VAPID）
# - POST /api/push/subscribe                存浏览器订阅，头里带 X-Pass；回复时向所有订阅发通知
# - GET  /api/reactions                     全部表情回应：{"<消息id>": {"me": ["👍"], "claude": ["❤️"]}}
# - POST /api/react     {"id": 12, "emoji": "👍"}   切换一个表情（有就去掉，没有就加上）；本机请求算 claude，其余算 me
# 引用回复、拍一拍由客户端编码在 text 里（[[bear-reply|…]]、[[bear-pat|…]]），后端原样存取
# 消息存在 data/messages.jsonl，每行 {"id","from","text","ts"}；from 是 "me" 或 "claude"
# 协议值说明：发件人协议值仍是 "claude"，界面上显示为「助手」；不要把协议值改成 assistant，
# 否则已部署的公开版客户端连旧服务器会对不上。
import http.server, json, time, threading, urllib.parse, pathlib, os

BASE = pathlib.Path(__file__).parent
ROOT = BASE / "public"
# CHAT_DATA_DIR / CHAT_PORT：同一份代码给另一个 AI 再起一份信箱，数据分开
DATA = pathlib.Path(os.environ.get("CHAT_DATA_DIR") or (BASE / "data")); DATA.mkdir(exist_ok=True)
FILES = DATA / "files"; FILES.mkdir(exist_ok=True)
LOG = DATA / "messages.jsonl"; LOG.touch()
PROFILE = DATA / "profile.json"
import secrets as _secrets
def _read_secret_file(name, env_name, generate=False):
    # 优先读同目录文件；没有就看同名环境变量；再没有：token 类现场生成随机值，
    # VAPID 类留空并禁用推送（不要因此启动失败，Docker 里文件本来就没有）。
    p = BASE / name
    try:
        v = p.read_text().strip()
        if v:
            return v
    except Exception:
        pass
    v = os.environ.get(env_name, "").strip()
    if v:
        return v
    if generate:
        v = _secrets.token_urlsafe(32)
        print(f"[server] warning: {name} 缺失，已现场生成随机值（重启后失效，生产部署请自行生成并持久化）", flush=True)
        return v
    return ""

UPLOAD_TOKEN = _read_secret_file(".upload-token", "UPLOAD_TOKEN", generate=True)
CHAT_PASS = _read_secret_file(".chat-pass", "CHAT_PASS", generate=True)
lock = threading.Lock()
SUBS = DATA / "push-subs.json"
VAPID_PUBLIC = _read_secret_file(".vapid-public", "VAPID_PUBLIC")
VAPID_PRIVATE = _read_secret_file(".vapid-private.pem", "VAPID_PRIVATE")
if not VAPID_PUBLIC or not VAPID_PRIVATE:
    print("[server] warning: VAPID 密钥缺失，Web Push 已禁用", flush=True)
    VAPID_PUBLIC = ""
    VAPID_PRIVATE = ""
REACTIONS = DATA / "reactions.json"
EVENTS = DATA / "events.jsonl"; EVENTS.touch()
# 流式气泡：API 助手把生成中的文字推到 /api/stream_event（仅本机），这里转发给所有 SSE 订阅者。
import queue as _queue
STREAM_SUBS = []
STREAM_LOCK = threading.Lock()
def stream_broadcast(ev):
    with STREAM_LOCK:
        for q in list(STREAM_SUBS):
            try: q.put_nowait(ev)
            except Exception: pass
import re as _re


def push_all(text):
    # 后台线程里发，失败不影响回复；410/404 说明订阅失效，删掉
    if not VAPID_PUBLIC or not VAPID_PRIVATE:
        return
    try:
        from pywebpush import webpush, WebPushException
    except ImportError:
        return
    with lock:
        subs = json.loads(SUBS.read_text()) if SUBS.exists() else []
    keep = []
    payload = json.dumps({"title": "助手", "body": text[:120]}, ensure_ascii=False)
    for sub in subs:
        try:
            webpush(sub, payload, vapid_private_key=VAPID_PRIVATE,
                    vapid_claims={"sub": "mailto:push@example.com"}, ttl=86400)
            keep.append(sub)
        except WebPushException as e:
            code = getattr(e.response, "status_code", None)
            if code not in (404, 410):
                keep.append(sub)
        except Exception:
            keep.append(sub)
    with lock:
        SUBS.write_text(json.dumps(keep))


def load():
    with lock:
        return [json.loads(l) for l in LOG.read_text().splitlines() if l.strip()]


def append(sender, text, file=None, extra=None):
    with lock:
        lines = [l for l in LOG.read_text().splitlines() if l.strip()]
        if extra and extra.get("response_id") is not None:
            # 同一回复的同一气泡只存一次（桥重连重发时不重复）
            for l in reversed(lines[-200:]):
                m = json.loads(l)
                if m.get("response_id") == extra["response_id"] and m.get("bubble_index") == extra.get("bubble_index"):
                    return m
        # 用最大 id + 1，不用行数：迁入的历史会让两者不一致。
        msg = {"id": max((json.loads(l).get("id", 0) for l in lines), default=0) + 1, "from": sender, "text": text, "ts": int(time.time())}
        if file:
            msg["file"] = file
        if extra:
            msg.update({k: v for k, v in extra.items() if v is not None})
        with LOG.open("a") as f:
            f.write(json.dumps(msg, ensure_ascii=False) + "\n")
    return msg


def retract(msg_id):
    # 只撤她自己发的消息；在原行上标 withdrawn，保留 id 让游标不乱
    with lock:
        lines = [l for l in LOG.read_text().splitlines() if l.strip()]
        hit = None
        for i in range(len(lines) - 1, max(-1, len(lines) - 2000), -1):
            m = json.loads(lines[i])
            if m.get("id") == msg_id:
                if m.get("from") != "me":
                    return None
                if m.get("forwarded"):
                    return "forwarded"
                m["withdrawn"] = True
                lines[i] = json.dumps(m, ensure_ascii=False)
                hit = m
                break
        if hit is None:
            return None
        tmp = LOG.with_suffix(".jsonl.tmp")
        tmp.write_text("\n".join(lines) + "\n")
        tmp.replace(LOG)
    return hit


def mark_forwarded(ids):
    # 桥把消息交给助手后打标记；之后这条不能再撤回
    ids = {int(i) for i in ids if str(i).lstrip("-").isdigit()}
    if not ids:
        return 0
    with lock:
        lines = [l for l in LOG.read_text().splitlines() if l.strip()]
        n = 0
        for i in range(len(lines) - 1, max(-1, len(lines) - 2000), -1):
            m = json.loads(lines[i])
            if m.get("id") in ids and not m.get("forwarded"):
                m["forwarded"] = True
                lines[i] = json.dumps(m, ensure_ascii=False)
                n += 1
        if n:
            tmp = LOG.with_suffix(".jsonl.tmp")
            tmp.write_text("\n".join(lines) + "\n")
            tmp.replace(LOG)
    return n


# 输入中信号：App 在输入框有字且在变时节流上报，桥用它判断要不要再等一等
# at = 用户（App 上报，只给 API 助手判断要不要再等）；claude_at = 助手正在组织回复（API 助手上报，App 标题栏用）
TYPING = {"at": 0.0, "claude_at": 0.0}


def load_reactions():
    return json.loads(REACTIONS.read_text()) if REACTIONS.exists() else {}


def toggle_reaction(msg_id, who, emoji):
    with lock:
        r = json.loads(REACTIONS.read_text()) if REACTIONS.exists() else {}
        cur = r.setdefault(str(msg_id), {}).setdefault(who, [])
        on = emoji not in cur
        if on:
            cur.append(emoji)
        else:
            cur.remove(emoji)
        if not cur:
            del r[str(msg_id)][who]
        if not r[str(msg_id)]:
            del r[str(msg_id)]
        REACTIONS.write_text(json.dumps(r, ensure_ascii=False))
        ev = {"type": "react", "from": who, "id": msg_id, "emoji": emoji, "on": on, "ts": int(time.time())}
        with EVENTS.open("a") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    return r



# 群聊排队（通用版，工人取件形态）：App 调 POST /api/groups/reply 把请求放进队列，
# 内置工人（worker.py）用 GET /api/groups/pending 取走、调 API 生成后用
# POST /api/groups/deliver 交回。这里不调任何本地 AI 程序、不读唤醒日志、不读绝对路径。
import uuid as _uuid
GROUP_LOCK = threading.Lock()
GROUP_WAIT = {}   # request_id -> {"group_id","prompt","images","ts","taken"}
GROUP_DONE = {}   # request_id -> text | NO_REPLY
NO_REPLY = object()


def group_enqueue(group_id, prompt, images, request_id):
    with GROUP_LOCK:
        GROUP_WAIT[request_id] = {"group_id": group_id, "prompt": prompt,
                                  "images": list(images), "ts": time.time(), "taken": False}


def group_take_pending():
    with GROUP_LOCK:
        todo = sorted(((v["ts"], k) for k, v in GROUP_WAIT.items() if not v["taken"]))
        if not todo:
            return None
        rid = todo[0][1]
        GROUP_WAIT[rid]["taken"] = True
        v = GROUP_WAIT[rid]
        return {"request_id": rid, "group_id": v["group_id"],
                "prompt": v["prompt"], "images": v.get("images", [])}


def group_deliver(request_id, text):
    with GROUP_LOCK:
        if request_id not in GROUP_WAIT:
            return False
        GROUP_DONE[request_id] = text
        return True


def group_wait_result(request_id, timeout=60.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        with GROUP_LOCK:
            if request_id in GROUP_DONE:
                return GROUP_DONE.pop(request_id)
        time.sleep(0.5)
    with GROUP_LOCK:
        GROUP_WAIT.pop(request_id, None)
    return None


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k):
        super().__init__(*a, directory=str(ROOT), **k)

    def log_message(s, *a):
        pass

    def _json(s, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        # 迁入 TG 历史后首屏有十来兆，大响应压一下
        gz = len(body) > 4096 and "gzip" in (s.headers.get("Accept-Encoding") or "")
        if gz:
            import gzip
            body = gzip.compress(body, 5)
        s.send_response(code)
        s.send_header("Content-Type", "application/json; charset=utf-8")
        if gz:
            s.send_header("Content-Encoding", "gzip")
        s.send_header("Content-Length", str(len(body)))
        s.end_headers()
        s.wfile.write(body)

    def _body(s, limit=200_000):
        n = int(s.headers.get("Content-Length", 0))
        if n > limit:
            return None
        try:
            return json.loads(s.rfile.read(n) or b"{}")
        except Exception:
            return None

    def _authed(s):
        # 她 2026-10-10 定：不要口令。/api/reply 仍只认本机
        return True

    def _local(s):
        # 隧道过来的请求带 Cf-Connecting-Ip，本机直连不带
        if s.client_address[0] == "127.0.0.1" and "Cf-Connecting-Ip" not in s.headers:
            return True
        # 容器间请求来自 Docker 网段：再认 X-Worker-Token（WORKER_TOKEN 未设置时不认 token）。
        tok = os.environ.get("WORKER_TOKEN", "")
        return bool(tok) and s.headers.get("X-Worker-Token") == tok

    def do_GET(s):
        u = urllib.parse.urlparse(s.path)
        if u.path == "/api/memory":
            # 记忆卡片：手机端整份上传，这里原样存一份供服务端读取
            if not s._authed():
                return s._json(401, {"error": "pass"})
            f = DATA / "memory_cards.json"
            try:
                cards = json.loads(f.read_text(encoding="utf-8")) if f.exists() else []
            except Exception:
                cards = []
            return s._json(200, {"cards": cards})
        if u.path in ("/web", "/web/"):
            # 电脑浏览器用的宽屏网页版，只是一个静态页，接口全部复用
            data = (ROOT / "web.html").read_bytes()
            s.send_response(200)
            s.send_header("Content-Type", "text/html; charset=utf-8")
            s.send_header("Content-Length", str(len(data)))
            s.send_header("Cache-Control", "no-cache")
            s.end_headers()
            s.wfile.write(data)
            return
        if u.path == "/api/stream":
            # SSE：event 为 bubble_start / text_delta / bubble_end / response_done，data 是 JSON
            q = _queue.Queue(maxsize=500)
            with STREAM_LOCK: STREAM_SUBS.append(q)
            try:
                s.send_response(200)
                s.send_header("Content-Type", "text/event-stream; charset=utf-8")
                s.send_header("Cache-Control", "no-cache")
                s.send_header("X-Accel-Buffering", "no")
                s.end_headers()
                s.wfile.write(b": ok\n\n"); s.wfile.flush()
                while True:
                    try:
                        ev = q.get(timeout=15)
                        s.wfile.write(("event: %s\ndata: %s\n\n" % (ev.get("type", "message"), json.dumps(ev, ensure_ascii=False))).encode())
                    except _queue.Empty:
                        s.wfile.write(b": ping\n\n")
                    s.wfile.flush()
            except Exception:
                pass
            finally:
                with STREAM_LOCK:
                    if q in STREAM_SUBS: STREAM_SUBS.remove(q)
            return
        if u.path == "/api/groups/pending":
            if not s._local():
                return s._json(403, {"error": "local only"})
            item = group_take_pending()
            return s._json(200, item or {})
        if u.path == "/api/push/key":
            return s._json(200, {"key": VAPID_PUBLIC})
        if u.path == "/api/messages":
            if not (s._authed() or s._local()):
                return s._json(401, {"error": "pass"})
            qs = urllib.parse.parse_qs(u.query)
            since = int(qs.get("since", ["0"])[0] or 0)
            items = [m for m in load() if m["id"] > since]
            # ?before=<id>：只取该 id 之前的消息（往上翻加载更早的一页）。
            before = qs.get("before", [None])[0]
            if before is not None:
                try:
                    items = [m for m in items if m["id"] < int(before)]
                except ValueError:
                    pass
            # ?limit=<n>：只取最后 n 条（首次只拉最近一页）。
            limit = qs.get("limit", [None])[0]
            if limit is not None:
                try:
                    n = int(limit)
                except ValueError:
                    n = 0
                if n > 0:
                    items = items[-n:]
            return s._json(200, items)
        if u.path == "/api/reactions":
            return s._json(200, load_reactions())
        if u.path == "/api/forwarded":
            # ?since=<id>：返回 id 大于 since、她发的、已交给助手的消息 id
            since = int(urllib.parse.parse_qs(u.query).get("since", ["0"])[0] or 0)
            return s._json(200, [m["id"] for m in load() if m["id"] > since and m.get("from") == "me" and m.get("forwarded")])
        if u.path == "/api/typing":
            return s._json(200, {"at": TYPING["at"], "claude_at": TYPING["claude_at"], "now": time.time()})
        if u.path == "/api/profile":
            if not s._authed():
                return s._json(401, {"error": "pass"})
            return s._json(200, json.loads(PROFILE.read_text()) if PROFILE.exists() else {"contacts": {}, "me": {}})
        if u.path.startswith("/api/file/"):
            k = urllib.parse.parse_qs(u.query).get("k", [""])[0]
            if False:  # 口令已取消
                return s.send_error(401)
            name = pathlib.Path(urllib.parse.unquote(u.path[len("/api/file/"):])).name
            f = FILES / name
            if not name or not f.is_file():
                return s.send_error(404)
            # 支持 Range：视频播放器按段拉取
            size = f.stat().st_size
            start, end = 0, size - 1
            rng = _re.match(r"bytes=(\d*)-(\d*)$", s.headers.get("Range", "").strip())
            partial = bool(rng) and size > 0
            if partial:
                a, b = rng.group(1), rng.group(2)
                if a:
                    start = int(a); end = min(int(b), size - 1) if b else size - 1
                elif b:
                    start = max(0, size - int(b))
                if start > end or start >= size:
                    s.send_response(416)
                    s.send_header("Content-Range", f"bytes */{size}")
                    s.end_headers()
                    return
            s.send_response(206 if partial else 200)
            s.send_header("Content-Type", s.guess_type(str(f)))
            s.send_header("Accept-Ranges", "bytes")
            if partial:
                s.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            s.send_header("Content-Length", str(end - start + 1))
            s.send_header("Cache-Control", "private, max-age=86400")
            s.end_headers()
            with open(f, "rb") as fh:
                fh.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = fh.read(min(1 << 20, left))
                    if not chunk:
                        break
                    s.wfile.write(chunk)
                    left -= len(chunk)
            return
        return super().do_GET()

    def do_POST(s):
        u = urllib.parse.urlparse(s.path)
        if u.path == "/api/stream_event":
            if not s._local():
                return s._json(403, {"error": "local only"})
            stream_broadcast(s._body() or {})
            return s._json(200, {"ok": True})
        if u.path == "/api/groups/deliver":
            if not s._local():
                return s._json(403, {"error": "local only"})
            b = s._body() or {}
            rid = str(b.get("request_id") or "")
            if not rid:
                return s._json(400, {"error": "request_id"})
            text = NO_REPLY if b.get("no_reply") else str(b.get("text") or "").strip()
            return s._json(200, {"ok": True, "accepted": group_deliver(rid, text)})
        if u.path == "/api/groups/reply":
            # App 侧调用，不做 Bearer 校验；只校验协议字段，放进队列等工人投递，最多等约 60 秒。
            b = s._body(limit=30_000_000)   # 群里的图和表情包会跟着来
            if not b or b.get("member_id") != "claude" or not b.get("group_id") or not str(b.get("prompt") or "").strip():
                return s._json(400, {"error": "body"})
            rid = str(b.get("request_id") or _uuid.uuid4())
            group_enqueue(str(b["group_id"])[:100], str(b["prompt"])[:20000],
                          [str(x) for x in (b.get("images") or [])[:4] if isinstance(x, str)], rid)
            result = group_wait_result(rid)
            if result is NO_REPLY:
                return s._json(200, {"group_id": b["group_id"], "member_id": "claude",
                                     "request_id": b.get("request_id"), "text": "", "no_reply": True})
            if result is None or not result:
                return s._json(502, {"error": "empty"})
            return s._json(200, {"group_id": b["group_id"], "member_id": "claude",
                                 "request_id": b.get("request_id"), "text": result})
        if u.path == "/api/memory":
            if not s._authed():
                return s._json(401, {"error": "pass"})
            b = s._body(limit=8_000_000)
            cards = b.get("cards") if isinstance(b, dict) else b
            if not isinstance(cards, list):
                return s._json(400, {"error": "cards"})
            f = DATA / "memory_cards.json"
            tmp = f.with_suffix(".tmp")
            tmp.write_text(json.dumps(cards, ensure_ascii=False, indent=1), encoding="utf-8")
            tmp.replace(f)
            return s._json(200, {"ok": True, "count": len(cards)})
        if u.path == "/api/send":
            if not s._authed():
                return s._json(401, {"error": "pass"})
            b = s._body()
            if not b:
                return s._json(400, {"error": "body"})
            text, file = str(b.get("text", "")).strip(), b.get("file")
            if file:
                file = pathlib.Path(str(file)).name
                if not (FILES / file).is_file():
                    return s._json(400, {"error": "file"})
            if not text and not file:
                return s._json(400, {"error": "text"})
            return s._json(200, append("me", text[:20000], file))
        if u.path == "/api/profile":
            if not s._authed():
                return s._json(401, {"error": "pass"})
            b = s._body()
            if not isinstance(b, dict):
                return s._json(400, {"error": "body"})
            with lock:
                PROFILE.write_text(json.dumps(b, ensure_ascii=False))
            return s._json(200, {"ok": True})
        if u.path == "/api/upload":
            if not s._authed():
                return s._json(401, {"error": "pass"})
            n = int(s.headers.get("Content-Length", 0))
            raw = urllib.parse.unquote(s.headers.get("X-Filename", "file"))
            safe = "".join(c for c in pathlib.Path(raw).name if c.isalnum() or c in "._-") or "file"
            # 视频放宽到 200 MB，其他仍是 25 MB；分块落盘，不整块读进内存
            limit = 200_000_000 if safe.lower().endswith((".mov", ".mp4", ".m4v")) else 25_000_000
            if not n or n > limit:
                return s._json(413, {"error": "size"})
            name = f"{int(time.time() * 1000)}-{safe[-60:]}"
            left = n
            with open(FILES / name, "wb") as out:
                while left > 0:
                    chunk = s.rfile.read(min(1 << 20, left))
                    if not chunk:
                        break
                    out.write(chunk)
                    left -= len(chunk)
            if left > 0:
                (FILES / name).unlink(missing_ok=True)
                return s._json(400, {"error": "incomplete"})
            return s._json(200, {"name": name})
        if u.path == "/api/push/subscribe":
            if not s._authed():
                return s._json(401, {"error": "pass"})
            b = s._body()
            if not isinstance(b, dict) or not str(b.get("endpoint", "")).startswith("https://"):
                return s._json(400, {"error": "body"})
            with lock:
                subs = json.loads(SUBS.read_text()) if SUBS.exists() else []
                subs = [x for x in subs if x.get("endpoint") != b["endpoint"]] + [b]
                SUBS.write_text(json.dumps(subs[-10:]))
            return s._json(200, {"ok": True})
        if u.path == "/api/typing":
            b = s._body() or {}
            if s._local() and isinstance(b, dict) and b.get("who") == "claude":
                TYPING["claude_at"] = time.time() if b.get("active") else 0.0
                return s._json(200, {"ok": True})
            TYPING["at"] = time.time()
            return s._json(200, {"ok": True})
        if u.path == "/api/forwarded":
            if not s._local():
                return s._json(403, {"error": "local only"})
            return s._json(200, {"ok": True, "marked": mark_forwarded((s._body() or {}).get("ids") or [])})
        if u.path == "/api/retract":
            b = s._body()
            try:
                msg_id = int((b or {}).get("id"))
            except (TypeError, ValueError):
                return s._json(400, {"error": "id"})
            m = retract(msg_id)
            if m == "forwarded":
                return s._json(409, {"error": "forwarded"})
            if m is None:
                return s._json(404, {"error": "not found"})
            return s._json(200, {"ok": True, "id": msg_id})
        if u.path == "/api/react":
            b = s._body()
            if not isinstance(b, dict):
                return s._json(400, {"error": "body"})
            try:
                msg_id = int(b.get("id"))
            except (TypeError, ValueError):
                return s._json(400, {"error": "id"})
            emoji = str(b.get("emoji", "")).strip()
            if not emoji or len(emoji) > 16:
                return s._json(400, {"error": "emoji"})
            who = "claude" if s._local() else "me"
            return s._json(200, toggle_reaction(msg_id, who, emoji))
        if u.path == "/api/reply":
            if not s._local():
                return s._json(403, {"error": "local only"})
            b = s._body()
            file = b.get("file") if b else None
            if file:
                file = pathlib.Path(str(file)).name
                if not (FILES / file).is_file():
                    return s._json(400, {"error": "file"})
            if not b or not (str(b.get("text", "")).strip() or file):
                return s._json(400, {"error": "text"})
            extra = {"response_id": b.get("response_id"), "bubble_index": b.get("bubble_index")} if b.get("response_id") else None
            msg = append("claude", str(b.get("text", "")), file, extra)
            # 一条回复拆成多个气泡时只推送第一个，免得手机连响
            if b.get("push", True):
                threading.Thread(target=push_all, args=(msg["text"],), daemon=True).start()
            return s._json(200, msg)
        return s.send_error(404)

    def do_PUT(s):
        u = urllib.parse.urlparse(s.path)
        q = urllib.parse.parse_qs(u.query)
        if not u.path.startswith("/_upload/") or q.get("t", [""])[0] != UPLOAD_TOKEN:
            return s.send_error(403)
        rel = urllib.parse.unquote(u.path[len("/_upload/"):])
        dst = (ROOT / rel).resolve()
        if not rel or ROOT.resolve() not in dst.parents:
            return s.send_error(400, "bad path")
        n = int(s.headers.get("Content-Length", 0))
        if n > 20_000_000:
            return s.send_error(413)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(s.rfile.read(n))
        s.send_response(200)
        s.end_headers()
        s.wfile.write(b"ok " + rel.encode())


HOST = os.environ.get("CHAT_HOST", "127.0.0.1")
http.server.ThreadingHTTPServer((HOST, int(os.environ.get("CHAT_PORT", "8810"))), H).serve_forever()
