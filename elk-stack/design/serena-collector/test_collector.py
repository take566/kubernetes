"""collector.py の単体テスト（クラスタ不要）。実行: python -m pytest elk-stack/design/serena-collector -q"""

from __future__ import annotations

import json
import socket
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import collector  # noqa: E402

SAMPLE = "INFO  2026-10-05 10:00:00,123 [MainThread] serena.agent:start_mcp_server:42 - Active tools (25): find_symbol"


class FakeSender:
    def __init__(self) -> None:
        self.events: list[dict] = []

    def send(self, event: dict) -> None:
        self.events.append(event)

    def close(self) -> None:
        pass


def make_collector(tmp_path: Path) -> tuple[collector.SerenaCollector, FakeSender]:
    home = tmp_path / "home"
    (home / "logs" / "2026-10-05").mkdir(parents=True)
    proj = tmp_path / "proj"
    (proj / ".serena" / "logs" / "health-checks").mkdir(parents=True)
    cfg = collector.CollectorConfig(logstash_host="127.0.0.1", serena_home=home, projects=[proj], hostname="h")
    c = collector.SerenaCollector(cfg)
    fake = FakeSender()
    c.sender = fake  # type: ignore[assignment]
    return c, fake


def test_parse_sample_line_fields(tmp_path: Path) -> None:
    m = collector.SERENA_LOG_PATTERN.match(SAMPLE)
    assert m is not None
    ev = collector.build_event(stream="mcp.file", parsed=m.groupdict(), raw_message=SAMPLE,
                               source_path=tmp_path / "mcp_x.txt", config=collector.CollectorConfig())
    assert ev["serena"]["logger"] == "serena.agent"
    assert ev["serena"]["function"] == "start_mcp_server"
    assert ev["serena"]["line"] == 42
    assert ev["log"]["level"] == "INFO"
    assert ev["@timestamp"] == "2026-10-05T10:00:00.123Z"
    assert ev["serena"]["session_id"] == "mcp_x"


def test_unparsed_line_is_kept_as_raw_message(tmp_path: Path) -> None:
    ev = collector.build_event(stream="mcp.file", parsed=None, raw_message="free text",
                               source_path=tmp_path / "mcp_y.txt", config=collector.CollectorConfig())
    assert ev["message"] == "free text"
    assert ev["log"]["level"] == "INFO"


def test_existing_file_at_startup_is_not_replayed(tmp_path: Path) -> None:
    c, fake = make_collector(tmp_path)
    old = c.config.serena_home / "logs" / "2026-10-05" / "mcp_old.txt"
    old.write_text(SAMPLE + "\n", encoding="utf-8")
    c.poll_files()  # 起動時の初回 poll
    assert fake.events == []
    with old.open("a", encoding="utf-8") as f:
        f.write(SAMPLE.replace("42", "43") + "\n")
    c.poll_files()
    assert [e["serena"]["line"] for e in fake.events] == [43]


def test_file_created_after_startup_is_read_from_beginning(tmp_path: Path) -> None:
    """ローテーションで後から現れたファイルの先頭行を落とさない（従来は末尾から読み始めて欠落していた）。"""
    c, fake = make_collector(tmp_path)
    c.poll_files()  # 起動時の初回 poll（ファイルなし）
    new = c.config.serena_home / "logs" / "2026-10-05" / "mcp_new.txt"
    new.write_text("".join(SAMPLE.replace("42", str(n)) + "\n" for n in (1, 2, 3)), encoding="utf-8")
    hc = c.config.projects[0] / ".serena" / "logs" / "health-checks" / "health_check_1.log"
    hc.write_text("health ok\n", encoding="utf-8")
    c.poll_files()
    assert [e["serena"]["line"] for e in fake.events if e["serena"]["stream"] == "mcp.file"] == [1, 2, 3]
    assert [e["message"] for e in fake.events if e["serena"]["stream"] == "health_check"] == ["health ok"]


def test_truncation_restarts_from_beginning(tmp_path: Path) -> None:
    c, fake = make_collector(tmp_path)
    c.poll_files()
    f = c.config.serena_home / "logs" / "2026-10-05" / "mcp_t.txt"
    f.write_text(SAMPLE + "\n" + SAMPLE.replace("42", "44") + "\n", encoding="utf-8")
    c.poll_files()
    f.write_text(SAMPLE.replace("42", "45") + "\n", encoding="utf-8")  # 短く書き直し（truncate）
    c.poll_files()
    assert [e["serena"]["line"] for e in fake.events] == [42, 44, 45]


def test_incomplete_trailing_line_waits_for_newline(tmp_path: Path) -> None:
    c, fake = make_collector(tmp_path)
    c.poll_files()
    f = c.config.serena_home / "logs" / "2026-10-05" / "mcp_p.txt"
    f.write_text(SAMPLE.replace("42", "50"), encoding="utf-8")  # 改行なし
    c.poll_files()
    assert fake.events == []
    with f.open("a", encoding="utf-8") as h:
        h.write("\n")
    c.poll_files()
    assert [e["serena"]["line"] for e in fake.events] == [50]


class LineServer:
    """改行区切りで受信した JSON を記録する TCP サーバ。close_clients() で接続中のクライアントを切る。"""

    def __init__(self) -> None:
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen()
        self.port = self.sock.getsockname()[1]
        self.received: list[dict] = []
        self.clients: list[socket.socket] = []
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.clients.append(conn)
            threading.Thread(target=self._read, args=(conn,), daemon=True).start()

    def _read(self, conn: socket.socket) -> None:
        buf = b""
        while True:
            try:
                data = conn.recv(65536)
            except OSError:
                return
            if not data:
                return
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self.received.append(json.loads(line))

    def close_clients(self) -> None:
        for c in self.clients:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            c.close()
        self.clients.clear()


def _wait(pred, timeout: float = 5.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def test_sender_does_not_lose_first_event_after_peer_closed() -> None:
    """Logstash 再起動相当: 相手が切断した直後の 1 件目を、死んだソケットに書いて黙って落とさない。"""
    srv = LineServer()
    sender = collector.LogstashSender("127.0.0.1", srv.port, reconnect_delay=0.1)
    sender.send({"n": 1})
    assert _wait(lambda: len(srv.received) == 1)
    srv.close_clients()
    time.sleep(0.2)  # FIN がクライアントに届くまで
    sender.send({"n": 2})
    sender.send({"n": 3})
    assert _wait(lambda: len(srv.received) == 3), srv.received
    assert [e["n"] for e in srv.received] == [1, 2, 3]
    sender.close()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
