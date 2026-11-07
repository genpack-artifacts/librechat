#!/bin/sh
# 初回起動時に /opt/librechat/.env を生成する (librechat.service と meilisearch.service の ExecStartPre)。
# 既存の .env には手を出さない (古い生成物に欠ける行の追記のみ)。.env を削除すれば再生成されるが、
# JWT と保存済み資格情報の復号鍵は無効になる (再ログイン / 再接続が必要)。
#
# meilisearch.service 側の ExecStartPre は + 接頭辞で root 実行 (生成後の chown が必要)。
# 両サービスが初回起動で競り得るので、ビルド時に作っておいた .env.lock の flock で直列化する。
set -e

ENV_FILE=/opt/librechat/.env
LOCK_FILE=/opt/librechat/.env.lock

hex() {
	od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

# 検索設定ブロック (新規生成テンプレと既存 .env への追記で共通)。
# MEILI_MASTER_KEY は Meilisearch が 16 文字以上を要求するので hex 32 (64 文字)。
search_block() {
	printf '%s\n' \
"# 過去チャット全文検索 (Meilisearch)。meilisearch.service が 127.0.0.1:7700 で起動する。
# 無効化は SEARCH=false (アプリ側が index を読まなくなり、検索は MongoDB 正規表現にフォールバック)
SEARCH=true
MEILI_HOST=http://127.0.0.1:7700
MEILI_NO_ANALYTICS=true
MEILI_MASTER_KEY=$(hex 32)"
}

[ -e "$LOCK_FILE" ] || : > "$LOCK_FILE"
exec 9>"$LOCK_FILE"
flock 9

if [ -f "$ENV_FILE" ]; then
	# .env は以降ユーザーの編集対象。ただしユーザーが明示的に (コメント含め) 宣言していない
	# 項目のみ、古い生成物へ追記する。

	# バインド先。LibreChat の既定バインドは localhost で、ループバックのみだと VM 外から到達できない
	if ! grep -qE '^[[:space:]]*#?[[:space:]]*HOST=' "$ENV_FILE"; then
		printf '\n# バインド先。:: はデュアルスタックで IPv4 も受け付ける。ループバック限定なら localhost\nHOST=::\n' >> "$ENV_FILE"
		echo "appended HOST=:: to $ENV_FILE"
	fi

	# Meilisearch 導入前の古い .env (SEARCH 行が無いもの) に検索設定を追記。
	# 起動時に meilisearch.service (root) が行うので、librechat 所有のファイルでも追記できる
	if ! grep -qE '^[[:space:]]*#?[[:space:]]*SEARCH=' "$ENV_FILE"; then
		printf '\n%s\n' "$(search_block)" >> "$ENV_FILE"
		echo "appended SEARCH/MEILI settings to $ENV_FILE"
	fi

	# root 実行 (meilisearch.service 経由) で新規生成された場合の所有権調整。
	# 既存ファイルで失敗しても (例: root 所有にして運用している) サービス起動を
	# 止めない
	chown librechat:librechat "$ENV_FILE" 2>/dev/null || true
	exit 0
fi

umask 077

cat > "$ENV_FILE" <<'TEMPLATE'
# LibreChat 環境設定 (初回起動時に自動生成されたもの)
#
# 全オプションと詳しい説明: /opt/librechat/.env.example
# LLM エンドポイントの登録は /opt/librechat/librechat.yaml で行う
# (OPENAI_API_BASE は v0.8.8 で廃止、.env 側では効かない)

PORT=3080
# バインド先。既定 (localhost) だとループバックにしか listen せず、VM の外から到達できない。
# :: はデュアルスタックで IPv4 も受け付ける (IPv4 限定にするなら 0.0.0.0)
HOST=::
MONGO_URI=mongodb://127.0.0.1:27017/LibreChat

# ブラウザから見る URL。VM をポートフォワードして localhost:3080 で使うならこのままで良い。
# ホスト名や IP で直接アクセスする運用なら書き換える。
DOMAIN_CLIENT=http://localhost:3080
DOMAIN_SERVER=http://localhost:3080

# MongoDB 単一ノード構成で schedules 機能を使うために必須 (無いと 503 で拒否される)
SCHEDULES_SINGLE_PROCESS=true

# クローラー向けの X-Robots-Tag (noindex) ヘッダー。検索機能とは無関係
# (過去チャット検索の ON/OFF は下の SEARCH)
NO_INDEX=true

TEMPLATE

search_block >> "$ENV_FILE"

cat >> "$ENV_FILE" <<'TEMPLATE'

# --- 任意設定 (コメントを解除して設定し、sudo systemctl restart librechat) ---
#
# 管理パネル (設定すると /admin が有効になる)
# ADMIN_PANEL_URL=http://[::]:3080/admin
# ADMIN_PANEL_SESSION_SECRET=<hex 32 バイト>
#
# Web Search / Fetch バックエンド (searchProvider: serper / searxng / tavily / keenable)
# SEARXNG_INSTANCE_URL=http://searxng.example.com/search?q={query}
# TAVILY_API_KEY=
# FIRECRAWL_API_URL=
#
# Exa は内蔵プロバイダに無いので MCP 経由 (管理パネルの MCP 管理で追加):
#   { "type": "streamable-http", "url": "https://mcp.exa.ai/mcp?exaApiKey=<key>" }
#
# rag-api (Python のファイル RAG) は同梱しない。無いとファイルアップロードの RAG だけ
# 警告付きでオフになる (会話検索の Meilisearch とは別系統)
TEMPLATE

cat >> "$ENV_FILE" <<EOF

# 永続シークレット。このファイルを消すと JWT と保存資格情報の暗号化が無効になる。
CREDS_KEY=$(hex 32)
CREDS_IV=$(hex 16)
JWT_SECRET=$(hex 32)
JWT_REFRESH_SECRET=$(hex 32)
EOF

# root 実行 (meilisearch.service 経由) で生成した場合、librechat が編集できるよう所有権を寄せる
chown librechat:librechat "$ENV_FILE"

echo "generated $ENV_FILE"
