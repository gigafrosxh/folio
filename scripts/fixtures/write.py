# Called by make-fixtures.sh: writes meta/body JSON for one version and runs its generator.
import base64, json, os, subprocess, sys
tag, d, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
ver = tag[1:]
rtf = base64.b64encode("{\\rtf1\\ansi\\ansicpg1252 Migration Gr\\u252\\'fc\\u223\\'df #alt\\par Zweite Zeile}".encode()).decode()
v = tuple(int(x) for x in ver.split("."))
# Block kinds each version knows: database since 0.10, formula/diagram/audio since 0.13.
extra = (["database"] if v >= (0, 10, 0) else []) + (["math", "diagram", "audio"] if v >= (0, 13, 0) else [])
meta = {"id": "00000000-0000-0000-0000-%012d" % int(ver.replace('.', '')), "title": "Migration " + ver, "preview": "Zweite Zeile",
        "tags": ["alt"], "created": 700000000, "modified": 700000100, "pinned": True,
        "searchText": "Migration Grüße #alt\nZweite Zeile", "links": [], "kinds": ["text", "code"],
        "environment": {"interpreters": {}, "variables": {"X": "1"}}}
blocks = [{"id": "00000000-0000-0000-0000-0000000000B1", "kind": "text", "rtf": rtf},
          {"id": "00000000-0000-0000-0000-0000000000B2", "kind": "code", "code": "print('hallo ✓')", "language": "python",
           "output": "hallo ✓\n", "outputIsError": False, "stdin": "x", "outputCollapsed": True},
          {"id": "00000000-0000-0000-0000-0000000000B3", "kind": "web", "url": "https://example.com", "height": 480, "width": 1, "mode": "preview"},
          {"id": "00000000-0000-0000-0000-0000000000B4", "kind": "image", "attachmentID": "00000000-0000-0000-0000-0000000000A1",
           "height": 0, "width": 0.75, "caption": "Bild"}]
for k in extra:
    b = {"id": "00000000-0000-0000-0000-0000000000C%d" % len(blocks), "kind": k}
    if k in ("database", "math", "diagram"):
        b["code"] = {"database": "select 1", "math": "e^{i\\pi}", "diagram": "graph TD; A-->B"}[k]
    if k == "audio":
        b["output"] = "Transkript"
    blocks.append(b)
json.dump(meta, open(f"{d}/meta.json", "w"))
json.dump({"blocks": blocks}, open(f"{d}/body.json", "w"))
subprocess.run([f"{d}/gen", f"{d}/meta.json", f"{d}/body.json", os.path.join(out_dir, f"note-{ver}.folio"), "att"], check=True)
