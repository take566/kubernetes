# kubeadm クラスタ接続（Windows / WSL）

GPU Teacher 検証や `vllm/overlays/kubeadm` の確認は **実 GPU 付き kubeadm クラスタ** が必要です。本リポジトリの `kubeadm/` は Linux ノード上での bootstrap 用であり、**リモート接続用の kubeconfig や SSH トンネルは同梱されていません**（`kubeadm/README.md` の `scp admin.conf` 手順のみ）。

## 現状の kubectl コンテキスト（よくある誤解）

| コンテキスト | 実体 | GPU |
|-------------|------|-----|
| `kind-dev` | kind（WSL/Docker） | なし |
| `awx` | **minikube プロファイル名**（kubeadm ではない） | 通常なし |

`awx` の API は `https://127.0.0.1:<動的ポート>`（minikube）です。コンテナが停止していると `connection refused` になります。GPU Teacher 用の kubeadm とは別物です。

## 前提

- control-plane または jump ホストへ **SSH** できること
- クラスタ側に `/etc/kubernetes/admin.conf` があること（`03-init-control-plane.sh` 実行済み）
- API がプライベート IP のみの場合は **SSH ローカルフォワード** が必要

`kubeadm/kubeadm-config.yaml` のプレースホルダ（本番では置き換え済みのはず）:

- `controlPlaneEndpoint`: `cp.example.com:6443`
- `advertiseAddress`: `192.168.1.10`

## 手順 A: スクリプトで取得・マージ（推奨）

環境変数（Linux/WSL）:

| 変数 | 説明 | 例 |
|------|------|-----|
| `KUBEADM_SSH_TARGET` | SSH 先（user@host） | `ubuntu@192.168.1.10` |
| `KUBEADM_CONTEXT_NAME` | マージ後の context 名 | `kubeadm-prod`（既定） |
| `KUBEADM_SERVER_URL` | API URL の上書き（トンネル利用時など） | `https://127.0.0.1:16443` |

### Linux / WSL

```bash
cd /path/to/kubernetes
export KUBEADM_SSH_TARGET=user@CONTROL_PLANE
export KUBEADM_CONTEXT_NAME=kubeadm-prod
# API が直接届く場合は省略可。トンネル利用時は fetch 後に設定:
# export KUBEADM_SERVER_URL=https://127.0.0.1:16443

./scripts/kubeadm-connect.sh status
./scripts/kubeadm-connect.sh fetch
./scripts/kubeadm-connect.sh tunnel   # 別ターミナル。KUBEADM_SSH_TARGET を使用
./scripts/kubeadm-connect.sh verify
```

`fetch` は control-plane 上で `kubeadm/scripts/08-export-kubeconfig.sh` を実行し、`CONTROL_PLANE_DNS:6443` に書き換えた kubeconfig を `~/.kube/config-kubeadm` に取得してマージします。証明書・トークンはログに出力しません。

control-plane 上で手動エクスポートする場合:

```bash
export CONTROL_PLANE_DNS=cp.example.com
sudo ./kubeadm/scripts/08-export-kubeconfig.sh /tmp/kubeconfig-export.conf
```

### Windows (PowerShell)

```powershell
cd D:\work\kubernetes
.\scripts\kubeadm-connect.ps1 -Action fetch -SshTarget user@CONTROL_PLANE -ContextName kubeadm-prod
# トンネル経由の場合は fetch 後、または -ServerUrl を指定:
.\scripts\kubeadm-connect.ps1 -Action fetch -SshTarget user@CONTROL_PLANE -ServerUrl https://127.0.0.1:16443
.\scripts\kubeadm-connect.ps1 -Action tunnel -SshTarget user@CONTROL_PLANE -LocalPort 16443
.\scripts\kubeadm-connect.ps1 -Action verify -Context kubeadm-prod
```

## 手順 B: kubeconfig を手動で取得してマージ

### 1. admin.conf を Windows にコピー

PowerShell（OpenSSH）:

```powershell
scp user@CONTROL_PLANE:/etc/kubernetes/admin.conf $env:USERPROFILE\.kube\config-kubeadm
```

WSL:

```bash
scp user@CONTROL_PLANE:/etc/kubernetes/admin.conf ~/.kube/config-kubeadm
```

