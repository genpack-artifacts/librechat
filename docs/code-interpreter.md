# LibreChat Code Interpreter 検討メモ

調査時点: 2026-10-16。実装はしていない。必要になった時にゼロから調べ直さなくて済むための記録。

## 問い

LibreChat の「コードを実行」（`execute_code`）をこのアーティファクトで使えるようにしたい。
サンドボックスは LibreChat 本体には内蔵されておらず、別サービスに繋ぐブリッジであることが分かった。
どこに何を立てるのが現実的かを比較したものが下の表。

## Code Interpreter の正体

- リポジトリ: https://github.com/LibreChat-AI/code-interpreter （Apache-2.0、ClickHouse 発。内部名は `codeapi`）
- 構成: 独立にスケールする複数コンポーネントが Redis キューと S3 互換ストレージで繋がる
  - API（HTTP ゲートウェイ）
  - Worker Sandbox（NsJail または libkrun microVM で実行）
  - File Server（S3 互換、IRSA 認証）
  - Tool Call Server（サンドボックス内からの programmatic tool call を中継）
  - Package Delivery（Python / Node / Bun を microVM の block-root イメージに焼き込む）
  - Remote Code Bridge（operator 管理の VM をアウトバウンド接続で stateful サンドボックスにする）
- 分離モード
  - NsJail のみ（`kvmEnabled: false`）: ホストカーネル共有。README 自身が「ローカル開発向けで、
    信頼できない人のコードを実行するには不適切」と明言
  - libkrun microVM（`kvmEnabled: true`）: 別ゲストカーネル + ゲスト内で NsJail。
    完全なハードニングは seccomp + egress gateway + network policy + 署名済み execution manifest
    + `hardenedSandboxMode` 込みで成立する
- 実行プロファイル: `default`（AWS 無し HTTP/libkrun、stateless）と `stateful`（AWS Lambda MicroVM 経路）。
  `X-CodeAPI-Expected-Profile` ヘッダで誤デプロイへの到達を 409 で止める。サイレントなフォールバック無し
- 制約: サンドボックスにネットワーク無し（egress gateway が前に出る）、1 実行あたり生成ファイル 10 個、
  入出力は `/mnt/data`。言語は Python / Node(JS/TS) / Go / C/C++ / Java / PHP / Rust / Fortran / Rscript
- 認証: LibreChat が短命 bearer を署名する JWT 方式（既定 EdDSA、TTL 300 s 上限 300 s）または API key
- 配布: Docker Compose / Helm（chart に Redis と MinIO subchart を同梱）。GHCR に 7 本のプリビルドイメージ
  （api / worker / file-server / egress-gateway / tool-call-server / sandbox-runner / sandbox-runner-direct）。
  `latest` は無く `sha-<commit>` タグで固定する
- 詳細ドキュメント: https://www.librechat.ai/docs/features/code_interpreter

## LibreChat 側の接続設定

`.env`（api/server 側、.env.example:753-800）:

- `LIBRECHAT_CODE_BASEURL`, `LIBRECHAT_CODE_API_KEY`
- stateful 用に `LIBRECHAT_CODE_BASEURL_STATEFUL`（専用 route は `stateful` プロファイル広告必須）
- JWT 方式は `CODEAPI_AUTH_PROVIDER=librechat-jwt` + `CODEAPI_JWT_PRIVATE_KEY`（PEM / base64 PEM / JWK）
  + `CODEAPI_JWT_ALGORITHM=EdDSA` + `CODEAPI_JWT_KID` + `CODEAPI_JWT_ISSUER` + `CODEAPI_JWT_AUDIENCE`。
  Code Interpreter 側は `CODEAPI_JWT_JWKS_JSON` 等で公開鍵を検証する
- `LIBRECHAT_CODE_SANDBOX_OUTPUT_MAX_SIZE`（既定 65536）は worker の同名設定と揃える
- `CODE_SANDBOX_PREWARM`（既定 true）、`CODE_SANDBOX_COLD_AFTER_MS`（既定 2100000 = 35 分）

librechat.yaml 側は `endpoints.agents` の capabilities に `execute_code`、
使うなら `run_in_background` / `stateful_code_sessions` / `programmatic_tools` を足し、
Agent 側で Code Interpreter を有効化する。

LibreChat 内の実装箇所（このリポジトリのビュー):

- `packages/api/src/code/`（bridge, capabilities, command, config, targets, workspace など）
- `packages/api/src/agents/tools.ts:1205-1275`（`execute_code` を `bash_tool` + `read_file` に展開する）
- `packages/api/src/code/capabilities.ts:186`（worker が native sandbox を広告すると `nativeSandbox: true`）

## genpack VM 実測（2026-10-16）

- `/dev/kvm` 有り（`crw-rw-rw- 1 root kvm 10, 232`）、`CONFIG_KVM=m` → nested virt が効くので
  libkrun microVM 経路は技術的に可能
- `CONFIG_NAMESPACES=y`, `CONFIG_USER_NS=y`, `CONFIG_CGROUPS=y`, `CONFIG_SECCOMP=y`,
  `/sys/fs/cgroup` は cgroup2fs → NsJail 的な要素も揃う
