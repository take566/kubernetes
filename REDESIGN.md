# Kubernetes プロジェクト ゼロベース再設計 - 統合レポート

> 作成日: 2026-03-08
> 分析チーム: System Architect, DevOps Architect, Security Engineer, Devil's Advocate

## チーム構成と各エージェントの役割

| エージェント | 役割 | 実施した作業 |
|---|---|---|
| **System Architect** | システムアーキテクト | プロジェクト全49ファイルを分析。ディレクトリ構造、Kustomize+Helm統合、環境分離、ApplicationSet、Secret管理、namespace戦略、リソース標準化の7領域を設計 |
| **DevOps Architect** | DevOpsアーキテクト | CI/CD、監視スタック（ELK vs Loki）、ローカル開発ツール、バックアップ戦略、イメージ管理を分析・比較検討 |
| **Security Engineer** | セキュリティエンジニア | 脆弱性監査（Critical 2件、High 1件、Medium 2件検出）、Secret管理比較、NetworkPolicy設計、優先度付きロードマップ策定 |
| **Devil's Advocate** | 悪魔の代弁者（反証役） | 全7提案に対して過剰設計の指摘、隠れたコスト分析、現実的な代替案を提示 |

---

## 1. 現状の致命的問題（全エージェント一致）

| 問題 | 深刻度 | 対応 |
|---|---|---|
| `gitlab-secret.yaml` に平文パスワードがGitコミット済み | **CRITICAL** | 即座対応 |
| Elasticsearch `xpack.security.enabled=false`（認証なし） | **CRITICAL** | 即座対応 |
| ArgoCD `root-application.yaml` に TODO URL が残存（5/7アプリ） | **HIGH** | 即座対応 |
| nginx/Prometheus にリソース制限なし | **MEDIUM** | 短期対応 |
| NetworkPolicy 一切なし | **HIGH** | 議論あり |

---

## 2. 理想的なディレクトリ構造（System Architect提案）

```
kubernetes/
├── bootstrap/                     # 手動適用（ArgoCD/Sealed Secrets本体）
│   ├── argocd/
│   └── sealed-secrets/
├── platform/                      # ArgoCD GitOps管理対象
│   ├── applicationsets/           # ApplicationSet（App of Apps代替、DRY）
│   ├── base/                      # Kustomize base（環境非依存）
│   │   ├── cert-manager/          # HelmChartInflator
│   │   ├── elk-stack/             # 純Kustomize
│   │   ├── monitoring/            # HelmChartInflator (kube-prometheus-stack)
│   │   ├── nexus/                 # 純Kustomize
│   │   ├── gitlab/                # HelmChartInflator
│   │   └── nginx/                 # 純Kustomize
│   └── overlays/                  # 環境別差分
│       ├── dev/
│       ├── staging/
│       └── prod/
├── policies/                      # NetworkPolicy, ResourceQuota
└── scripts/                       # bootstrap, seal-secret, validate
```

---

## 3. マニフェスト管理方式

**結論: Kustomize First, Helm as Source**

| サービス | 管理方式 | 理由 |
|----------|----------|------|
| cert-manager | Kustomize + HelmChartInflator | 複雑なCRD/RBAC、公式Helm成熟 |
| monitoring | Kustomize + HelmChartInflator | kube-prometheus-stackが業界標準 |
| gitlab | Kustomize + HelmChartInflator | 公式Helmチャート必須 |
| elk-stack | 純Kustomize | 生YAMLで十分、ECKは過剰 |
| nexus | 純Kustomize | シンプル構成 |
| nginx | 純Kustomize | 最もシンプル |

---

## 4. DevOpsツールチェーン推奨

| 項目 | 推奨 | 理由 |
|---|---|---|
| CI/CD | GitLab CI（既存活用）+ ArgoCD | GitLab CEが既にクラスタ内にデプロイ済み |
| 監視 | kube-prometheus-stack | Grafana同時解決、手書きPrometheus置換 |
| ログ | ELK維持 + ES_JAVA_OPTS削減 | 業界経験価値。256mに削減で十分 |
| ローカル開発 | Skaffold | 既存YAML対応、CI/CD統合可能 |
| バックアップ | Phase 1: スクリプトベース → Phase 3: Velero | 段階的導入 |
| イメージタグ | semver + gitsha（`v1.2.3-abc1234`） | 一意性と可読性の両立 |

---

## 5. セキュリティ監査結果

### 脆弱性分類

**CRITICAL:**
1. 平文Secret のGitコミット（CWE-798）
2. Elasticsearch 認証無効（CWE-306）

**HIGH:**
3. NetworkPolicy 未設定（CWE-284）

