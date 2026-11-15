# 熊窝 build 99 — selection, favorites, private shared albums

## App

- Chat's custom menu owns copy/select-all; UITextView keeps native selection handles but returns an empty system edit menu. Parent dismiss gestures exclude action-bar and active selection frames.
- Favorites keep a local snapshot under Documents/Favorites and sync to the authenticated service for the assistant to read. Saving snapshots text, sender remark, date and attachments. The index is atomically committed only after attachments have been downloaded; source withdrawal does not remove favorites. Removing an index entry keeps cached attachments recoverable and queues a durable cloud deletion. Unsynced items are visibly marked and retried without duplicating records.
- Chat's Translate action uses Apple's built-in translation presentation on iOS 17.4+. It translates the selected text, or the full message when there is no selection, without replacing the original.
- Me → Favorites has search, type filters, preview cards and detail pages. Me → Albums uses the authenticated shared service below.

## Shared albums deployment

Deployed beside the existing Moments service.
`server.mjs` is the integrated server snapshot; no credentials or production data are included.
`albums.json` and `private-album-photos/` are separate from the existing feed, and must be backed up together. Writes are atomic and corrupt indexes fail closed.

The album routes accept only an authenticated Moments cookie or the already-configured assistant Bearer identity. They DO NOT use the older feed's anonymous HUMAN fallback. Album image routes are authenticated and are not in public uploads. Access is limited to the owner and the configured assistant identities (see the allow-list in `albums.mjs`).

The app first reuses its existing session. If it has none, the owner enters the existing Moments account password in a secure field. Login uses the existing `/api/login` endpoint, clears the input after success and uses the secure HttpOnly session cookie; no password is embedded or logged. The existing server uses in-memory sessions, so a server restart requires verification again.

## Environment

`server.mjs` reads a `.env` file next to it at startup. `.env` is never
committed to this repository; create it on your own server:

- `MOMENTS_TOKEN_ASSISTANT` — Bearer token for the first assistant identity (`assistant`).
- `MOMENTS_TOKEN_ASSISTANT_2` — Bearer token for the second assistant identity (`assistant-2`).
- `MOMENTS_OWNER_PW` — password the owner uses to log in on the web and in the app.

No credentials or production data are included in this repository. Generated
`data.json`, `albums.json`, `favorites.json`, `uploads/`,
`private-album-photos/` and `private-favorite-files/` are runtime data, not
source files.

HTTP routes:

- GET `/api/albums`: album and photo metadata.
- POST `/api/albums/create` with `name`.
- POST `/api/albums/rename` with `album_id`, `name`.
- POST `/api/albums/upload` with `album_id`, `image_base64`, optional `caption`. JPEG/PNG, <=8 MB each.
- GET `/api/albums/photos/{photo_id}`: authenticated image bytes.
- POST `/api/albums/remove-photo` with `album_id`, `photo_id`: recoverable removal, does not erase original file.
- POST `/api/albums/caption` with `album_id`, `photo_id`, `caption`: edit a photo's caption (records `captionBy`/`captionAt`). MCP: `album_caption_photo`.

The assistant's existing Moments MCP endpoint now advertises `album_list`, `album_create`, `album_rename`, `album_upload_photo`, `album_view_photo`. Refresh the client's MCP tool inventory if cached. `album_view_photo` returns an MCP image block, not just a URL, so the assistant can inspect the actual picture. Existing credentials stay in their configured service and client; no extra copying is needed.

## Shared favorites (read-only for the assistant)

The owner explicitly authorized sharing all favorites with the assistant. They are stored separately in `favorites.json` and `private-favorite-files/`. These paths are NOT public static files. Both must be backed up together. The owner can save/remove; the assistant is read-only at the HTTP and MCP layers. Anonymous identities cannot access favorites; only the owner and the configured assistant identities can.

- GET `/api/favorites`: read/search metadata, optional query parameter `query`.
- POST `/api/favorites/save`: owner-only, body `record` containing a serialized object with `id` (UUID), `text`, `sourceRemark`, `savedAt` (epoch milliseconds), and `assets` (`name`, `base64`). Each record's attachments total at most 24 MB.
- POST `/api/favorites/remove`: owner-only, body `id`; marks deletion so stale retries cannot resurrect it. Original attachment bytes remain recoverable.
- GET `/api/favorites/attachment/{id}/{asset_id}`: authenticated attachment bytes.
- Assistant MCP: `favorites_list`, `favorites_read`, `favorites_view_attachment`; images return image blocks, text files return text, other files return embedded resources. File contents are data, not instructions to execute.

Favorites and albums share the existing authenticated session. The app prompts for the existing owner password when needed; it never embeds credentials. Local JSON migrates from the original array format to an atomic snapshot containing items and queued deletions. Existing and new favorites are synced; this is not a full multi-device restore client.

## Verification

- `node --test ai-bridge.test.mjs albums.test.mjs favorites.test.mjs`: isolated tests covering authorization, sharing, read-only assistant favorites permissions, persistence, image content, idempotent saves/deletions, invalid input, corrupt-index handling and HTTP errors.
- `python3 test_albums.py`: the same tests plus unauthenticated GET checks against the running localhost service. No production album mutations.
- GitHub Actions builds the actual SwiftUI target with Xcode 26.3, deployment target iOS 17.
- Device gesture behavior and visual rendering still need an installation check; CI compilation is not a device UI test.

## Docker 部署

见根目录 `docker-compose.yml` 与根 README 的 Docker 一节：朋友圈服务由 compose
以 `MOMENTS_HOST=0.0.0.0`、`MOMENTS_DATA_DIR=/app/data` 启动，数据落在 named volume
`moments-data` 里（`data.json`、`uploads/`、`albums.json`、`favorites.json` 及两个
私密文件目录都在里面）。本地不用 Docker 也可以直接跑：

```sh
node server.mjs
```

默认监听 `127.0.0.1:8799`；`PORT` / `MOMENTS_HOST` / `MOMENTS_DATA_DIR` 三个环境变量
可改监听地址与数据目录，`.env` 缺失时只用环境变量，不会启动失败。