- exec-guard は `trusted_devs` に overlay の **lower（squashfs）デバイスを 1 本だけ**登録する
  （genpack-init/exec_guard.cpp:38-41）。data image でも専用ディスクでも untrusted 扱いで、
  その上の ELF は `execve` が `EPERM`
- 無効化は `system.ini` の `exec_guard = false` だけで、デバイス単位の許可リストは無い
- build.d で lower に焼いたバイナリは信頼済みになる。nsjail は C++ の素直なビルドだが、
  libkrun はゲストカーネルと rootfs 組み立てまであるので単純なビルドスクリプトには重い

## 2 方式の比較

| 観点 | A: managed Code Interpreter | B: attached / BYOM worker |
| --- | --- | --- |
| 想定用途 | 不特定ユーザーのコードを実行させる | 自分が管理するマシンでエージェントに作業させる |
| 構成 | api / worker / file server / tool call server / egress gateway / sandbox-runner + Redis + S3 互換 | Code API（ブリッジ）+ VM 上の `@librechat/code` ワーカー 1 本 |
| サンドボックス | libkrun microVM または NsJail | `native-srt`（Anthropic SRT = bubblewrap + seccomp）。任意で Docker/NsJail adapter |
| 分離強度 | microVM + seccomp + egress gateway + signed manifest で「妥当に安全」。NsJail のみは開発用 | VM 境界への信頼委譲。`trusted-vm` プリセットは egress / local bind / Unix socket を開く |
| Docker | 必要（Compose / Helm） | 不要（native-srt が既定） |
| exec-guard との相性 | コンテナ内 ELF が untrusted で `EPERM`。`exec_guard = false` か信頼デバイス拡張が必須 | 影響なし。bubblewrap 等は lower に入る |
| Portage | docker は amd64 安定、redis も有る。MinIO は ebuild 無し。nsjail / libkrun は無し | sys-apps/bubblewrap、net-misc/socat、sys-apps/ripgrep、app-misc/jq、net-libs/nodejs で揃う |
| ソースビルド | イメージに頼らないなら ebuild 化が要る（libkrun が重い） | ほぼ不要（SRT は npm パッケージ） |
| 状態保持 | `stateful` profile か managed stateful route | user / agent+user / conversation 単位の workspace、会話ごとの git worktree |
| ファイル受け渡し | File Server（S3 互換） | file relay（egress gateway 経由。1 転送 10 MiB、1 実行 100 ファイル / 100 MiB、並列 4） |
| 認証 | LibreChat 署名の短命 JWT（EdDSA）または API key | one-time code + Ed25519 ペアリング、要求単位の署名と nonce |
| VM 外に必要になるもの | Code API スタックそのもの | Code API（ブリッジ）。ワーカーはアウトバウンドのみで公開ポート不要 |
| 構成の複雑さ | 高い（6 サービス + Redis + S3） | 低い（Node ワーカー 1 本 + Code API） |
| 更新追従 | GHCR の `sha-` タグ固定、Helm chart の pinned release | npm パッケージの更新 |
| 追加で得られるもの | Programmatic Tool Calling、background execution | 上記に加え workspace ツール、GitHub App 認証、会話 PR 表示 |

## B 方式の勘所

- ワーカーは `@librechat/code`（Node.js 22.21 以降。20 は未対応）
- ペアリングは管理者が作った one-time code を使い、秘密鍵は VM から出さない
  ```sh
  librechat-code pair https://code.example.com/v1 '<one-time-code>' --worker-id my-vm
  ```
- 起動（native SRT、Docker 不要）
  ```sh
  librechat-code run --worker-dir /path/to/project \
    --allow-workspace-writes --allow-workspace-commands
  ```
- VM 境界に信頼を委譲するプリセット（genpack VM のような構成向け）
  ```sh
  librechat-code run --worker-dir /home/librechat/src \
    --allow-workspace-writes --allow-workspace-commands \
    --command-policy-preset trusted-vm
  ```
  egress / local bind / Unix socket を開く分「外側の VM 境界が防ぎうる経路を operator が判断する」前提。
  Unix socket はコンテナデーモン等の強いホストサービスに届きうる、とドキュメントが注意書きしている
- Linux で必要なもの: bubblewrap、socat、ripgrep。Bash programmatic には bash 5.2+ と jq
- Git 認証は GitHub App を推奨。トークンはサンドボックスには渡らず host 側プロキシで差し替えられる
- ワーカーのローカル実行エンドポイントは loopback かプライベートネットワークに留める。
  ペアリングは輸送の認証であってサンドボックス境界ではない
- 詳細: https://github.com/LibreChat-AI/code-interpreter/blob/main/packages/code/README.md と
  `docs/remote-bridge/README.md`、`docs/remote-bridge/worker-runbook.md`

## 残る課題と次の一手

1. B でもブリッジとなる Code API が必要。ブリッジ専業の最小構成（api + Redis + bridge route）で
   足りるかを README と helm chart から詰める
2. A を VM に入れるなら exec-guard の扱いを先に決める。genpack-init に「追加の信頼デバイス」設定を
   入れるのが筋で、genpack 側の改修として立てる
3. 複数ユーザーに安全に提供するのが目的なら A の microVM 経路が要り、それは VM の外に置く話になる
4. 単発の試す用途なら、Code API を一時的に別のマシン（またはコンテナランタイムのある環境）に立てて
   VM 上のワーカーをペアリングするのが一番軽い
