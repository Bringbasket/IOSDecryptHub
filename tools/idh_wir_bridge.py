#!/usr/bin/env python3
"""把 pymobiledevice3 WebInspector/CDP 的 Network.* 事件汇总到 IOSDecryptHub 面板。"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass
from typing import Any

try:
    import websocket  # type: ignore
except ImportError:  # pragma: no cover - 依赖提示本身就是运行时行为
    websocket = None


MAX_RESPONSE_BODY_CHARS = 512 * 1024


def get_json(url: str, timeout: float = 3.0) -> Any:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


class Collector:
    def __init__(self, endpoint: str) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.pid = os.getpid()
        self._seq = 0
        self._lock = threading.Lock()

    def check(self) -> dict[str, Any]:
        info = get_json(self.endpoint + "/api/collector/info")
        if info.get("format") != "iosdecrypthub.collector.v1":
            raise RuntimeError("目标不是支持跨进程汇总的 IOSDecryptHub 引擎")
        return info

    def _next_seq(self) -> int:
        with self._lock:
            self._seq += 1
            return self._seq

    def emit(self, method: str, params: dict[str, Any], target: dict[str, Any]) -> None:
        params = dict(params)
        if method == "Network.responseBody":
            body = params.get("body")
            if isinstance(body, str) and len(body) > MAX_RESPONSE_BODY_CHARS:
                params["body"] = body[:MAX_RESPONSE_BODY_CHARS]
                params["bodyTruncated"] = True
                params["bodyOriginalChars"] = len(body)

        request = params.get("request") if isinstance(params.get("request"), dict) else {}
        response = params.get("response") if isinstance(params.get("response"), dict) else {}
        request_id = str(params.get("requestId", ""))
        url = str(request.get("url") or response.get("url") or params.get("documentURL") or target.get("url") or "")
        http_method = str(request.get("method") or "")
        status = response.get("status")
        detail_parts = [http_method or method]
        if url:
            detail_parts.append(url)
        if status is not None:
            detail_parts.append("status=" + str(status))

        event = {
            "schema": "iosdecrypthub.cdp.v1",
            "method": method,
            "params": params,
            "ts": int(time.time() * 1000),
            "target": {
                "id": target.get("id", ""),
                "title": target.get("title", ""),
                "url": target.get("url", ""),
            },
        }
        raw = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        envelope = {
            "format": "iosdecrypthub.collector.v1",
            "source": "wir",
            "originPid": self.pid,
            "originSeq": self._next_seq(),
            "replace": False,
            "category": 6,
            "algorithm": "WEBKIT-CDP",
            "operation": method,
            "detail": " ".join(detail_parts),
            "timestampMs": event["ts"],
            "inputBase64": base64.b64encode(raw).decode("ascii"),
            "metadata": {
                "source": "wir",
                "eventName": method,
                "requestId": request_id,
                "url": url,
                "resourceType": str(params.get("type", "")),
                "targetId": str(target.get("id", "")),
                "schema": "iosdecrypthub.cdp.v1",
            },
        }
        data = json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        req = urllib.request.Request(
            self.endpoint + "/api/collector/ingest",
            data=data,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5.0) as result:
                if result.status not in (200, 202):
                    raise RuntimeError(f"collector HTTP {result.status}")
        except Exception as exc:
            print(f"[WIR] 上报失败: {exc}", file=sys.stderr)


@dataclass
class PendingCommand:
    synthetic_method: str
    request_id: str


class TargetWorker(threading.Thread):
    def __init__(self, target: dict[str, Any], collector: Collector, stop: threading.Event) -> None:
        super().__init__(daemon=True, name="wir-" + str(target.get("id", "target"))[:20])
        self.target = target
        self.collector = collector
        self.stop = stop
        self.next_command_id = 0
        self.pending: dict[int, PendingCommand] = {}

    def send_command(self, ws: Any, method: str, params: dict[str, Any] | None = None,
                     pending: PendingCommand | None = None) -> None:
        self.next_command_id += 1
        command_id = self.next_command_id
        ws.send(json.dumps({"id": command_id, "method": method, "params": params or {}}))
        if pending:
            self.pending[command_id] = pending

    def handle_response(self, message: dict[str, Any]) -> None:
        command_id = message.get("id")
        if not isinstance(command_id, int):
            return
        pending = self.pending.pop(command_id, None)
        if not pending:
            return
        result = message.get("result") if isinstance(message.get("result"), dict) else {}
        params = {"requestId": pending.request_id, **result}
        if "error" in message:
            params["error"] = message["error"]
        self.collector.emit(pending.synthetic_method, params, self.target)

    def handle_event(self, ws: Any, method: str, params: dict[str, Any]) -> None:
        if not method.startswith("Network."):
            return
        self.collector.emit(method, params, self.target)
        request_id = str(params.get("requestId", ""))
        if method == "Network.loadingFinished" and request_id:
            self.send_command(
                ws,
                "Network.getResponseBody",
                {"requestId": request_id},
                PendingCommand("Network.responseBody", request_id),
            )
        elif method == "Network.requestWillBeSent" and request_id:
            request = params.get("request") if isinstance(params.get("request"), dict) else {}
            if request.get("hasPostData") and "postData" not in request:
                self.send_command(
                    ws,
                    "Network.getRequestPostData",
                    {"requestId": request_id},
                    PendingCommand("Network.requestPostData", request_id),
                )

    def run(self) -> None:
        if websocket is None:
            return
        ws_url = str(self.target.get("webSocketDebuggerUrl") or "")
        if not ws_url:
            return
        print(f"[WIR] 连接 {self.target.get('title') or self.target.get('url') or ws_url}")
        try:
            ws = websocket.create_connection(ws_url, timeout=3, enable_multithread=False)
            ws.settimeout(1)
            self.send_command(ws, "Network.enable", {
                "maxTotalBufferSize": 20 * 1024 * 1024,
                "maxResourceBufferSize": 2 * 1024 * 1024,
                "maxPostDataSize": 1024 * 1024,
            })
            while not self.stop.is_set():
                try:
                    raw = ws.recv()
                except Exception as exc:
                    if exc.__class__.__name__ in {"WebSocketTimeoutException", "TimeoutError"}:
                        continue
                    raise
                if not raw:
                    break
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8", "replace")
                message = json.loads(raw)
                if "id" in message:
                    self.handle_response(message)
                    continue
                method = message.get("method")
                params = message.get("params")
                if isinstance(method, str) and isinstance(params, dict):
                    self.handle_event(ws, method, params)
        except Exception as exc:
            if not self.stop.is_set():
                print(f"[WIR] 目标断开: {exc}", file=sys.stderr)
        finally:
            try:
                ws.close()  # type: ignore[possibly-undefined]
            except Exception:
                pass


def fetch_targets(cdp: str) -> list[dict[str, Any]]:
    last_error: Exception | None = None
    for path in ("/json/list", "/json"):
        try:
            data = get_json(cdp.rstrip("/") + path)
            if isinstance(data, list):
                return [item for item in data if isinstance(item, dict)]
        except Exception as exc:
            last_error = exc
    raise RuntimeError(f"无法读取 CDP targets: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description="将 iOS WebInspector Network.* 汇总到 IOSDecryptHub")
    parser.add_argument("--cdp", default="http://127.0.0.1:9222", help="pymobiledevice3 CDP 地址")
    parser.add_argument("--collector", required=True, help="手机 App 面板地址，如 http://192.168.1.159:8088")
    parser.add_argument("--target", default="", help="只连接 title/url 匹配此正则的 target")
    parser.add_argument("--poll", type=float, default=2.0, help="target 扫描间隔秒数")
    args = parser.parse_args()

    if websocket is None:
        print("缺少 websocket-client：python -m pip install websocket-client", file=sys.stderr)
        return 2
    try:
        pattern = re.compile(args.target, re.I) if args.target else None
    except re.error as exc:
        print(f"target 正则错误: {exc}", file=sys.stderr)
        return 2

    collector = Collector(args.collector)
    try:
        info = collector.check()
    except Exception as exc:
        print(f"Collector 不可用: {exc}", file=sys.stderr)
        return 1
    print(f"[WIR] Collector: {info.get('bundleId') or info.get('process')} 端口 {info.get('port')}")

    workers: dict[str, tuple[threading.Event, TargetWorker]] = {}
    try:
        while True:
            try:
                targets = fetch_targets(args.cdp)
                visible: set[str] = set()
                for target in targets:
                    ws_url = str(target.get("webSocketDebuggerUrl") or "")
                    haystack = str(target.get("title", "")) + "\n" + str(target.get("url", ""))
                    if not ws_url or (pattern and not pattern.search(haystack)):
                        continue
                    visible.add(ws_url)
                    current = workers.get(ws_url)
                    if current and current[1].is_alive():
                        continue
                    stop = threading.Event()
                    worker = TargetWorker(target, collector, stop)
                    workers[ws_url] = (stop, worker)
                    worker.start()
                for ws_url, (stop, worker) in list(workers.items()):
                    if ws_url not in visible or not worker.is_alive():
                        stop.set()
                        workers.pop(ws_url, None)
            except Exception as exc:
                print(f"[WIR] 扫描失败: {exc}", file=sys.stderr)
            time.sleep(max(0.5, args.poll))
    except KeyboardInterrupt:
        print("\n[WIR] 正在停止…")
    finally:
        for stop, _worker in workers.values():
            stop.set()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
