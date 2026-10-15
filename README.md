# librechat

[LibreChat](https://github.com/danny-avila/LibreChat) (セルフホスト LLM チャット UI) の paravirt アーティファクト。

## 構成

- ソース: リリースタグ `v0.8.8` のシャロークローンを `/opt/librechat` に配置
- ビルド: `npm ci` → `npm run frontend` (packages 群 + client の vite ビルド) → `npm prune --omit=dev`
  - backend は実行時に `node_modules` を要する (フロントと違い削除不可)。`--omit=dev` までが安全
  - node は実行時も必要なので `packages` 側 (`net-libs/nodejs`)。package.json に engines 制限はなく 26 系で検証済み
- 外部サービス: MongoDB のみ。meilisearch 不要 (`NO_INDEX=true` 既定)、rag-api (Python) は任意
  (無いとファイルアップロード RAG だけ警告付きでオフ)
- MongoDB: Portage の `dev-db/mongodb` 7 系 (amd64 安定。8 系は `~amd64` で accept_keywords 追加要)。
  ebuild 同梱の `mongodb.service` を `services` で有効化。dbPath `/var/lib/mongodb` は build.d で作成する
  (ebuild は `/var/log/mongodb` しか作らない)。DB の事前投入は不要で mongoose が初回接続時に作成する
- 設定: `/opt/librechat/librechat.yaml` (build.d 前にコピーされるテンプレート。エンドポイント例は
  コメントアウト済み。`version` は v0.8.8 対応の `1.3.17`。古い値だと起動時に
  "Outdated Config version" 警告が出る) と
  `/opt/librechat/.env` (初回起動時に `gen-env.sh` が生成。永続シークレット込み)
- 実行: `librechat.service` が `node api/server/index.js` を :3080 で起動 (User=librechat)
- 権限: 初回登録ユーザーは自動的に ADMIN (`api/server/services/AuthService.js:416`)。
  `npm run create-user` でも作成可。旧 `ADMIN_USER_IDS` は廃止で、権限は DB ロール体系
  (`librechat.yaml` の grant で `interface.webSearch` 等を初期設定できる。UPGRADING.md 参照)
- 実行保護: genpack-init の exec-guard を有効化 (ref: exec-guard)。upper layer に持ち込まれた
  ELF バイナリ・共有ライブラリの exec / dlopen を eBPF LSM でブロックし、ブロック分を audit に
  `exec_guard_deny` として残す。`/usr` は read-only bind mount になる

## ビルド

```sh
genpack build
```

## 起動後

- バインドは `.env` の `HOST=::` (node はデュアルスタックでバインドし IPv4 も受け付ける)。
  LibreChat の既定 `localhost` だとループバックにしか listen せず VM 外から到達できない。
  IPv4 限定は `0.0.0.0`、ループバック限定は `localhost`
- VM 外からは `vm run --hostfwd tcp::3080-:3080 ...` でアクセスする (既定の NIC が user モード。
  SLIRP 経由なので到達は IPv4 になる)
- 既存データパーティションの古い `.env` (HOST 行が無いもの) には、起動時に `gen-env.sh` が
  `HOST=::` を追記する (HOST 行を明示している場合はユーザーの判断とみなして触らない)
- イメージ内に `/root/README.md` として初期設定手順 (LLM エンドポイント登録 → 管理者作成 →
  Web Search 設定 → 反映 → 状態確認) が入っている。

## 検証済みの設定上の要点 (v0.8.8)

- 自前 LLM エンドポイントは `librechat.yaml` の
  カスタムエンドポイントで登録する。`baseOptions:` は無く `baseURL` 直書き、`provider:` は anthropic 専用、
  `models.default` は必須 (無いと黙ってフィルタで落ちる)
- 単一レプリカ構成では `.env` に `SCHEDULES_SINGLE_PROCESS=true` が必須 (無いと schedules 機能が 503)
- Web Search / Fetch は標準 capability だが検索バックエンドの指定が要る
  (searchProvider: serper / searxng / tavily / keenable、scraperProvider: firecrawl / serper / tavily / keenable)。
  `.env` の `SEARXNG_INSTANCE_URL` 等または管理パネルで設定
- Exa は内蔵プロバイダに無い → MCP 経由 (`{ "type": "streamable-http", "url": "https://mcp.exa.ai/mcp?exaApiKey=..." }`)。
  MCP サーバー定義は DB 管理 (管理パネルの MCP 管理)。
- `CREDS_KEY` / `CREDS_IV` / `JWT_SECRET` / `JWT_REFRESH_SECRET` 未設定時は `.env.temp` に一時生成され
  再起動でセッション失効する。このアーティファクトでは初回起動時に `.env` へ固定値を書き出して永続化する

## sudoers

`librechat` ユーザーは `app-admin/sudo` と `files/etc/sudoers.d/librechat` により、
パスワードなしで `systemctl restart|status librechat` / `restart|status mongodb` を実行できる。

- sudoers drop-in はモード 0440 が必須。git は 0440 を保持できないので `files/build.d/librechat.sh` で
  `chmod 0440` と `visudo -cf` を行う
- sudo 既定の `/etc/sudoers` には `#includedir /etc/sudoers.d` が入っていない
  (upstream の `examples/sudoers.in` に無い) ため、build.d で追記する

## 注意

- mongodb-7.0.28 のビルドには `dev-python/pkg-resources` が要る (buildtime_packages)。
  SConstruct が `from pkg_resources import parse_version` を使うのに ebuild の BDEPEND に無い
  (setuptools 81 で pkg_resources が別パッケージへ分離されたため)。無いと
  `ModuleNotFoundError: No module named 'pkg_resources'` で compile フェーズが落ちる。
  8 系は `dev-python/packaging` を BDEPEND に持つのでこの問題は無い。
  これは宣言依存ではないので一括 emerge では順序が保証されず、
  `buildtime_packages_first: true` で先行パスに焼く (genpack ADR-0003 の clang-kernel と同型)
- `npm prune --omit=dev` で実行時依存が欠ける場合は prune を外す (node_modules は 2GiB 前後)
- `ADMIN_PANEL_URL` の有効化は運用方針次第 (`.env` でコメント解除)。設定時は
  `ADMIN_PANEL_SESSION_SECRET` も設定する
- `librechat` ユーザーのシェルは `/bin/bash` (設定編集・サービス再起動をこのユーザーで行う運用)。
  root 編集厳格運用なら `nologin` に変える
- 版本は Portage 安定版優先。mongodb は `=dev-db/mongodb-7*` でピン留めしている
- exec-guard の有効確認は `/var/log/genpack-init.log` の `exec_guard: active.` 行、または
  `/sys/fs/bpf/exec_guard/` にリンクがあるか。ブロックログは
  `ausearch -k exec_guard_deny --input-logs`。無効化は boot パーティションの `system.ini` に
  `exec_guard = false`
- 実行時に任意バイナリを持ち込んで走らせる運用は採らない (exec-guard でブロックされる)。
  使いたい CLI や stdio MCP サーバーは `packages` 経由で lower に入れておく
- コンテキストウィンドウ表示の分母は LibreChat 内蔵のモデル別テーブル (packages/api/src/utils/tokens.ts)
  から決まる。テーブルキーは部分一致の最長キーで選ばれ (`findLongestKey`)、自前ホストのモデル名が
  別モデルのキーに引っ掛かると実ウィンドウと無関係な値になる (例: `*-flash` 系のキーが
  1,000,000 で当たり、5% リザーブが二段適用 (initialize.ts の `DEFAULT_RESERVE_RATIO` と
  @librechat/agents の pruning) されて 902,500 表示になった)。llama.cpp などの `n_ctx` は
  参照されず、実ウィンドウより大きく見える。実値に寄せるなら `endpoints.custom[].tokenConfig`
  の `context` で宣言する (内蔵テーブルより優先、tokens.ts:731-736)。会話単位なら
  `maxContextTokens` (UI、URL の `?maxContextTokens=250000`、または `modelSpecs[].preset`)
  で上書きする。env 変数や
  endpoints 直下の別の設定では上書きできない
- URL からチャットを開始できる: `?q=` または `?prompt=` (優先) で入力欄に流し込み、
  `&submit=true` で即送信 (client/src/hooks/Input/useQueryParams.ts:209)。設定パラメータも
  `tQueryParamsSchema` の範囲で渡せる (`model`, `spec`, `endpoint`, `agent_id`, `promptPrefix`,
  `temperature` 等)。既定で自動送信が許容されているので、閉じるなら `librechat.yaml` の
  `interface: { autoSubmitFromUrl: false }`
- LibreOffice 連携 (docx / pptx プレビューの soffice 変換) は v0.8.8 で一時的に停止中
  (PR #16583 / commit 9f1256e、2026-10-01。`IN_PROCESS_LIBREOFFICE_DISABLED = true`、
  packages/api/src/files/documents/libreoffice.ts:73)。理由の記載はなく breaking change として扱われ、
  docx-preview / mammoth / slide-list 等の代替経路にフォールバックする。
  `.env` に `OFFICE_PREVIEW_LIBREOFFICE` を書いても soffice は呼ばれないので同梱しない。
  再有効化の動き (fork 側 PR aproorg/LibreChat#88、2026-10-07) を確認してから
  `app-office/libreoffice` を `packages` に足す (ヘッドレス変換に X/Wayland は不要。
  実装は `--norestore --invisible --nodefault` に呼び出しごとの `-env:UserInstallation` 一時プロファイル、
  env は PATH/HOME/TMPDIR のみ、30s タイムアウト、50MB 上限。soffice は /usr 由来なので exec-guard と相容れる)

## メモリ

2GB 割り当ての VM (swap なし) での実測。稼働開始後通常チャット利用時:

| 対象 | RSS | ピーク |
| --- | --- | --- |
| librechat (node) | 431 MB | 496 MB |
| mongodb (mongod) | 180 MB | 180 MB |
| VM 全体 | used 729 MB / available 1217 MB | |

`free` の buff/cache 815 MB はページキャッシュ (SquashFS 由来の読み込みを含む) で回収される。
1ユーザーの通常利用なら 2GB で足りる。ただし上限を宣言していない箇所がある:

- WiredTiger キャッシュは `/etc/mongodb.conf` に指定がなく、既定式 `(RAM - 1GB) * 0.5 + 1GB` で
  2GB では約 1.5GB まで膨張し得る。現状はデータが小さく 180MB しか使っていないだけで、
  負荷が上がると node と競う
- node は `NODE_OPTIONS` 未指定。swap なしでは V8 の GC より先に OOM killer に触れる形になる
- 低メモリ運用なら `librechat.service` の `Environment=` に
  `NODE_OPTIONS=--max-old-space-size=1024`、`/etc/mongodb.conf` に
  `storage.wiredTiger.collectionConfig.cacheSizeGB: 0.5` を宣言して固定するのが素直
- コンテキストウィンドウの実値を `tokenConfig` で宣言しておくと (上の項)、巨大なプロンプト
  組み立てを未然に防いでメモリ側にも効く

## ストレージ

2GB VM での実測。MongoDB dbPath は 321MB に見えるが、内訳はジャーナルの事前確保:

| 内訳 | 使用 |
| --- | --- |
| `journal/` (WiredTigerLog 100MB + WiredTigerPreplog ×2) | 300 MB |
| collection / index 等の `.wt` 合計 | 7.6 MB |
| 実データ (db.stats) | dataSize 1.8 MB / storageSize 2.2 MB / indexSize 3.7 MB (messages 63 件) |

- 300MB のジャーナルは MongoDB 7 では縮小できない (mongod に prealloc 系のオプションが無く、
  journal 無効化は 5.0 で廃止)。データ量と無関係に載る固定コストとして見る
- 保存量は素のテキストよりツール出力が効く。実測で messageTokens 27,480 に対し
  toolMessageTokens 26,636 (検索・取得系エージェントでは保存量が倍近いペースで増える)
- WiredTiger は空き領域をファイルシステムへ返さない。削除で穴が残るので `db.compact()` 相当で戻す
- アップロードファイルは Mongo ではなく `/opt/librechat/data`。ログは `/var/log/mongodb` と
  `/opt/librechat/logs`
- 実際の制約は overlay (実測 960M 中 403M 使用 / 558M 空き)。Mongo の 321MB が固定でのるため
  overlay を詰めると最初に詰まるのはここ

## リバースプロキシ経由で公開する

`HOST` はバインドの話で、`DOMAIN_CLIENT` / `DOMAIN_SERVER` は「外からどう見えるか」の話。
生成される `.env` は両方 `http://localhost:3080` なので、プロキシ経由で公開するなら公開 origin
(例 `https://chat.example.com`) に書き換える。

- 認証系エンドポイント (`/login`、`/2fa/verify-temp`、`/passkey/login/verify`、登録・パスワードリセット、
  admin 認証) に same-origin ガードがある (api/server/routes/auth.js:73,156,188 →
  packages/api/src/middleware/origin.ts:65-87)。信頼 origin は `DOMAIN_CLIENT` / `DOMAIN_SERVER` /
  `ADMIN_PANEL_URL` だけ (api/server/middleware/requireSameOrigin.js:5-7) で、外すための env は無い。
  合わないと 403 `Cross-site request rejected`
- ガードは `req.protocol` と `Host` も見る。プロキシは `Host` と `X-Forwarded-Proto` を転送し、
  `TRUST_PROXY` (既定 1 = 最初のプロキシを信頼、api/server/index.js:104,205) を実構成に合わせる
- 認証 cookie は `sameSite: 'strict'` (api/server/services/AuthService.js:726-737)。`secure` は
  `SESSION_COOKIE_SECURE` 未指定時「`NODE_ENV=production` かつ `DOMAIN_SERVER` のホスト名が
  localhost 系でない」で true (packages/api/src/oauth/csrf.ts:21-47)。scheme ではなくホスト名で
  決まるので、`DOMAIN_SERVER` を `localhost` に残したまま HTTPS 公開すると cookie が non-secure のまま
- passkey を使うなら `PASSKEY_RP_ID` の既定は `DOMAIN_CLIENT` のホスト名。後からホスト名を変えると
  既存 passkey は使えなくなる (`.env.example` の PASSKEY 節)。公開前に最終ホストを決める
- Origin / Sec-Fetch-Site を持たないリクエストはガードを素通しする (origin.ts:49-52)。
  API や CLI 経由の運用は origin 設定の影響を受けない
- same-origin ガードは login CSRF に対する二重壁。cookie が `sameSite: strict` で守られている既定構成では
  ブラウザ側が既にクロスサイトの `Set-Cookie` を弾くため、ガード自体は無くても動いてしまう。
  `SESSION_COOKIE_SECURE=false` や平文 HTTP など cookie が緩む構成では唯一の防御になる

## MCP サーバーの権限

- 既定で USER ロールは MCP サーバーを「使える」が「追加できない」 (`MCP_SERVERS` の USE=true /
  CREATE=false、packages/data-provider/src/roles.ts:256-262)。2 人目以降のユーザーに追加 UI が出ない
  のは仕様で、ナビの追加項目は CREATE 側でゲートされている (client/src/hooks/Nav/useSideNavLinks.ts:84-90)
- 一般ユーザーに使えるようにする運用は ADMIN 側でサーバー単位共有 (全員共有可) が素直。
  サーバー単位の effective permissions で USE が通る (client/src/hooks/MCP/useMCPServerManager.ts:124-141)
- ロール全体で CREATE を開けるなら管理パネルのロール編集
  (`PUT /api/admin/roles/:roleName/mcp-servers`、`MANAGE_ROLES` capability 必須、
  api/server/routes/roles.js:184)。管理パネルは `.env` の `ADMIN_PANEL_URL` を設定すると有効になる
- 共通サーバーを管理者定義として配るなら `librechat.yaml` のトップレベル `mcpServers` でも定義できる
  (packages/data-provider/src/config.ts:3869)

## MCP サーバーの同梱方針

stdio MCP サーバーはイメージに焼き込まず、インスタンス側で GitHub から clone して `librechat.yaml` の
`mcpServers` に登録する運用にする。そのため `packages` に `dev-vcs/git` と `sys-apps/keyutils` を立てている。

- exec-guard は upper layer 由来の ELF 実行を止めるだけで、インタープリタ経由のスクリプト実行は制限しない
  (docs/exec-guard.md:52)。Python stdlib のみの stdio MCP サーバーなら clone してそのまま動かせる
- clone したリポジトリに ELF や `.so` が含まれる場合 (プリコンパイル済み補助バイナリ、`pip install` する
  C 拡張など) は upper 由来なので実行も dlopen もできない。必要なら `packages` 経由で lower に入れる
- API 鍵はファイルシステムに残さない運用にする。`su - librechat` 後に `keyctl padd user <key_name> @u` で
  UID keyring に投入する (payload は stdin から読むので argv にもシェル履歴にも残らない)。
  root で投入すると root の UID keyring に入り uid 1000 からは見えない。UID keyring は uid 1000 の
  プロセスが全て消えると破棄され得る
- 投入作業には同梱ユーティリティ `/usr/bin/register-keyring-key` を使う。名前を並べて実行すると
  鍵ごとにエコーバックなしで入力し、登録済みの場合は先頭 4 文字だけをマスク表示して空 Enter で
  既存を保持する (`register-keyring-key xai_api_key other_service_api_key`)
- サービスから UID keyring の鍵を読むには `librechat.service` の `KeyringMode=shared` が要る。
  VM で実測: 既定 (inherit) の `User=librechat` サービスでは `keyctl search @u` は通るが
  `keyctl print` は `EACCES`。`KeyringMode=shared` を足すと読めるようになった。既定値では
  サービスの session keyring に user keyring がリンクされない (systemd.exec の KeyringMode 説明)
- `keyctl padd` が作る鍵の既定権限は possessor 全権 + user は VIEW だけで、`keyctl setperm` は
  作成した cred でないと実行できない (他プロセスからは `EACCES`)。だから権限いじりではなく
  `KeyringMode=shared` で解決する

### リクエスト主の情報を MCP サーバーに渡す

stdio MCP サーバーにはリクエスト主の情報を渡せる。MCP 接続はユーザー単位でプールされる
(`MCPManager.userConnections: Map<userId, Map<serverName, MCPConnection>>`) ので、yaml 定義の
stdio サーバーはユーザーごとに別プロセスとして spawn され、`env` と `args` の両方が
`{{LIBRECHAT_USER_*}}` / `{{LIBRECHAT_BODY_*}}` / `{{LIBRECHAT_OPENID_*}}` で解決される
(packages/api/src/utils/env.ts:450-479)。許可フィールドは `id`, `name`, `username`, `email`,
`provider`, `role`, `openidId` など (env.ts:34 以降)、body 側は `conversationId`,
`parentMessageId`, `messageId` (env.ts:151)。

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

- 渡すのは env と args のどちらか片方でよい。判断基準:
  - 引数は `/proc/<pid>/cmdline` に出る。そのホストのローカルユーザーなら誰でも `ps` で読めて、
    監査ログやクラッシュログにも残る
  - env は `/proc/<pid>/environ` を同じ UID か root しか読めない
  - 別 UID で動かす (sudo ラッパー) 構成では `sudo` の `env_reset` で env が消えることがある
- サーバー側は両方受け付けて (引数優先、未指定なら env を参照) どちらで渡すかはコンフィグを書く側が
  判断するのが素直
- env に定数を書くとその値は全ユーザーのインスタンスに同じように配られる。env が設定可能でも
  ユーザーごとに違う値にはならない。ユーザー依存の値 (宛先アドレス、記憶の namespace など) は
  `MAIL_TO: '{{LIBRECHAT_USER_EMAIL}}'` / `MEMORY_KEY: '{{LIBRECHAT_USER_ID}}'` のように
  プレースホルダで書く
- tool call の既定タイムアウトは 60 s (packages/api/src/mcp/connection.ts:155 `DEFAULT_TIMEOUT`)。
  外部 API を呼んで長く待つサーバーは `timeout` を越す値で宣言しないと途中で kill される
  (`initTimeout` は 30 s)
- プレースホルダを含むサーバーは起動時の app 共有接続を使えない (`requiresUserScopedConnection`,
  packages/api/src/mcp/utils.ts:600。`args` と `env` が検査対象, utils.ts:252-263)。起動ログでは
  `Capabilities: undefined` / `Tools: undefined` / `Initialized in: 0ms` に出て、ツールはユーザーが
  初めてリクエストしたときに登録される。0 ms で undefined なのは失敗ではない
- UI から追加した DB 由来サーバー (`source === 'user'` / `dbId`) では env/args のプレースホルダが
  解決されず `customUserVars` だけになる (env.ts:419-433)。ユーザー識別を渡すなら yaml 定義が必須
- 解決できない名前は空文字にストリップされる (`stripUnresolvedPlaceholders`)。タイポは黙って空になる。
  ユーザーごとにプロセスが増えるので起動コストとメモリはユーザー数に比例する
- 鍵を env 経由で渡すなら `env: { XAI_API_KEY: "${XAI_API_KEY}" }` と書ける。`${VAR}` は LibreChat
  プロセスの `process.env` から解決される (packages/data-provider/src/utils.ts:37-52)。
  keyring 運用ではスクリプト側が `keyctl search @u` で読む
