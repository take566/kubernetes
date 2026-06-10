# AMD GPU Device Plugin（参照）

kubeadm アドオンには AMD Device Plugin の固定マニフェストを含めていません。ROCm / GPU 型番 / Operator 選定は環境依存のため、公式手順に従ってください。

## 推奨リンク

- [ROCm k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin)
- [AMD GPU Operator](https://instinct.docs.amd.com/projects/gpu-operator/)
- [Device Plugin 設定](https://instinct.docs.amd.com/projects/k8s-device-plugin/en/latest/user-guide/configuration.html)

## デプロイ例

```bash
# シンプルな DaemonSet（単一 GPU リソース amd.com/gpu）
kubectl apply -f https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml

# ラベル確認
kubectl label node <node> amd.com/gpu.present=true --overwrite
```

vLLM AMD スタック: `kubectl apply -k vllm/amd/`
