#!/bin/sh
# 初回起動時に /opt/librechat/.env を生成する (librechat.service の ExecStartPre)。
# 既存の .env には手を出さない。.env を削除すれば再生成されるが、
# JWT と保存済み資格情報の復号鍵は無効になる (再ログイン / 再接続が必要)。
set -e

ENV_FILE=/opt/librechat/.env

if [ -f "$ENV_FILE" ]; then
	# .env は以降ユーザーの編集対象。ただし HOST の行が無い古い生成物には追記する
	# (LibreChat の既定バインドは localhost で、ループバックのみだと VM 外から到達できない)。
	# コメントで明示的に HOST を扱っている場合はユーザーの判断とみなして触らない。
	if ! grep -qE '^[[:space:]]*#?[[:space:]]*HOST=' "$ENV_FILE"; then
		printf '\n# バインド先。:: はデュアルスタックで IPv4 も受け付ける。ループバック限定なら localhost\nHOST=::\n' >> "$ENV_FILE"
		echo "appended HOST=:: to $ENV_FILE"
	fi
	exit 0
fi

hex() {
	od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

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

# 検索インデックス (meilisearch) は使わない。rag-api (Python) は任意で、
# 無いとファイルアップロードの RAG だけ警告付きでオフになる。
NO_INDEX=true

# エラーログをファイルへ (console 出力は journald へ)。出力先は /opt/librechat/logs
LOG_TO_FILE=true

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
TEMPLATE

cat >> "$ENV_FILE" <<EOF

# 永続シークレット。このファイルを消すと JWT と保存資格情報の暗号化が無効になる。
CREDS_KEY=$(hex 32)
CREDS_IV=$(hex 16)
JWT_SECRET=$(hex 32)
JWT_REFRESH_SECRET=$(hex 32)
EOF

echo "generated $ENV_FILE"
