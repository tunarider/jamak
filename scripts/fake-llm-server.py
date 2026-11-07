#!/usr/bin/env python3
"""수동 검증용 가짜 OpenAI 호환 LLM 서버(테스트 전용, 표준 라이브러리만 쓴다).

  python3 scripts/fake-llm-server.py [--port 8765] [--delay 0.5]

- GET  /v1/models            → fake-text, fake-vision
- POST /v1/chat/completions  → 프롬프트의 문구로 단계를 골라 고정 JSON을 돌려준다.
  - 분석 구간(analysis-chunk): 줄거리, 인물 1명, 용어 1개
  - 줄거리 합치기(analysis-merge): 합친 줄거리
  - 원문 검토(source-review): 대상 첫 줄에 의심 티켓(제안 = 원문 끝에 "?")
  - 번역 검토(translation-review): 대상 첫 줄에 번역 고침 티켓(번역 끝에 "~"),
    둘째 줄에 원문 의심 티켓(target "source", 제안 없음 = text 빈 문자열)
  - 용어집(glossary): 표기 1개(가짜원문 → 가짜번역), 말투 1개
  - 번역(translation): {"lines":[{"id", "text"}]}, 대상 줄마다 "<번역할 언어> 번역: <원문>"
요청마다 경로, 단계, 프롬프트 가변 부분의 앞 80자를 표준 출력에 남긴다(이어서 하기 확인용).

요청에 `stream: true`가 있으면 SSE로 답한다: 본문을 몇 조각의 delta로 나눠 보내고, 마지막 조각에
usage(prompt_tokens = 프롬프트 글자 수 / 4, completion_tokens = 본문 글자 수 / 4, 최소 1)를 담은 뒤 `data: [DONE]`.
`--delay`는 스트림이면 첫 조각 전에 절반, 나머지를 조각 사이에 나눠 기다린다. 없으면 예전처럼 한 번에 JSON으로 답한다.
"""
import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY = 0.0


def prompt_text(body):
    texts = []
    for message in body.get("messages", []):
        content = message.get("content")
        if isinstance(content, str):
            texts.append(content)
        elif isinstance(content, list):
            for part in content:
                if part.get("type") == "text":
                    texts.append(part.get("text", ""))
    return "\n".join(texts)


def after(text, marker):
    i = text.rfind(marker)
    return text[i + len(marker):].strip() if i >= 0 else text


def json_lines(text, marker):
    """marker 뒤의 JSON 줄 중 맥락이 아닌 줄."""
    lines = []
    for raw in after(text, marker).splitlines():
        try:
            line = json.loads(raw)
        except ValueError:
            continue
        if isinstance(line, dict) and not line.get("context"):
            lines.append(line)
    return lines


def first_line(lines):
    return (str(lines[0]["id"]) + ": " + lines[0].get("source", "")) if lines else ""


def translation_reply(text):
    name = after(text, "번역할 언어:").splitlines()[0].strip() if "번역할 언어:" in text else "번역"
    lines = json_lines(text, "자막 줄")
    reply = {"lines": [{"id": line["id"], "text": f"{name} 번역: {line.get('source', '')}"} for line in lines]}
    return reply, first_line(lines)


def source_review_reply(text):
    lines = json_lines(text, "자막 줄")
    tickets = []
    if lines:
        tickets.append({"level": "suspect", "reason": "가짜 서버: 잘못 들은 말 같아요",
                        "changes": [{"id": lines[0]["id"], "text": lines[0].get("source", "") + "?"}]})
    return {"tickets": tickets}, first_line(lines)


def translation_review_reply(text):
    lines = json_lines(text, "자막 줄")
    tickets = []
    if lines:
        tickets.append({"level": "fix", "reason": "가짜 서버: 맥락상 번역을 고쳤어요", "target": "translation",
                        "changes": [{"id": lines[0]["id"], "text": lines[0].get("translation", "") + "~"}]})
    if len(lines) > 1:
        tickets.append({"level": "suspect", "reason": "가짜 서버: 원문이 잘못 받아쓰인 것 같아요", "target": "source",
                        "changes": [{"id": lines[1]["id"], "text": ""}]})
    return {"tickets": tickets}, first_line(lines)


