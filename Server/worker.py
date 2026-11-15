# 内置 API 工人（worker.py）
#
# 聊天服务器本身不调任何模型。删掉本地 Claude 程序调用之后，由这个工人替它干活：
# 轮询信箱里用户发来的新消息，调 OpenAI 兼容的 /chat/completions 接口生成回复，
# 再写回 /api/reply；群聊请求也走它（/api/groups/pending 取件、/api/groups/deliver 交回）。
#
# 只用 Python 标准库。不调本地 AI 程序、不读唤醒日志、不读任何绝对路径。
#
# 配置（读同目录 .env，环境变量优先，缺 .env 也不崩溃）：
#   AI_BASE_URL       模型接口地址，如 https://api.deepseek.com/v1（不要带 /chat/completions）
#   AI_API_KEY        模型接口密钥
#   AI_MODEL          模型名，如 deepseek-chat / kimi-k2.5 / glm-4.6
#   AI_SYSTEM_PROMPT  可选，私聊默认提示（默认一句通用中文助手提示）
#   CHAT_SERVER_URL   聊天服务器地址，默认 http://127.0.0.1:8810
#   WORKER_POLL_INTERVAL  轮询间隔秒数，默认 2
#   WORKER_TOKEN      与聊天服务器之间的共享口令（本机直连可留空；Docker 里由 compose 注入）
#
# 日志只打到 stdout：带时间与请求摘要，不打 API key，不打完整 prompt，
# prompt 摘要截断 100 字。
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = pathlib.Path(__file__).parent
DEFAULT_SYSTEM = "你是一个贴心的中文 AI 助手，用简体中文回复，简短自然。"
GROUP_SYSTEM = ("这是熊窝 App 的群聊，不是私聊。只输出要发进群里的那一句或几句话，"
                "纯文本，简短自然，不用「〰」分段。")
FALLBACK_TEXT = "刚才没回上，你再发一次试试"
MAX_ATTEMPTS = 3


def load_dotenv():
    env_file = HERE / ".env"
    try:
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k and k not in os.environ:
                os.environ[k] = v
    except FileNotFoundError:
        pass
    except Exception as e:
        log(f"读 .env 失败（只用环境变量）：{e}")


def log(msg):
    print(f"[{time.strftime('%F %T')}] {msg}", flush=True)


def trunc(s, n=100):
    s = str(s or "")
    return s if len(s) <= n else s[:n] + "…"


class Config:
    def __init__(self):
        load_dotenv()
        self.base_url = os.environ.get("AI_BASE_URL", "").rstrip("/")
        self.api_key = os.environ.get("AI_API_KEY", "")
        self.model = os.environ.get("AI_MODEL", "")
        self.system = os.environ.get("AI_SYSTEM_PROMPT", "") or DEFAULT_SYSTEM
        self.chat_url = os.environ.get("CHAT_SERVER_URL", "http://127.0.0.1:8810").rstrip("/")
        self.poll = float(os.environ.get("WORKER_POLL_INTERVAL", "2") or 2)
        self.token = os.environ.get("WORKER_TOKEN", "")

    def check(self):
        missing = [k for k, v in (("AI_BASE_URL", self.base_url),
                                  ("AI_API_KEY", self.api_key),
                                  ("AI_MODEL", self.model)) if not v]
        if missing:
            log(f"缺少配置：{', '.join(missing)}，请在 .env 或环境变量里填好再启动")
            return False
        return True


