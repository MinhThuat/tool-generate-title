#!/usr/bin/env python3
"""Web UI: controls, log and downloaded images + results.
No embedded Claude terminal — Python drives the Trello pipeline on its own.

  python web_studio.py            # opens http://127.0.0.1:8770
"""
import argparse
import asyncio
import json
import os
import threading
import time
import urllib.parse
import webbrowser

from aiohttp import web

import keyword_generator as kg

ROOT = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.join(ROOT, "studio.html")


# ---------------- pipeline <-> browser bridge ----------------
class WebIO:
    """io the pipeline (running in a worker thread) talks through. Emits events
    to the browser over the /events WebSocket; ask() returns pre-filled answers
    collected from the run form (order: mode, optional prompt, board, list-index)."""

    def __init__(self, app, loop, answers):
        self.app = app
        self.loop = loop
        self.answers = list(answers)
        self.stop = threading.Event()
        self.proc = None  # claude subprocess currently running, if any

    def _emit(self, evt):
        asyncio.run_coroutine_threadsafe(broadcast(self.app, evt), self.loop)

    def ask(self, prompt, secret=False):
        self._emit({"t": "log", "msg": prompt})
        return self.answers.pop(0) if self.answers else ""

    def log(self, msg):
        self._emit({"t": "log", "msg": msg})

    def image(self, card_id, path):
        self.app["media"].add(os.path.realpath(path))
        self._emit({"t": "image", "card": card_id,
                    "url": "/media?p=" + urllib.parse.quote(path)})

    def result(self, card_id, sku, title, tags, ok):
        self._emit({"t": "result", "card": card_id, "sku": sku,
                    "title": title, "tags": tags, "ok": ok})


async def broadcast(app, evt):
    dead = []
    for ws in app["clients"]:
        try:
            await ws.send_json(evt)
        except ConnectionResetError:
            dead.append(ws)
    for ws in dead:
        app["clients"].discard(ws)


# ---------------- HTTP endpoints ----------------
async def index(request):
    return web.FileResponse(HTML)


