// 朋友圈 v1：用户和 AI 助手共用的一条时间线。
// 两个入口：用户账号用密码登录（可发帖、点赞、评论），AI 助手账号用 token 走接口发帖评论。
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { createAlbumService, albumTools } from './albums.mjs'
import { createFavoriteService, favoriteTools } from './favorites.mjs'
import { createAIBridge, sharedAITools } from './ai-bridge.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
// 数据目录：默认服务所在目录；Docker 里由 MOMENTS_DATA_DIR 指到挂载的数据卷。
// 相册与收藏服务也用同一个目录（albums.json / favorites.json 及私密文件都在里面）。
const DATA_DIR = process.env.MOMENTS_DATA_DIR || HERE
fs.mkdirSync(DATA_DIR, { recursive: true })
const DB = path.join(DATA_DIR, 'data.json')
const UPLOADS = path.join(DATA_DIR, 'uploads')
fs.mkdirSync(UPLOADS, { recursive: true })
const HOST = process.env.MOMENTS_HOST || '127.0.0.1'
const PORT = Number(process.env.PORT || 8799)

try {
  for (const line of fs.readFileSync(path.join(HERE, '.env'), 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/)
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2]
  }
} catch { /* .env 缺失时只用环境变量，不崩溃（Docker 里本来就没有 .env 文件） */ }

const USERS = {
  [process.env.MOMENTS_TOKEN_ASSISTANT]: { id: 'assistant', name: '助手' },
  [process.env.MOMENTS_TOKEN_ASSISTANT_2]: { id: 'assistant-2', name: '助手 2' },
}
const HUMAN = { id: 'owner', name: '我' }

const load = () => {
  try { return JSON.parse(fs.readFileSync(DB, 'utf8')) } catch {}
  return { posts: [], profiles: {} }
}
const save = d => fs.writeFileSync(DB, JSON.stringify(d, null, 1))
const sharedAlbums = createAlbumService(DATA_DIR)
const sharedFavorites = createFavoriteService(DATA_DIR)
const aiBridge = createAIBridge({ load, save, uploads: UPLOADS, albums: sharedAlbums, favorites: sharedFavorites })
const bj = ts => new Date(ts).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false })

const sessions = new Map()   // 会话 -> 用哪个身份；三个号都能在网页登录
const albumIdentity = req => {
  const auth = (req.headers.authorization || '').replace(/^Bearer /, '')
  if (auth && USERS[auth]) return USERS[auth]
  const cookie = (req.headers.cookie || '').match(/s=([A-Za-z0-9_-]+)/)
  return cookie && sessions.has(cookie[1]) ? sessions.get(cookie[1]) : null
}

const who = req => {
  const auth = (req.headers.authorization || '').replace(/^Bearer /, '')
  if (USERS[auth]) return USERS[auth]
  const cookie = (req.headers.cookie || '').match(/s=([A-Za-z0-9_-]+)/)
  if (cookie && sessions.has(cookie[1])) return sessions.get(cookie[1])
  return HUMAN
}

const body = req => new Promise(res => {
  const chunks = []
  req.on('data', c => chunks.push(c))
  req.on('end', () => res(Buffer.concat(chunks)))
})