**MEDIUM:**
4. RBAC の過剰権限（CWE-250）
5. コンテナリソース制限なし（CWE-770）

### Secret管理推奨: SOPS + AGE
- Minikubeに外部プロバイダ不要
- CLIベースで復号可能（コントローラ障害時も安全）
- ArgoCD + SOPS プラグインでGitOps統合可能

---

## 6. Devil's Advocateの反証

### 過剰設計トップ3

| 順位 | 提案 | 理由 |
|------|------|------|
| 1位 | Service Mesh (Istio/Linkerd) | Minikubeのリソースに収まらない。replicas:1で無意味 |
| 2位 | dev/staging/prod環境分離 | 10GBメモリで3環境は物理的に不可能 |
| 3位 | NetworkPolicy全通信制御 | kindnetが未対応。Calico追加で300-500MB消費 |

### 最小必要セット
1. ArgoCD root-application.yaml の TODO を解消する
2. resource requests/limitsの統一
3. GitLabの要否判断（除外で3GB回収）

### 核心メッセージ
> 「このプロジェクトに最も必要なのは『新しいツールの導入』ではなく、既に導入したものを完成させること。」

---

## 7. 主要論点の合意・対立マトリックス

| 論点 | Architect | DevOps | Security | Devil's Advocate | **統合判断** |
|---|---|---|---|---|---|
| Secret管理 | Sealed Secrets | - | SOPS+AGE | .gitignoreで十分 | Phase 1: .gitignore → Phase 2: SOPS+AGE |
| ELK→Loki移行 | 維持 | Loki移行 | - | ELK維持 | ELK維持 + ES最適化 |
| 環境分離 | 3環境 | - | - | 物理的不可能 | dev overlayのみ（学習目的） |
| CI/CD | - | GitLab CI | Trivy統合 | 最小yamllintで十分 | Phase 2: yamllint → Phase 3: GitLab CI |
| 監視 | kube-prometheus-stack | 同左 | - | 既存最適化 | kube-prometheus-stack導入 |
| NetworkPolicy | default-deny | - | 必須 | kindnet未対応 | Phase 3: クラウド移行時 |
| Service Mesh | - | - | mTLS検討 | 最も破壊的な過剰設計 | 導入しない |

---

## 8. 統合ロードマップ

### Phase 1: 即座（1-2日）
- [x] gitlab-secret.yaml の平文パスワード除去 + .gitignore追加
- [x] ArgoCD root-application.yaml のTODO URL修正
- [x] nginx-deployment.yaml にresource requests/limits追加
- [x] prometheus-statefulset.yaml にresource requests/limits追加
- [x] Elasticsearch xpack.security.enabled: true に変更

### Phase 2: 短期（1-2週間）
- [ ] 各ディレクトリに最小限の kustomization.yaml を追加
- [ ] cert-manager: 1334行YAML → HelmChartInflator + values.yaml に移行
- [ ] kube-prometheus-stack Helm導入（Grafana問題解決）
- [ ] ES_JAVA_OPTS を -Xms256m -Xmx256m に削減
- [ ] Skaffold導入（ローカル開発改善）
- [ ] GitLab必要性の最終判断

### Phase 3: 将来（必要時のみ）
- [ ] SOPS+AGE によるSecret管理
- [ ] ApplicationSet導入
- [ ] GitLab CI + Trivyスキャンパイプライン
- [ ] NetworkPolicy（クラウド移行時）
- [ ] Velero バックアップ

### 導入しないもの
- Service Mesh（Istio/Linkerd）
- 完全なdev/staging/prod 3環境分離
- 全通信のNetworkPolicy制御（Minikube上では）

---

## リソース見積もり（dev環境 / Minikube）

| サービス | CPU req | CPU lim | MEM req | MEM lim |
|---|---|---|---|---|
| Elasticsearch | 500m | 1000m | 1Gi | 2Gi |
| Kibana | 50m | 200m | 256Mi | 512Mi |
| Logstash | 250m | 500m | 512Mi | 1Gi |
| Prometheus | 250m | 1000m | 512Mi | 2Gi |
| Node Exporter | 100m | 200m | 50Mi | 100Mi |
| Nexus | 1000m | 2000m | 2Gi | 4Gi |
| nginx | 50m | 200m | 64Mi | 256Mi |
| cert-manager | 150m | 600m | 192Mi | 768Mi |
| ArgoCD | 250m | 500m | 256Mi | 512Mi |
| **合計** | **2600m** | **6200m** | **4.86Gi** | **11.12Gi** |

Minikube推奨: `minikube start --cpus=8 --memory=16384`