def choose(text):
    """(단계 이름, 응답 JSON, 로그에 남길 가변 부분)"""
    if "자막 원문 검토자" in text:
        reply, first = source_review_reply(text)
        return "source-review", reply, first
    if "자막 번역 검토자" in text:
        reply, first = translation_review_reply(text)
        return "translation-review", reply, first
    if "번역 전에 정해 둘 용어집" in text:
        return "glossary", {
            "spellings": [{"source": "가짜원문", "target": "가짜번역", "note": "가짜 서버의 표기"}],
            "speech": [{"pair": "가짜인물 → 상대", "style": "반말"}],
        }, after(text, "자막 원문")
    if "아래 대상 줄을 " in text:
        reply, first = translation_reply(text)
        return "translate", reply, first
    if "구간별 줄거리" in text:
        return "merge", {"synopsis": "가짜 서버가 합친 줄거리입니다."}, after(text, "구간별 줄거리")
    if "줄거리, 등장인물, 용어" in text:
        return "analyze", {
            "synopsis": "가짜 서버가 쓴 줄거리입니다.",
            "characters": [{"name": "가짜인물", "reading": "", "relation": "주인공", "speech": "존댓말"}],
            "terms": [{"term": "가짜용어", "note": "가짜 서버가 만든 용어"}],
        }, after(text, "자막 원문")
    return "unknown", {}, text


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_stream(self, model, content, prompt, parts=4):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def event(value):
            self.wfile.write(b"data: " + json.dumps(value, ensure_ascii=False).encode("utf-8") + b"\n\n")
            self.wfile.flush()

        def chunk(delta, finish=None, usage=None):
            value = {"id": "fake", "object": "chat.completion.chunk", "model": model,
                     "choices": [] if usage else [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                value["usage"] = usage
            return value

        if DELAY:
            time.sleep(DELAY / 2)
        size = max(1, -(-len(content) // parts))
        pieces = [content[i:i + size] for i in range(0, len(content), size)] or [""]
        for i, piece in enumerate(pieces):
            if i and DELAY:
                time.sleep(DELAY / 2 / max(1, len(pieces) - 1))
            event(chunk({"role": "assistant", "content": piece} if i == 0 else {"content": piece}))
        event(chunk({}, finish="stop"))
        event(chunk(None, usage={"prompt_tokens": max(1, len(prompt) // 4),
                                 "completion_tokens": max(1, len(content) // 4),
                                 "total_tokens": max(1, len(prompt) // 4) + max(1, len(content) // 4)}))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def do_GET(self):
        print(f"GET {self.path}", flush=True)
        if self.path.rstrip("/").endswith("/models"):
            self.send_json(200, {"object": "list", "data": [{"id": "fake-text"}, {"id": "fake-vision"}]})
        else:
            self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self.send_json(404, {"error": {"message": "not found"}})
            return
        prompt = prompt_text(body)
        stage, reply, variable = choose(prompt)
        streaming = body.get("stream") is True
        print(f"POST {self.path} {stage}{' stream' if streaming else ''} {variable[:80]!r}", flush=True)
        if streaming:
            self.send_stream(body.get("model", ""), json.dumps(reply, ensure_ascii=False), prompt)
            return
        if DELAY:
            time.sleep(DELAY)
        self.send_json(200, {
            "id": "fake", "object": "chat.completion", "model": body.get("model", ""),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": json.dumps(reply, ensure_ascii=False)}}],
        })


def main():
    global DELAY
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--delay", type=float, default=0.0, help="응답마다 기다리는 초")
    args = parser.parse_args()
    DELAY = args.delay
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"fake LLM server on http://127.0.0.1:{args.port}/v1", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
