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
chmod 0755 /usr/bin/register-keyring-key

# 7. Meilisearch (過去チャット全文検索)。Portage に ebuild が無いので GitHub リリースの
#    プリビルドバイナリを lower (squashfs) に焼く。upper 由来バイナリは exec-guard に
#    ブロックされるため、実行時持ち込みは不可 (go2rtc と同じ方針)。
#    ビルド再現性のためバージョンをピンし sha256 を検証する。
MEILI_VERSION=1.56.1
case "$(uname -m)" in
	x86_64)
		MEILI_ARCH=amd64
		MEILI_SHA256=b2c7a647d4cdfdd7a901466bfd6797077b849e90f5eb2c0f5b1d05869592e27e
		;;
	aarch64)
		MEILI_ARCH=aarch64
		MEILI_SHA256=f73987f92b094fd15b79956f9bfc9e8fc7294ad6ad610ebf8a4403c170890726
		;;
	*)
		echo "Unsupported architecture for meilisearch: $(uname -m)" >&2
		exit 1
		;;
esac
download "https://github.com/meilisearch/meilisearch/releases/download/v${MEILI_VERSION}/meilisearch-linux-${MEILI_ARCH}" > /tmp/meilisearch
echo "${MEILI_SHA256}  /tmp/meilisearch" | sha256sum -c -
install -m 0755 /tmp/meilisearch /usr/bin/meilisearch
rm -f /tmp/meilisearch

# インデックスの dbPath (実行時の書き込みはデータパーティションへ copy-up される)。
# ユーザー作成は create_home: false (genpack 1f4eecf 以降で -M が付く) にしているので、
# skel 混入のない素の状態を build.d で作る。dotfile が入ると Meilisearch は起動できない。
# meilisearch ユーザーは genpack.json5 の users で作成される。
[ -d /var/lib/meilisearch ] || install -d -o meilisearch -g meilisearch -m 0750 /var/lib/meilisearch

# gen-env.sh の直列化用ロック (librechat サービスと meilisearch サービスが共有)。
# 0666 にしないと root / librechat のどちらから先に開いても失敗する
install -m 0666 -o librechat -g librechat /dev/null /opt/librechat/.env.lock

# 8. sudoers drop-in の整備
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
