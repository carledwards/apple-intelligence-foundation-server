#!/bin/bash
#
# Send an image plus a text prompt to the Foundation Server.
#
#   ./scripts/ask-image.sh photo.jpg "What subjects are in this photo?"
#   ./scripts/ask-image.sh photo.jpg                  # uses a default prompt
#
# Environment knobs:
#   MAX_DIM=1024        longest edge after downscaling; set 0 to send as-is
#   SERVER=http://localhost:8080
#   SESSION=<uuid>      continue an existing session instead of a one-shot
#
# Two details this handles that a naive curl one-liner does not:
#
#   1. The base64 payload never becomes a command-line argument. A 750KB image
#      already exceeds ARG_MAX (1MB on macOS), so `-d "{...$IMG...}"` dies with
#      "argument list too long". Here Python reads the file and writes the JSON
#      to stdout, and curl streams it back in with --data-binary @-.
#   2. Images are downscaled first. The model resamples to a fixed resolution
#      internally, so full-resolution uploads cost time and can push past the
#      server's 32MB body cap without improving the answer.

# Kept free of bash-only syntax so `sh ask-image.sh` behaves the same as running
# it directly — macOS /bin/sh is bash in POSIX mode.
set -eu

IMAGE="${1:-}"
PROMPT="${2:-Describe this image.}"
MAX_DIM="${MAX_DIM:-1024}"
SERVER="${SERVER:-http://localhost:8080}"
SESSION="${SESSION:-}"

if [ -z "$IMAGE" ]; then
    echo "usage: $(basename "$0") <image-file> [prompt]" >&2
    exit 64
fi
if [ ! -r "$IMAGE" ]; then
    echo "error: cannot read image: $IMAGE" >&2
    exit 66
fi

# Downscale into a temp file unless MAX_DIM=0. sips ships with macOS.
CLEANUP=""
if [ "$MAX_DIM" != "0" ]; then
    TMP="$(mktemp -t askimage).jpg"
    CLEANUP="$TMP"
    trap 'rm -f "$CLEANUP"' EXIT
    if ! sips -Z "$MAX_DIM" -s format jpeg "$IMAGE" --out "$TMP" >/dev/null 2>&1; then
        echo "error: sips could not read '$IMAGE' as an image" >&2
        exit 65
    fi
    SEND="$TMP"
else
    SEND="$IMAGE"
fi

# Build the request body. Python reads the image itself, so the base64 is never
# passed through argv and the prompt is JSON-escaped correctly.
python3 -c '
import base64, json, sys
path, prompt, session = sys.argv[1], sys.argv[2], sys.argv[3]
body = {
    "prompt": prompt,
    "images": [{"data": base64.b64encode(open(path, "rb").read()).decode()}],
}
if session:
    body["session_id"] = session
sys.stdout.write(json.dumps(body))
' "$SEND" "$PROMPT" "$SESSION" \
  | curl -sS -X POST "$SERVER/inference" \
        -H "Content-Type: application/json" \
        --data-binary @- 2>/dev/null \
  | python3 -c '
import json, os, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit("error: no response from " + os.environ.get("SERVER", "http://localhost:8080")
             + " — is the server running? (swift run)")
try:
    data = json.loads(raw)
except ValueError:
    sys.exit("error: unexpected response from server:\n" + raw[:400])
if "error" in data:
    sys.exit("error: " + data["error"])
print(data["response"])
if data.get("session_id"):
    print("[session " + data["session_id"] + "]", file=sys.stderr)
'
