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
