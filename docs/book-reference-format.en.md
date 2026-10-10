# StackNest Reference File (.stacknestbook) — Version 1

[日本語](book-reference-format.md) | **English**

This document is for authors of external viewers. It describes how a viewer declares support, the reference file StackNest hands to a supported external viewer, and the API the viewer reads the book through.

## How it works

1. The user turns on "Sync Reading Position with StackNest (Supported Apps Only)" in StackNest and sets images to open in an external viewer.
2. Only when that viewer declares support in its `Info.plist` (see [Declaring support](#declaring-support)), StackNest writes a **reference file** (extension `.stacknestbook`) instead of the book's file and opens it in the external viewer. The viewer used is the one set for the book's own type for archives, folders and images, and the one set for archives for PDFs (local or remote) and image-only EPUBs from a remote library. A local EPUB isn't handed off by reference; it opens as a file as before.
3. The viewer fetches pages one at a time from the API named in the reference file, and writes back the page the reader reaches. Every request carries the viewer's identification (see [Identification header](#identification-header)).
4. A while after the hand-off (15 seconds by default), StackNest checks once whether the token was used (see [Checking that the book was loaded](#checking-that-the-book-was-loaded)).

## Declaring support

**This declaration is required.** A supporting viewer puts this key in its `Contents/Info.plist`:

```xml
<key>StackNestViewerSupport</key>
<dict>
  <key>referenceFormatVersions</key>
  <array><integer>1</integer></array>
</dict>
```

- List the reference file versions the viewer can read in `referenceFormatVersions`, as integers. StackNest picks the **highest version both sides support** (StackNest writes `1` today) and puts it in the file's `version`. A viewer that declares `[1, 2]` gets version 2 once StackNest can write it, and version 1 until then.
- Before the hand-off, StackNest reads the viewer's `Info.plist` directly (it doesn't rely on LaunchServices or any cache). In any of these cases the viewer counts as unsupported: StackNest issues no token, writes no reference file, and hands the book over as before (a local book as the file, a remote book in StackNest's built-in viewer).
  - The key is missing, isn't a `dict`, or its `referenceFormatVersions` isn't an array
  - No version is supported by both sides
- Elements that aren't integers (booleans, reals, strings) and values of 0 or less are ignored.
- Declaring that the viewer opens the reference file type (`CFBundleDocumentTypes`, UTType) is **not used to decide support**, so that an app that claims to open any file isn't mistaken for a supporting viewer.

## Type

| Item | Value |
|---|---|
| Extension | `stacknestbook` |
| UTType | `app.shelfsmith.stacknest.book-reference` (conforms to `public.json`; exported by StackNest) |

To accept the reference file as a document, import this type with `UTImportedTypeDeclarations` in the viewer's `Info.plist` and accept it as a document type with `CFBundleDocumentTypes` (it arrives in `application(_:open:)`). StackNest names the app when it opens the file, so a rank (`LSHandlerRank`) of `Alternate` is enough. This is for how the file looks in the Finder and for receiving it; support itself is decided by the declaration above.

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
| `version` | integer | Format version, chosen by StackNest from the versions the viewer declares (this document is `1`). **Don't open the file if you can't read the value** |
| `title` | string | The book's title (for the window title and so on) |
| `book` | string (URL) | Base of the book's API; the four requests below are appended to it |
| `token` | string | A read token for this book only. Send it as `Authorization: Bearer <token>` |
| `expiresAt` | string (ISO 8601, UTC) | When the token expires (30 days after it was issued) |
| `pageCount` | integer | Page count when the book was opened (`manifest` is authoritative) |
| `direction` | `"rtl"` / `"ltr"` | Reading direction when the book was opened (`manifest` is authoritative) |
| `startPage` | integer (0-based) | Reading position when the book was opened. Open here |

- Ignore keys you don't know, so that later versions that add keys still open.
- For a book in a local library, `book` is `http://127.0.0.1:<port>/api/v1/libraries/<lib>/books/<id>` (an endpoint that listens on that Mac only).
- **For a book in a remote library, `book` is also on 127.0.0.1: `http://127.0.0.1:<port>/api/v1/relay/<relayID>`** (trial). StackNest relays the requests it receives there to the remote server. Measured: a sandboxed viewer under `NSAllowsLocalNetworking` can reach loopback and private-range addresses, but App Transport Security blocks plain HTTP to Tailscale addresses (100.64.0.0/10) and public addresses. That is why StackNest relays remote books, so the viewer only ever connects to 127.0.0.1 on its own Mac. The four requests below are the same as for a local book, and the viewer doesn't need to tell the two forms of `book` apart. The remote server's token never reaches the viewer (the file's `token` is the relay's own token, and `expiresAt` is the earlier of 30 days after issue and the remote token's expiry).
- The endpoint works only while StackNest is running with the setting on, and its port can change. If the connection is refused, tell the reader to open the book from StackNest again. Quitting StackNest drops its relays, so later requests get **401** (so does an expired relay; again, tell the reader to open the book from StackNest again). A relayed request gets **502** when the remote server can't be reached, the response is too large, or it redirects. A relayed `progress` body over 64 KiB gets **413** and is not forwarded. Other remote responses (including 403, 404 and `X-Library-Locked`) are passed through unchanged. When the remote server refuses the relay with **401 or 403** (a changed password, revoked access and so on), StackNest passes that response through and closes the relay, so later requests get **401**, even for pages it has cached (tell the reader to open the book from StackNest again).
- When relaying, `pages/{n}` without `maxw` (or with `maxw=1600`) returns the same image StackNest's built-in viewer gets: a page wider than 1600 pixels is scaled down so its longest side is at most 1600 pixels and re-encoded as JPEG, PNG and WebP pages included (the original size and format are not available; check `Content-Type`). StackNest keeps relayed pages in its local cache, shares them with the built-in viewer, and after the hand-off prefetches the pages around the one being read (or every page, depending on StackNest's settings) in the background. These responses carry no `ETag`, so fetch them again without `If-None-Match` (they come from the cache, so it's fast). Any other `maxw` is forwarded to the remote server as before.

## API

Send `Authorization: Bearer <token>` and the [identification header](#identification-header) with every request.

| Request | Response |
|---|---|
| `GET {book}/manifest` | `{"pageCount": 180, "direction": "rtl", "format": "archive", "etag": "…"}` (ignore other keys). `format` is informational: `archive`, `folder`, `image`, or `text` (PDF and image-only EPUB). Read every book through `pages/{n}` regardless of it |
| `GET {book}/pages/{n}` | The image of page `n` (0-based): JPEG, PNG, WebP and so on (check `Content-Type`). Ask for a smaller image with `?maxw=<width>`. When the response carries an `ETag`, `If-None-Match` can return 304 (relayed pages may come without one) |
| `GET {book}/cover` | The cover image (`?maxw=` works too) |
| `POST {book}/progress` | Body `{"page": n}` (0-based) writes back the reading position. 200 |

- The token works for these four requests only. Any other URL or any other book is **403**.
- A **403** on the book's own URL that carries the header `X-Library-Locked: 1` means the library's lock changed after the file was made (its password was changed, or it was locked). Tell the reader to unlock the library in StackNest and open the book from StackNest again.
- **401** means the token expired (or was revoked). It is also 401 when, after the token was issued, the book's number was taken by a different book (the book was removed and another one was added). Tell the reader to open the book from StackNest again.
- **404** means the book is gone (removed from the library, or the server closed the library). For `pages/{n}`, a page number past the end is also **404**.
- `pages/{n}` returns **500** when a page can't be rendered, and `progress` returns **400** for a negative page.

## Identification header

**This header is required.** Send it with every request to the book's API:

```
X-StackNest-Viewer: <bundle id>/<viewer version>; format=<reference file version>
```

Example: `X-StackNest-Viewer: com.example.viewer/1.80; format=1`

- `<viewer version>` is the version the user sees, such as `CFBundleShortVersionString`. Put the opened file's `version` in `format=`.
- StackNest doesn't refuse a request without it. The first time the token is used, StackNest records the time and this header's value once (printable ASCII only, cut at 200 characters). Settings ▸ View ▸ External Viewer uses the record to show which viewer has been confirmed to work (with the date and version).

## Checking that the book was loaded

- A while after the hand-off (15 seconds by default), StackNest checks once whether the token was used, from the records of its own 127.0.0.1 endpoint, for local books and relayed remote books alike. (Only in the form that connects to the remote server directly instead of relaying does it check through the status API, `GET /api/v1/viewer-tokens/{tokenID}`, from the connection that issued the token.)
- For a relay token, "used" means the viewer **reached** the 127.0.0.1 endpoint with a valid relay token, not that it loaded a page (it is recorded even if the remote answers 502, as soon as a request such as `manifest` arrives). A relay token's record carries no real library or book but a sentinel identity (library `"relay"`, book 0); viewers needn't care.
- If it wasn't used yet, StackNest tells the reader that the app hasn't loaded the book and offers a button to open it the usual way (a local book as the file, a remote book in the built-in viewer). The token isn't revoked, so a viewer that starts late still works.
- When you receive a reference file, fetch `manifest` first, so the open is noticed early.

## What we ask of viewers

- Open at `startPage`. If the viewer keeps its own reading position, prefer the reference file's `startPage`.
- Don't write back on every page turn; batch for a few seconds and send `progress`. Send it when the book is closed, too.
- Send the [identification header](#identification-header) with every request.
- The token is a secret. Don't log it or send it anywhere else (see Security notes below).
- Traffic is plain HTTP (StackNest is meant for a LAN or Tailscale). Allow plain HTTP to 127.0.0.1 and the LAN in App Transport Security, and if the viewer is sandboxed, give it the outgoing network (client) entitlement.

## Security notes

- The token is **plaintext** inside the reference file. StackNest writes the file with mode 600 (owner only) inside directories with mode 700. The token lasts 30 days. The viewer must not copy it elsewhere or log it.
- When the base in `book` is a plain `http://` address on a LAN, the token travels in cleartext. StackNest serves plain HTTP only. Over a plain LAN the token is not encrypted; using StackNest's remote connection over Tailscale encrypts it. When remote books are relayed (the trial default), the viewer's traffic stays within 127.0.0.1, and the hop between StackNest and the remote server takes the same path as StackNest's remote connection.
- The base may be an IPv6 literal (for example `http://[fe80::1%25en0]:51234/…`), so the viewer must parse bracketed hosts, including zone IDs.
- Send the token only to the origin (scheme, host and port) given by `book` in the file. Don't attach it to redirects or to any other host.
- Only the principal that issued a token can read whether it was used (`GET /api/v1/viewer-tokens/{tokenID}`). But when the shared server runs with a fixed token (no grants), principals can't be told apart, so every connection holding that token can read the use status (the time and the identification header only) of per-book tokens issued with it. On the 127.0.0.1 endpoint with Local Control on, the CLI and MCP token can read the status of tokens the app issued. Either way only the identification header's value is visible, never the book or the token.

## Versions

| Version | Notes |
|---|---|
| 1 | This document (introduced in Phase G60) |

A viewer declares the versions it reads in `referenceFormatVersions`, and StackNest writes the highest version both support. When a later version adds keys, a viewer that declares only version 1 still gets version 1.

The full API is described in `/openapi.yaml` (`/docs`) served by the StackNest server.
