#!/usr/bin/env python3
"""Fake model provider for the agent smoke tests (in-sandbox-agents, design D10).

Answers the Anthropic Messages API (POST /v1/messages, JSON or SSE) and the OpenAI Responses and
Chat Completions APIs (POST /v1/responses, /v1/chat/completions, JSON or SSE) with a fixed reply
and fixed usage, and appends every request it sees to a JSON-lines file, so tests can check what
the gateway forwarded (path, headers, model). It never talks to the real providers.

Usage: fake-provider.py <port> <requests.jsonl> [reply-text]
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]
REPLY = sys.argv[3] if len(sys.argv) > 3 else "FAKE-PROVIDER-REPLY"
USAGE_IN, USAGE_OUT = 10, 5


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _record(self, body):
        try:
            parsed = json.loads(body or b"{}")
        except ValueError:
            parsed = {}
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "method": self.command, "path": self.path,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "model": parsed.get("model"), "stream": bool(parsed.get("stream")),
            }) + "\n")
        return parsed

    def _json(self, obj, status=200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for name, obj in events:
            chunk = (f"event: {name}\n" if name else "") + f"data: {json.dumps(obj)}\n\n"
            self.wfile.write(chunk.encode())
            self.wfile.flush()
            time.sleep(0.01)
        self.close_connection = True

    def do_GET(self):
        self._record(b"")
        if self.path.startswith("/v1/models"):
            self._json({"object": "list", "data": [{"id": "gpt-5.1-codex-max", "object": "model"}]})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        req = self._record(body)
        model = req.get("model", "unknown")
        if self.path.startswith("/v1/messages/count_tokens"):
            self._json({"input_tokens": USAGE_IN})
        elif self.path.startswith("/v1/messages"):
            self._anthropic(model, req.get("stream"))
        elif self.path.startswith("/v1/responses"):
            self._responses(model, req.get("stream"))
        elif self.path.startswith("/v1/chat/completions"):
            self._json({"id": "chatcmpl-fake", "object": "chat.completion", "model": model,
                        "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY}, "finish_reason": "stop"}],
                        "usage": {"prompt_tokens": USAGE_IN, "completion_tokens": USAGE_OUT, "total_tokens": USAGE_IN + USAGE_OUT}})
        else:
            self._json({"error": "not found"}, 404)

    def _anthropic(self, model, stream):
        msg = {"id": "msg_fake", "type": "message", "role": "assistant", "model": model,
               "content": [{"type": "text", "text": REPLY}], "stop_reason": "end_turn", "stop_sequence": None,
               "usage": {"input_tokens": USAGE_IN, "output_tokens": USAGE_OUT}}
        if not stream:
            self._json(msg)
            return
        start = dict(msg, content=[], stop_reason=None, usage={"input_tokens": USAGE_IN, "output_tokens": 1})
        self._sse([
            ("message_start", {"type": "message_start", "message": start}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": REPLY}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                               "usage": {"output_tokens": USAGE_OUT}}),
            ("message_stop", {"type": "message_stop"}),
        ])

    def _responses(self, model, stream):
        item = {"id": "msg_fake", "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": REPLY, "annotations": []}]}
        resp = {"id": "resp_fake", "object": "response", "created_at": int(time.time()), "model": model,
                "status": "completed", "output": [item],
                "usage": {"input_tokens": USAGE_IN, "output_tokens": USAGE_OUT, "total_tokens": USAGE_IN + USAGE_OUT}}
        if not stream:
            self._json(resp)
            return
        created = dict(resp, status="in_progress", output=[], usage=None)
        self._sse([
            ("response.created", {"type": "response.created", "response": created}),
            ("response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress", content=[])}),
            ("response.output_text.delta", {"type": "response.output_text.delta", "item_id": "msg_fake", "output_index": 0, "content_index": 0, "delta": REPLY}),
            ("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
            ("response.completed", {"type": "response.completed", "response": resp}),
        ])


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
