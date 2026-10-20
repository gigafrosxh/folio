#!/usr/bin/env python3
"""Run app self-tests in fresh libraries; preserve logs and fixtures for inspection."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
RUN = Path(tempfile.mkdtemp(prefix="folio-dev-regression-"))
print(f"Test libraries and logs: {RUN}", flush=True)
failed = False
for flag, prefix in [("DEV", "DEV"), ("SAFETY", "SAFETY"), ("ORG", "ORG"), ("EDITOR", "EDIT"), ("KEY", "KEY"), ("A11Y", "A11Y")]:
    library = RUN / flag
    library.mkdir()
    log = RUN / f"{flag}.log"
    env = dict(os.environ, FOLIO_LIBRARY=str(library))
    env[f"FOLIO_{flag}_TEST"] = "1"
    if flag == "A11Y":
        # Accessibility audit (#60) of a note with every kind of block.
        env.update(FOLIO_A11Y_AUDIT="1", FOLIO_LAYOUT_DUMP="1", FOLIO_DUMP_DELAY="6",
                   FOLIO_SAMPLE_MEDIA=str(RUN / "no-audio-needed.wav"))
    if flag == "EDITOR":
        # This harness needs a second note with an attachment; generate an image fixture.
        env["FOLIO_SAMPLE_MEDIA"] = str(RUN / "no-audio-needed.wav")
    with log.open("w") as output:
        proc = subprocess.Popen([str(ROOT / ".build/debug/Folio")], env=env,
                                stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 60
            while proc.poll() is None and time.monotonic() < deadline:
                current = log.read_text(errors="replace")
                if f"{prefix} done" in current or (flag == "A11Y" and "A11Y checked" in current):
                    break
                time.sleep(0.25)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
    text = log.read_text(errors="replace")
    print("\n".join(line for line in text.splitlines() if line.startswith(prefix)), flush=True)
    if flag == "A11Y":
        # Done when the summary line is there; every control needs a name.
        summary = next((l for l in text.splitlines() if l.startswith("A11Y checked")), "")
        if not summary or not summary.endswith(" 0 without name"):
            failed = True
            print(f"FAIL: {log}", flush=True)
        continue
    if f"{prefix} done" not in text or f"{prefix} FAIL" in text:
        failed = True
        print(f"FAIL: {log}", flush=True)
raise SystemExit(1 if failed else 0)