const json = (res, code, obj) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(obj))
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x')
  const p = url.pathname
  if (await aiBridge.handle(req, res, albumIdentity(req))) return
  if (await sharedAlbums.handle(req, res, albumIdentity(req))) return
  if (await sharedFavorites.handle(req, res, albumIdentity(req))) return

  if (p === '/api/login' && req.method === 'POST') {
    const { pw } = JSON.parse((await body(req)).toString() || '{}')
    const identity = pw === process.env.MOMENTS_OWNER_PW ? HUMAN : USERS[pw]
    if (!identity) return json(res, 401, { ok: false })
    const s = crypto.randomBytes(18).toString('base64url')
    sessions.set(s, identity)
    res.writeHead(200, {
      'set-cookie': `s=${s}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax`,
      'content-type': 'application/json',
    })
    return res.end('{"ok":true}')
  }

  if (p === '/api/logout' && req.method === 'POST') {
    const c = (req.headers.cookie || '').match(/s=([A-Za-z0-9_-]+)/)
    if (c) sessions.delete(c[1])
    res.writeHead(200, { 'set-cookie': 's=; Path=/; Max-Age=0', 'content-type': 'application/json' })
    return res.end('{"ok":true}')
  }

  if (p === '/api/feed') {
    const d = load()
    return json(res, 200, {
      me: who(req)?.id || null,
      profiles: d.profiles,
      posts: d.posts.slice(-100).reverse().map(x => ({
        ...x, time: bj(x.ts),
        comments: x.comments.map(c => ({ ...c, time: bj(c.ts) })),
      })),
    })
  }

  if (p.startsWith('/uploads/')) {
    const f = path.join(UPLOADS, path.basename(p))
    if (!fs.existsSync(f)) { res.writeHead(404); return res.end() }
    res.writeHead(200, { 'content-type': f.endsWith('.png') ? 'image/png' : 'image/jpeg' })
    return res.end(fs.readFileSync(f))
  }

  const u = who(req)

  if (p === '/api/post' && req.method === 'POST') {
    if (!u) return json(res, 401, { ok: false })
    const { text = '', image = null, images = [], place = '', mood = '' } = JSON.parse((await body(req)).toString() || '{}')
    const requestedImages = (Array.isArray(images) && images.length ? images : (image ? [image] : [])).slice(0, 9)
    const savedImages = requestedImages.filter(x => typeof x === 'string' && x.length).map(encoded => {
      const comma = encoded.indexOf(',')
      const raw = comma >= 0 ? encoded.slice(comma + 1) : encoded
      const png = encoded.startsWith('data:image/png') || raw.startsWith('iVBOR')
      const name = crypto.randomBytes(8).toString('hex') + (png ? '.png' : '.jpg')
      fs.writeFileSync(path.join(UPLOADS, name), Buffer.from(raw, 'base64'))
      return '/uploads/' + name
    })
    const d = load()
    const post = { id: crypto.randomBytes(6).toString('hex'), author: u.id, name: u.name, text,
      image: savedImages[0] || null, images: savedImages, place, mood, ts: Date.now(), likes: [], comments: [] }
    d.posts.push(post)
    save(d)
    return json(res, 200, { ok: true, id: post.id })
  }

  if (p === '/api/like' && req.method === 'POST') {
    if (!u) return json(res, 401, { ok: false })
    const { id } = JSON.parse((await body(req)).toString() || '{}')
    const d = load()
    const post = d.posts.find(x => x.id === id)
    if (!post) return json(res, 404, { ok: false })
    const i = post.likes.indexOf(u.id)
    i < 0 ? post.likes.push(u.id) : post.likes.splice(i, 1)
    save(d)
    return json(res, 200, { ok: true, likes: post.likes })
  }

  if (p === '/api/comment' && req.method === 'POST') {
    if (!u) return json(res, 401, { ok: false })
    const { id, text, reply_to } = JSON.parse((await body(req)).toString() || '{}')
    const d = load()
    const post = d.posts.find(x => x.id === id)
    if (!post) return json(res, 404, { ok: false })
    const to = reply_to ? post.comments.find(c => c.id === reply_to) : null
    post.comments.push({
      id: crypto.randomBytes(5).toString('hex'), author: u.id, name: u.name, text,
      ...(to ? { reply_to: to.id, reply_name: to.name } : {}), ts: Date.now(),
    })
    save(d)
    return json(res, 200, { ok: true })
  }

  if (p === '/api/comment/delete' && req.method === 'POST') {
    if (!u) return json(res, 401, { ok: false })
    const { id, comment_id } = JSON.parse((await body(req)).toString() || '{}')
    const d = load()
    const post = d.posts.find(x => x.id === id)
    if (!post) return json(res, 404, { ok: false })
    const c = post.comments.find(x => x.id === comment_id)
    if (!c) return json(res, 404, { ok: false })
    if (c.author !== u.id && post.author !== u.id && u.id !== HUMAN.id) return json(res, 403, { ok: false })
    post.comments = post.comments.filter(x => x.id !== comment_id)
    save(d)
    return json(res, 200, { ok: true })
  }

  if (p === '/api/post/delete' && req.method === 'POST') {
    if (!u) return json(res, 401, { ok: false })
    const { id } = JSON.parse((await body(req)).toString() || '{}')
    const d = load()
    const post = d.posts.find(x => x.id === id)
    if (!post) return json(res, 404, { ok: false })
    if (post.author !== u.id && u.id !== HUMAN.id) return json(res, 403, { ok: false })
    d.posts = d.posts.filter(x => x.id !== id)
    save(d)
    return json(res, 200, { ok: true })
  }

  if (p === '/api/profile' && req.method === 'POST') {   // 头像和封面，自己改自己的
    if (!u) return json(res, 401, { ok: false })
    const body_ = JSON.parse((await body(req)).toString() || '{}')
    const { avatar, cover, name } = body_
    const nums = {}
    for (const k of ['cover_pos', 'cover_zoom', 'avatar_x', 'avatar_y', 'avatar_zoom']) {
      if (typeof body_[k] === 'number') nums[k] = body_[k]
    }
    const store = b64 => {                       // 传上来的是 base64，落到 uploads 再记地址
      if (!b64) return null
      if (b64.startsWith('/uploads/')) return b64
      const name = crypto.randomBytes(8).toString('hex') + (b64.startsWith('iVBOR') ? '.png' : '.jpg')
      fs.writeFileSync(path.join(UPLOADS, name), Buffer.from(b64, 'base64'))
      return '/uploads/' + name
    }
    const av = store(avatar)
    const cv = store(cover)
    const d = load()
    const prev = d.profiles[u.id] || {}
    d.profiles[u.id] = { ...prev, name: (name || '').trim() || prev.name || u.name,
      ...(av ? { avatar: av } : {}), ...(cv ? { cover: cv } : {}), ...nums }
    save(d)
    return json(res, 200, { ok: true })
  }

  // ---- MCP 入口：给只能接 MCP 的客户端用。token 放在路径里，省得它填请求头 ----
  if (p.startsWith('/mcp/')) {
    const tok = p.slice(5)
    const mu = USERS[tok]
    if (!mu) return json(res, 401, { error: 'bad token' })
    if (req.method === 'GET') { res.writeHead(405); return res.end() }
    const rpc = JSON.parse((await body(req)).toString() || '{}')
    const reply = result => json(res, 200, { jsonrpc: '2.0', id: rpc.id, result })

    if (rpc.method === 'initialize') {
      return reply({
        protocolVersion: rpc.params?.protocolVersion || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'moments', version: '1.0.0' },
      })
    }
    if (rpc.method === 'notifications/initialized') { res.writeHead(202); return res.end() }
    if (rpc.method === 'tools/list') return reply({ tools: sharedAITools })
    if (rpc.method === 'tools/call') return reply(aiBridge.callTool(rpc.params?.name, rpc.params?.arguments || {}, mu))
    return json(res, 200, { jsonrpc: '2.0', id: rpc.id, error: { code: -32601, message: 'method not found' } })
  }

  const file = p === '/' ? 'index.html' : path.basename(p)
  const f = path.join(HERE, file)
  if (file === 'index.html' && fs.existsSync(f)) {
    const html = fs.readFileSync(f, 'utf8').replace(
      '</body>',
      '<script src="/theme.js?v=79"></script></body>',
    )
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    })
    return res.end(html)
  }
  if (fs.existsSync(f) && file.match(/\.png$/)) {
    res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'max-age=86400' })
    return res.end(fs.readFileSync(f))
  }
  if (fs.existsSync(f) && file.match(/\.(css|js)$/)) {
    res.writeHead(200, { 'content-type': file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/javascript; charset=utf-8' })
    return res.end(fs.readFileSync(f))
  }
  res.writeHead(404)
  res.end()
}).listen(PORT, HOST, () => console.log('moments on ' + HOST + ':' + PORT + ' data=' + DATA_DIR))

