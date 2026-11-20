#!/usr/bin/env python3
"""Prints the crashed thread of every Folio crash report (.ips) with symbols, for CI logs (#223)."""
import glob, json, os, sys, time

# ReportCrash writes the report a little after the process died; wait up to a minute for it.
pattern = os.path.expanduser("~/Library/Logs/DiagnosticReports/Folio*.ips")
for _ in range(60):
    if glob.glob(pattern):
        break
    time.sleep(1)
if not glob.glob(pattern):
    print("Kein Absturzbericht gefunden.")
for path in sorted(glob.glob(pattern)):
    with open(path, errors="replace") as f:
        text = f.read()
    header, _, body = text.partition("\n")
    try:
        report = json.loads(body)
    except ValueError:
        print(f"== {path}: not readable\n{text[:4000]}")
        continue
    images = report.get("usedImages", [])
    print(f"== {path}")
    print("exception:", report.get("exception"), "termination:", report.get("termination", {}).get("indicator"))
    for key in ("asi", "lastExceptionBacktrace"):
        if key in report:
            print(key, json.dumps(report[key])[:2000])
    threads = report.get("threads", [])
    crashed = next((t for t in threads if t.get("triggered")), threads[report.get("faultingThread", 0)] if threads else None)
    for frame in (crashed or {}).get("frames", [])[:40]:
        image = images[frame.get("imageIndex", 0)] if images else {}
        print(f"  {image.get('name', '?'):28} {frame.get('symbol', hex(frame.get('imageOffset', 0)))} "
              f"{frame.get('sourceFile', '')}:{frame.get('sourceLine', '')}")
sys.exit(0)
