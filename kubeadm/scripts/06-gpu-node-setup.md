# GPU ノードセットアップ（kubeadm クラスタ向け）

Linux ワーカーに GPU ドライバを入れた後、クラスタ側で Device Plugin とスケジューリング設定を行います。

## 前提

| 項目 | NVIDIA | AMD (ROCm) |
|------|--------|------------|
| ホスト | ドライバ + `nvidia-smi` | ROCm + `rocminfo`（必須）、`amd-smi`（推奨・gfx1010 では任意） |
| Device Plugin | [NVIDIA k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) | [ROCm k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin) |
| リソース名 | `nvidia.com/gpu` | `amd.com/gpu` |

## 1. ノード参加後のラベル（推奨）

```bash
# NVIDIA 推論 (vllm/)
kubectl label node <gpu-node> nvidia.com/gpu.present=true --overwrite
kubectl label node <gpu-node> workload=vllm --overwrite

# AMD 推論 / 学習 (vllm/overlays/kubeadm/amd/, vllm/overlays/kubeadm/finetune/)
kubectl label node <gpu-node> amd.com/gpu.present=true --overwrite
kubectl label node <gpu-node> workload=vllm-amd --overwrite
```

## 2. 専用 GPU ノード用 taint（任意）

```bash
kubectl taint nodes <gpu-node> nvidia.com/gpu=:NoSchedule --overwrite
# または AMD
kubectl taint nodes <gpu-node> amd.com/gpu=:NoSchedule --overwrite
```

`vllm/base/vllm-deployment.yaml` / `vllm/components/amd/vllm-deployment.yaml` 内の `tolerations` / `nodeSelector` コメントを解除してください。

## 3. Device Plugin デプロイ

クラスタアドオンから適用:

```bash
kubectl apply -k kubeadm/addons/nvidia-device-plugin/   # NVIDIA ノードのみ
# AMD: 公式 Helm/マニフェストを参照（下記）
```

### NVIDIA（本リポジトリ）

```bash
kubectl apply -k kubeadm/addons/nvidia-device-plugin/
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl describe node <gpu-node> | grep -A5 'Capacity:'
```

### AMD（参照のみ — 環境依存）

ROCm Device Plugin はクラスタ/ドライバ版に依存するため、スタブとして公式手順を参照:

```bash
# 例: GPU Operator（推奨される場合あり）
# https://instinct.docs.amd.com/projects/gpu-operator/

# または k8s-device-plugin manifest
# kubectl apply -f https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml
```

`kubeadm/addons/amd-gpu-device-plugin/README.md` も参照。

## 4. 動作確認

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu',AMD:.status.capacity.'amd\.com/gpu'
kubectl -n vllm get pods -o wide
```

## 5. vLLM デプロイ

```bash
# kubeadm + local-path ストレージ
kubectl apply -k vllm/overlays/kubeadm/
kubectl apply -k vllm/overlays/kubeadm/amd/
kubectl apply -k vllm/overlays/kubeadm/finetune/
```

Argo CD: `vllm-kubeadm`（NVIDIA auto sync）、`vllm-amd` / `vllm-finetune`（manual）。同一 namespace で推論スタックは 1 つのみ auto sync すること。
