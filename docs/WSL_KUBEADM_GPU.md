# WSL2 荳翫・ kubeadm + NVIDIA GPU vLLM

Windows 11 + WSL2 (Ubuntu 24.04) 縺ｧ蜊倅ｸ繝弱・繝・kubeadm 繧ｯ繝ｩ繧ｹ繧ｿ繧堤ｫ九※縲～vllm/overlays/kubeadm/gtx1650/` 繧偵ョ繝励Ο繧､縺吶ｋ謇矩・〒縺吶・
## 蜑肴署

| 鬆・岼 | 蜀・ｮｹ |
|------|------|
| GPU | NVIDIA GeForce GTX 1650 4GB・医ラ繝ｩ繧､繝舌・ Windows 蛛ｴ・・|
| WSL | Ubuntu-24.04・・docker-desktop` 縺ｮ縺ｿ縺ｧ縺ｯ荳榊庄・・|
| 繝帙せ繝・| Docker Desktop / Ollama 縺ｧ GPU 貂医∩縺ｧ縺ゅｋ縺薙→ |
| 繝ｪ繝昴ず繝医Μ | `C:\work\kubernetes` 竊・WSL 縺ｧ縺ｯ `/mnt/c/work/kubernetes` |

`wsl -l -v` 縺ｧ **Ubuntu-24.04** 縺・Version 2 縺ｧ縺ゅｋ縺薙→繧堤｢ｺ隱阪＠縺ｦ縺上□縺輔＞縲よ悴蟆主・譎・

```powershell
wsl --install Ubuntu-24.04
```

蛻晏屓襍ｷ蜍輔〒 Linux 繝ｦ繝ｼ繧ｶ繝ｼ繧剃ｽ懈・縺励～/etc/wsl.conf` 縺ｧ systemd 繧呈怏蜉ｹ蛹悶＠縺ｾ縺呻ｼ域里螳壹〒 Ubuntu 24.04 縺ｯ譛牙柑縺ｪ縺薙→縺悟､壹＞・・

```ini
[boot]
systemd=true
```

## 繧ｯ繧､繝・け繧ｹ繧ｿ繝ｼ繝・
```powershell
wsl -d Ubuntu-24.04
```

```bash
cd /mnt/c/work/kubernetes
sudo bash scripts/setup-wsl-kubeadm.sh
```

繧ｹ繧ｯ繝ｪ繝励ヨ縺ｯ谺｡繧定｡後＞縺ｾ縺吶・
1. 繝ｪ繝昴ず繝医Μ繧・`~/kubernetes-wsl` 縺ｫ繧ｳ繝斐・・・RLF 竊・LF・・2. `containerd` / `kubelet` 縺ｮ襍ｷ蜍暮・ｒ隱ｿ謨ｴ
3. [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/) 繧・containerd 縺ｫ險ｭ螳・4. `kubeadm/bootstrap.sh --role init --with-nvidia`
5. 蜊倅ｸ繝弱・繝臥畑縺ｫ control-plane taint 繧定ｧ｣髯､縲；PU 繝ｩ繝吶Ν莉倅ｸ・6. `kubectl apply -k vllm/overlays/kubeadm/gtx1650/`

## 謇句虚繝悶・繝医せ繝医Λ繝・・・亥盾閠・ｼ・
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

GPU 繝弱・繝画焔鬆・・隧ｳ邏ｰ: [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)

## 讀懆ｨｼ繧ｳ繝槭Φ繝・
```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl -n vllm get pods -o wide
kubectl -n vllm port-forward svc/vllm 8000:8000
curl -s http://127.0.0.1:8000/health
# NodePort: curl -s http://$(hostname -I | awk '{print $1}'):30800/health
```

## GTX 1650 蜷代￠ vLLM 險ｭ螳・
| 險ｭ螳・| 蛟､ |
|------|-----|
| Overlay | `vllm/overlays/kubeadm/gtx1650/` |
| 繝｢繝・Ν | Qwen2.5-0.5B-Instruct |
| 繝｡繝｢繝ｪ | requests 4Gi / limits 8Gi |
| vLLM 繝輔Λ繧ｰ | `--gpu-memory-utilization 0.75`, `--max-model-len 2048`, `--enforce-eager` |

Windows 繝阪う繝・ぅ繝・Docker 縺ｨ縺ｮ謨ｴ蜷・ [scripts/run-vllm-docker.ps1](../scripts/run-vllm-docker.ps1)

## 譌｢遏･縺ｮ繝ｪ繧ｹ繧ｯ繝ｻ繝医Λ繝悶Ν繧ｷ繝･繝ｼ繝・
1. **`kubeadm config validate` 螟ｱ謨・* 窶・`kubeadm/kubeadm-config.yaml` 縺ｯ蜈磯ｭ縺・`---` 縺ｮ繝槭Ν繝√ラ繧ｭ繝･繝｡繝ｳ繝医〒縺ゅｋ蠢・ｦ√′縺ゅｊ縺ｾ縺呻ｼ亥・鬆ｭ縺ｫ繧ｳ繝｡繝ｳ繝医・縺ｿ縺ｮ繝悶Ο繝・け繧堤ｽｮ縺九↑縺・ｼ峨・2. **WSL 縺ｧ kubelet / containerd 縺ｮ遶ｶ蜷・* 窶・`containerd` 縺瑚ｵｷ蜍輔☆繧句燕縺ｫ `kubelet` 縺御ｸ翫′繧九→ API 縺瑚誠縺｡縺ｾ縺吶Ａsystemctl enable --now containerd` 縺ｮ蠕後↓ `kubelet` 繧貞・襍ｷ蜍輔＠縺ｦ縺上□縺輔＞縲・3. **`/mnt/c` 荳翫〒 `*.sh` 繧堤峩謗･螳溯｡・* 窶・CRLF 縺ｧ螢翫ｌ繧九◆繧√∝ｿ・★ `~/kubernetes-wsl` 縺ｫ繧ｳ繝斐・縺励※ `dos2unix` 縺励※縺上□縺輔＞縲・4. **4GB VRAM** 窶・譌｢螳壹・ `vllm/overlays/kubeadm/`・・.5B・峨・ OOM 縺励ｄ縺吶＞縲・TX 1650 縺ｯ `gtx1650` overlay 繧剃ｽｿ逕ｨ縲・5. **蜊倅ｸ繝弱・繝・* 窶・control-plane taint 隗｣髯､縺悟ｿ・ｦ√よ悽逡ｪ HA 讒区・縺ｯ Linux VM 繧呈耳螂ｨ・・kubeadm/README.md](../kubeadm/README.md)・峨・
## 髢｢騾｣繝峨く繝･繝｡繝ｳ繝・
- [docs/LOCAL_GPU_SETUP_WINDOWS.md](LOCAL_GPU_SETUP_WINDOWS.md)
- [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)
- [vllm/overlays/kubeadm/gtx1650/README.md](../vllm/overlays/kubeadm/gtx1650/README.md)

