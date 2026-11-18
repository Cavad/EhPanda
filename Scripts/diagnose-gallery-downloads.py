"""Run the actual app on a clean iPhone simulator and keep only numeric diagnostics."""

import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time


GALLERIES = ((80, "4119423/b944b57311"), (88, "4133615/e84a09fe25"))
TERMINAL = ("settled result=", "detail_failed ")


def simctl(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *args], text=True, check=True, **kwargs)


def page_counts(data, gid):
    for manifest in (data / "Documents" / "Downloads").glob("**/manifest.json"):
        try:
            info = json.loads(manifest.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            continue
        if info.get("gid") == gid:
            pages = info["pages"]
            missing = sorted(int(page) for page, digest in pages.items() if not digest)
            return len(pages) - len(missing), len(pages), missing
    return 0, 0, []


def run_gallery(device, bundle, data, output, host, gallery, expected_count):
    gid = gallery.split("/")[0]
    url = f"https://{host}.org/g/{gallery}/"
    preflight = subprocess.run(
        ["curl", "-sS", "--max-time", "15", "-o", os.devnull, "-w", "%{http_code}", url],
        capture_output=True, text=True, check=False,
    )
    label = f"{host}-{expected_count}"
    print(f"{label} starting (runner gallery HTTP {preflight.stdout or 'unavailable'})", flush=True)
    environment = os.environ | {
        "SIMCTL_CHILD_EHPANDA_DOWNLOAD_DIAGNOSIS": "1",
        "SIMCTL_CHILD_EHPANDA_AUTOMATION_GALLERY_URL": url,
        "SIMCTL_CHILD_EHPANDA_AUTOMATION_AUTO_DOWNLOAD_GID": gid,
    }
    began = time.monotonic()
    events = []
    last_counts = None
    with (output / f"{label}.log").open("w+") as log:
        monitor = subprocess.Popen([
            "xcrun", "simctl", "spawn", device, "log", "stream", "--level", "info", "--style", "compact",
            "--predicate", 'eventMessage BEGINSWITH "DL_DIAG "',
        ], stdout=log, stderr=subprocess.STDOUT)
        offset = 0
        try:
            time.sleep(2)
            simctl("launch", "--terminate-running-process", device, bundle, env=environment, capture_output=True)
            while True:
                time.sleep(3)
                log.seek(offset)
                new_events = re.findall(r"DL_DIAG ([^\r\n]+)\n", log.read())
                offset = log.tell()
                events.extend(new_events)
                elapsed = round(time.monotonic() - began)
                counts = page_counts(data, gid)
                if counts[:2] != last_counts:
                    last_counts = counts[:2]
                    if counts[1] > 0:
                        print(f"{label} {elapsed}s: {counts[0]}/{counts[1]} saved", flush=True)
                for event in new_events:
                    if not event.startswith(("response ", "resolved ")):
                        print(f"{label} {event}", flush=True)
                if any(event.startswith(TERMINAL) for event in events):
                    reason = "terminal"
                    break
                if monitor.poll() is not None:
                    reason = "monitor_stopped"
                    break
                if elapsed >= 900 or (elapsed >= 90 and counts[1] == 0):
                    reason = "deadline"
                    break
        finally:
            monitor.terminate()
            monitor.wait(timeout=15)
            subprocess.run(["xcrun", "simctl", "terminate", device, bundle], capture_output=True, check=False)
    completed, total, missing = page_counts(data, gid)
    report = {
        "host": host, "expected_pages": expected_count, "manifest_pages": total, "saved_pages": completed,
        "missing_pages": missing, "runner_http": preflight.stdout, "seconds": round(time.monotonic() - began),
        "end": reason, "events": events,
    }
    (output / f"{label}.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{label} final {completed}/{total or expected_count} in {report['seconds']}s ({reason})", flush=True)
    return report


def main():
    app, output = map(Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    with (app / "Info.plist").open("rb") as handle:
        bundle = plistlib.load(handle)["CFBundleIdentifier"]
    runtimes = json.loads(simctl("list", "devices", "available", "-j", capture_output=True).stdout)["devices"]
    devices = runtimes["com.apple.CoreSimulator.SimRuntime.iOS-27-0"]
    device = next(item for item in devices if item["name"] == "iPhone Air")
    udid = device["udid"]
    if device["state"] != "Booted":
        simctl("boot", udid)
    simctl("bootstatus", udid, "-b")
    for host in ("e-hentai", "exhentai"):
        simctl("install", udid, str(app))
        data = Path(simctl("get_app_container", udid, bundle, "data", capture_output=True).stdout.strip())
        for expected, gallery in GALLERIES:
            report = run_gallery(udid, bundle, data, output, host, gallery, expected)
            if any("code=quotaExceeded" in event or "code=ipBanned" in event for event in report["events"]):
                break
            if host == "exhentai" and report["runner_http"].startswith(("3", "4")) and not report["manifest_pages"]:
                break
        simctl("uninstall", udid, bundle, capture_output=True)


if __name__ == "__main__":
    main()

