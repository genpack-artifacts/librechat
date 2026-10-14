#!/bin/sh
# LibreChat のソース取得・ビルド・実行準備
#
# 実機検証済みの手順 (v0.8.8 / node 26):
#   npm ci -> npm run frontend (packages 群 + client の vite ビルド) -> npm prune --omit=dev
# backend は実行時に node_modules を要する (フロントと違い prune 不可)。
# --omit=dev までが安全と確認済み。起動時に MODULE_NOT_FOUND が出るなら
# この prune を外す (node_modules は 2GiB 前後になる)。
set -e

LIBRECHAT_VERSION=v0.8.8
APP_DIR=/opt/librechat

# 1. ソース (リリースタグのシャロークローン)
#    files/opt/librechat/librechat.yaml は build.d 前に /opt/librechat へコピー済み。
#    git clone は空ディレクトリでしかできないので先に退避する。
if [ -f "$APP_DIR/librechat.yaml" ]; then
	mv "$APP_DIR/librechat.yaml" /tmp/librechat.yaml
fi
git clone --depth 1 --branch "$LIBRECHAT_VERSION" \
	https://github.com/danny-avila/LibreChat "$APP_DIR"
if [ -f /tmp/librechat.yaml ]; then
	mv /tmp/librechat.yaml "$APP_DIR/librechat.yaml"
fi

# 2. 依存導入とフロントエンドビルド (client/dist を生成)
cd "$APP_DIR"
npm ci
npm run frontend

# 3. 開発依存の除去 (実行時依存は残す)
npm prune --omit=dev

# 4. ビルド残骸の除去
rm -rf "$APP_DIR/.git" /root/.npm /root/.cache

# 5. MongoDB の dbPath。ebuild は /var/log/mongodb しか作らないため这里是らで用意する
#    (mongod は User=mongodb で走るため、存在しない dbPath を自分で作れない)。
#    acct-user/mongodb がホームとして作る場合もあるので、無いときだけ作る。
[ -d /var/lib/mongodb ] || install -d -o mongodb -g mongodb -m 0750 /var/lib/mongodb

# 6. アプリの書き込み領域 (data/, logs/, .env) と設定編集を librechat に
chown -R librechat:librechat "$APP_DIR"
chmod 0755 /usr/lib/librechat/gen-env.sh

# 7. sudoers drop-in の整備
#    - git は 0440 を保持できないのでモードをここで確定させる
#    - sudo 既定の /etc/sudoers には includedir が入っていない (upstream の
#      examples/sudoers.in に無い) ので、drop-in が読まれるように追記する
mkdir -p /etc/sudoers.d
chown root:root /etc/sudoers.d
chmod 0750 /etc/sudoers.d
chown root:root /etc/sudoers.d/librechat
chmod 0440 /etc/sudoers.d/librechat
visudo -cf /etc/sudoers.d/librechat
if ! grep -qE '^[#@]includedir /etc/sudoers\.d' /etc/sudoers; then
	chmod 0640 /etc/sudoers
	printf '\n#includedir /etc/sudoers.d\n' >> /etc/sudoers
	chmod 0440 /etc/sudoers
fi
visudo -c
