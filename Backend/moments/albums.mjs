// Shared private photo albums for the owner and the assistant. Never use Moments' anonymous fallback.
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

export const albumTools = [
  { name: 'album_list', description: '列出熊窝共享相册及照片，照片可用 album_view_photo 查看实际图片', inputSchema: { type: 'object', properties: {} } },
  { name: 'album_create', description: '创建熊窝共享相册', inputSchema: { type: 'object', required: ['name'], properties: { name: { type: 'string' } } } },
  { name: 'album_rename', description: '修改熊窝相册名称', inputSchema: { type: 'object', required: ['album_id', 'name'], properties: { album_id: { type: 'string' }, name: { type: 'string' } } } },
  { name: 'album_upload_photo', description: '向熊窝相册上传 JPEG 或 PNG 照片（最多 8 MB），可附文字说明', inputSchema: { type: 'object', required: ['album_id', 'image_base64'], properties: { album_id: { type: 'string' }, image_base64: { type: 'string' }, caption: { type: 'string' } } } },
  { name: 'album_caption_photo', description: '修改熊窝相册里某张照片的文字说明', inputSchema: { type: 'object', required: ['album_id', 'photo_id', 'caption'], properties: { album_id: { type: 'string' }, photo_id: { type: 'string' }, caption: { type: 'string' } } } },
  { name: 'album_set_cover', description: '把熊窝相册里某张照片设为该相册封面；photo_id 留空则恢复默认封面', inputSchema: { type: 'object', required: ['album_id'], properties: { album_id: { type: 'string' }, photo_id: { type: 'string' } } } },
  { name: 'album_view_photo', description: '查看熊窝相册中的实际照片，返回图片供视觉识别', inputSchema: { type: 'object', required: ['photo_id'], properties: { photo_id: { type: 'string' } } } },
]

