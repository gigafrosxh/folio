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
for flag, prefix in [("DEV", "DEV"), ("SAFETY", "SAFETY"), ("ORG", "ORG"), ("EDITOR", "EDIT")]:
    library = RUN / flag
    library.mkdir()
    log = RUN / f"{flag}.log"
    env = dict(os.environ, FOLIO_LIBRARY=str(library))
    env[f"FOLIO_{flag}_TEST"] = "1"
    if flag == "EDITOR":
        # This harness needs a second note with an attachment; generate an image fixture.
        env["FOLIO_SAMPLE_MEDIA"] = str(RUN / "no-audio-needed.wav")
    with log.open("w") as output:
        proc = subprocess.Popen([str(ROOT / ".build/debug/Folio")], env=env,
                                stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 60
            while proc.poll() is None and time.monotonic() < deadline:
                if f"{prefix} done" in log.read_text(errors="replace"):
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
    if f"{prefix} done" not in text or f"{prefix} FAIL" in text:
        failed = True
        print(f"FAIL: {log}", flush=True)
raise SystemExit(1 if failed else 0)
