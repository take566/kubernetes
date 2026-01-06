# Nexus リポジトリ設定ガイド

## 初期設定

### 1. 管理者パスワード取得
```powershell
./get-admin-password.ps1
```

または

```bash
./get-admin-password.sh
```

### 2. Nexus Web UI へアクセス
- **URL**: http://nexus.local:8081
- **ユーザー名**: admin
- **パスワード**: 上記で取得したパスワード

---

## npm レジストリの設定

### Hosted Repository 作成 (npm)
1. **Administration** → **Repositories** → **Create repository**
2. **Recipe**: npm (hosted)
3. **Name**: `npm-internal`
4. **Version policy**: Mixed
5. **Deployment policy**: Allow redeploy
6. **Create repository**

### npm へのログイン設定

```bash
# .npmrc ファイルを設定
npm config set registry http://npm-registry.local:8083/repository/npm-internal/
npm config set /npm-registry.local:8083/:_authToken=<token>

# または対話的にログイン
npm adduser --registry http://npm-registry.local:8083/repository/npm-internal/
# ユーザー名: admin
# パスワード: <admin-password>
# Email: <your-email>
```

### パッケージの公開

```bash
npm publish --registry http://npm-registry.local:8083/repository/npm-internal/
```

---

## Docker Registry の設定

### Hosted Repository 作成 (Docker)
1. **Administration** → **Repositories** → **Create repository**
2. **Recipe**: Docker (hosted)
3. **Name**: `docker-internal`
4. **HTTP**: `8082` (Port)
5. **Allow clients to use the V1 API and perform pushes/pulls without authentication**: チェック（必要に応じて）
6. **Create repository**

### Docker へのログイン設定

```bash
# Docker ログイン
docker login -u admin -p <admin-password> docker-registry.local:8082

# または ~/.docker/config.json に設定
{
  "auths": {
    "docker-registry.local:8082": {
      "auth": "YWRtaW46PHBhc3N3b3JkPg=="
    }
  }
}
```

### イメージのプッシュ

```bash
# ローカルイメージにタグ付け
docker tag my-app:latest docker-registry.local:8082/my-app:latest

# レジストリにプッシュ
docker push docker-registry.local:8082/my-app:latest
```

### イメージのプル

```bash
docker pull docker-registry.local:8082/my-app:latest
```

---

## Proxy Repository の設定（オプション）

### npm の公式レジストリをプロキシ

1. **Administration** → **Repositories** → **Create repository**
2. **Recipe**: npm (proxy)
3. **Name**: `npm-proxy`
4. **Remote storage**: `https://registry.npmjs.org`
5. **Create repository**

### Docker Hub をプロキシ

1. **Administration** → **Repositories** → **Create repository**
2. **Recipe**: Docker (proxy)
3. **Name**: `docker-proxy`
4. **Remote storage**: `https://registry-1.docker.io`
5. **Create repository**

---

## Group Repository の設定（オプション）

### npm Group
1. **Administration** → **Repositories** → **Create repository**
2. **Recipe**: npm (group)
3. **Name**: `npm-group`
4. **Member repositories**: 
   - npm-internal
   - npm-proxy (作成した場合)
5. **Create repository**

### Docker Group
1. **Administration** → **Repositories** → **Create repository**
2. **Recipe**: Docker (group)
3. **Name**: `docker-group`
4. **Member repositories**:
   - docker-internal
   - docker-proxy (作成した場合)
5. **Create repository**

---

## Jenkins での使用例

### npm パッケージの公開

```groovy
pipeline {
    stages {
        stage('Publish') {
            steps {
                sh '''
                    npm config set registry http://nexus:8083/repository/npm-internal/
                    npm config set /nexus:8083/:_authToken=${NPM_TOKEN}
                    npm publish
                '''
            }
        }
    }
}
```

### Docker イメージのビルド・プッシュ

```groovy
pipeline {
    stages {
        stage('Build and Push') {
            steps {
                sh '''
                    docker build -t docker-registry:8082/my-app:${BUILD_NUMBER} .
                    docker login -u admin -p ${DOCKER_PASSWORD} docker-registry:8082
                    docker push docker-registry:8082/my-app:${BUILD_NUMBER}
                '''
            }
        }
    }
}
```

---

## トラブルシューティング

### npm パッケージが見つからない
- Proxy リポジトリが正しく設定されているか確認
- Nexus のログで 404 エラーを確認

### Docker プッシュの失敗
- ホスト名の DNS 解決を確認（/etc/hosts または hosts ファイル）
- 認証情報が正しいか確認

### パフォーマンスの問題
- ストレージ容量を確認
- ファイアウォール設定を確認
- CPU/メモリ使用率を監視

---

## セキュリティ設定

### API トークンの作成
1. **Administration** → **Security** → **API Tokens**
2. **Create token**
3. トークンを使用して認証

### LDAP/AD との統合
1. **Administration** → **Security** → **LDAP**
2. サーバー設定を入力
3. **Save**

---

## バックアップとリカバリ

### バックアップの作成
```bash
kubectl -n nexus exec <pod-name> -- \
  tar czf /nexus-data/nexus-backup-$(date +%Y%m%d).tar.gz \
  --exclude=/nexus-data/blobs \
  /nexus-data/
```

### リカバリ
```bash
kubectl -n nexus exec <pod-name> -- \
  tar xzf /nexus-data/nexus-backup-<date>.tar.gz -C /nexus-data/
```

---

## 参考資料
- [Nexus Repository Documentation](https://help.sonatype.com/repomanager3)
- [npm Registry Setup](https://help.sonatype.com/repomanager3/nexus-repository-manager/formats/npm-registry)
- [Docker Registry Setup](https://help.sonatype.com/repomanager3/nexus-repository-manager/formats/docker-registry)
