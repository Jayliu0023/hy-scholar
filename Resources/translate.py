"""Keep the installed offline Hy engine warm and stream the latest selection."""
import contextlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import re
import socket
import sys
import threading

path = Path.home() / ".local/share/hy-mt2-7b/hy-mt2-7b"
loader = importlib.machinery.SourceFileLoader("local_hy", str(path))
hy = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(hy)

condition = threading.Condition()
latest = None
active = None
serial = 0
closed = False

def send(job, field, value):
    with condition:
        if serial == job and not closed:
            print(json.dumps({"id": job, field: value}, ensure_ascii=False), flush=True)

def translate(sock, job, text, example, context):
    global active
    abbreviations = dict.fromkeys(w for w in re.findall(r"[（(]([a-zA-Z][a-zA-Z0-9./+-]{1,30})[)）]", text) if any(c.isupper() for c in w))
    keep = "保留括号缩写：" + "、".join(abbreviations) + "。" if abbreviations else ""
    prompt = ("将下列文献选区准确翻译为简体中文。若只有一个术语，给出该术语的简明译名。"
              "保留专业术语、数值、单位、否定和原文的证据强度。" + keep + "只输出译文。\n\n" + text)
    if context and context.casefold() != text.casefold():
        prompt = ("Translate the term into Chinese as a glossary entry.\nDomain context: " + context
                  + "\nEnglish term: " + text + "\nChinese term:")
    if example:
        prompt = ("Write one short, natural English example sentence using the word or phrase below "
                  "in a scientific or academic context. Output the English sentence only.\n\n" + text)
    payload = {"model":"local", "messages":[{"role":"user","content":prompt}], "stream":True,
               "temperature":0 if context and not example else 0.7, "top_p":0.6, "top_k":20, "repeat_penalty":1.05, "seed":42, "max_tokens":4096}
    with contextlib.closing(hy.LocalConnection(sock, 300)) as conn:
        conn.connect()
        with condition:
            if serial != job or closed:
                return
            active = conn
        try:
            conn.request("POST", "/v1/chat/completions", json.dumps(payload).encode(), {"Content-Type":"application/json"})
            with conn.getresponse() as response:
                if response.status != 200:
                    raise RuntimeError("选区超出模型上下文，或本地推理服务暂时不可用。请缩短选区重试。")
                finished = False
                for line in response:
                    if not line.startswith(b"data:"):
                        continue
                    data = line[5:].strip()
                    if data == b"[DONE]":
                        break
                    packet = json.loads(data)
                    choice = packet["choices"][0]
                    if choice["delta"].get("content"):
                        send(job, "delta", choice["delta"]["content"])
                    if choice.get("finish_reason") == "length":
                        raise RuntimeError("译文达到长度上限，请缩短选区。")
                    if choice.get("finish_reason") == "stop":
                        finished = True
                if not finished:
                    raise RuntimeError("翻译中断，请重新选择原文。")
                send(job, "done", True)
        finally:
            with condition:
                active = None

def worker():
    global latest
    with contextlib.ExitStack() as stack:
        sock = None
        while True:
            with condition:
                condition.wait_for(lambda: closed or latest is not None)
                if closed:
                    return
                job, text, example, context = latest
                latest = None
            try:
                if sock is None:
                    sock = stack.enter_context(hy.engine())
                translate(sock, job, text, example, context)
            except Exception as exc:
                with condition:
                    cancelled = closed or serial != job
                if not cancelled:
                    send(job, "error", str(exc) if isinstance(exc, RuntimeError) else "本地翻译引擎未响应，请重新选择原文。")
                    stack.close()
                    sock = None

def interrupt():
    if active and active.sock:
        try:
            active.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

thread = threading.Thread(target=worker)
thread.start()
try:
    for line in sys.stdin:
        msg = json.loads(line)
        with condition:
            serial = msg["id"]
            latest = (serial, msg["text"], bool(msg.get("example")), msg.get("context", "")) if msg.get("text") else None
            interrupt()
            condition.notify()
finally:
    with condition:
        closed = True
        interrupt()
        condition.notify()
    thread.join()
