# 朋友圈服务：Node 朋友圈 + 共享相册 + 收藏 + AI 桥接，零第三方依赖。
FROM node:22-alpine
WORKDIR /app
COPY *.mjs ./
# 数据（data.json / uploads / albums.json / favorites.json 及私密文件）默认写在
# MOMENTS_DATA_DIR，compose 里指到 named volume；不拷任何数据文件。
EXPOSE 8799
CMD ["node", "server.mjs"]
