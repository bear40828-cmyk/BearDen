# 信箱服务器 + 内置 API 工人：Python 标准库，无第三方依赖。
# 同一个镜像两个用法：默认跑 server.py；工人服务用 command ["python3", "worker.py"] 启动。
FROM python:3.12-slim
WORKDIR /app
COPY server.py worker.py ./
COPY public/ ./public/
# 缺失的 secret 文件（.chat-pass / .upload-token / VAPID）由 server.py 自身容错处理：
# token 类现场生成随机值，VAPID 缺失则禁用推送，不会启动失败。
EXPOSE 8810
CMD ["python3", "server.py"]
