#!/bin/bash
#
# Classify one image or a whole directory of them against a label set.
#
#   ./scripts/classify.sh frame.jpg
#   ./scripts/classify.sh ./frames/
#   CLASSES=person,animal,vehicle,none SAMPLES=3 ./scripts/classify.sh ./frames/
#
# Built for tuning: point it at saved camera frames, adjust CLASSES, and watch
# the agreement column. Labels the model is unsure about show up as agreement
# below 1.00, which is the signal that your vocabulary needs work.
#
# Environment knobs:
#   CLASSES   comma-separated label set (must include an escape hatch like "none")
#   SAMPLES   1-9, how many times to classify each image (default 3)
#   MAX_DIM   longest edge after downscaling; 0 sends as-is (default 1024)
#   SERVER    default http://localhost:8080
#   CAMERA    recorded as metadata.camera in the server log
#   JSONL     also append each raw server response to this file

# Kept free of arrays and process substitution so it behaves the same whether it
# is run directly, as `bash classify.sh`, or as `sh classify.sh` — macOS /bin/sh
# is bash in POSIX mode, where those constructs are unavailable.
set -eu

TARGET="${1:-}"
HINT="${2:-}"
# Coarse categories by default. The on-device model is reliable at "person vs
# animal vs vehicle" and unreliable at species — it reads turkeys as dogs. See
# the "What this model can and cannot do" section of the README.
CLASSES="${CLASSES:-person,animal,vehicle,none}"
SAMPLES="${SAMPLES:-3}"
MAX_DIM="${MAX_DIM:-1024}"
SERVER="${SERVER:-http://localhost:8080}"
CAMERA="${CAMERA:-}"
JSONL="${JSONL:-}"

if [ -z "$TARGET" ]; then
    echo "usage: $(basename "$0") <image-file-or-directory> [hint]" >&2
    echo "       CLASSES=a,b,none SAMPLES=3 $(basename "$0") ./frames/" >&2
    exit 64
fi

# Collect the images to run, one path per line in a temp file.
LIST="$(mktemp -t classifylist)"
TMP="$(mktemp -t classify).jpg"
RESULTS="$(mktemp -t classifyres)"
trap 'rm -f "$TMP" "$RESULTS" "$LIST"' EXIT

if [ -d "$TARGET" ]; then
    find "$TARGET" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tiff' \) \
        | sort > "$LIST"
    if [ ! -s "$LIST" ]; then
        echo "error: no images found in $TARGET" >&2
        exit 66
    fi
elif [ -r "$TARGET" ]; then
    printf '%s\n' "$TARGET" > "$LIST"
else
    echo "error: cannot read $TARGET" >&2
    exit 66
fi

echo "classes: $CLASSES"
echo "samples: $SAMPLES   images: $(wc -l < "$LIST" | tr -d ' ')"
echo
printf '%-30s %-38s %8s\n' "FILE" "SUBJECTS (label agreement)" "MS"
printf '%-30s %-38s %8s\n' "----" "--------------------------" "--"

while IFS= read -r f; do
    if [ "$MAX_DIM" != "0" ]; then
        if ! sips -Z "$MAX_DIM" -s format jpeg "$f" --out "$TMP" >/dev/null 2>&1; then
            printf '%-30s %-38s %8s\n' "$(basename "$f" | cut -c1-30)" "<not an image>" "-"
            continue
        fi
        SEND="$TMP"
    else
        SEND="$f"
    fi

    RESPONSE=$(python3 -c '
import base64, json, sys
path, classes, samples, hint, camera = sys.argv[1:6]
body = {
    "classes": [c.strip() for c in classes.split(",") if c.strip()],
    "images": [{"data": base64.b64encode(open(path, "rb").read()).decode()}],
    "samples": int(samples),
}
if hint:
    body["hint"] = hint
meta = {"source": sys.argv[6]}
if camera:
    meta["camera"] = camera
body["metadata"] = meta
sys.stdout.write(json.dumps(body))
' "$SEND" "$CLASSES" "$SAMPLES" "$HINT" "$CAMERA" "$f" \
      | curl -sS -X POST "$SERVER/classify" \
            -H "Content-Type: application/json" --data-binary @- 2>/dev/null) || RESPONSE=""

    if [ -n "$JSONL" ] && [ -n "$RESPONSE" ]; then
        printf '%s\n' "$RESPONSE" >> "$JSONL"
    fi

    printf '%s\t%s\n' "$f" "$RESPONSE" >> "$RESULTS"

    python3 -c '
import json, os, sys
path, raw = sys.argv[1], sys.argv[2]
name = os.path.basename(path)[:30]
if not raw.strip():
    print(f"{name:<30} {"<no response>":<38} {"-":>8}")
    sys.exit()
d = json.loads(raw)
if "error" in d:
    # Errors get their own line rather than being squeezed into the column.
    print(f"{name:<30} {"<error>":<38} {"-":>8}")
    print(f"    {d["error"]}")
else:
    labels = ", ".join(f"{s["label"]} {s["agreement"]:.2f}" for s in d["subjects"])
    print(f"{name:<30} {labels[:38]:<38} {d["duration_ms"]:>8}")
' "$f" "$RESPONSE"
done < "$LIST"

echo
python3 -c '
import json, sys, collections
rows = []
for line in open(sys.argv[1]):
    path, _, raw = line.partition("\t")
    raw = raw.strip()
    if not raw:
        continue
    try:
        d = json.loads(raw)
    except ValueError:
        continue
    if "subjects" in d:
        rows.append(d)
if not rows:
    sys.exit("no successful classifications")
tally = collections.Counter(s["label"] for r in rows for s in r["subjects"])
print(f"{len(rows)} classified — " + ", ".join(f"{k}: {v}" for k, v in tally.most_common()))
unsure = [(r, s) for r in rows for s in r["subjects"] if s["agreement"] < 1.0]
if unsure:
    print(f"{len(unsure)} label(s) below full agreement (vocabulary may need work):")
    for r, s in unsure:
        print(f"  {s["label"]} {s["agreement"]:.2f}  samples={r["samples"]}")
else:
    print("all unanimous")
print(f"mean latency: {sum(r["duration_ms"] for r in rows) // len(rows)}ms")
' "$RESULTS"
