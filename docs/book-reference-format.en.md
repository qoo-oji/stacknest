# StackNest Reference File (.stacknestbook) — Version 1

[日本語](book-reference-format.md) | **English**

This document is for authors of external viewers. It describes the reference file StackNest hands to a supported external viewer, and the API the viewer reads the book through.

## How it works

1. The user turns on "Sync Reading Position with StackNest (Supported Apps Only)" in StackNest and sets images to open in an external viewer.
2. Instead of the book's file, StackNest writes a **reference file** (extension `.stacknestbook`) and opens it in the external viewer. The viewer used is the one set for the book's own type for archives, folders and images, and the one set for archives for PDFs (local or remote) and image-only EPUBs from a remote library. A local EPUB isn't handed off by reference; it opens as a file as before.
3. The viewer fetches pages one at a time from the API named in the reference file, and writes back the page the reader reaches.

## Type

| Item | Value |
|---|---|
| Extension | `stacknestbook` |
| UTType | `app.shelfsmith.stacknest.book-reference` (conforms to `public.json`; exported by StackNest) |

A supporting viewer should import this type with `UTImportedTypeDeclarations` in its `Info.plist` and accept it as a document type with `CFBundleDocumentTypes` (it arrives in `application(_:open:)`).

## Contents (UTF-8 JSON)

```json
{
  "format": "stacknest-book-reference",
  "version": 1,
  "title": "Book Title",
  "book": "http://192.168.1.10:51234/api/v1/libraries/<lib-uuid>/books/<id>",
  "token": "<per-book token>",
  "expiresAt": "2026-10-31T12:00:00Z",
  "pageCount": 180,
  "direction": "rtl",
  "startPage": 41
}
```

| Key | Type | Meaning |
|---|---|---|
| `format` | string | Always `stacknest-book-reference`. Don't open the file if it differs |
| `version` | integer | Format version; this document is `1`. **Don't open the file if you can't read the value** |
| `title` | string | The book's title (for the window title and so on) |
| `book` | string (URL) | Base of the book's API; the four requests below are appended to it |
| `token` | string | A read token for this book only. Send it as `Authorization: Bearer <token>` |
| `expiresAt` | string (ISO 8601, UTC) | When the token expires (30 days after it was issued) |
| `pageCount` | integer | Page count when the book was opened (`manifest` is authoritative) |
| `direction` | `"rtl"` / `"ltr"` | Reading direction when the book was opened (`manifest` is authoritative) |
| `startPage` | integer (0-based) | Reading position when the book was opened. Open here |

- Ignore keys you don't know, so that later versions that add keys still open.
- For a book in a local library, `book` is `http://127.0.0.1:<port>/…` (an endpoint that listens on that Mac only). It works only while StackNest is running with the setting on, and its port can change. If the connection is refused, tell the reader to open the book from StackNest again.

## API

Send `Authorization: Bearer <token>` with every request.

| Request | Response |
|---|---|
| `GET {book}/manifest` | `{"pageCount": 180, "direction": "rtl", "format": "archive", "etag": "…"}` (ignore other keys). `format` is informational: `archive`, `folder`, `image`, or `text` (PDF and image-only EPUB). Read every book through `pages/{n}` regardless of it |
| `GET {book}/pages/{n}` | The image of page `n` (0-based): JPEG, PNG, WebP and so on (check `Content-Type`). Ask for a smaller image with `?maxw=<width>`. Responses carry an `ETag`, so `If-None-Match` can return 304 |
| `GET {book}/cover` | The cover image (`?maxw=` works too) |
| `POST {book}/progress` | Body `{"page": n}` (0-based) writes back the reading position. 200 |

- The token works for these four requests only. Any other URL or any other book is **403**.
- A **403** on the book's own URL that carries the header `X-Library-Locked: 1` means the library's lock changed after the file was made (its password was changed, or it was locked). Tell the reader to unlock the library in StackNest and open the book from StackNest again.
- **401** means the token expired (or was revoked). Tell the reader to open the book from StackNest again.
- **404** means the book is gone (removed from the library, or the server closed the library). For `pages/{n}`, a page number past the end is also **404**.
- `pages/{n}` returns **500** when a page can't be rendered, and `progress` returns **400** for a negative page.

## What we ask of viewers

- Open at `startPage`. If the viewer keeps its own reading position, prefer the reference file's `startPage`.
- Don't write back on every page turn; batch for a few seconds and send `progress`. Send it when the book is closed, too.
- The token is a secret. Don't log it or send it anywhere else (see Security notes below).
- Traffic is plain HTTP (StackNest is meant for a LAN or Tailscale). Allow plain HTTP to 127.0.0.1 and the LAN in App Transport Security, and if the viewer is sandboxed, give it the outgoing network (client) entitlement.

## Security notes

- The token is **plaintext** inside the reference file. StackNest writes the file with mode 600 (owner only) inside directories with mode 700. The token lasts 30 days. The viewer must not copy it elsewhere or log it.
- When the base in `book` is a plain `http://` address on a LAN, the token travels in cleartext. StackNest serves plain HTTP only. Over a plain LAN the token is not encrypted; using StackNest's remote connection over Tailscale encrypts it.
- The base may be an IPv6 literal (for example `http://[fe80::1%25en0]:51234/…`), so the viewer must parse bracketed hosts, including zone IDs.
- Send the token only to the origin (scheme, host and port) given by `book` in the file. Don't attach it to redirects or to any other host.

## Versions

| Version | Notes |
|---|---|
| 1 | This document (introduced in Phase G60) |

The full API is described in `/openapi.yaml` (`/docs`) served by the StackNest server.
