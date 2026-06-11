#!/usr/bin/env python3
"""Windows Serena MCP log collector — tail logs and ship JSON lines to Logstash TCP."""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import logging
import os
import re
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

# SERENA_LOG_FORMAT from serena/src/serena/constants.py
# "%(levelname)-5s %(asctime)-15s [%(threadName)s] %(name)s:%(funcName)s:%(lineno)d - %(message)s"
SERENA_LOG_PATTERN = re.compile(
    r"^(?P<level>[A-Z]+)\s+"
    r"(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s+"
    r"\[(?P<thread>[^\]]+)\]\s+"
    r"(?P<logger>[^:]+):(?P<function>[^:]+):(?P<line>\d+)\s+-\s+"
    r"(?P<message>.*)$"
)

DEFAULT_LOGSTASH_HOST = "localhost"
DEFAULT_LOGSTASH_PORT = 5000
DEFAULT_POLL_INTERVAL = 1.0
DEFAULT_RECONNECT_DELAY = 5.0

logger = logging.getLogger("serena.collector")


def expand_user(path: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(path))).resolve()


def parse_logstash_endpoint(value: str) -> tuple[str, int]:
    if ":" not in value:
        return value, DEFAULT_LOGSTASH_PORT
    host, _, port_str = value.rpartition(":")
    if not host:
        raise argparse.ArgumentTypeError(f"invalid logstash endpoint: {value!r}")
    try:
        port = int(port_str)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid logstash port: {port_str!r}") from exc
    return host, port


def parse_timestamp(raw: str) -> str:
    """Convert Serena log timestamp to ISO-8601 UTC."""
    dt = datetime.strptime(raw, "%Y-%m-%d %H:%M:%S,%f")
    return dt.replace(tzinfo=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _coerce_scalar(value: str) -> Any:
    value = value.strip().strip("'\"")
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def load_simple_yaml(path: Path) -> dict[str, Any]:
    """Minimal YAML loader for nested maps and string lists (stdlib only)."""
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(0, root)]
    lines = path.read_text(encoding="utf-8").splitlines()
    index = 0

    def next_nonempty(start: int) -> int | None:
        for j in range(start, len(lines)):
            if lines[j].split("#", 1)[0].strip():
                return j
        return None

    while index < len(lines):
        raw_line = lines[index]
        line = raw_line.split("#", 1)[0].rstrip()
        index += 1
        if not line.strip():
            continue

        indent = len(line) - len(line.lstrip())
        content = line.lstrip()

        while stack and indent < stack[-1][0]:
            stack.pop()
        container = stack[-1][1]

        if content.startswith("- "):
            item = _coerce_scalar(content[2:])
            for key, value in reversed(list(container.items())):
                if isinstance(value, list):
                    value.append(item)
                    break
            continue

        if ":" not in content:
            continue

        key, _, value = content.partition(":")
        key = key.strip()
        value = value.strip()

        if not value:
            child = next_nonempty(index)
            if child is not None:
                child_indent = len(lines[child]) - len(lines[child].lstrip())
                child_content = lines[child].lstrip()
                if child_indent > indent and child_content.startswith("- "):
                    container[key] = []
                    continue
            nested: dict[str, Any] = {}
            container[key] = nested
            stack.append((indent + 2, nested))
            continue

        container[key] = _coerce_scalar(value)

    return root


def load_config(path: Path) -> dict[str, Any]:
    if path.suffix.lower() == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    return load_simple_yaml(path)