def http_json(cfg, method, url, body=None, headers=None, timeout=30):
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if cfg.token:
        req.add_header("X-Worker-Token", cfg.token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() if hasattr(e, "read") else b""
        raise RuntimeError(f"HTTP {e.code} {trunc(raw.decode('utf-8', 'ignore'), 200)}")
    except Exception as e:
        raise RuntimeError(str(e))


def chat_get(cfg, path, timeout=10):
    return http_json(cfg, "GET", cfg.chat_url + path, timeout=timeout)


def chat_post(cfg, path, body, timeout=30):
    return http_json(cfg, "POST", cfg.chat_url + path, body=body, timeout=timeout)


def chat_completions_url(cfg):
    if cfg.base_url.endswith("/chat/completions"):
        return cfg.base_url
    return cfg.base_url + "/chat/completions"


def call_api(cfg, messages, stream, on_delta=None):
    """调 OpenAI 兼容接口。stream 时边收边回调 on_delta(全文)，返回全文。
    流式失败抛错，由调用方决定是否回落非流式。"""
    url = chat_completions_url(cfg)
    payload = {"model": cfg.model, "messages": messages, "stream": stream}
    data = json.dumps(payload, ensure_ascii=False).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + cfg.api_key)
    if not stream:
        with urllib.request.urlopen(req, timeout=120) as r:
            obj = json.loads(r.read() or b"{}")
        return (obj.get("choices") or [{}])[0].get("message", {}).get("content") or ""
    text = ""
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            chunk = line[5:].strip()
            if chunk == "[DONE]":
                break
            try:
                obj = json.loads(chunk)
            except Exception:
                continue
            delta = ((obj.get("choices") or [{}])[0].get("delta") or {}).get("content") or ""
            if delta:
                text += delta
                if on_delta:
                    on_delta(text)
    return text


def split_bubbles(text):
    import re
    parts = [p.strip() for p in re.split(r"(?m)^[ \t]*〰[ \t]*$", text or "")]
    return [p for p in parts if p]


def deliver_bubbles(cfg, text, stream_events=True):
    """把生成文本按 〰 分气泡写回。流式时先推事件，写回后再补 bubble_end 带消息 id。"""
    bubbles = split_bubbles(text)
    if not bubbles:
        return 0
    rid = uuid.uuid4().hex
    for i, bubble in enumerate(bubbles):
        if stream_events:
            chat_post(cfg, "/api/stream_event",
                      {"type": "bubble_start", "response_id": rid, "bubble_index": i})
        msg = chat_post(cfg, "/api/reply",
                        {"text": bubble, "response_id": rid, "bubble_index": i,
                         "push": i == 0})
        if stream_events:
            chat_post(cfg, "/api/stream_event",
                      {"type": "bubble_end", "response_id": rid, "bubble_index": i,
                       "text": bubble, "id": msg.get("id")})
    if stream_events:
        chat_post(cfg, "/api/stream_event",
                  {"type": "response_done", "response_id": rid, "bubbles": len(bubbles)})
    return len(bubbles)


def set_typing(cfg, active):
    try:
        chat_post(cfg, "/api/typing", {"who": "claude", "active": bool(active)})
    except Exception:
        pass


def stream_event(cfg, ev):
    try:
        chat_post(cfg, "/api/stream_event", ev)
    except Exception:
        pass