### 2. サーバー URL をトンネル用に書き換え（API が localhost 経由のとき）

admin.conf 内の `clusters[].cluster.server` がプライベート IP の場合、トンネル利用時は `https://127.0.0.1:16443` などに変更するか、マージ後に `kubectl config set-cluster` で上書きします。

### 3. コンテキストをマージ

```powershell
$env:KUBECONFIG = "$env:USERPROFILE\.kube\config;$env:USERPROFILE\.kube\config-kubeadm"
kubectl config view --flatten | Set-Content $env:USERPROFILE\.kube\config -Encoding utf8
kubectl config rename-context kubernetes-admin@kubernetes kubeadm-prod
kubectl config use-context kubeadm-prod
```

（元の context 名は admin.conf により `kubernetes-admin@kubernetes` など異なる場合があります。`kubectl config get-contexts` で確認。）

### 4. SSH トンネル（API が直接届かない場合）

別ターミナルで維持:

```powershell
ssh -N -L 16443:127.0.0.1:6443 user@CONTROL_PLANE
# または API がノード LAN IP のみで listen している場合:
ssh -N -L 16443:192.168.1.10:6443 user@JUMP_OR_CP
```

トンネル利用時:

```powershell
kubectl config set-cluster $(kubectl config view -o jsonpath='{.contexts[?(@.name=="kubeadm-prod")].context.cluster}') --server=https://127.0.0.1:16443
```

## 手順 C: 個別アクション（既に kubeconfig がある場合）

```powershell
cd D:\work\kubernetes
.\scripts\kubeadm-connect.ps1 -Action status
.\scripts\kubeadm-connect.ps1 -Action merge -KubeconfigPath "$env:USERPROFILE\.kube\config-kubeadm" -ContextName kubeadm-prod
.\scripts\kubeadm-connect.ps1 -Action tunnel -SshTarget user@CONTROL_PLANE -LocalPort 16443 -RemoteHost 127.0.0.1 -RemotePort 6443
.\scripts\kubeadm-connect.ps1 -Action verify -Context kubeadm-prod
```

```bash
./scripts/kubeadm-connect.sh merge ~/.kube/config-kubeadm
KUBEADM_SSH_TARGET=user@CONTROL_PLANE ./scripts/kubeadm-connect.sh tunnel
./scripts/kubeadm-connect.sh verify
```

## 接続確認と GPU

```powershell
kubectl --context kubeadm-prod get nodes -o wide
kubectl --context kubeadm-prod get nodes -o custom-columns=NAME:.metadata.name,NVIDIA_GPU:.status.allocatable.nvidia\.com/gpu,AMD_GPU:.status.allocatable.amd\.com/gpu
kubectl --context kubeadm-prod get pods -A -l app=nvidia-device-plugin-daemonset
kubectl --context kubeadm-prod get pods -A -l name=amdgpu-dp-ds
```

GPU が空の場合は [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md) と `kubeadm/addons/apply-addons.sh --with-nvidia` を参照。

AMD GPU ワーカー追加手順は [docs/GPU_WORKER_JOIN_AMD.md](GPU_WORKER_JOIN_AMD.md) を参照。

## awx（minikube）を再度使う場合（kubeadm 代替ではない）

```powershell
minikube start -p awx
kubectl config use-context awx
```

GPU Teacher の本番相当検証には **kubeadm + GPU ワーカー** を優先してください。

## トラブルシュート

| 症状 | 対処 |
|------|------|
| `connection refused` @ 127.0.0.1 | minikube/kind が停止、または SSH トンネル未起動 |
| `certificate signed by unknown authority` | 別クラスタの kubeconfig をマージしていないか確認 |
| `Unable to connect to the server` | `server` URL とトンネル先ポートの不一致 |
| context はあるが GPU なし | 正しいクラスタか確認（kind/minikube では不可） |

## 関連

- [kubeadm/README.md](../kubeadm/README.md)
- [docs/LOCAL_GPU_SETUP_WINDOWS.md](LOCAL_GPU_SETUP_WINDOWS.md)
- [vllm/overlays/kubeadm/README.md](../vllm/overlays/kubeadm/README.md)
