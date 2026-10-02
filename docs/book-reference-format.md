# StackNest の参照ファイル（.stacknestbook）— 版 1

**日本語** | [English](book-reference-format.en.md)

外部ビューアの作者向けの文書です。StackNest が対応した外部ビューアへ本を渡すときの、参照ファイルの形式と API の約束を書きます。

## 流れ

1. 利用者が StackNest で「StackNest と読書位置を同期する（対応アプリのみ）」を ON にし、画像の本を外部ビューアで開く設定にする。
2. StackNest は、そのビューアがこの型を宣言しているときだけ（[型](#型)の「この宣言は必須です」を参照）、本のファイルの代わりに **参照ファイル**（拡張子 `.stacknestbook`）を書き、外部ビューアで開く。開くビューアは、アーカイブ・フォルダ・画像の本ではそれぞれの種類の指定、PDF（ローカル・リモートとも）とリモートの画像だけの EPUB では「アーカイブ」の指定（ローカルの EPUB は参照ファイルを使わず、従来どおりファイルで開く）。
3. ビューアは参照ファイルに書かれた API から、ページを 1 枚ずつ取って表示し、読み進めたページを書き戻す。

## 型

| 項目 | 値 |
|---|---|
| 拡張子 | `stacknestbook` |
| UTType | `app.shelfsmith.stacknest.book-reference`（`public.json` に適合。StackNest が宣言する） |

対応するビューアは、この型を `Info.plist` の `UTImportedTypeDeclarations` で取り込み宣言し、`CFBundleDocumentTypes` で書類の種類として受け付けてください（`application(_:open:)` に届きます）。

**この宣言は必須です。** StackNest は参照ファイルを渡す前に、そのビューアの `Info.plist` を直接読み、`CFBundleDocumentTypes` のいずれかの項目が `LSItemContentTypes` に UTType（`app.shelfsmith.stacknest.book-reference`）を持つか、`CFBundleTypeExtensions` に拡張子（`stacknestbook`。大文字小文字は区別しない）を持つかを確かめます。宣言が無いアプリには参照ファイルを渡さず、従来どおり本を渡します（ローカルの本はファイルのまま、リモートの本は StackNest の内蔵ビューアで開きます）。

## 中身（UTF-8 の JSON）

```json
{
  "format": "stacknest-book-reference",
  "version": 1,
  "title": "本の題名",
  "book": "http://192.168.1.10:51234/api/v1/libraries/<lib-uuid>/books/<id>",
  "token": "<本専用のトークン>",
  "expiresAt": "2026-10-31T12:00:00Z",
  "pageCount": 180,
  "direction": "rtl",
  "startPage": 41
}
```

| 項目 | 型 | 意味 |
|---|---|---|
| `format` | 文字列 | 常に `stacknest-book-reference`。違えば開かない |
| `version` | 整数 | 形式の版。この文書は `1`。**読めない値なら開かない** |
| `title` | 文字列 | 本の題名（窓の題名などに使う） |
| `book` | 文字列（URL） | 本の API の基点。下の 4 つの API はこれに続ける |
| `token` | 文字列 | その本専用の読み取りトークン。`Authorization: Bearer <token>` で渡す |
| `expiresAt` | 文字列（ISO 8601・UTC） | トークンの有効期限（発行から 30 日） |
| `pageCount` | 整数 | 開いた時点のページ数（正は `manifest`） |
| `direction` | `"rtl"` / `"ltr"` | 開いた時点の読む方向（正は `manifest`） |
| `startPage` | 整数（0 始まり） | 開いた時点の読書位置。ここから開く |

- 知らない項目は読み飛ばしてください（後の版で項目が増えても開けるように）。
- ローカルの書庫の本では `book` が `http://127.0.0.1:<port>/…` になります（その Mac の中だけで待ち受ける口）。この口は StackNest が起動していて設定が ON のあいだだけ動き、ポートも変わることがあります。接続を拒まれたら、「StackNest から開き直してください」と表示してください。

## API

すべて `Authorization: Bearer <token>` を付けます。

| 要求 | 応答 |
|---|---|
| `GET {book}/manifest` | `{"pageCount": 180, "direction": "rtl", "format": "archive", "etag": "…"}`（ほかの項目は読み飛ばす）。`format` は参考情報で、値は `archive`・`folder`・`image`・`text`（PDF と画像だけの EPUB）。どの値でも `pages/{n}` で同じように読んでください |
| `GET {book}/pages/{n}` | `n` 番目（0 始まり）のページの画像（JPEG・PNG・WebP など。`Content-Type` を見る）。`?maxw=<幅>` で縮小を頼める。`ETag` を返すので `If-None-Match` で 304 を受けられる |
| `GET {book}/cover` | 表紙の画像（`?maxw=` 可） |
| `POST {book}/progress` | 本文 `{"page": n}`（0 始まり）で読書位置を書き戻す。200 |

- このトークンで使えるのは上の 4 つだけです。ほかの URL・ほかの本は **403** です。
- 自分の本への **403** でも、ヘッダ `X-Library-Locked: 1` が付いているときは、参照ファイルを作った後に書庫のロックが変わった（パスワードを変えた、または施錠した）ことを表します。「StackNest で書庫を解錠し、StackNest から開き直してください」と表示してください。
- **401** はトークンの期限切れ（または取り消し）です。「StackNest から開き直してください」と表示してください。
- **404** は本が見つからない（書庫から消えた、サーバが書庫を閉じた）ことを表します。`pages/{n}` では範囲外のページ番号も **404** です。
- `pages/{n}` でページを描画できないときは **500**、`progress` に負のページを送ると **400** です。

## ビューアへのお願い

- `startPage` から開いてください。ビューア自身の読書位置の記録があっても、参照ファイルの `startPage` を優先してください。
- ページを移るたびに書き戻すのではなく、数秒まとめて `progress` に送ってください。閉じるときにも送ってください。
- トークンは秘密です。ログに出さず、ほかへ送らないでください（詳しくは下の「セキュリティ上の注意」）。
- 通信は HTTP です（LAN か Tailscale での利用を前提にしています）。App Transport Security で 127.0.0.1 と LAN への平文 HTTP を許可し、App Sandbox を使うならネットワーク（クライアント）の権限を付けてください。

## セキュリティ上の注意

- トークンは参照ファイルの中に**平文**で入っています。StackNest は参照ファイルを権限 600（本人だけ読める）、置き場のディレクトリを 700 で書きます。有効期限は 30 日です。ビューアはトークンをほかの場所へ写さず、ログにも出さないでください。
- `book` の基点が LAN 上の `http://` のアドレスのとき、トークンは暗号化されずに流れます。StackNest は HTTP だけを提供します。素の LAN では暗号化されないので、Tailscale 越しの StackNest のリモート接続を使うと通信が暗号化されます。
- 基点には IPv6 のアドレスが入ることがあります（例: `http://[fe80::1%25en0]:51234/…`）。ビューアは角括弧で囲まれたホスト（ゾーン ID を含む）を解釈できるようにしてください。
- トークンは参照ファイルの `book` が指すオリジン（スキーム・ホスト・ポート）にだけ送ってください。リダイレクト先や別のホストへ付けて送らないでください。

## 版の扱い

| 版 | 内容 |
|---|---|
| 1 | この文書（Phase G60 で導入） |

API の詳しい仕様は StackNest のサーバが配る `/openapi.yaml`（`/docs`）にあります。
