import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { Readable } from 'node:stream'
import { createAlbumService } from './albums.mjs'

const human = { id: 'owner' }, assistant = { id: 'assistant' }
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII='
const service = () => { const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bear-albums-test-')); return { root, api: createAlbumService(root) } }

test('private identity is required for every album action', () => {
  const { api } = service()
  for (const user of [null, { id: 'anonymous' }, { id: 'ai_bad', appAI: true }]) {
    assert.throws(() => api.execute('album_list', {}, user), { status: 401 })
    assert.throws(() => api.execute('album_create', { name: 'test' }, user), { status: 401 })
    assert.throws(() => api.execute('album_view_photo', { photo_id: '../data.json' }, user), { status: 401 })
  }
})
test('owner and assistant share create, rename, upload and image reads across restarts', () => {
  const { api, root } = service()
  const id = api.execute('album_create', { name: ' 一起出去玩 ' }, human).albums[0].id
  api.execute('album_rename', { album_id: id, name: '我们的照片' }, assistant)
  const list = api.execute('album_upload_photo', { album_id: id, image_base64: png, caption: '合影' }, assistant)
  const photo = list.albums[0].photos[0]
  assert.equal(photo.author, 'assistant'); assert.equal(photo.filename, undefined)
  const restarted = createAlbumService(root)
  assert.equal(restarted.execute('album_list', {}, human).albums[0].name, '我们的照片')
  assert.equal(restarted.execute('album_view_photo', { photo_id: photo.id }, human).data.toString('base64'), png)
  const result = restarted.callTool('album_view_photo', { photo_id: photo.id }, assistant)
  assert.equal(result.content[0].type, 'image'); assert.equal(result.content[0].mimeType, 'image/png')
  assert.throws(() => restarted.execute('album_view_photo', { photo_id: '../../data.json' }, assistant), { status: 404 })
})
test('invalid input does not replace existing albums', () => {
  const { api } = service()
  assert.throws(() => api.execute('album_create', { name: ' ' }, human), { status: 400 })
  const id = api.execute('album_create', { name: '原相册' }, human).albums[0].id
  assert.throws(() => api.execute('album_upload_photo', { album_id: id, image_base64: Buffer.from('<script>').toString('base64') }, assistant), { status: 400 })
  assert.throws(() => api.execute('album_upload_photo', { album_id: id, image_base64: 'a'.repeat(13 * 1024 * 1024) }, assistant), { status: 400 })
  assert.equal(api.execute('album_list', {}, human).albums[0].photos.length, 0)
})
test('corrupt index fails closed instead of resetting data', () => {
  const { api, root } = service()
  fs.writeFileSync(path.join(root, 'albums.json'), '{broken')
  assert.throws(() => api.execute('album_create', { name: 'do not overwrite' }, human))
  assert.equal(fs.readFileSync(path.join(root, 'albums.json'), 'utf8'), '{broken')
})
test('HTTP enforces authentication and handles malformed JSON without crashing', async () => {
  const { api } = service()
  async function request(url, method, body, user) {
    const req = Readable.from(body ? [Buffer.from(body)] : []); req.url = url; req.method = method
    const res = { status: null, body: '', writeHead(status) { this.status = status }, end(body) { this.body = body } }
    await api.handle(req, res, user); return res
  }
  assert.equal((await request('/api/albums', 'GET', null, null)).status, 401)
  assert.equal((await request('/api/albums/photos/id', 'GET', null, null)).status, 401)
  assert.equal((await request('/api/albums/create', 'POST', '{broken', human)).status, 400)
  assert.equal((await request('/api/albums/create', 'POST', '{"name":"试试"}', human)).status, 200)
  assert.equal((await request('/api/albums', 'GET', null, assistant)).status, 200)
})
