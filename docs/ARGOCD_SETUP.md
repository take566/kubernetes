# Argo CD セットアップ・Application 一覧

## Bootstrap

```bash
./scripts/bootstrap.sh
kubectl apply -f argocd/apps/root-application.yaml
```

`root-application` が `argocd/apps/` 配下の全 Application を App of Apps パターンで管理します。

## Application 一覧

| Application | Source path | Namespace | Auto sync |
|-------------|-------------|-----------|-----------|
| `root-application` | `argocd/apps` | argocd | Yes |
| `vllm-kubeadm` | `vllm/overlays/kubeadm` | vllm | Yes |
| `vllm-kind` | `vllm/overlays/kind` | vllm | No |
| `vllm-amd` | `vllm/overlays/kubeadm/amd` | vllm | No |
| `vllm-finetune` | `vllm/overlays/kubeadm/finetune` | vllm | No |
| `vllm-benchmark` | `vllm/benchmark` | vllm | No |
| `nginx` | `nginx` | default | Yes |
| `nexus` | `nexus` | nexus | Yes |
| `cert-manager` | `cert-manager` | cert-manager | Yes |
| `agents` | `agents/hermes` | agents | Yes |
| `prometheus` | `prometheus` | monitoring | Yes |
| `monitoring` | `monitoring` | monitoring | No |
| `gitlab` | `gitlab` (Helm) | gitlab | No |
| `jenkins` | `jenkins` (Helm) | jenkins | No |
| `actions-runner-controller` | `actions-runner-controller` (Helm) | actions-runner-system | No |
| `github-runners` | `github-runners` (Helm) | github-runners | No |
| `elk-stack` | `elk-stack` | elk-stack | No |

詳細・廃止パス: [argocd/apps/DEPRECATED.md](../argocd/apps/DEPRECATED.md)

## sync policy 方針

- **Auto**: 軽量 infra（nginx, nexus, cert-manager, agents, prometheus）
- **Manual**: GPU/排他 vLLM、stateful（gitlab, jenkins, elk-stack）、namespace 競合（monitoring）、Secret 必須（github-runners）

### 注意

- `prometheus` と `monitoring` は同一 namespace `monitoring` を使用。同時 auto-sync しないこと。
- `vllm-kubeadm` と `vllm-amd` は namespace `vllm` で排他。
## 検証

```bash
./scripts/validate.sh
```

## UI アクセス

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080
```

## 参考

- [argocd/README.md](../argocd/README.md)
- [Argo CD 公式ドキュメント](https://argo-cd.readthedocs.io/)