@dataclass
class CollectorConfig:
    logstash_host: str = DEFAULT_LOGSTASH_HOST
    logstash_port: int = DEFAULT_LOGSTASH_PORT
    serena_home: Path = field(default_factory=lambda: expand_user("~/.serena"))
    projects: list[Path] = field(default_factory=list)
    poll_interval: float = DEFAULT_POLL_INTERVAL
    reconnect_delay: float = DEFAULT_RECONNECT_DELAY
    hostname: str = field(default_factory=lambda: os.environ.get("COMPUTERNAME", "windows-host"))

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CollectorConfig:
        logstash = data.get("logstash", {})
        if isinstance(logstash, str):
            host, port = parse_logstash_endpoint(logstash)
        elif isinstance(logstash, dict):
            host = str(logstash.get("host", DEFAULT_LOGSTASH_HOST))
            port = int(logstash.get("port", DEFAULT_LOGSTASH_PORT))
        else:
            host, port = DEFAULT_LOGSTASH_HOST, DEFAULT_LOGSTASH_PORT

        serena_home = expand_user(str(data.get("serena_home", "~/.serena")))
        projects_raw = data.get("projects", [])
        projects = [expand_user(str(p)) for p in projects_raw] if projects_raw else []

        return cls(
            logstash_host=host,
            logstash_port=port,
            serena_home=serena_home,
            projects=projects,
            poll_interval=float(data.get("poll_interval", DEFAULT_POLL_INTERVAL)),
            reconnect_delay=float(data.get("reconnect_delay", DEFAULT_RECONNECT_DELAY)),
            hostname=str(data.get("hostname", os.environ.get("COMPUTERNAME", "windows-host"))),
        )


class LogstashSender:
    """Send newline-delimited JSON over TCP with reconnect."""

    def __init__(self, host: str, port: int, reconnect_delay: float) -> None:
        self.host = host
        self.port = port
        self.reconnect_delay = reconnect_delay
        self._sock: socket.socket | None = None
        self._lock = threading.Lock()

    def connect(self) -> None:
        self.close()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10.0)
        sock.connect((self.host, self.port))
        self._sock = sock
        logger.info("connected to logstash %s:%s", self.host, self.port)

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def send(self, event: dict[str, Any]) -> None:
        payload = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
        with self._lock:
            for attempt in range(2):
                try:
                    if self._sock is None:
                        self.connect()
                    assert self._sock is not None
                    self._sock.sendall(payload)
                    return
                except OSError as exc:
                    logger.warning("logstash send failed (attempt %s): %s", attempt + 1, exc)
                    self.close()
                    if attempt == 0:
                        time.sleep(self.reconnect_delay)
                        continue
                    raise


