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
