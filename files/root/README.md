# LibreChat

- アプリ: `/opt/librechat` (ユーザー `librechat`、UID 1000)
- サービス: `librechat.service` (:3080) / `mongodb.service` (127.0.0.1:27017)
- 設定: `/opt/librechat/librechat.yaml` (LLM エンドポイント) と `/opt/librechat/.env` (初回起動時に自動生成)
- データ: MongoDB dbPath `/var/lib/mongodb`、アプリのアップロード等 `/opt/librechat/data`

設定ファイルは `librechat` ユーザーが編集できる。サービス操作は sudo でパスワード不要。

## 1. 接続先 LLM の登録

`/opt/librechat/librechat.yaml` を編集する (初期値は例がコメントアウトされた状態)。

```yaml
version: 1.3.17

endpoints:
  custom:
    - name: "example"
      apiKey: "unused"
      baseURL: "http://llm.example.com:8080/v1"
      models:
        default:
          - example-model
        fetch: true
```

- `OPENAI_API_BASE` は v0.8.8 で廃止 (`.env` に書いても無視される)
- `baseOptions:` は無い。`baseURL` 直書き。`provider:` は anthropic 専用
- `models.default` は必須 (無いと黙ってフィルタで落ちる)。`fetch: true` で `/models` から一覧取得

## 2. 管理者アカウント作成

ブラウザで `http://localhost:3080` にアクセスして最初の登録を行うと、自動的に ADMIN になる。
CLI で作ることもできる (パスワードは対話、空欄なら自動生成):

```sh
cd /opt/librechat && npm run create-user -- admin@example.com "Admin" admin
```

## 3. Web Search 有効化 (任意)

`/opt/librechat/.env` に検索バックエンドを追記する (serper / searxng / tavily / keenable):

```
SEARXNG_INSTANCE_URL=http://searxng.example.com/search?q={query}
```

Exa は内蔵プロバイダに無いので MCP 経由。管理パネルの MCP 管理で:

```json
{ "type": "streamable-http", "url": "https://mcp.exa.ai/mcp?exaApiKey=<key>" }
```

## 4. 反映

```sh
sudo systemctl restart librechat
```

## 5. 状態確認

```sh
sudo systemctl status librechat mongodb
journalctl -u librechat -n 50
ls /opt/librechat/logs        # error-YYYY-MM-DD.log
```

- MongoDB のログ: `/var/log/mongodb/mongodb.log`
- `.env` の全オプションと説明: `/opt/librechat/.env.example`
- 管理パネルを使う場合は `.env` に `ADMIN_PANEL_URL` を設定する (例 `http://[::]:3080/admin`)
- `.env` の `HOST=::` が外部アクセスの前提 (既定の `localhost` だとループバック限定。
  デュアルスタックで IPv4 も受け付ける)。ホスト側では `vm run --hostfwd tcp::3080-:3080 ...` で
  アクセスする
- 実行保護 exec-guard が有効。状態は `grep exec_guard /var/log/genpack-init.log`、
  ブロックされた実行は `ausearch -k exec_guard_deny --input-logs` に残る

## 6. メモリ

2GB 割り当て (swap なし) での実測: node 431 MB (ピーク 496 MB) / mongod 180 MB /
VM 全体 used 729 MB・available 1217 MB。`free` の buff/cache はページキャッシュで回収される。
1ユーザーの通常利用なら 2GB で足りる。

ただし上限が宣言されていない箇所がある。小さい VM では宣言しておく:

```sh
# /etc/systemd/system/librechat.service の Environment= に追記
NODE_OPTIONS=--max-old-space-size=1024
```

```yaml
# /etc/mongodb.conf
storage:
    wiredTiger:
        collectionConfig:
            cacheSizeGB: 0.5
```

WiredTiger の既定キャッシュは `(RAM - 1GB) * 0.5 + 1GB` で、2GB では約 1.5GB になる
(今はデータが小さく 180MB しか使っていないだけ)。変更後は `sudo systemctl restart librechat mongodb`。

## 7. ストレージ

`/var/lib/mongodb` は 321MB だが、内訳はジャーナルの事前確保 (300MB) でデータは 7.6MB 程度。
実データは dataSize 1.8MB / storageSize 2.2MB / indexSize 3.7MB (messages 63 件)。

- `journal/` の 300MB (WiredTigerLog 100MB + WiredTigerPreplog ×2) は MongoDB 7 では縮小できない。
  データ量と無関係に載る固定コスト
- 保存量は素のテキストよりツール出力が効く (検索・取得系エージェントのツール結果がメッセージに保存される)
- WiredTiger は空き領域をファイルシステムへ返さない。削除で穴が残るので `db.compact()` 相当で戻す
- アップロードファイルは Mongo ではなく `/opt/librechat/data`。ログは `/var/log/mongodb` と
  `/opt/librechat/logs`
- 書き込み先 overlay は 960M 中 403M 使用 / 558M 空き。Mongo の 321MB が固定でのる

## 8. リバースプロキシ経由で公開する場合

