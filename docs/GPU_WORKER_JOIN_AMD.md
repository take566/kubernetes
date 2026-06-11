# AMD GPU ワーカー接続 Runbook（Linux + kubeadm）

`kind` は Docker 内クラスタのため、**外部 Linux ワーカーを join できません**。  
AMD GPU ワーカーを追加する場合は、`kubeadm/` の別クラスタを使います。

## Phase 0: 前提チェック

```bash
# 管理端末（Windows/WSL/Linux）
cd /path/to/kubernetes
kubectl config current-context
kubectl get nodes -o wide
```

チェックリスト:

- control-plane へ SSH できる
- ワーカーは Ubuntu 24.04（ベアメタル Linux）
- ワーカーで `kubeadm/scripts/01-prerequisites.sh` / `02-install-kubeadm.sh` 実行済み
- 管理者側で kubeadm クラスタに `kubectl` 接続済み（`docs/kubeadm-connect.md`）

## Phase 1: kubeadm control-plane bootstrap（新規時のみ）

既存クラスタがあるならスキップ。

```bash
# control-plane
cd /path/to/kubernetes
sudo kubeadm/scripts/01-prerequisites.sh
sudo kubeadm/scripts/02-install-kubeadm.sh
sudo CONTROL_PLANE_IP=192.168.1.10 CONTROL_PLANE_DNS=cp.example.com kubeadm/scripts/03-init-control-plane.sh
sudo kubeadm/scripts/05-install-cni.sh
sudo kubeadm/addons/apply-addons.sh
```

join コマンド発行:

```bash
kubeadm token create --print-join-command
```

## Phase 2: Linux GPU ワーカー（ROCm + join）

```bash
# GPU worker
cd /path/to/kubernetes
sudo kubeadm/scripts/01-prerequisites.sh
sudo kubeadm/scripts/02-install-kubeadm.sh

# ROCm インストール（変更なし確認）
sudo kubeadm/scripts/05-install-rocm-worker.sh --check

# ROCm 本実行
sudo kubeadm/scripts/05-install-rocm-worker.sh
source /etc/profile.d/rocm-rx5700.sh
rocminfo | head -40
amd-smi version || amd-smi static || rocm-smi
./scripts/verify-amd-smi.sh
```

RX 5700（RDNA1/gfx1010）は下記が必要です:

```bash
echo "HSA_OVERRIDE_GFX_VERSION=10.3.0" | sudo tee -a /etc/environment
```

ワーカー join:

```bash
sudo kubeadm/scripts/04-join-worker.sh --join 'kubeadm join cp.example.com:6443 --token ... --discovery-token-ca-cert-hash sha256:...'
```

## Phase 3: 管理者側で GPU ノード登録

`setup-amd-gpu-node.sh` 相当の処理（device plugin 適用、ラベル付与、allocatable 確認、必要なら vLLM overlay）。

```bash
# 管理者端末（kubectl が kubeadm cluster を向いていること）
cd /path/to/kubernetes

# 登録のみ
./kubeadm/scripts/07-register-gpu-worker.sh --node <GPU_NODE_NAME> --vendor amd

# vLLM AMD overlay まで適用
./kubeadm/scripts/07-register-gpu-worker.sh --node <GPU_NODE_NAME> --vendor amd --apply-vllm --overlay kubeadm/amd
```

既存スクリプトを直接使う場合:

```bash
NODE_NAME=<GPU_NODE_NAME> OVERLAY=kubeadm/amd ./scripts/setup-amd-gpu-node.sh
```

## Phase 4: Windows から kubectl 接続

```powershell
cd D:\work\kubernetes
.\scripts\kubeadm-connect.ps1 -Action status
.\scripts\kubeadm-connect.ps1 -Action merge -KubeconfigPath "$env:USERPROFILE\.kube\config-kubeadm" -ContextName kubeadm-prod
.\scripts\kubeadm-connect.ps1 -Action verify -Context kubeadm-prod
```

## Troubleshooting

| 症状 | 確認コマンド | 対処 |
|---|---|---|
| `kind` に worker join できない | `kubectl config current-context` | `kind` では不可。`kubeadm` クラスタで実施 |
| `rocminfo` で GPU が見えない | `rocminfo \| head -40` | ROCm 再導入、カーネル/ドライバ確認 |
| RX5700 で推論初期化失敗 | `echo $HSA_OVERRIDE_GFX_VERSION` | `HSA_OVERRIDE_GFX_VERSION=10.3.0` を `/etc/environment` へ設定 |
| `amd.com/gpu` が 0 のまま | `kubectl get node <n> -o jsonpath='{.status.allocatable.amd\.com/gpu}'` | device plugin Pod とホスト側 ROCm を確認 |
| AMD plugin Pod がいない | `kubectl get pods -A -l name=amdgpu-dp-ds` | `kubeadm/addons/apply-addons.sh --with-amd` または `07-register-gpu-worker.sh` 再実行 |
| vLLM Pod が Pending | `kubectl -n vllm get pods` | ノードラベル `workload=vllm-amd` と allocatable GPU を確認 |
