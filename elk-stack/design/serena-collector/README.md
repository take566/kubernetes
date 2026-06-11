# Serena Log Collector (Windows)

Windows ホスト上の Serena MCP ログを tail し、構造化 JSON として Logstash TCP `:5000` に送信します。

## 前提

1. ELK スタックが `elk-stack` 名前空間にデプロイ済み
2. `kubectl port-forward` で Logstash TCP 5000 がローカルに転送されている

```powershell
# リポジトリルートから
.\elk-stack\start-elk-portforward.ps1
```

## インストール

```powershell
cd elk-stack\design\serena-collector
pip install -r requirements.txt
```

`watchdog` は任意です。未インストール時はポーリングで動作します。

## 収集対象

| ストリーム | パス | `serena.stream` |
|-----------|------|-----------------|
| MCP ファイルログ | `%USERPROFILE%\.serena\logs\<YYYY-MM-DD>\mcp_*.txt` | `mcp.file` |
| Health-check | `<project>\.serena\logs\health-checks\health_check_*.log` | `health_check` |

起動時は既存ファイルの末尾から読み始めます（全履歴の再送はしません）。新規行とローテーション（新しい `mcp_*.txt`）を検知します。

## 使い方

### CLI 引数

```powershell
python collector.py --logstash localhost:5000 --projects "d:\work\kubernetes","d:\work\serena"
```

### 設定ファイル

```powershell
copy collector-config.example.yml $env:USERPROFILE\.serena\collector-config.yml
# プロジェクトパスを編集
python collector.py --config $env:USERPROFILE\.serena\collector-config.yml
```

### 送信イベント例

```json
{
  "@timestamp": "2026-05-23T08:12:56.701Z",
  "event": { "kind": "serena.log" },
  "serena": {
    "stream": "mcp.file",
    "session_id": "mcp_20260523-081256",
    "project": "d:\\work\\kubernetes",
    "host": "DESKTOP-EXAMPLE",
    "logger": "serena.cli",
    "function": "start_mcp_server",
    "line": 166
  },
  "log": { "level": "INFO", "thread": "MainThread" },
  "message": "Initializing Serena MCP server",
  "host": { "os": { "type": "windows" } }
}
```

## Task Scheduler 登録

Collector を Windows ログオン時に自動起動する手順です。

### 1. 起動用バッチを作成

`%USERPROFILE%\.serena\start-serena-collector.bat` を作成:

```bat
@echo off
cd /d D:\work\kubernetes\elk-stack\design\serena-collector
python collector.py --config %USERPROFILE%\.serena\collector-config.yml >> %USERPROFILE%\.serena\collector.log 2>&1
```

パスは環境に合わせて変更してください。

### 2. タスクの作成（PowerShell）

```powershell
$action = New-ScheduledTaskAction `
  -Execute "$env:USERPROFILE\.serena\start-serena-collector.bat"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask `
  -TaskName "Serena Log Collector" `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description "Ship Serena MCP logs to ELK via Logstash TCP 5000"
```

### 3. port-forward も自動化する場合

Collector は `localhost:5000` へ送るため、ELK port-forward も起動している必要があります。別タスクとして:

```powershell
$pfAction = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File D:\work\kubernetes\elk-stack\start-elk-portforward.ps1"
$pfTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask `
  -TaskName "ELK Port Forward" `
  -Action $pfAction `
  -Trigger $pfTrigger `
  -Description "kubectl port-forward for ELK (incl. Logstash TCP 5000)"
```

`start-elk-portforward.ps1` は対話プロンプトを含むため、本番運用では非対話版への分割を検討してください。

### 4. 動作確認

```powershell
# Collector ログ
Get-Content $env:USERPROFILE\.serena\collector.log -Tail 20

# Kibana / ES（port-forward 9200 後）
curl "http://localhost:9200/logs-serena/_search?q=event.kind:serena.log&size=3&pretty"
```

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| 接続エラー `logstash send failed` | `start-elk-portforward.ps1` で TCP 5000 が転送されているか確認 |
| Kibana にログが出ない | Logstash serena フィルタと `logs-serena` テンプレートが適用済みか確認 |
| health-check が取れない | `--projects` / 設定ファイルのプロジェクトパスを確認 |
| 重複イベント | 同一内容は起動中メモリで dedup（再起動後は再送されうる） |

## 関連ドキュメント

- [docs/design/elk-stack-serena-logs-llm.md](../../../docs/design/elk-stack-serena-logs-llm.md) — 統合設計
- [elk-stack/README.md](../../README.md) — ELK デプロイと Serena 連携概要
