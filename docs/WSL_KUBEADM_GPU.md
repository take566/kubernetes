# WSL2 上の kubeadm + NVIDIA GPU vLLM

Windows 11 + WSL2 (Ubuntu 24.04) で単一ノード kubeadm クラスタを立て、`vllm/overlays/kubeadm/gtx1650/` をデプロイする手順です。

## 前提

| 項目 | 内容 |
|------|------|
| GPU | NVIDIA GeForce GTX 1650 4GB（ドライバは Windows 側） |
| WSL | Ubuntu-24.04（`docker-desktop` のみでは不可） |
| ホスト | Docker Desktop / Ollama で GPU 済みであること |
| リポジトリ | `C:\work\kubernetes` → WSL では `/mnt/c/work/kubernetes` |

`wsl -l -v` で **Ubuntu-24.04** が Version 2 であることを確認してください。未導入時:

```powershell
wsl --install Ubuntu-24.04
```

初回起動で Linux ユーザーを作成し、`/etc/wsl.conf` で systemd を有効化します（既定で Ubuntu 24.04 は有効なことが多い）:

```ini
[boot]
systemd=true
```

## クイックスタート

```powershell
wsl -d Ubuntu-24.04
```

```bash
cd /mnt/c/work/kubernetes
sudo bash scripts/setup-wsl-kubeadm.sh
```

スクリプトは次を行います。

1. リポジトリを `~/kubernetes-wsl` にコピー（CRLF → LF）
2. `containerd` / `kubelet` の起動順を調整
3. [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/) を containerd に設定
4. `kubeadm/bootstrap.sh --role init --with-nvidia`
5. 単一ノード用に control-plane taint を解除、GPU ラベル付与
6. `kubectl apply -k vllm/overlays/kubeadm/gtx1650/`

## 手動ブートストラップ（参考）

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
IP=$(hostname -I | awk '{print $1}')
export CONTROL_PLANE_IP="$IP"
cd ~/kubernetes-wsl
sudo ./kubeadm/bootstrap.sh --role init --with-nvidia
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl label node <node> nvidia.com/gpu.present=true workload=vllm --overwrite
kubectl apply -k vllm/overlays/kubeadm/gtx1650/
```

GPU ノード手順の詳細: [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)

## 検証コマンド

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl -n vllm get pods -o wide
kubectl -n vllm port-forward svc/vllm 8000:8000
curl -s http://127.0.0.1:8000/health
# NodePort: curl -s http://$(hostname -I | awk '{print $1}'):30800/health
```

## GTX 1650 向け vLLM 設定

| 設定 | 値 |
|------|-----|
| Overlay | `vllm/overlays/kubeadm/gtx1650/` |
| モデル | Qwen2.5-0.5B-Instruct |
| メモリ | requests 4Gi / limits 8Gi |
| vLLM フラグ | `--gpu-memory-utilization 0.75`, `--max-model-len 2048`, `--enforce-eager` |

Windows ネイティブ Docker との整合: [scripts/run-vllm-docker.ps1](../scripts/run-vllm-docker.ps1)

## 既知のリスク・トラブルシュート

1. **`kubeadm config validate` 失敗** — `kubeadm/kubeadm-config.yaml` は先頭が `---` のマルチドキュメントである必要があります（先頭にコメントのみのブロックを置かない）。
2. **WSL で kubelet / containerd の競合** — `containerd` が起動する前に `kubelet` が上がると API が落ちます。`systemctl enable --now containerd` の後に `kubelet` を再起動してください。
3. **`/mnt/c` 上で `*.sh` を直接実行** — CRLF で壊れるため、必ず `~/kubernetes-wsl` にコピーして `dos2unix` してください。
4. **4GB VRAM** — 既定の `vllm/overlays/kubeadm/`（1.5B）は OOM しやすい。GTX 1650 は `gtx1650` overlay を使用。
5. **単一ノード** — control-plane taint 解除が必要。本番 HA 構成は Linux VM を推奨（[kubeadm/README.md](../kubeadm/README.md)）。

## 関連ドキュメント

- [docs/LOCAL_GPU_SETUP_WINDOWS.md](LOCAL_GPU_SETUP_WINDOWS.md)
- [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)
- [vllm/overlays/kubeadm/gtx1650/README.md](../vllm/overlays/kubeadm/gtx1650/README.md)
