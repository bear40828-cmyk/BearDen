import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { Readable } from 'node:stream'
import { createFavoriteService } from './favorites.mjs'

const owner = { id: 'owner' }, assistant = { id: 'assistant' }
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII='
const setup = () => { const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bear-favorites-test-')); return { root, api: createFavoriteService(root) } }
const record = () => ({ id: crypto.randomUUID(), text: '留着以后看', sourceRemark: '我的备注', savedAt: Date.now(), assets: [{ name: 'photo.png', base64: png }] })

test('assistant can read but cannot create, replace or delete favorites', () => {
  const { api } = setup(), item = record()
  api.execute('favorites_save', { record: item }, owner)
  assert.equal(api.execute('favorites_list', { query: '我的备注' }, assistant).items.length, 1)
  assert.equal(api.execute('favorites_read', { id: item.id }, assistant).text, item.text)
  for (const action of ['favorites_save', 'favorites_remove']) assert.throws(() => api.execute(action, { record: item, id: item.id }, assistant), { status: 403 })
  assert.equal(api.callTool('favorites_remove', { id: item.id }, assistant).isError, true)
  assert.equal(api.execute('favorites_list', {}, owner).items.length, 1)
})
test('private image and text attachments are readable and persist after restart', () => {
  const { api, root } = setup(), item = record()
  item.assets.push({ name: 'note.txt', base64: Buffer.from('照片说明').toString('base64') })
  api.execute('favorites_save', { record: JSON.stringify(item) }, owner)
  const reopened = createFavoriteService(root)
  const result = reopened.callTool('favorites_view_attachment', { id: item.id, asset_id: '0' }, assistant)
  assert.equal(result.content[0].type, 'image'); assert.equal(result.content[0].data, png)
  assert.equal(reopened.callTool('favorites_view_attachment', { id: item.id, asset_id: '1' }, assistant).content[0].text, '照片说明')
  assert.equal(reopened.execute('favorites_read', { id: item.id }, assistant).assets[0].filename, undefined)
  assert.throws(() => reopened.execute('favorites_view_attachment', { id: item.id, asset_id: '../../data.json' }, assistant), { status: 404 })
})
test('retries are idempotent and stale retries cannot resurrect deleted favorites', () => {
  const { api, root } = setup(), item = record()
  api.execute('favorites_save', { record: item }, owner); api.execute('favorites_save', { record: item }, owner)
  assert.equal(api.execute('favorites_list', {}, assistant).items.length, 1)
  api.execute('favorites_remove', { id: item.id }, owner)
  assert.equal(api.execute('favorites_list', {}, assistant).items.length, 0)
  assert.throws(() => api.execute('favorites_save', { record: item }, owner), { status: 409 })
  assert.equal(fs.readdirSync(path.join(root, 'private-favorite-files')).length, 1)
})
test('anonymous or unrelated identities cannot read even when they know ids', () => {
  const { api } = setup(), item = record(); api.execute('favorites_save', { record: item }, owner)
  for (const user of [null, { id: 'anonymous' }, { id: 'ai_bad', appAI: true }]) {
    assert.throws(() => api.execute('favorites_list', {}, user), { status: 401 })
    assert.throws(() => api.execute('favorites_read', { id: item.id }, user), { status: 401 })
    assert.throws(() => api.execute('favorites_view_attachment', { id: item.id, asset_id: '0' }, user), { status: 401 })
  }
})
test('invalid input and corrupted storage never wipe the index', () => {
  const { api, root } = setup(), item = record(); api.execute('favorites_save', { record: item }, owner)
  assert.throws(() => api.execute('favorites_save', { record: { ...item, id: '../../bad' } }, owner), { status: 400 })
  assert.equal(api.execute('favorites_list', {}, owner).items.length, 1)
  fs.writeFileSync(path.join(root, 'favorites.json'), '{bad')
  assert.throws(() => api.execute('favorites_save', { record: record() }, owner))
  assert.equal(fs.readFileSync(path.join(root, 'favorites.json'), 'utf8'), '{bad')
})
test('HTTP write authorization and attachment routing', async () => {
  const { api } = setup(), item = record()
  const request = async (url, method, value, user) => {
    const req = Readable.from(value ? [Buffer.from(JSON.stringify(value))] : []); req.url = url; req.method = method
    const res = { writeHead(status) { this.status = status }, end(body) { this.body = body } }
    await api.handle(req, res, user); return res
  }
  assert.equal((await request('/api/favorites/save', 'POST', { record: item }, assistant)).status, 403)
  assert.equal((await request('/api/favorites/save', 'POST', { record: item }, owner)).status, 200)
  const file = await request(`/api/favorites/attachment/${item.id}/0`, 'GET', null, assistant)
  assert.equal(file.status, 200); assert.equal(file.body.toString('base64'), png)
  assert.equal((await request(`/api/favorites/attachment/${item.id}/0`, 'GET', null, null)).status, 401)
})
