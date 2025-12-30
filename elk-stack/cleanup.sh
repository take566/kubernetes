#!/bin/bash

echo "ELK Stackを削除しています..."

# 名前空間ごと削除
echo "名前空間とすべてのリソースを削除中..."
kubectl delete namespace elk-stack

echo "ELK Stackの削除が完了しました！"