async def events(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    request.app["clients"].add(ws)
    try:
        async for _ in ws:  # client only listens
            pass
    finally:
        request.app["clients"].discard(ws)
    return ws


async def media(request):
    p = os.path.realpath(urllib.parse.unquote(request.query.get("p", "")))
    if p not in request.app["media"] or not os.path.isfile(p):
        return web.Response(status=404, text="not found")
    return web.FileResponse(p, headers={"Content-Type": "image/jpeg"})


async def status(request):
    """Claude connectivity (haiku ping) + whether Trello creds are saved."""
    msgs = []
    ok = await asyncio.get_event_loop().run_in_executor(
        None, kg.check_claude_connection, _CollectIO(msgs))
    creds = bool((kg.TRELLO_API_KEY and kg.TRELLO_TOKEN) or os.path.exists(kg.CONFIG_PATH))
    return web.json_response({"claude_ok": ok, "claude_log": msgs, "creds_saved": creds})


async def save_creds(request):
    d = await request.json()
    kg.TRELLO_API_KEY = (d.get("key") or "").strip()
    kg.TRELLO_TOKEN = (d.get("token") or "").strip()
    try:
        with open(kg.CONFIG_PATH, "w") as f:
            json.dump({"TRELLO_API_KEY": kg.TRELLO_API_KEY,
                       "TRELLO_TOKEN": kg.TRELLO_TOKEN}, f)
        os.chmod(kg.CONFIG_PATH, 0o600)
    except OSError:
        pass
    return web.json_response({"saved": bool(kg.TRELLO_API_KEY and kg.TRELLO_TOKEN)})


def _load_saved_creds():
    if kg.TRELLO_API_KEY and kg.TRELLO_TOKEN:
        return
    try:
        with open(kg.CONFIG_PATH) as f:
            cfg = json.load(f)
        kg.TRELLO_API_KEY = kg.TRELLO_API_KEY or cfg.get("TRELLO_API_KEY", "").strip()
        kg.TRELLO_TOKEN = kg.TRELLO_TOKEN or cfg.get("TRELLO_TOKEN", "").strip()
    except (OSError, json.JSONDecodeError):
        pass


async def lists(request):
    _load_saved_creds()
    if not (kg.TRELLO_API_KEY and kg.TRELLO_TOKEN):
        return web.json_response({"err": "Chưa có Trello key/token."}, status=400)
    board = kg.parse_board_id(request.query.get("board", "").strip())
    msgs = []
    data = await asyncio.get_event_loop().run_in_executor(
        None, kg.get_lists, board, _CollectIO(msgs))
    if not data:
        return web.json_response({"err": " ".join(msgs) or "Không lấy được lists."}, status=400)
    return web.json_response({"lists": [{"id": l["id"], "name": l["name"]} for l in data]})


RAN_PATH = os.path.join(kg.base_dir(), "ran_lists.json")


def _load_ran():
    """{list_id: "YYYY-MM-DD HH:MM"} of lists already run."""
    try:
        with open(RAN_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _mark_ran(list_id):
    ran = _load_ran()
    ran[list_id] = time.strftime("%Y-%m-%d %H:%M")
    try:
        with open(RAN_PATH, "w", encoding="utf-8") as f:
            json.dump(ran, f, indent=2)
    except OSError:
        pass


async def run(request):
    d = await request.json()
    # No await between check and claim, so two clicks can't both start a run.
    if request.app["state"]["running"]:
        return web.json_response({"err": "Đang chạy rồi."}, status=409)
    _load_saved_creds()
    if not (kg.TRELLO_API_KEY and kg.TRELLO_TOKEN):
        return web.json_response({"err": "Chưa có Trello key/token."}, status=400)
    list_id = str(d.get("list_id", ""))
    ran_at = _load_ran().get(list_id)
    if ran_at and not d.get("force"):
        return web.json_response({"confirm": True, "ran_at": ran_at})
    # run_pipeline asks in this order: mode, optional prompt, board, list (id).
    answers = [d.get("mode", "1"), d.get("prompt", ""),
               d.get("board", ""), list_id]
    loop = asyncio.get_event_loop()
    io = WebIO(request.app, loop, answers)
    request.app["state"]["running"] = True
    request.app["state"]["io"] = io
    io.log("Bắt đầu chạy…")

    def worker():
        try:
            if kg.run_pipeline(io, ping=False) == 0:
                _mark_ran(list_id)  # also on Stop: some cards were already updated
        except Exception as e:
            io.log(f"Fatal: {e}")
        finally:
            io._emit({"t": "done"})
            request.app["state"]["running"] = False

    threading.Thread(target=worker, daemon=True).start()
    return web.json_response({"started": True})


async def stop(request):
    io = request.app["state"].get("io")
    if not request.app["state"]["running"] or not io:
        return web.json_response({"err": "Không có gì đang chạy."}, status=409)
    io.stop.set()
    proc = io.proc
    if proc:
        kg.kill_proc(proc)
    io.log("Đang dừng…")
    return web.json_response({"stopping": True})


class _CollectIO:
    """Minimal io that just collects log lines (for status/lists helpers)."""
    def __init__(self, sink):
        self.sink = sink

    def ask(self, prompt, secret=False):
        return ""

    def log(self, msg):
        self.sink.append(msg)

    def image(self, *a):
        pass

    def result(self, *a):
        pass


@web.middleware
async def same_origin_only(request, handler):
    """Block other websites open in the same browser from driving this local
    server (saving creds, starting paid runs, reading /events). Browsers always
    send Origin on cross-site POSTs and WebSocket upgrades."""
    origin = request.headers.get("Origin")
    hostname = request.host.rsplit(":", 1)[0]  # Host check also stops DNS rebinding
    if hostname not in ("127.0.0.1", "localhost") or (origin and origin != f"http://{request.host}"):
        return web.Response(status=403, text="forbidden origin")
    return await handler(request)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()

    app = web.Application(client_max_size=64 * 1024 * 1024, middlewares=[same_origin_only])
    app["clients"] = set()
    app["media"] = set()
    app["state"] = {"running": False}
    app.add_routes([
        web.get("/", index),
        web.get("/events", events),
        web.get("/media", media),
        web.get("/status", status),
        web.post("/creds", save_creds),
        web.get("/lists", lists),
        web.post("/run", run),
        web.post("/stop", stop),
    ])
    url = f"http://127.0.0.1:{a.port}"
    print(f"Studio: {url}")
    if not a.no_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    web.run_app(app, host="127.0.0.1", port=a.port, print=None)


if __name__ == "__main__":
    main()