## API 縺・6443 refused 縺ｮ縺ｨ縺・
Calico 縺・API 縺ｪ縺励〒繧ｵ繝ｳ繝峨・繝・け繧ｹ蜑企勁縺ｧ縺阪★ kubelet 縺瑚ｩｰ縺ｾ繧九％縺ｨ縺後≠繧翫∪縺吶・
sudo bash scripts/wsl-api-recover.sh

API 縺・ok 縺ｫ縺ｪ縺｣縺溘ｉ騾壼ｸｸ縺ｩ縺翫ｊ Calico / 繧｢繝峨が繝ｳ繧貞・驕ｩ逕ｨ縺励∪縺吶・## vLLM / GPU 縺御ｸ榊ｮ牙ｮ壹↑縺ｨ縺搾ｼ・SL 蜀崎ｵｷ蜍募ｾ後↑縺ｩ・・
1. API 蠕ｩ譌ｧ: `sudo bash scripts/wsl-api-recover.sh`・・KUBECONFIG=/etc/kubernetes/admin.conf`・・2. vLLM繝ｻdevice plugin 蜀榊酔譛・ `sudo bash scripts/wsl-recover-vllm.sh`  
   - DaemonSet 縺ｮ `wsl-patch` 縺梧里縺ｫ蠖薙◆縺｣縺ｦ縺・ｋ縺ｨ duplicate volume 繧ｨ繝ｩ繝ｼ縺悟・縺ｾ縺吶′辟｡隕悶＠縺ｦ讒九＞縺ｾ縺帙ｓ縲・3. Pod 縺・`ContainerStatusUnknown` 縺ｮ縺ｨ縺・  
   `kubectl -n vllm delete pod -l app=vllm --force --grace-period=0` 縺ｮ縺ゅ→ `kubectl -n vllm rollout restart deployment/vllm`
4. 遒ｺ隱・

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status,GPU:.status.allocatable.nvidia\\.com/gpu
kubectl -n vllm get pods -o wide
curl -sf http://127.0.0.1:30800/health && echo ok
curl -sf --connect-timeout 120 http://127.0.0.1:30800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```

`nvidia.com/gpu` 縺ｮ allocatable 縺・0 縺ｮ縺ｨ縺阪・ device plugin Pod 縺・Running 縺ｫ縺ｪ繧九∪縺ｧ蠕・▽縺九∽ｸ願ｨ・2 繧貞・螳溯｡後＠縺ｦ縺上□縺輔＞縲ゅ・繝ｩ繧ｰ繧､繝ｳ豁｣蟶ｸ蠕後・ **1** 縺ｨ陦ｨ遉ｺ縺輔ｌ繧九％縺ｨ繧堤｢ｺ隱肴ｸ医∩縺ｧ縺吶・
Windows 蛛ｴ縺ｮ逍朱夂｢ｺ隱・ `.\scripts\verify-vllm-windows.ps1`・・ocker `vllm-gtx1650` :8000・峨・
