"""Walks one ExHentai gallery the way EhPanda's downloader does and records per-page timings.

Usage (the session cookie comes from the environment, never from the command line or a file):
    set EH_COOKIE=ipb_member_id=...; ipb_pass_hash=...      (Windows cmd)
    $env:EH_COOKIE = "ipb_member_id=...; ipb_pass_hash=..."  (PowerShell)
    python Scripts/probe-gallery-transfers.py https://exhentai.org/g/<gid>/<token>/ out.json
Optional: WORKERS (default 2), HARD_CAP seconds per transfer (default 240).

Viewer page -> img#img src (+ nl reload token) -> streamed image transfer, with chunk-gap and
throughput tracking. Does NOT apply the app's watchdog: each transfer gets a hard cap so long
tails are observed rather than hidden. Results go to a JSON file; image bytes are discarded.
"""
import concurrent.futures as cf
import html
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request

COOKIE = os.environ["EH_COOKIE"]
CA = os.environ.get("EH_CA_BUNDLE", "")
CTX = ssl.create_default_context(cafile=CA) if CA and os.path.exists(CA) else ssl.create_default_context()
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
HARD_CAP = float(os.environ.get("HARD_CAP", "240"))
lock = threading.Lock()


def opener():
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=CTX))


def get(url, timeout=30, cookie=True):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **({"Cookie": COOKIE} if cookie else {})})
    with opener().open(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def page_links(gallery_url):
    links = {}
    p = 0
    while True:
        doc = get(f"{gallery_url}?p={p}")
        found = re.findall(r'https://exhentai\.org/s/([0-9a-f]+)/(\d+)-(\d+)', doc)
        new = 0
        for key, gid, idx in found:
            if int(idx) not in links:
                links[int(idx)] = f"https://exhentai.org/s/{key}/{gid}-{idx}"
                new += 1
        if new == 0:
            break
        p += 1
    return links


def viewer(url, nl=None):
    if nl:
        url = f"{url}?nl={urllib.parse.quote(nl)}"
    t0 = time.monotonic()
    doc = get(url, timeout=20)
    dt = time.monotonic() - t0
    m = re.search(r'<img id="img" src="([^"]+)"', doc)
    n = re.search(r"nl\('([^']+)'\)", doc)
    return (html.unescape(m.group(1)) if m else None), (n.group(1) if n else None), dt


def transfer(url):
    """Streams the image, returning timing facts. Never raises."""
    res = {"host": urllib.parse.urlsplit(url).hostname, "port": urllib.parse.urlsplit(url).port or 443}
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://exhentai.org/"})
        with opener().open(req, timeout=60) as r:
            res["status"] = r.status
            res["ttfb"] = round(time.monotonic() - t0, 2)
            expected = int(r.headers.get("Content-Length") or -1)
            res["expected"] = expected
            got, last, max_gap, first = 0, time.monotonic(), 0.0, None
            while True:
                chunk = r.read(16384)
                now = time.monotonic()
                if not chunk:
                    break
                first = first or now
                max_gap = max(max_gap, now - last)
                last = now
                got += len(chunk)
                if now - t0 > HARD_CAP:
                    res["capped"] = True
                    break
            res["bytes"] = got
            res["max_gap"] = round(max_gap, 2)
    except Exception as exc:  # noqa: BLE001 - probe records every failure kind
        res["error"] = f"{type(exc).__name__}: {exc}"[:160]
    res["total"] = round(time.monotonic() - t0, 2)
    if res.get("bytes") and res["total"] > 0:
        res["kbps"] = round(res["bytes"] / 1024 / res["total"], 1)
    return res


def page(idx, url):
    rec = {"page": idx, "attempts": []}
    nl = None
    for attempt in range(4):
        a = {"attempt": attempt + 1}
        try:
            img, nl_next, vdt = viewer(url, nl)
            a["viewer_s"] = round(vdt, 2)
        except Exception as exc:  # noqa: BLE001
            a["viewer_error"] = f"{type(exc).__name__}: {exc}"[:160]
            rec["attempts"].append(a)
            continue
        if not img:
            a["viewer_error"] = "no img"
            rec["attempts"].append(a)
            continue
        a.update(transfer(img))
        rec["attempts"].append(a)
        ok = a.get("status") == 200 and not a.get("error") and not a.get("capped") \
            and (a.get("expected", -1) < 0 or a.get("bytes") == a.get("expected"))
        if ok:
            rec["ok"] = True
            break
        nl = nl_next
    with lock:
        last = rec["attempts"][-1]
        print(f"p{idx:>3} ok={rec.get('ok', False)} tries={len(rec['attempts'])} "
              f"viewer={last.get('viewer_s')} {last.get('host')}:{last.get('port')} "
              f"ttfb={last.get('ttfb')} total={last.get('total')} kbps={last.get('kbps')} "
              f"gap={last.get('max_gap')} {last.get('error', '')}", flush=True)
    return rec


def main():
    gallery, out = sys.argv[1], sys.argv[2]
    workers = int(os.environ.get("WORKERS", "2"))
    links = page_links(gallery)
    print(f"{len(links)} page links", flush=True)
    t0 = time.monotonic()
    with cf.ThreadPoolExecutor(workers) as pool:
        results = list(pool.map(lambda kv: page(*kv), sorted(links.items())))
    summary = {"gallery": gallery.split("/g/")[1], "pages": len(links),
               "ok": sum(1 for r in results if r.get("ok")), "wall_s": round(time.monotonic() - t0, 1)}
    print(json.dumps(summary), flush=True)
    with open(out, "w") as fh:
        json.dump({"summary": summary, "results": results}, fh, indent=1)


if __name__ == "__main__":
    main()