class FileTailState:
    """Track read offset and detect rotation via inode/size changes."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.offset = 0
        self.inode: int | None = None
        self._load_position()

    def _stat(self) -> os.stat_result | None:
        try:
            return self.path.stat()
        except OSError:
            return None

    def _load_position(self) -> None:
        stat = self._stat()
        if stat is None:
            return
        self.inode = stat.st_ino
        if stat.st_size < self.offset:
            self.offset = 0

    def rotated(self) -> bool:
        stat = self._stat()
        if stat is None:
            return True
        if self.inode is not None and stat.st_ino != self.inode:
            self.offset = 0
            self.inode = stat.st_ino
            return True
        if stat.st_size < self.offset:
            self.offset = 0
            return True
        return False

    def read_new_lines(self) -> list[str]:
        if not self.path.is_file():
            return []

        self.rotated()
        lines: list[str] = []
        try:
            with self.path.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(self.offset)
                chunk = handle.read()
                self.offset = handle.tell()
        except OSError as exc:
            logger.debug("cannot read %s: %s", self.path, exc)
            return []

        if not chunk:
            return []

        parts = chunk.splitlines()
        if chunk and not chunk.endswith("\n") and parts:
            # Incomplete trailing line — rewind offset
            last = parts.pop()
            self.offset -= len(last.encode("utf-8", errors="replace"))
            if self.offset < 0:
                self.offset = 0

        return parts


def session_id_from_path(path: Path) -> str:
    name = path.stem
    if name.startswith("mcp_"):
        return name
    if name.startswith("health_check_"):
        return name
    return name


def infer_project(path: Path, projects: list[Path]) -> str:
    resolved = str(path.resolve())
    for project in projects:
        project_str = str(project)
        if resolved.startswith(project_str):
            return project_str
    return ""


def build_event(
    *,
    stream: str,
    parsed: dict[str, str] | None,
    raw_message: str,
    source_path: Path,
    config: CollectorConfig,
) -> dict[str, Any]:
    project = infer_project(source_path, config.projects)
    session_id = session_id_from_path(source_path)

    if parsed:
        event: dict[str, Any] = {
            "@timestamp": parse_timestamp(parsed["timestamp"]),
            "event": {"kind": "serena.log"},
            "serena": {
                "stream": stream,
                "session_id": session_id,
                "host": config.hostname,
                "logger": parsed["logger"],
                "function": parsed["function"],
                "line": int(parsed["line"]),
            },
            "log": {
                "level": parsed["level"],
                "thread": parsed["thread"],
            },
            "message": parsed["message"],
            "host": {"os": {"type": "windows"}},
        }
        if project:
            event["serena"]["project"] = project
        return event

    event = {
        "@timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "event": {"kind": "serena.log"},
        "serena": {
            "stream": stream,
            "session_id": session_id,
            "host": config.hostname,
        },
        "log": {"level": "INFO"},
        "message": raw_message,
        "host": {"os": {"type": "windows"}},
    }
    if project:
        event["serena"]["project"] = project
    return event


class SerenaCollector:
    def __init__(self, config: CollectorConfig) -> None:
        self.config = config
        self.sender = LogstashSender(
            config.logstash_host,
            config.logstash_port,
            config.reconnect_delay,
        )
        self._tails: dict[str, FileTailState] = {}
        self._seen_hashes: set[str] = set()
        self._seen_limit = 10_000
        self._stop = threading.Event()
        self._watchdog_available = False
        self._observer: Any = None

    def _dedupe_key(self, event: dict[str, Any]) -> str:
        payload = json.dumps(event, sort_keys=True, ensure_ascii=False)
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def _emit(self, event: dict[str, Any]) -> None:
        key = self._dedupe_key(event)
        if key in self._seen_hashes:
            return
        self._seen_hashes.add(key)
        if len(self._seen_hashes) > self._seen_limit:
            self._seen_hashes.clear()

        try:
            self.sender.send(event)
            logger.debug(
                "sent stream=%s level=%s",
                event.get("serena", {}).get("stream"),
                event.get("log", {}).get("level"),
            )
        except OSError as exc:
            logger.error("failed to send event: %s", exc)

    def _process_line(
        self,
        line: str,
        source_path: Path,
        stream: str,
    ) -> None:
        line = line.strip()
        if not line:
            return

        match = SERENA_LOG_PATTERN.match(line)
        parsed = match.groupdict() if match else None
        event = build_event(
            stream=stream,
            parsed=parsed,
            raw_message=line,
            source_path=source_path,
            config=self.config,
        )
        self._emit(event)

    def _tail_key(self, path: Path) -> str:
        return str(path.resolve())

    def _get_tail(self, path: Path) -> FileTailState:
        key = self._tail_key(path)
        if key not in self._tails:
            state = FileTailState(path)
            # Start at end for existing files to avoid replaying full history on startup
            stat = state._stat()
            if stat is not None:
                state.offset = stat.st_size
            self._tails[key] = state
        return self._tails[key]

    def discover_mcp_files(self) -> list[Path]:
        pattern = str(self.config.serena_home / "logs" / "*" / "mcp_*.txt")
        return sorted(Path(p) for p in glob.glob(pattern))

    def discover_health_check_files(self) -> list[Path]:
        files: list[Path] = []
        for project in self.config.projects:
            pattern = str(project / ".serena" / "logs" / "health-checks" / "health_check_*.log")
            files.extend(Path(p) for p in glob.glob(pattern))
        return sorted(files)

    def poll_files(self) -> None:
        targets: list[tuple[Path, str]] = []
        for path in self.discover_mcp_files():
            targets.append((path, "mcp.file"))
        for path in self.discover_health_check_files():
            targets.append((path, "health_check"))

        for path, stream in targets:
            tail = self._get_tail(path)
            for line in tail.read_new_lines():
                self._process_line(line, path, stream)

    def _on_file_event(self, path: Path, stream: str) -> None:
        if not path.is_file():
            return
        tail = self._get_tail(path)
        for line in tail.read_new_lines():
            self._process_line(line, path, stream)

    def _setup_watchdog(self) -> bool:
        try:
            from watchdog.events import FileSystemEventHandler
            from watchdog.observers import Observer
        except ImportError:
            return False

        collector = self

        class Handler(FileSystemEventHandler):
            def on_modified(self, event: Any) -> None:
                if event.is_directory:
                    return
                path = Path(event.src_path)
                if path.name.startswith("mcp_") and path.suffix == ".txt":
                    collector._on_file_event(path, "mcp.file")
                elif path.name.startswith("health_check_") and path.suffix == ".log":
                    collector._on_file_event(path, "health_check")

            def on_created(self, event: Any) -> None:
                self.on_modified(event)

        observer = Observer()
        mcp_root = self.config.serena_home / "logs"
        if mcp_root.is_dir():
            observer.schedule(Handler(), str(mcp_root), recursive=True)

        for project in self.config.projects:
            hc_dir = project / ".serena" / "logs" / "health-checks"
            if hc_dir.is_dir():
                observer.schedule(Handler(), str(hc_dir), recursive=False)

        observer.start()
        self._observer = observer
        self._watchdog_available = True
        logger.info("watchdog file observer started")
        return True

    def run(self) -> None:
        logger.info(
            "starting collector logstash=%s:%s serena_home=%s projects=%s",
            self.config.logstash_host,
            self.config.logstash_port,
            self.config.serena_home,
            [str(p) for p in self.config.projects],
        )

        use_watchdog = self._setup_watchdog()

        try:
            while not self._stop.is_set():
                if not use_watchdog:
                    self.poll_files()
                else:
                    # Periodic discovery for new rotated files
                    self.poll_files()
                time.sleep(self.config.poll_interval)
        except KeyboardInterrupt:
            logger.info("shutting down")
        finally:
            if self._observer is not None:
                self._observer.stop()
                self._observer.join(timeout=5)
            self.sender.close()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Tail Serena MCP logs on Windows and ship JSON lines to Logstash TCP.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        help="Path to collector config (YAML or JSON).",
    )
    parser.add_argument(
        "--logstash",
        type=parse_logstash_endpoint,
        default=(DEFAULT_LOGSTASH_HOST, DEFAULT_LOGSTASH_PORT),
        metavar="HOST:PORT",
        help=f"Logstash TCP endpoint (default: {DEFAULT_LOGSTASH_HOST}:{DEFAULT_LOGSTASH_PORT})",
    )
    parser.add_argument(
        "--projects",
        type=str,
        default="",
        help="Comma-separated project roots to watch for health-check logs.",
    )
    parser.add_argument(
        "--serena-home",
        type=Path,
        default=None,
        help="Serena home directory (default: ~/.serena).",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL,
        help="Poll interval in seconds when watchdog is unavailable.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.config:
        config_data = load_config(args.config)
        config = CollectorConfig.from_dict(config_data)
    else:
        host, port = args.logstash
        projects = [expand_user(p.strip()) for p in args.projects.split(",") if p.strip()]
        serena_home = expand_user(str(args.serena_home)) if args.serena_home else expand_user("~/.serena")
        config = CollectorConfig(
            logstash_host=host,
            logstash_port=port,
            serena_home=serena_home,
            projects=projects,
            poll_interval=args.poll_interval,
        )

    if args.config is None and args.projects:
        config.projects = [expand_user(p.strip()) for p in args.projects.split(",") if p.strip()]
    if args.config is None and args.logstash != (DEFAULT_LOGSTASH_HOST, DEFAULT_LOGSTASH_PORT):
        config.logstash_host, config.logstash_port = args.logstash
    if args.config is None and args.serena_home:
        config.serena_home = expand_user(str(args.serena_home))
    if args.config is None:
        config.poll_interval = args.poll_interval

    collector = SerenaCollector(config)
    collector.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