class Worker:
    def __init__(self, cfg):
        self.cfg = cfg
        # 已打 forwarded 标记、但生成失败待重试的私聊批次：key 为消息 id 元组。
        self.failed = {}

    # ---- 私聊 ----
    def handle_private(self):
        cfg = self.cfg
        try:
            messages = chat_get(cfg, "/api/messages?since=0")
        except Exception as e:
            log(f"拉消息失败：{e}")
            return
        if not isinstance(messages, list):
            return
        fresh = [m for m in messages if m.get("from") == "me" and not m.get("forwarded")]
        if fresh:
            ids = tuple(m["id"] for m in fresh)
            try:
                chat_post(cfg, "/api/forwarded", {"ids": [m["id"] for m in fresh]})
            except Exception as e:
                log(f"打 forwarded 标记失败：{e}")
                return
            self.failed[ids] = {"attempts": 0, "texts": [m.get("text", "") for m in fresh],
                                "all": messages}
            log(f"新消息 {len(fresh)} 条 id={list(ids)} 摘要={trunc(' / '.join(self.failed[ids]['texts']))}")
        # 重试（含刚收到的）所有待处理批次，每轮各试一次
        for ids in list(self.failed):
            job = self.failed[ids]
            job["attempts"] += 1
            ok = self._generate_private(job)
            if ok:
                del self.failed[ids]
            elif job["attempts"] >= MAX_ATTEMPTS:
                log(f"私聊 id={list(ids)} 第 {MAX_ATTEMPTS} 次仍失败，回一条通用短句")
                try:
                    set_typing(cfg, True)
                    deliver_bubbles(cfg, FALLBACK_TEXT, stream_events=False)
                except Exception as e:
                    log(f"回通用短句失败：{e}")
                finally:
                    set_typing(cfg, False)
                del self.failed[ids]

    def _generate_private(self, job):
        cfg = self.cfg
        history = job["all"][-20:]
        msgs = [{"role": "system", "content": cfg.system}]
        for m in history:
            role = "user" if m.get("from") == "me" else "assistant"
            if str(m.get("text") or "").strip():
                msgs.append({"role": role, "content": m["text"]})
        rid = uuid.uuid4().hex
        try:
            set_typing(cfg, True)
            stream_event(cfg, {"type": "bubble_start", "response_id": rid, "bubble_index": 0})
            acc = {"text": ""}

            def on_delta(full):
                delta = full[len(acc["text"]):]
                acc["text"] = full
                stream_event(cfg, {"type": "text_delta", "response_id": rid,
                                   "bubble_index": 0, "delta": delta, "text": full})

            try:
                text = call_api(cfg, msgs, stream=True, on_delta=on_delta)
            except Exception as e:
                log(f"流式失败，回落非流式：{trunc(str(e))}")
                text = call_api(cfg, msgs, stream=False)
            if not (text or "").strip():
                raise RuntimeError("模型返回空回复")
            # 流式已推过 text_delta（bubble 0 的全文占位）；按 〰 分气泡写回时不再重复推。
            bubbles = split_bubbles(text)
            n = 0
            for i, bubble in enumerate(bubbles):
                msg = chat_post(cfg, "/api/reply",
                                {"text": bubble, "response_id": rid, "bubble_index": i,
                                 "push": i == 0})
                stream_event(cfg, {"type": "bubble_end", "response_id": rid,
                                   "bubble_index": i, "text": bubble, "id": msg.get("id")})
                n += 1
            stream_event(cfg, {"type": "response_done", "response_id": rid, "bubbles": n})
            log(f"私聊已回 {n} 个气泡")
            return True
        except Exception as e:
            log(f"私聊生成失败（第 {job['attempts']} 次）：{trunc(str(e))}")
            return False
        finally:
            set_typing(cfg, False)

    # ---- 群聊 ----
    def handle_group(self):
        cfg = self.cfg
        try:
            item = chat_get(cfg, "/api/groups/pending")
        except Exception as e:
            log(f"取群聊请求失败：{e}")
            return False
        if not isinstance(item, dict) or not item.get("request_id"):
            return False
        rid = item["request_id"]
        prompt = str(item.get("prompt") or "")
        images = [x for x in (item.get("images") or []) if isinstance(x, str)][:4]
        log(f"群聊 {item.get('group_id')} 摘要={trunc(prompt)} 图片={len(images)} 张")
        text = ""
        try:
            text = self._generate_group(prompt, images)
        except Exception as e:
            log(f"群聊生成失败：{trunc(str(e))}")
        try:
            if (text or "").strip():
                chat_post(cfg, "/api/groups/deliver", {"request_id": rid, "text": text.strip()})
            else:
                chat_post(cfg, "/api/groups/deliver", {"request_id": rid, "no_reply": True})
        except Exception as e:
            log(f"群聊交回失败：{e}")
        return True

    def _generate_group(self, prompt, images):
        cfg = self.cfg
        if images:
            content = [{"type": "text", "text": prompt}]
            for u in images:
                content.append({"type": "image_url", "image_url": {"url": u}})
            msgs = [{"role": "system", "content": GROUP_SYSTEM},
                    {"role": "user", "content": content}]
            try:
                return call_api(cfg, msgs, stream=False)
            except Exception as e:
                log(f"群聊带图失败，重试纯文字：{trunc(str(e))}")
        msgs = [{"role": "system", "content": GROUP_SYSTEM},
                {"role": "user", "content": prompt}]
        return call_api(cfg, msgs, stream=False)

    def run(self):
        cfg = self.cfg
        log(f"工人启动：模型={cfg.model} 接口={trunc(cfg.base_url, 60)} "
            f"信箱={cfg.chat_url} 轮询={cfg.poll}s")
        while True:
            try:
                self.handle_group()
                self.handle_private()
            except Exception as e:
                log(f"本轮异常（继续）：{trunc(str(e))}")
            time.sleep(cfg.poll)


def main():
    cfg = Config()
    if not cfg.check():
        sys.exit(2)
    Worker(cfg).run()


if __name__ == "__main__":
    main()
