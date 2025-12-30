#!/bin/bash
#
# Raspberry Pi rsyslog 設定スクリプト
# このスクリプトをRaspberry Pi上で実行してください
#
# 使用方法:
#   chmod +x setup-raspi-rsyslog.sh
#   sudo ./setup-raspi-rsyslog.sh <WINDOWS_HOST_IP> [udp|tcp]
#
# 例:
#   sudo ./setup-raspi-rsyslog.sh 192.168.0.100 udp
#

set -e

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 引数チェック
if [ $# -lt 1 ]; then
    echo -e "${RED}エラー: 引数が不足しています${NC}"
    echo "使用方法: $0 <WINDOWS_HOST_IP> [udp|tcp]"
    echo "例: $0 192.168.0.100 udp"
    exit 1
fi

WINDOWS_HOST_IP=$1
PROTOCOL=${2:-udp}  # デフォルトはUDP
PORT=514

# プロトコル記号設定
if [ "$PROTOCOL" == "tcp" ]; then
    PROTO_SYMBOL="@@"
    PROTO_NAME="TCP"
else
    PROTO_SYMBOL="@"
    PROTO_NAME="UDP"
fi

echo -e "${BLUE}=== Raspberry Pi rsyslog 設定スクリプト ===${NC}"
echo ""
echo "設定情報:"
echo "  Windows Host IP: $WINDOWS_HOST_IP"
echo "  ポート: $PORT"
echo "  プロトコル: $PROTO_NAME"
echo ""

# rootチェック
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}このスクリプトはroot権限で実行する必要があります${NC}"
    echo "sudo $0 $@"
    exit 1
fi

# rsyslogインストール確認
if ! command -v rsyslogd &> /dev/null; then
    echo -e "${YELLOW}rsyslogがインストールされていません。インストールします...${NC}"
    apt-get update
    apt-get install -y rsyslog
fi

# バックアップ
BACKUP_DIR="/etc/rsyslog.d/backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

if [ -f /etc/rsyslog.d/50-elk.conf ]; then
    echo -e "${YELLOW}既存の設定をバックアップします...${NC}"
    cp /etc/rsyslog.d/50-elk.conf "$BACKUP_DIR/50-elk.conf.$TIMESTAMP"
fi

# rsyslog設定ファイル作成
CONFIG_FILE="/etc/rsyslog.d/50-elk.conf"
echo -e "${GREEN}設定ファイルを作成します: $CONFIG_FILE${NC}"

cat > "$CONFIG_FILE" << EOF
# ELK Stack rsyslog 設定
# 作成日時: $(date)
# Windows Host: $WINDOWS_HOST_IP:$PORT ($PROTO_NAME)
# Raspberry Pi: $(hostname) ($(hostname -I | awk '{print $1}'))

# すべてのログをELKスタックに転送
*.* $PROTO_SYMBOL$WINDOWS_HOST_IP:$PORT

# 特定のログのみ転送する場合は、上記をコメントアウトして以下を使用:
# kern.*,user.*,daemon.* $PROTO_SYMBOL$WINDOWS_HOST_IP:$PORT
# authpriv.* $PROTO_SYMBOL$WINDOWS_HOST_IP:$PORT
# *.err $PROTO_SYMBOL$WINDOWS_HOST_IP:$PORT
EOF

echo -e "${GREEN}設定ファイルが作成されました${NC}"
echo ""

# 設定ファイルの内容を表示
echo -e "${YELLOW}設定内容:${NC}"
cat "$CONFIG_FILE"
echo ""

# rsyslog設定テスト
echo -e "${YELLOW}rsyslog設定をテストします...${NC}"
if rsyslogd -N1; then
    echo -e "${GREEN}設定ファイルは正常です${NC}"
else
    echo -e "${RED}設定ファイルにエラーがあります${NC}"
    exit 1
fi

# rsyslog再起動
echo -e "${YELLOW}rsyslogを再起動します...${NC}"
systemctl restart rsyslog

if systemctl is-active --quiet rsyslog; then
    echo -e "${GREEN}rsyslogが正常に起動しました${NC}"
else
    echo -e "${RED}rsyslogの起動に失敗しました${NC}"
    systemctl status rsyslog
    exit 1
fi

echo ""
echo -e "${GREEN}=== 設定完了 ===${NC}"
echo ""
echo -e "${BLUE}次のステップ:${NC}"
echo ""
echo "1. ${YELLOW}接続テスト:${NC}"
echo "   logger -p user.notice 'ELK Stack test from Raspberry Pi $(hostname)'"
echo ""
echo "2. ${YELLOW}Windowsホスト側でポートフォワーディングを開始:${NC}"
echo "   kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0"
echo ""
echo "3. ${YELLOW}Logstashのログを確認:${NC}"
echo "   kubectl logs -f deployment/logstash -n elk-stack"
echo ""
echo "4. ${YELLOW}Kibanaでログを確認:${NC}"
echo "   kubectl port-forward svc/kibana 5601:5601 -n elk-stack"
echo "   ブラウザで http://localhost:5601 にアクセス"
echo "   インデックスパターン 'logstash-*' を作成"
echo "   Discoverでログを閲覧"
echo ""
echo "5. ${YELLOW}トラブルシューティング:${NC}"
echo "   - rsyslog状態: systemctl status rsyslog"
echo "   - rsyslogログ: tail -f /var/log/syslog"
echo "   - 接続テスト: nc -zvu $WINDOWS_HOST_IP $PORT"
echo ""
echo -e "${YELLOW}詳細は RSYSLOG_SETUP.md を参照してください${NC}"