`.env` の `HOST` はバインド、`DOMAIN_CLIENT` / `DOMAIN_SERVER` は外から見える URL。
公開する場合は初期値の `http://localhost:3080` を公開 origin に書き換える。

```
DOMAIN_CLIENT=https://chat.example.com
DOMAIN_SERVER=https://chat.example.com
TRUST_PROXY=1
```

- 認証系 (`/login` など) には same-origin ガードがあり、信頼 origin は `DOMAIN_CLIENT` /
  `DOMAIN_SERVER` / `ADMIN_PANEL_URL` だけ。合わないと 403 `Cross-site request rejected`
- プロキシは `Host` と `X-Forwarded-Proto` を転送する。`TRUST_PROXY` は既定 1 (最初のプロキシを信頼)
- `DOMAIN_SERVER` のホスト名が localhost 系だと `NODE_ENV=production` でも認証 cookie が
  non-secure になる (HTTPS 公開時は公開ホスト名にすること)
- passkey を使うなら公開前に最終ホストを決める。`PASSKEY_RP_ID` の既定が `DOMAIN_CLIENT` の
  ホスト名で、後から変えると既存 passkey が使えなくなる
- 変更後は `sudo systemctl restart librechat`

## 9. モバイルからアプリとして使う (iOS)

manifest と service worker は同梱済み (`/manifest.webmanifest`、`/sw.js`)。ホーム画面に追加すると
単独ウィンドウで起動する Web アプリになる。

Safari でサイトを開いて「…」→「共有」→「ホーム画面に追加」→「Web アプリとして開く」をオン→「追加」。
iOS 26 の既定レイアウト (Compact) では共有ボタンが「…」に統合されたため、この経路はワンタップ増える。
アドレスバー長押しから共有を出すこともできる。ツールバーに常時表示したい場合は
設定 > アプリ > Safari > タブ を Bottom または Top にする。

- 共有シートに「ホーム画面に追加」が無ければシート下部の「動作を編集」で有効化する
- HTTPS 前提 (プロキシまたはトンネル側で HTTPS 終端)
- アプリ名は manifest に焼き込まれた "LibreChat" で、`APP_TITLE` は効かない

## 10. MCP サーバーの権限

既定で一般ユーザー (USER ロール) は MCP サーバーを「使える」が「追加できない」。追加 UI が出ないのは仕様。

- 一般ユーザーに使わせるには ADMIN がサーバー単位で共有する (全員共有可)
- ロール全体で追加権限を開けるなら管理パネルのロール編集で `MCP_SERVERS` の CREATE を有効にする
  (`.env` に `ADMIN_PANEL_URL` が必要)
- 共通サーバーを管理者定義として配るなら `/opt/librechat/librechat.yaml` のトップレベル `mcpServers` でも定義できる

### リクエスト主の情報を受け渡す

stdio サーバーはユーザーごとに別プロセスで起動するので、`env` と `args` に `{{LIBRECHAT_USER_ID}}`
などのプレースホルダを書けばそのユーザーの情報が入る。

```yaml
mcpServers:
  mydata:
    type: stdio
    command: /usr/bin/python3
    args:
      - /opt/librechat/mcp/mydata.py
      - '--user-id'
      - '{{LIBRECHAT_USER_ID}}'
    env:
      LIBRECHAT_USER_ID: '{{LIBRECHAT_USER_ID}}'
    timeout: 130000
```

- env と args はどちらか片方でよい。引数は `ps` で見える、env は同じ UID と root だけ。
  秘密値は env、識別子はどちらでも可
- サーバー側は両方受け付けて (引数優先、無ければ env) どちらで渡すかはコンフィグを書く側が決める
- env に定数を書くと全ユーザー共通の値になる。ユーザーごとに違えるものはプレースホルダで書く
  (`MAIL_TO: '{{LIBRECHAT_USER_EMAIL}}'`, `MEMORY_KEY: '{{LIBRECHAT_USER_ID}}'`)
- tool call の既定タイムアウトは 60 s。外部 API を長く待つサーバーは `timeout` を上げておく
- UI から追加したサーバーではプレースホルダが解決されない。ユーザー識別を渡すなら yaml 定義が必須

## 11. API 鍵の投入 (keyring)

MCP サーバーなどに渡す API 鍵はファイルシステムに置かず、UID keyring に入れる。

```sh
su - librechat
register-keyring-key xai_api_key other_service_api_key
```

- 鍵ごとにエコーバックなしで入力する。登録済みなら先頭 4 文字だけをマスク表示し、空 Enter で既存を保持して次へ進む
- 投入先は実行したユーザーの UID keyring (`@u`)。LibreChat が読む鍵は `su - librechat` して投入する
  (root で投入すると root の UID keyring に入り uid 1000 からは見えない)
- keyring はディスクに永続化されない。再起動後、または uid 1000 のプロセスが全て消えた後は再投入が必要
- 確認は `keyctl search @u user xai_api_key`。中身を出す `keyctl print` は避ける
- LibreChat が鍵を読めるのは `librechat.service` に `KeyringMode=shared` がある場合だけ。
  無いとサービス側は `keyctl search @u` こそ通るが `keyctl print` は Permission denied になる