export function createAlbumService(root = path.dirname(fileURLToPath(import.meta.url))) {
  const index = path.join(root, 'albums.json')
  const photosDir = path.join(root, 'private-album-photos')
  const fail = (status, message) => { throw Object.assign(new Error(message), { status }) }
  const authorize = user => { if (!user || !(['owner', 'assistant', 'assistant-2'].includes(user.id) || (user.appAI === true && /^ai_[a-f0-9-]{36}$/i.test(user.id)))) fail(401, '请先验证相册访问身份') }
  const load = () => fs.existsSync(index) ? JSON.parse(fs.readFileSync(index, 'utf8')) : { albums: [] }
  const save = d => {
    const temp = index + '.tmp'
    fs.writeFileSync(temp, JSON.stringify(d), { mode: 0o600 })
    fs.renameSync(temp, index)
  }
  const name = raw => {
    if (typeof raw !== 'string' || !raw.trim() || raw.trim().length > 80) fail(400, '相册名称需为 1–80 个字符')
    return raw.trim()
  }
  const findPhoto = (d, id) => d.albums.flatMap(a => a.photos).find(p => p.id === id && !p.deleted)
  const publicData = d => ({ albums: d.albums.map(a => ({ ...a, photos: a.photos.filter(p => !p.deleted).map(({ filename, ...p }) => p) })) })
  function execute(action, args, user) {
    authorize(user)
    const d = load()
    if (action === 'album_list') return publicData(d)
    if (action === 'album_view_photo') {
      const photo = findPhoto(d, args.photo_id)
      if (!photo) fail(404, '照片不存在')
      return { data: fs.readFileSync(path.join(photosDir, path.basename(photo.filename))), mime: photo.mime }
    }
    if (action === 'album_create') {
      d.albums.unshift({ id: crypto.randomUUID(), name: name(args.name), createdAt: Date.now(), updatedAt: Date.now(), author: user.id, photos: [] })
    } else {
      const album = d.albums.find(a => a.id === args.album_id)
      if (!album) fail(404, '相册不存在')
      if (action === 'album_rename') album.name = name(args.name)
      else if (action === 'album_upload_photo') {
        const encoded = String(args.image_base64 || '').replace(/^data:image\/(?:png|jpeg);base64,/, '')
        if (!encoded || encoded.length > 12 * 1024 * 1024 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) fail(400, '照片格式或大小不符合要求')
        const data = Buffer.from(encoded, 'base64')
        if (data.length > 8 * 1024 * 1024) fail(413, '每张照片最多 8 MB')
        const png = data.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))
        const jpg = data[0] === 255 && data[1] === 216 && data[2] === 255
        if (!png && !jpg) fail(400, '只支持 JPEG 和 PNG 照片')
        const id = crypto.randomUUID()
        const filename = id + (png ? '.png' : '.jpg')
        fs.mkdirSync(photosDir, { recursive: true, mode: 0o700 })
        fs.writeFileSync(path.join(photosDir, filename), data, { flag: 'wx', mode: 0o600 })
        album.photos.push({ id, filename, mime: png ? 'image/png' : 'image/jpeg', caption: String(args.caption || '').slice(0, 2000), author: user.id, createdAt: Date.now() })
      } else if (action === 'album_caption_photo') {
        const photo = album.photos.find(p => p.id === args.photo_id && !p.deleted)
        if (!photo) fail(404, '照片不存在')
        photo.caption = String(args.caption || '').slice(0, 2000)
        photo.captionBy = user.id
        photo.captionAt = Date.now()
      } else if (action === 'album_set_cover') {
        if (!args.photo_id) delete album.coverPhotoId
        else {
          if (!album.photos.find(p => p.id === args.photo_id && !p.deleted)) fail(404, '照片不存在')
          album.coverPhotoId = args.photo_id
        }
      } else if (action === 'album_remove_photo') {
        const photo = album.photos.find(p => p.id === args.photo_id && !p.deleted)
        if (!photo) fail(404, '照片不存在')
        photo.deleted = true // recoverable; the original file is not erased
      } else fail(404, '操作不存在')
      album.updatedAt = Date.now()
    }
    save(d)
    return publicData(d)
  }

  async function handle(req, res, user) {
    const p = new URL(req.url, 'http://localhost').pathname
    if (!p.startsWith('/api/albums')) return false
    const json = (status, data) => { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(data)) }
    try {
      authorize(user)
      if (req.method === 'GET' && p.startsWith('/api/albums/photos/')) {
        const photo = execute('album_view_photo', { photo_id: p.split('/').pop() }, user)
        res.writeHead(200, { 'content-type': photo.mime, 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff' })
        res.end(photo.data)
      } else if (req.method === 'GET' && p === '/api/albums') json(200, execute('album_list', {}, user))
      else if (req.method === 'POST') {
        const routes = { '/api/albums/create': 'album_create', '/api/albums/rename': 'album_rename', '/api/albums/upload': 'album_upload_photo', '/api/albums/remove-photo': 'album_remove_photo', '/api/albums/caption': 'album_caption_photo', '/api/albums/cover': 'album_set_cover' }
        if (!routes[p]) fail(404, '操作不存在')
        const chunks = []; let length = 0
        for await (const chunk of req) {
          length += chunk.length
          if (length > 13 * 1024 * 1024) fail(413, '上传内容过大')
          chunks.push(chunk)
        }
        const args = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
        json(200, execute(routes[p], args, user))
      } else json(405, { error: '不支持此请求方法' })
    } catch (error) { json(error.status || 400, { error: error.status ? error.message : '相册请求失败，请重试' }) }
    return true
  }
  function callTool(tool, args, user) {
    try {
      const result = execute(tool, args, user)
      return tool === 'album_view_photo'
        ? { content: [{ type: 'image', data: result.data.toString('base64'), mimeType: result.mime }] }
        : { content: [{ type: 'text', text: JSON.stringify(result) }] }
    } catch (error) { return { isError: true, content: [{ type: 'text', text: error.status ? error.message : '相册操作失败' }] } }
  }
  return { execute, handle, callTool }
}
