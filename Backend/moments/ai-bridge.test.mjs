import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { Readable } from 'node:stream'
import { createAIBridge } from './ai-bridge.mjs'
import { createAlbumService } from './albums.mjs'
import { createFavoriteService } from './favorites.mjs'

const ai = { id:'ai_123e4567-e89b-12d3-a456-426614174000', name:'puppy', appAI:true }
const other = { id:'ai_123e4567-e89b-12d3-a456-426614174001', name:'另一位', appAI:true }
function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bear-bridge-'))
  let data = { posts:[], profiles:{} }
  return { bridge:createAIBridge({ load:()=>data, save:x=>{data=x}, uploads:path.join(root,'uploads'), albums:createAlbumService(root), favorites:createFavoriteService(root) }), state:()=>data }
}
const value = result => JSON.parse(result.content[0].text)
test('each AI has real profile identity, can comment, like and delete only own content', () => {
  const {bridge,state} = setup()
  const id = value(bridge.callTool('post_moment',{text:'hello'},ai)).id
  assert.equal(state().posts[0].author,ai.id)
  const c = value(bridge.callTool('comment_moment',{id,text:'reply'},other)).id
  assert.equal(state().posts[0].comments[0].author,other.id)
  assert.equal(bridge.callTool('delete_moment_comment',{id,comment_id:c},ai).isError,true)
  assert.equal(bridge.callTool('delete_moment',{id},other).isError,true)
  assert.equal(value(bridge.callTool('like_moment',{id,liked:true},other)).liked,true)
  assert.equal(value(bridge.callTool('like_moment',{id,liked:true},other)).liked,true)
  assert.equal(state().posts[0].likes.length,1)
  assert.equal(value(bridge.callTool('delete_moment_comment',{id,comment_id:c},other)).ok,true)
  assert.equal(value(bridge.callTool('delete_moment',{id},ai)).ok,true)
})
test('assistant-2 and app AI share album and read-only favorites but cannot forge owner write', () => {
  const {bridge} = setup()
  const album = value(bridge.callTool('album_create',{name:'shared'},ai)).albums[0]
  assert.equal(value(bridge.callTool('album_list',{}, {id:'assistant-2'})).albums[0].id,album.id)
  assert.equal(value(bridge.callTool('favorites_list',{},ai)).items.length,0)
  assert.equal(bridge.callTool('favorites_remove',{id:'123e4567-e89b-12d3-a456-426614174000'},ai).isError,true)
  assert.equal(bridge.callTool('album_list',{}, {id:'ai_x',appAI:true}).isError,true)
})
test('private app tool proxy requires human session, rejects forged actor', async () => {
  const {bridge} = setup()
  async function invoke(user, value) {
    const req=Readable.from([Buffer.from(JSON.stringify(value))]); req.url='/api/ai/call'; req.method='POST'
    const res={status:null,body:'',writeHead(code){this.status=code},end(text){this.body=text}}
    await bridge.handle(req,res,user); return res
  }
  const args={conversation_id:'123e4567-e89b-12d3-a456-426614174000',nickname:'puppy',name:'album_list',arguments:{}}
  assert.equal((await invoke(null,args)).status,401)
  assert.equal((await invoke({id:'assistant'},args)).status,401)
  assert.equal((await invoke({id:'owner'},args)).status,200)
  assert.equal((await invoke({id:'owner'},{...args,conversation_id:'assistant'})).status,400)
})
