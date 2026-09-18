# Apple Intelligence Foundation Server (macOS)

A Swift command-line HTTP server that exposes the Apple Intelligence system language model over a simple JSON REST API using Apple's `FoundationModels` framework. Run it locally on supported devices to perform on-device language model inference.

This package is intended for experimentation and local development with Apple Intelligence.

> **Working with images?** Read
> [Phrasing Changes the Answer](#phrasing-changes-the-answer--test-before-you-trust)
> first. Measured on real photos, the same question about the same image swung
> from 0% to 100% correct depending only on how it was worded and how the answer
> was requested. A prompt that reads sensibly is not evidence that it works.

---

## Requirements

- **macOS 27.0+** to run the server
- **iOS 27.0+** for anything linking `FoundationCore` directly
- **Swift 6.2+**
- **Apple Intelligence enabled** on your device
- **Xcode 27+** (for the macOS 27 / iOS 27 SDKs)

The floor is 27 on purpose. This targets the current on-device models, so the
back-compatibility paths that used to report `variant: null` and refuse images on
macOS 26 have been removed rather than carried forward.

> Only devices that support Apple Intelligence can use this server. You must enable Apple Intelligence in System Settings.

---

## Project Structure

```text
apple-intelligence-foundation-server/
├── Core/                           # FoundationCore — the model layer
│   ├── Package.swift               #   no dependencies at all
│   ├── Sources/FoundationCore/
│   │   ├── InferenceService.swift  #   sessions, image prompting, classification
│   │   ├── InferenceError.swift    #   every error this package throws
│   │   ├── InferenceLog.swift      #   JSONL request log
│   │   ├── Models.swift            #   request/response types
│   │   ├── OutputSchema.swift      #   caller-defined JSON shape → GenerationSchema
│   │   ├── KitchenHelper.swift     #   the prompt + schema the app ships and the tests measure
│   │   └── JSONValue.swift         #   arbitrary caller metadata
│   └── Tests/FoundationCoreEvaluations/  # Apple Evaluations framework: measures KitchenHelper
├── Server/                         # FoundationServer — the HTTP interface
│   ├── Package.swift               #   depends on ../Core and Vapor
│   └── Sources/FoundationServer/
│       ├── App.swift               #   routes and startup
│       └── HTTP.swift              #   Content conformances, error mapping
├── App/                            # FoundationApp — the scratchpad UI
│   ├── Package.swift               #   depends on ../Core; no Vapor
│   └── Sources/
│       ├── FoundationAppKit/       #   views and models, builds for macOS + iOS
│       └── FoundationAppMac/       #   runnable macOS shell
├── iOS/
│   ├── FoundationAppiOS.xcodeproj  # iOS app target; links ../App's FoundationAppKit
│   └── FoundationAppiOS/           #   entry point, entitlements (simulator-only), its Info.plist flag
├── macOS/
│   ├── FoundationAppMacOS.xcodeproj # bundled, signed Mac app; same shape as iOS
│   └── FoundationAppMacOS/
├── scripts/
│   ├── ask-image.sh                # Send an image + prompt from the shell
│   └── classify.sh                 # Batch-classify images; tune your label set
├── docs/screenshots/               # the four images in this README
└── README.md
```

### Why two packages

`Core` holds everything that talks to the model and has **no dependencies**, so a
SwiftUI app can link it directly and skip the HTTP hop entirely. `Server` is a
thin translation layer: it decodes JSON, calls `Core`, and maps
`InferenceError` onto status codes.

The split is by *manifest*, not just by directory, and that is the point. SwiftPM
resolves a dependency's entire manifest graph rather than only the products you
consume — a target depending on a Vapor-declaring package checks out Vapor and
its transitive dependencies (measured: 29 packages, 177 MB) even when it links
none of them. Keeping Vapor out of `Core/Package.swift` keeps it out of every
app that links `FoundationCore`.

---

## Installation

1. Clone or navigate to the project directory
2. Resolve the server's dependencies:
   ```bash
   swift package resolve --package-path Server
   ```
   `Core` has no dependencies, so there is nothing to resolve for it.

---

## Usage

### Running the server

```bash
swift run --package-path Server
```

The server will start on:

```text
http://localhost:8080
```

### Running the scratchpad app

A SwiftUI client that talks to the model **in process** — no HTTP, no server
required. It links `FoundationCore` directly, which is the whole reason `Core`
carries no dependencies.

It carries a **Model** menu listing whichever Apple Foundation Models are
available on the machine (changing it starts a new session), a live context
meter, an editable **System prompt**, an **Output** switch between prose and
a JSON object whose fields you define (guided generation — see
[`schema`](#structured-output--schema)), and a restart that
retires the current conversation rather than deleting it — so the run that hit
a wall stays readable, along with the prompt that was steering it. It launches
pre-seeded as a kitchen helper with a four-field schema (`dish`, `servings`,
`ingredients`, `vegetarian`), so the first message you type — "Thanksgiving
dessert for 10, easy to make" — gets a structured answer with a shoppable
ingredient list ("1 can (15 oz) pure pumpkin puree"), and flipping Output to
Text shows the same model answering the same message in prose. That prompt and
schema are defined once, in `KitchenHelper.swift`, and measured by an
[evaluation](#evaluating-the-prompt-with-apples-evaluations-framework) — the
schema wording shipped here is the result of that measurement.

```bash
swift run --package-path App FoundationAppMac
```

The **Photos** tab is the batch version of the Image tab, built for labeling a
folder of your own photos: add many at once, put one circle on each subject
(drag to move it, pinch or the slider to tighten it; the circle's bounding
square is cut from the full-resolution original, and the pane shows the crop's
pixel size so the 384 px floor is visible), and the model classifies the whole
frame and the circle against your closed label set — N samples, per-label
agreement — plus one sentence about each. Apple's Vision framework runs beside
it on both, animals by name and the scene classifier's top labels with their
real confidences, so the two can be compared per photo. Moving a circle re-runs
that photo after a short pause, one photo at a time. "Read text" runs a third pass on a photo:
Vision reads the words off the full-resolution original and the model, given
only those words, names the place (with the country when it can be inferred),
the people, the dates, and the occasion — a signpost says "Zermatt", the model
says Switzerland. Off by default and available per photo, since most photos
have no text and the few that do are the interesting ones. "Send at" is a set of
checkable sizes: one is the normal run, several is a resolution sweep with a
verdict kept per size and a by-size table in the summary. Check the rows you
want and Export writes one folder: `labels.csv` (file, kinds, notes, crop) in
the format the Looking Back photo harness reads, `summary.md` with a row per
photo and the totals to dial a class list against, and `photos.json` with every
vote. The exported kinds are the model's; correct them before treating the file
as truth.

<table>
  <tr>
    <td align="center"><b>Chat</b> — a kitchen helper answering as JSON</td>
    <td align="center"><b>Image</b> — the same question three times, agreement measured</td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/mac-chat.png" width="560" alt="Chat tab on macOS: system prompt, JSON schema editor, and a structured answer listing red salsa ingredients with quantities"></td>
    <td><img src="docs/screenshots/mac-image.png" width="560" alt="Image tab on macOS: a photo of two dogs and a cat, a JSON schema, and results showing a 2-of-3 split between answers"></td>
  </tr>
</table>

The same message on the same phone, on-device model on the left and Private
Cloud Compute on the right. The schema guarantees the shape either way; what
the larger model adds is the detail inside it.

<table>
  <tr>
    <td><img src="docs/screenshots/iphone-chat-on-device.png" width="280" alt="Chat tab on iPhone using the on-device model: pumpkin pie with four loosely specified ingredients"></td>
    <td><img src="docs/screenshots/iphone-chat-private-cloud.png" width="280" alt="Chat tab on iPhone using Private Cloud Compute: pumpkin pie with nine fully specified ingredients"></td>
  </tr>
</table>

#### From Xcode

Open the workspace, not an individual package — it carries all three so you get
one window with every scheme and can jump between the app, the model layer, and
the server:

```bash
open AppleIntelligenceFoundation.xcworkspace
```

Schemes: `FoundationAppMacOS` (the Mac app), `FoundationAppiOS` (iPhone or
iPad simulator), `FoundationAppMac` (the bare SwiftPM Mac binary, on-device
model only), `FoundationServer` (the server), `FoundationCoreEvaluations`
(the prompt evaluation — ⌘U, then the Evaluations tab of the test report; see
[Evaluating the prompt](#evaluating-the-prompt-with-apples-evaluations-framework)),
plus `FoundationCore` and `FoundationAppKit` for building the libraries alone. Pick a scheme and a
matching destination and Run. Breakpoints and the debugger work normally, and
`ContextMeter` carries a `#Preview` covering its states — including the
unmeasurable one — so the meter can be tuned without driving a real session
into each condition.

Xcode resolves the `../Core` and `../App` path dependencies to the copies
already in the workspace, so there is no duplicate-package conflict.

`FoundationAppKit` holds every view and builds for iOS as well as macOS. Each
shell supplies only an entry point:

- `FoundationAppMacOS` and `FoundationAppiOS` are Xcode projects: one file
  each, linking `FoundationAppKit` from `../App`, signed with the team in
  `DEVELOPMENT_TEAM`. The iOS project attaches the
  `com.apple.developer.private-cloud-compute` entitlement **for simulator
  builds only**, so a device build installs with an ordinary profile and
  offers the on-device model alone. iOS needs an Xcode project regardless —
  the simulator and devices run only `.app` bundles.
- `FoundationAppMac` is a plain SwiftPM executable rather than a bundled
  `.app`: `swift run --package-path App FoundationAppMac` with no Xcode
  project involved. A bare binary carries no entitlements, so it reaches the
  on-device model only. It compiles for iOS as an empty stub, so a
  whole-workspace build for an iOS destination succeeds; running that stub
  exits immediately with code 0.

#### Two things a SwiftPM executable needs that a bundled app gets for free

Both are handled in this package, but they explain code that otherwise looks
pointless, and they are worth knowing before building any AppKit binary this way.

**An identity.** With no `Info.plist` there is no `CFBundleIdentifier`, and every
macOS service that looks an app up by bundle ID refuses the connection —
a wall of `NSCocoaErrorDomain Code=4097` at launch, plus
`Cannot index window tabs due to missing main bundle identifier`. `Package.swift`
embeds a plist into the binary's `__TEXT,__info_plist` section with linker flags,
which grants an identifier without making the binary a bundle. Verified both
ways: `Bundle.main.bundleIdentifier` is `nil` without the flag and set with it.

**An activation policy.** This one is worse, because it looks like a crash.
macOS gives an unbundled binary `.prohibited`, meaning it can never be activated
and gets no Dock icon. SwiftUI builds the scene and the window really is on
screen — but it sits behind everything and there is no way to reach it, so the
app appears to start and show nothing. `AppDelegate` claims `.regular`
explicitly. Measured before and after, same binary otherwise:

| | activation policy | frontmost | on-screen windows |
|---|---|---|---|
| Without the delegate | `2` = `.prohibited` | `false` | 1 |
| With the delegate    | `0` = `.regular`    | `true`  | 1 |

The remaining `com.apple.linkd.autoShortcut` messages are App Intents
registration failing for an unbundled process. They are noise; nothing in this
package uses App Intents, and the model is unaffected. A real Xcode app target
retires all of it.

---

## API Overview

All responses are JSON. Errors are also returned as JSON with a consistent shape:

```json
{
  "error": "Human-readable error message"
}
```

### Endpoint summary

| Method | Path                     | Description                                       |
|--------|--------------------------|---------------------------------------------------|
| POST   | `/inference`             | Run text (or text + image) generation             |
| POST   | `/sample`                | Run one free-form prompt N times and group the answers |
| POST   | `/classify`              | Closed-set image classification against your own labels |
| POST   | `/sessions`              | Create a conversation session, optionally with instructions |
| DELETE | `/sessions/{session_id}` | Delete a conversation session                     |
| GET    | `/sessions/{session_id}/context` | How much of the context window that session has spent |
| POST   | `/tokens`                | What a prompt would cost, without spending it     |
| GET    | `/status`                | Report the backing model, context size, and capabilities |
| GET    | `/health`                | Basic liveness/health check                       |

---

## API Endpoints

### POST `/inference`

Send a prompt and receive a generated response from Apple Intelligence.

**Request:**

```bash
curl -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is Swift programming?"}'
```

**Request body:**

```json
{
  "prompt": "Your prompt text here",
  "session_id": "optional-session-uuid",
  "new_session": false,
  "reset": false,
  "images": [
    { "data": "<base64-encoded image bytes>", "label": "optional name" }
  ],
  "instructions": "optional system prompt, new sessions and one-shots only",
  "model": "on_device | private_cloud — default on_device, fixed per session",
  "schema": {
    "fields": [
      { "name": "likes", "type": "string[]", "description": "things the user says they like" }
    ]
  }
}
```

Only `prompt` is required.

**Successful response:**

```json
{
  "response": "Generated text from Apple Intelligence...",
  "session_id": "the-session-this-ran-in"
}
```

`session_id` is omitted entirely for a one-shot request that was not persisted.

If the model is not available, you will receive an error response describing the issue.

#### Choosing a session

| `session_id` | `new_session` | `reset` | Behavior |
|---|---|---|---|
| —   | —      | —      | One-shot. A throwaway session is used and discarded; nothing is stored. |
| —   | `true` | —      | Creates a fresh persisted session, answers in it, and returns its id. |
| set | —      | —      | Continues that session. `404` if it does not exist. |
| set | —      | `true` | Clears that session's transcript, then answers. The id stays the same. |
| set | `true` | —      | `400` — conflicting. Use `reset` to clear an existing session. |
| —   | —      | `true` | `400` — `reset` needs a `session_id`. Use `new_session` to start fresh. |

`new_session` saves a round trip: it replaces `POST /sessions` followed by
`POST /inference`, and hands back the id in the same response.

#### Instructions — the system prompt

`instructions` is a separate channel from the prompt. It is set once, applies to
every turn in the session, and is charged to the context budget once rather than
being resent with each prompt.

```bash
# Create a session with instructions
curl -X POST http://localhost:8080/sessions \
  -H "Content-Type: application/json" \
  -d '{"instructions":"You always answer with exactly one word, in French."}'
# {"session_id":"F48D7BD9-…","instructions":"You always answer with exactly one word, in French."}

curl -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What color is the sky?","session_id":"F48D7BD9-…"}'
# {"response":"Bleu","session_id":"F48D7BD9-…"}
```

Or in one call, with `new_session` or as a one-shot:

```bash
curl -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What color is the sky?","instructions":"Answer with exactly one word in German."}'
# {"response":"Blau"}
```

Two rules follow from `LanguageModelSession` fixing its instructions when it is
constructed:

- **Instructions cannot be changed on an existing session.** Sending them with a
  `session_id` returns `400` rather than being silently ignored. Start a new
  session instead.
- **They survive `reset`.** A reset clears the transcript and frees the context
  it consumed, but the session keeps its configuration and keeps steering.

Whether a given piece of framing works better as instructions or inside the
prompt is not obvious and is worth measuring — see
[Phrasing Changes the Answer](#phrasing-changes-the-answer--test-before-you-trust).

#### Choosing a model — `model`

Two Apple Foundation Models are reachable: `on_device` (the default) and
`private_cloud`, the larger model on Apple's Private Cloud Compute. Nothing
falls back from one to the other; every request runs on the model it named,
or fails.

```bash
curl -s -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Summarize the plot of Hamlet in two sentences.","model":"private_cloud"}'
```

`model` follows the same rule as `instructions`: it is fixed when a session is
created. Pass it with `new_session`, on a one-shot, or to `POST /sessions`; a
different value sent with an existing `session_id` is `400`, not a silent
switch. `GET /status?model=private_cloud` reports the cloud model's window
and capabilities, and `/sessions/{id}/context` on a cloud session reports the
window with `used: null` — the cloud model has no token counter.

What the cloud model reports on this machine, next to the on-device one:

| | `on_device` | `private_cloud` |
|---|---|---|
| `context_size` | 8192 | 32768 |
| `supports_vision` | true | true |
| `supports_guided_generation` | true | true |
| `supports_reasoning` | false | true |

Two things are different about the cloud model in practice. It has a usage
quota — exhausting it is `429` with the framework's message naming the reset
window. And it requires the **`com.apple.developer.private-cloud-compute`
entitlement**. Without it, `availability` still reports `available` — it
describes the service, not the caller — and then: a bare binary such as this
server gets `LanguageModelError -1` wrapping `ModelManagerError 1046` on
every request, and a signed app **traps** inside the framework with
`Fatal error: Missing entitlement: com.apple.developer.private-cloud-compute`.
It is not a thrown error the app can catch.

The entitlement is a managed capability: Apple assigns it to a developer
account on request, at <https://developer.apple.com/contact/request/private-cloud-compute/>,
for accounts enrolled in the App Store Small Business Program with fewer than
two million first-time downloads. Until it is assigned, it does not appear on
any App ID and no profile can carry it. Where that leaves each target, measured
on macOS 27.0 / Xcode 27.0:

- **iOS simulator: works.** `iOS/FoundationAppiOS/FoundationAppiOS.entitlements`
  carries the key, the simulator embeds it without consulting the developer
  portal, and the cloud model answers. A convenience for testing, not a sign
  the account is eligible.
- **iOS devices: on-device model only, and it installs.** The project attaches
  the entitlements file under a build condition, `[sdk=iphonesimulator*]`, so
  a device build carries no entitlement and signs with an ordinary profile.
  The same condition sets an `Info.plist` key, `FoundationPrivateCloudCompute`,
  which is how the app knows at runtime which flavor it is. Once the account
  has the entitlement, dropping the condition is the whole change.
- **Mac: wait on the account.** Automatic signing reports *"Entitlement
  com.apple.developer.private-cloud-compute not found and could not be
  included in profile"*, and an entitlement that cannot go in the profile
  fails the build. So `macOS/FoundationAppMacOS/FoundationAppMacOS.entitlements`
  carries the key only as a comment, to be restored once the entitlement is
  assigned to the account.

Because a signed app that asks without the entitlement traps, the process
checks its own code signature before offering the cloud model: on macOS
`ProcessEntitlements` reads the entitlement with `SecTaskCopyValueForEntitlement`,
and without it `/status?model=private_cloud` reports `available: false` with a
message naming the entitlement, a `private_cloud` request is `503`, and the
app's model menu never lists it. That covers the SwiftPM executables too — this
server and `FoundationAppMac` are plain binaries with no entitlements. iOS has
no public API for the check, so there the app reads the `Info.plist` key the
project sets under the same condition as the entitlement: present on the
simulator, absent on a device. The on-device model needs no entitlement.

#### Structured output — `schema`

`schema` makes the response a JSON object with exactly the fields you list,
produced by guided generation: the framework builds the structure and the model
supplies only the values. It never emits a brace or a quote.

```bash
curl -s -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "The user likes eggs, but only scrambled, and cannot stand cilantro.",
    "instructions": "You extract what the user likes and dislikes.",
    "schema": {"fields": [
      {"name": "likes",    "type": "string[]", "description": "things the user says they like"},
      {"name": "dislikes", "type": "string[]", "description": "things the user explicitly says they do not like"}
    ]}
  }'
# {"response":"{\"likes\":[\"scrambled eggs\"],\"dislikes\":[\"cilantro\"]}"}
```

Each field has a `name`, a `type`, and an optional `description`. A type is
`string`, `number`, `integer`, or `bool`, followed by any number of array
suffixes: `[]` for a list, `[N]` for a list of exactly N. Suffixes nest
innermost-first, so `integer[4][]` is a list of four-integer lists — the
shape of bounding boxes:

```json
{"name": "boxes", "type": "integer[4][]",
 "description": "one box per animal as x, y, width, height in pixels of the sent image"}
```

The framework enforces the structure, including the exact count. It does
not make the model good at localisation: the on-device model describes what
it sees and will fill a box schema with plausible-looking numbers, so treat
coordinates from it as a hypothesis to check, not a detection. The
description is the model's guide for that field: it is the one place the
field's meaning is explained, so a rule such as "only if the user explicitly
says so" belongs there as much as in `instructions`.

`schema` is per request, not per session. The same session can answer in
prose on one turn and structured on the next. `response` is still a string;
parse it as JSON.

Use this rather than asking for JSON in the prompt. Prompted JSON is assembled
token by token, and this model sometimes puts a reserved control token where a
quote belongs — it decodes as the literal text `<ctrl46>`, in otherwise
correct output, intermittently. A schema removes the quote from the model's
job entirely.

Requests sharing a session must be **sequential**. A second request that arrives
while the first is still generating gets `409 Conflict`, because the underlying
`LanguageModelSession` rejects overlapping `respond` calls. Wait for a response
before sending the next one on that id, or use separate sessions — different
sessions run in parallel, and one-shot requests never conflict.

`reset` is the one to reach for when a session approaches the context limit.
It swaps in an empty session under the same id, so clients holding that id keep
working while the accumulated transcript — and the context budget it was
consuming — is released. This matters most for image sessions, since each image
occupies a meaningful share of the window.

```bash
# Start a session and get its id in one call
curl -s -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt": "My secret word is BANANA. Just say OK.", "new_session": true}'
# {"response":"OK.","session_id":"A7089C54-..."}

# It remembers
curl -s -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is my secret word?", "session_id": "A7089C54-..."}'
# {"response":"BANANA.","session_id":"A7089C54-..."}

# Clear it without changing the id
curl -s -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is my secret word?", "session_id": "A7089C54-...", "reset": true}'
# {"response":"I DO NOT KNOW.","session_id":"A7089C54-..."}
```

#### Image input

The on-device model accepts images. Attach one or more via the `images` array;
check `supports_vision` on `/status` first.

Each entry's `data` is base64-encoded bytes in any format ImageIO reads (PNG,
JPEG, HEIC, …). A full `data:image/png;base64,...` URL is also accepted, so
payloads produced by a browser's `canvas.toDataURL()` work unmodified.

The optional `label` names the image so a prompt can refer to a specific one
when several are sent together; it defaults to `image 1`, `image 2`, and so on.

The easiest way is the bundled helper, which handles downscaling and body
streaming for you:

```bash
./scripts/ask-image.sh photo.jpg "What subjects are in this photo?"
```

To call the endpoint directly, **stream the body into curl rather than passing
it as an argument**:

```bash
{
  printf '{"prompt":"Describe this image in one sentence.","images":[{"data":"'
  base64 -i photo.jpg | tr -d '\n'
  printf '"}]}'
} | curl -s -X POST http://localhost:8080/inference \
      -H "Content-Type: application/json" --data-binary @-
```

> **Do not** build the request as `-d "{...$IMG...}"`. `ARG_MAX` is 1 MB on macOS
> and base64 inflates by 4/3, so any image over roughly 750 KB fails with
> `zsh: argument list too long: curl` before the request is ever sent. Piping to
> `--data-binary @-` — or writing the JSON to a file and using `-d @body.json` —
> keeps the payload off the command line entirely.

#### `scripts/ask-image.sh`

```bash
./scripts/ask-image.sh <image-file> [prompt]
```

Downscales the image, builds the JSON, streams it to `/inference`, and prints
the response. Reads anything ImageIO handles, including HEIC.

| Variable | Default | Purpose |
|---|---|---|
| `MAX_DIM` | `1024` | Longest edge after downscaling. `0` sends the file as-is. |
| `SERVER`  | `http://localhost:8080` | Server base URL. |
| `SESSION` | — | Continue an existing session instead of a one-shot. |

```bash
./scripts/ask-image.sh photo.jpg "What subjects are in this photo?"
SESSION=$SID ./scripts/ask-image.sh photo.jpg "Describe this."
MAX_DIM=2048 ./scripts/ask-image.sh photo.jpg "Read the small text."
```

Downscaling is on by default because the model resamples to a fixed resolution
internally — full-resolution uploads cost time and can exceed the 32 MB body cap
without improving the answer.

Images become part of the session transcript, so when you pass a `session_id` a
later text-only turn can still refer back to an image from an earlier turn.

Requests carrying images are much larger than text, so the server accepts bodies
up to **32 MB**. Base64 inflates the payload by roughly 4/3 over the raw bytes.

Sending `images` to a model variant that reports no vision capability returns
`400` rather than silently dropping them.

---

### POST `/sample`

Asks the same question several times and groups identical answers. Where
`/classify` constrains the model to a vocabulary, this leaves the output free —
it is for finding out what the model actually says, and how much it wavers.

```bash
curl -X POST http://localhost:8080/sample \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What animals are in this image?","samples":5,
       "instructions":"Answer with a comma-separated list of animal names only.",
       "images":[{"data":"<base64>"}]}'
```

`model` (`on_device` or `private_cloud`) picks which model is sampled; every
sample runs on that one.

`schema` — the same object as on [`/inference`](#structured-output--schema) —
makes every sample a JSON object with those fields, and agreement then
compares whole objects: it measures whether the model is consistent about the
*values*, not the wording. Exclusive with `choices`. Structured responses —
here and on `/inference` — come back with their keys sorted, so two objects
with the same values are the same string regardless of the order the model
produced the fields in. The order of items inside a list is the model's and
is not normalized: the same things listed in a different order are different
answers.

```bash
curl -X POST http://localhost:8080/sample \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What is in this image?","samples":5,
       "schema":{"fields":[{"name":"subjects","type":"string[]","description":"every distinct thing visible"}]},
       "images":[{"data":"<base64>"}]}'
```

```json
{
  "answers": [
    {"text": "dog, dog, bird", "count": 3, "agreement": 0.6},
    {"text": "dog, bird",      "count": 2, "agreement": 0.4}
  ],
  "responses": ["dog, dog, bird", "dog, bird", "dog, dog, bird", "dog, dog, bird", "dog, bird"],
  "sample_count": 5,
  "duration_ms": 2203
}
```

| Field | Required | Meaning |
|---|---|---|
| `prompt` | yes | The question. Must not be empty. |
| `images` | no | Same shape as `/inference`. Text-only prompts are fine. |
| `instructions` | no | The system prompt, applied to every sample. |
| `samples` | no | 1–9, default 3. Each runs in its own session so votes stay uncorrelated. |
| `choices` | no | 2–64 options. Constrains the answer to a closed set, which is what makes agreement mean anything — see below. |
| `metadata` | no | Recorded in the log, never sent to the model. |

Answers are grouped by a deliberately shallow normalization — casing, surrounding
whitespace and trailing punctuation only, so `"Bleu"`, `"bleu."` and `" Bleu "`
count as one. Anything fuzzier would hide real disagreement behind a similarity
threshold nobody can audit. `responses` always carries the raw, ungrouped output
so you can check what the grouping did.

**Use `choices` for anything you intend to measure.** Over free prose, agreement
counts wordings, not meanings. The same question on the same frame:

```text
"Are there any animals?"  free text, 6 samples
  0.17  Yes, there are animals in the image.
  0.17  Yes, there are three animals in the image.
  0.17  Yes, there are animals in the image. There are four dogs visible.
  0.17  Yes, there are animals in the image. There are three dogs and one cat.
  0.17  Yes, there are animals in the image. There are three dogs and one bird.
  0.17  Yes, there are animals in the image. There are four animals, which appear to be dogs.

"Are there any animals?"  choices: yes, no
  1.00  (6/6) yes
```

Six answers that all say *yes* look like total disagreement, because they are six
distinct strings. Nothing was wrong with the model; the measurement was wrong.

**Full agreement is still not correctness.** With `choices: deer, turkey, dog,
bird, none` on a frame containing three turkeys, the model answers `dog` 6/6 —
unanimous, confident, and wrong, with the right answer sitting in the list.

---

### POST `/classify`

Classifies an image against a label set **you** supply. The model is constrained
to that vocabulary by a schema built at request time — it cannot answer with
anything outside your list, so results aggregate cleanly.

```bash
curl -s -X POST http://localhost:8080/classify \
  -H "Content-Type: application/json" \
  -d '{
    "classes": ["deer","turkey","person","dog","cat","bird","insect","vehicle","none"],
    "images": [{"data": "<base64>"}],
    "hint": "Night-vision frame from a driveway camera",
    "samples": 3,
    "metadata": {"camera": "driveway", "reolink_class": "person"}
  }'
```

```json
{
  "subjects": [
    {"label": "person", "votes": 3, "agreement": 1.0},
    {"label": "dog",    "votes": 3, "agreement": 1.0}
  ],
  "sample_count": 3,
  "samples": [["person","dog"], ["person","dog"], ["person","dog"]],
  "duration_ms": 2182
}
```

**Classification is multi-label.** A frame showing a car pulling up while someone
walks past returns both `vehicle` and `person` — real scenes usually contain more
than one thing, and forcing a single answer silently discards the rest. Each
label carries its own `agreement`, so you can act on one while ignoring another
the model was unsure about.

| Field | Required | Meaning |
|---|---|---|
| `classes` | yes | 2–64 unique, non-empty labels. The model can only answer from this list. |
| `images` | yes | At least one, same format as `/inference`. |
| `hint` | no | Extra framing appended to the instruction. |
| `samples` | no | 1–9 (default 1). Classify N times and report per-label agreement. |
| `max_labels` | no | 1–10 (default 5). Most labels one sample may return. Set `1` to force a single best label. |
| `metadata` | no | Logged verbatim, never sent to the model. |

`agreement` is per label: the fraction of samples that included it. Threshold on
the label you care about rather than on the result as a whole:

```bash
# act only when "deer" is present and consistently seen
jq 'select(any(.subjects[]; .label=="deer" and .agreement >= 0.67))'
```

#### What this model can and cannot do

Measured on real camera photos, 5 samples each.

**It is reliable at coarse categories.** `["person","animal","vehicle","none"]`
was correct on every image tested:

| Image | Result |
|---|---|
| White pickup truck + 3 turkeys | `animal 1.0, vehicle 1.0` |
| Person + dog | `person 1.0, animal 1.0` |
| Abstract pattern, nothing present | `none 1.0` |

**It is not reliable at species.** Asked to choose among
`deer/turkey/person/dog/cat/bird/insect/vehicle`, the same turkey photo returned
`dog 1.0, bird 1.0, vehicle 1.0`. Removing `bird` from the list did not make it
say `turkey` — it answered `dog, vehicle`. Asked directly "is there a turkey in
this image", it said NO 0/5. The free-form description explains why:

> "Four black dogs and three trash cans in a driveway with a white pickup truck."

It sees dark turkeys as black dogs.

**But that is a resolution limit, not a knowledge limit — and cropping fixes it.**
Every result above sends the whole frame, downscaled to 1024px on the longest
edge. A turkey in a 3840×2160 driveway shot occupies roughly 40×40 pixels once
downscaled. Cut the same bird out of the *original* and send it alone:

| Sent | Question | Answer |
|---|---|---|
| Whole frame, 1024×576 | "What kind of animal is in this image?" `turkey/dog/deer/bird/cat/none` | `dog` **6/6** |
| Crop 384×281 of the original | identical question, identical choices | `turkey` **6/6** |

Same model, same prompt, same closed answer set, same photo. Both unanimous.
The only variable was how many pixels the bird occupied.

So the earlier conclusion — *no prompt or schema change fixes that* — was right
about prompts and wrong about the cause. The model knows what a turkey is. It
was never shown one.

**Sending a bigger frame does not help. Only cropping does.** The obvious
alternative — skip the crop, just upload more pixels — was measured and fails,
5 samples per row:

| Whole frame sent at | Answer |
|---|---|
| 1024×576 | `dog` 5/5 |
| 1536×864 | `bird` 4/5, `dog` 1/5 |
| 2048×1152 | `dog` 5/5 |
| 3840×2160 (untouched original) | `dog` 5/5 |

Four times the resolution, same wrong answer. What matters is how much of the
*sent frame* the subject occupies, not how many pixels the file contains.

**There is a floor, and it is a gradient rather than a cliff.** Holding the crop
fixed on one bird and varying only the resolution it is sent at, 5 samples per
row:

| Crop sent at | Answer |
|---|---|
| 384×281 | `turkey` 4/5, `bird` 1/5 |
| 256×187 | `bird` 3/5, `turkey` 2/5 |
| 128×94 | `bird` 5/5 |
| 64×47 | `bird` 5/5 |

Species identification fades in between roughly 256 and 384 px rather than
switching on. A first pass of this measurement, one run per size, looked like a
clean break at 384 — running it as a sweep showed `turkey` already appearing 2/5
at 256. Single runs make gradients look like cliffs.

The failure is graceful: it degrades through `bird`, still a useful answer for a
false-positive filter, before bottoming out. `dog` only appears when the subject
is a small part of a wide frame.

**Phrasing still matters after the resolution is fixed.** Same crop, same 384 px,
same closed answer set — only the wording changing:

| Prompt | Answer |
|---|---|
| "Identify the bird in this photo." | `turkey` 5/5 |
| "This is a driveway camera frame. What animal is it?" | `turkey` 5/5 |
| "What kind of animal is in this image?" | `turkey` 4/5 |
| "What species is this?" | `turkey` 3/5 |

Resolution decides whether the answer is *reachable*; phrasing decides how
reliably you reach it. Note that the prompt naming the wrong species — "identify
the **bird**" — scored best. Priming the model toward the general category
appears to help rather than trap it, which is not what you would guess.

**What this means in practice:** do not ask about a whole camera frame, and do
not bother uploading it at full resolution. Crop to the region of interest, cut
from the highest-resolution copy you have, and send the crop at **384 px or
larger** on its longest edge. If your camera already reports a motion box, feed
that box in as the crop — it costs nothing and is the difference between `dog`
and `turkey`.

One caveat on all of the above: these are 5-sample measurements, and the
`bird 4/5` at 1536 px breaks the pattern in row two. Re-measure on your own
frames rather than treating these numbers as constants.

The app's Image tab does exactly this: drag a selection, and the crop is cut from
the full-resolution original rather than the displayed copy.

**`dog` came back at `agreement 1.0` and was wrong** — twelve consecutive samples
agreed on an animal that was not there. This is the caveat above made concrete:
agreement measures consistency, not correctness.

**Presence questions are far more robust than identity questions.** "Is a person
present" — the thing false-positive filtering actually needs — was perfect:

| Image | Person detected |
|---|---|
| Truck + turkeys (no person) | 0/5 ✓ |
| Person + dog | 5/5 ✓ |

**How you ask matters as much as what you ask.** The same question about the same
image can go from 0% to 100% accurate depending on wording, output format, and
whether labels compete. See
[Phrasing Changes the Answer](#phrasing-changes-the-answer--test-before-you-trust)
before settling on a label set or a hint.

**Set `max_labels: 1` for binary questions.** With `["person","none"]` and the
default `max_labels: 5`, a person photo returned `person 1.0, none 1.0` — the
model padded the array with a contradictory label. `max_labels: 1` returned a
clean `person 1.0`, and `none 1.0` on the image with no person.

**Always include a `"none"` or `"other"` label.** A constrained schema forces a
choice, so without an escape hatch an unlisted subject is reported as whichever
listed label fits worst. The difference is stark on the same image:

| `classes` | `samples` | `agreement` |
|---|---|---|
| `["deer","turkey"]` | `turkey, deer, deer` | `0.67` — forced into a wrong answer |
| `["deer","turkey","none"]` | `none, none, none` | `1.0` |

#### `scripts/classify.sh`

Classifies a single image or an entire directory. Built for tuning your label set
against saved frames before wiring anything up to it.

```bash
./scripts/classify.sh ./frames/
CLASSES=person,animal,vehicle,none SAMPLES=3 ./scripts/classify.sh ./frames/
```

```text
classes: person,animal,vehicle,none
samples: 3   images: 6

FILE                           SUBJECTS (label agreement)                   MS
----                           --------------------------                   --
backyard-03.jpg                none 1.00                                   761
driveway-01.jpg                none 1.00                                   742
IMG_4740.jpeg                  person 1.00, dog 1.00                       550
junk-05.jpg                    <not an image>                                -
shape-02.png                   none 1.00                                   744
side-04.heic                   none 1.00                                   746

5 classified — none: 4, person: 1, dog: 1
all unanimous
mean latency: 708ms
```

| Variable | Default | Purpose |
|---|---|---|
| `CLASSES` | `person,animal,vehicle,none` | Comma-separated label set. Coarse categories by default; see the accuracy notes above. |
| `SAMPLES` | `3` | Classifications per image, 1–9. |
| `MAX_LABELS` | `5` | Most labels per sample, 1–10. |
| `MAX_DIM` | `1024` | Longest edge after downscaling; `0` sends as-is. |
| `SERVER`  | `http://localhost:8080` | Server base URL. |
| `CAMERA`  | — | Recorded as `metadata.camera` in the server log. |
| `JSONL`   | — | Also append each raw response to this file. |

The summary calls out anything below full agreement, which is how you find a
vocabulary that needs work. Dropping `none` from the list above turns a clean run
into this:

```text
backyard-03.jpg                deer 0.67                                  1737
driveway-01.jpg                turkey 1.00                                1392
shape-02.png                   turkey 0.67                                1390

3 label(s) below full agreement (vocabulary may need work):
  deer 0.67    samples=[['deer'], ['deer'], ['turkey']]
  turkey 0.67  samples=[['turkey'], ['turkey'], ['deer']]
```

Note `driveway-01.jpg` there: **`turkey` at 1.00 agreement, and completely
wrong** — three samples agreeing on the same bad answer, because the label set
gave the model no way to be right. Low agreement is a useful warning; high
agreement is not a guarantee. See
[Agreement catches uncertainty, not error](#agreement-catches-uncertainty-not-error).

`samples: 3` costs roughly 3× the latency (~1.8s vs ~0.7s here).

---

### GET `/sessions/{session_id}/context`

How much of the context window a session has consumed.

```bash
curl http://localhost:8080/sessions/$SID/context
```

```json
{ "used": 200, "limit": 8192, "remaining": 7992, "fraction": 0.0244, "note": null }
```

`used` is measured over the session's real transcript, not estimated from message
counts, so it stays correct as instructions and tool definitions are added.

**`used` can be `null`.** The model refuses to count any transcript containing an
image, and there is no way to ask it to try harder:

```json
{
  "used": null, "limit": 8192, "remaining": null, "fraction": null,
  "note": "Token counting unavailable for this session (… ModelManagerError error 1001 …)"
}
```

Inference on that session keeps working normally — only the count is lost. A UI
showing a context meter needs a fallback (turn count, image count) for any
conversation that has seen a picture.

---

### POST `/tokens`

What a prompt would cost before you spend it.

```bash
curl -X POST http://localhost:8080/tokens \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Describe this image in detail please."}'
# {"tokens":8,"context_size":8192}
```

Text only. Images are rejected with `400` rather than an opaque failure, for the
same reason as above: the framework cannot count an attachment.

---

### GET `/status`

Reports which model is actually serving requests — useful for confirming an OS
upgrade swapped in a newer on-device model. `?model=private_cloud` describes
the cloud model instead.

```bash
curl http://localhost:8080/status
curl "http://localhost:8080/status?model=private_cloud"
```

```json
{
  "model": "on_device",
  "available": true,
  "message": "Model is available",
  "variant": "AFM 3 Core Advanced",
  "context_size": 8192,
  "supports_vision": true,
  "supports_guided_generation": true,
  "supports_reasoning": false
}
```

`variant` is the display name of the on-device model variant. The cloud
model does not name one; it reports `"Private Cloud Compute"`.

`context_size` is read from the model rather than hardcoded — 8192 on current
hardware. Read it from the endpoint instead of assuming it.

---

### GET `/health`

Health check endpoint to verify the server is running.

**Request:**

```bash
curl http://localhost:8080/health
```

**Response:**

```json
{
  "status": "ok"
}
```

---

## Phrasing Changes the Answer — Test Before You Trust

The on-device model is unusually sensitive to *how* a question is asked. This is
not a matter of style. Every result below comes from real photos run on this
hardware, with known ground truth, and shows the answer swinging between fully
correct and fully wrong while the image and the underlying question stay fixed.

If you take one thing from this README: **a prompt that reads sensibly is not
evidence that it works.** Measure it against frames you have labeled yourself.

### Same fact, different wording

A white pickup truck, plainly visible in the frame. Five samples each:

| Question | Detected |
|---|---|
| "Is there a car or truck in this image?" | **0/5** |
| "Is there a vehicle in this image?" | 3/5 |
| "Is a motor vehicle visible in this image?" | **5/5** |

Three phrasings of one question, spanning the entire range from never to always.
"Car or truck" is arguably the most natural way to ask, and it was the worst.

### Same question, same words, different output format

A photo with a truck and three turkeys, and **no person in it**. Asked "is there
a person visible in this image?" eight times per row:

| How the answer was requested | Said YES |
|---|---|
| Constrained to a `Bool` schema, asked alone | **8/8** ✗ |
| Free text, "answer only YES or NO", asked alone | **0/8** ✓ |
| Competing against other labels via `/classify` | **0/8** ✓ |

Identical question, identical image. Requesting the answer as a typed boolean
inverted it completely. No explanation is offered here because none was
established — the point is that the failure was invisible until measured.

### Asking in isolation vs. letting labels compete

Same truck-and-turkeys photo, `["person","animal","vehicle","none"]`:

| Approach | Result | Calls |
|---|---|---|
| All labels in one schema (`/classify`) | `animal 3/3, vehicle 3/3` ✓ | 3 |
| One label per request, asked individually | `animal 3/3, vehicle 3/3, `**`person 3/3`** ✗ | 9 |

Asking about each label on its own produced a confident false person alert at
three times the cost. When labels share a schema, `person` has to win against
`animal` and `vehicle`; asked alone it has nothing to lose to.

**Practical consequence:** include `animal` and `vehicle` in `classes` even if you
only care about `person`. They are not decoration — they are what `person` has to
beat. A bare `["person","none"]` is the configuration most likely to produce
false positives.

### Instructing the model to be careful made it worse

Same photo, asking for a label list:

| Instruction | Result |
|---|---|
| "List every distinct subject visible in this image." | `dog, bird, vehicle` |
| "List only what you can clearly and certainly see. Do not guess. Prefer the most specific label." | `dog, dog, bird, vehicle` |

The stricter, more careful-sounding instruction produced a duplicate and no gain
in accuracy. Prompt text that reads like it should help is not evidence it does.

### The model's own confidence is not a signal

Asked for a 0–100 confidence alongside its answer, on one fixed image, six
identical calls:

```
verdict:    correct all six times
confidence: 100, 0, 100, 100, 0, 100
```

It could not hold a consistent meaning for the number — 0 reading as "not
confident it is a deer" and 100 as "confident in my answer", flipping between
them. This is why `/classify` reports `agreement` across independent samples
instead of asking the model how sure it is.

### Agreement catches uncertainty, not error

`agreement` is real, but it measures **consistency, not correctness**. On the
turkey photo the model reported `dog` at `agreement 1.00` across twelve
consecutive samples. It was simply wrong, twelve times, in complete agreement
with itself.

Use low agreement as a signal that something needs attention. Never read high
agreement as confirmation that an answer is right.

### Don't use the model to judge its own output

The obvious fix for prose answers is to ask the model whether two answers mean
the same thing, and group by that. It does not hold up. Four comparisons, six
samples each, using `choices: same, different`:

| Answers being compared | Question asked | Correct | Model said |
|---|---|---|---|
| "there are animals" vs "there are two dogs" | Are there any animals? | same | `same` 6/6 |
| "there are two dogs" vs "there are three dogs" | Are there any animals? | same | **`different` 6/6** |
| "there are animals" vs "there are no animals" | Are there any animals? | different | `different` 6/6 |
| "there are two dogs" vs "there are five dogs" | How many animals? | different | `different` 6/6 |

It handles the easy cases and fails the one a judge would exist for: same answer
to the question actually asked, different wording. It fixated on `two` vs
`three` and ignored the question. And it failed **unanimously**, so sampling the
judge would not have caught it — the error is systematic, not noisy.

Four comparisons is not a study, but the failing case is the motivating case. A
judge built on this model imports exactly the unreliability you are trying to
measure, and hides it behind a number that looks rigorous. A closed answer set
costs nothing, is deterministic, and is auditable.

The [evaluation target](#evaluating-the-prompt-with-apples-evaluations-framework)
uses a model judge anyway — as a source of rationales to read, never as a
number to gate on.

---

### How to actually test a change

1. **Save 20–50 real frames** from your cameras, covering the cases you care
   about — day, night, empty scenes, the ambiguous ones.
2. **Label them yourself.** This is the only ground truth that exists. Without
   it, nothing below means anything.
3. Put them in a directory and run the batch tool, capturing raw results:
   ```bash
   JSONL=./run-a.jsonl CLASSES=person,animal,vehicle,none \
     ./scripts/classify.sh ./frames/
   ```
4. **Compare against your labels.** Count false positives and false negatives per
   label — not overall accuracy, which hides the failure you care about.
5. **Change exactly one thing** — a label, a hint, `samples`, `max_labels` — and
   rerun into `run-b.jsonl`. One variable at a time, or you will not know which
   change moved the number.
6. **Keep `LOG_FILE` set in production.** Live frames will find failures your test
   set does not, and the log is the only way you will see them.

That is the shell version of the loop. For a feature written in Swift, Apple's
Evaluations framework does steps 3–5 as a test target — next section.

---

## Evaluating the Prompt with Apple's Evaluations Framework

Apple's [Evaluations framework](https://developer.apple.com/documentation/evaluations)
(WWDC26, in the 27 SDKs) turns "does this prompt still work" into a test. An
`Evaluation` is a dataset of samples, a `subject(from:)` that runs the feature
on one sample, a list of evaluators that each return a `Metric` (pass, fail, or
a score, with a rationale), and an `aggregateMetrics` step that computes
statistics over the whole dataset. A Swift Testing `@Test(.evaluates(…))`
then asserts on the aggregates, so a prompt change that makes the feature
worse fails the build.

`Core/Tests/FoundationCoreEvaluations` does this for the kitchen helper the
scratchpad ships with. The scratchpad is still where a prompt gets *found*;
this is where it gets *kept*.

```bash
swift test --package-path Core                                  # ~50 s on Apple silicon; one run in seven took four minutes
KITCHEN_RESULTS=./eval-results swift test --package-path Core   # also write per-sample JSON
```

In Xcode, pick the `FoundationCoreEvaluations` scheme, ⌘U, then open the test
report and its **Evaluations** tab: one row per sample with the prompt, the
answer, every metric, and every rationale. The JSON file written by
`KITCHEN_RESULTS` carries the same rows (with transcripts), so two runs can be
diffed outside Xcode.

### What it measures

Twelve asks, written by hand and varied in occasion, size, diet, and how the
serving count is phrased ("for 10", "for two", "my wife and me"). Each runs in a
fresh session with the shipped system prompt and schema. Per sample:

| Metric | Kind | Checks |
|---|---|---|
| `Servings` | pass/fail | `servings` equals the number asked for |
| `VegetarianFlag` | pass/fail | `vegetarian` equals the expected flag |
| `FlagMatchesList` | pass/fail | `vegetarian` agrees with the ingredient list — no expectation needed, both come from the same answer |
| `NamedIngredients` | pass/fail | words the ask implies ("avocado" for guacamole) appear in the list |
| `ListLength` | pass/fail | 3–20 ingredients — fewer is not worked out, more is not a shopping list |
| `Quantified` | score 0–1 | fraction of ingredients carrying a digit or a measure word |
| `Shoppable`, `FitsTheAsk` | model judge, 1–4 | rubric scored by a language model, with a written rationale |

### What it found

The first two runs scored `Quantified` at 0.74 and 0.71 and `ListLength` at
0.58 and 0.64, and the per-sample view showed why. Asked for a vegan lunch, the model answered
`ingredients: ["quinoa", "2 cups", "dried"]` — it read the field's description,
*one item each, with quantity and form*, as one **fact** per item. Other asks
came back with a single ingredient ("pumpkin puree – 2 cups, canned" for a
whole pie). Nothing in the chat window had made either pattern obvious; a
dozen answers side by side did.

The system prompt was never touched. Two changes to the description of the
`ingredients` field, measured one at a time:

| `ingredients` description | Quantified | ListLength | Shoppable (judge) |
|---|---|---|---|
| one item each, with quantity and form | 0.71 | 0.64 | 3.1 |
| one ingredient per item, written as quantity, form, and name together, e.g. "2 cups canned pumpkin puree" | 0.98 | 0.67 | 4.0 |
| every ingredient the dish needs, one per item, written as … (shipped) | 0.94–1.0 | 0.75–1.0 | 3.7–4.0 |

The last row is the spread over four runs of the same text: the model is not
deterministic, and the metric it moves most between runs is how many
ingredients it bothers to list. One run in seven also failed a sample outright
with *transcript exceeded the model's context size* — on a fresh session and a
seven-word prompt. The only thing in that transcript that can grow is the
unbounded `string[]`, so this is the model failing to stop a list; it is rare,
and the report records it as an inference error rather than hiding it in the
averages.

### Decision points

Each of these is a choice the framework leaves to you. What this project chose,
and what the alternative would have bought:

1. **Where the evaluation lives.** A test target in `Core`, so `swift test`
   runs it with no Xcode project and no Vapor, and the same target appears in
   the workspace with the Xcode report. The prompt and schema moved from the
   app into `KitchenHelper.swift` in `Core` for this reason: the app and the
   evaluation must read one definition, or the test measures a copy. The
   alternative is a test target on the Mac app project, which is what the
   Xcode template gives you and is the only option if the feature is entangled
   with UI code.

2. **What the subject calls.** The Foundation Models framework directly — a
   `LanguageModelSession` with the sample's instructions and a `respond(to:schema:)`
   — not `InferenceService` and not HTTP. The evaluation is of the prompt and
   the schema; the service adds nothing the model sees, and calling the
   framework directly gives the report a transcript. Point the subject at the
   HTTP API instead if what you want to regression-test is the server.

3. **Partial expectations.** The expected value is the same `Dish` type as the
   answer, with every field optional: nil means "not checked", and
   `ingredients` lists words that must appear rather than the whole list,
   which is the model's to choose. The framework requires expected and actual
   to share a type; making that type total would mean writing the model's
   answer down in advance, which is not a test of a generative feature.

4. **Quantitative gates, qualitative reports.** The six code-checked metrics
   are asserted. The two judge dimensions are aggregated and printed but not
   asserted. The judge defaults to the on-device model — the model grading its
   own homework, which the [section above](#dont-use-the-model-to-judge-its-own-output)
   shows is unreliable as a *comparator*. As a *reader's aid* it earns its
   place: it scored the birthday cake that ignored the gluten-free child a 2
   with a rationale saying so, when no code metric had caught it. Apple's
   guidance is a judge at least as capable as the model under test, meaning
   Private Cloud Compute: `KITCHEN_JUDGE=private_cloud` switches to it, and
   `KITCHEN_MODEL=private_cloud` puts it under test instead. Both need the
   entitlement, which the `swift test` host process does not carry, so on the
   Mac they fail the same way the bare binary does until the entitlement is
   granted and the tests run from a signed host.

5. **Thresholds from the spread, not the wish.** Each `#expect` sits one
   sample (8 points, with twelve samples) below the lowest value seen across
   four runs. They are tripwires: crossing one means a change made the feature
   worse on a case the dataset covers. Setting them at the target you would
   *like* makes the test fail on the model's own variance, and a test that
   fails on its own is switched off within a week. More samples narrow the
   step and let the thresholds rise.

6. **A failing sample, kept.** "A vegan lunch for my daughter and her three
   friends" returns `servings: 5` in every run — the model counts the parent.
   It stays in the dataset as a recorded weakness the `Servings` threshold
   accommodates. Deleting it would raise the number and lose the fact; the fix
   is a prompt change, which this test will measure when it is made.

7. **Twelve hand-written samples.** The framework's `SampleGenerator` can grow
   a seed set to hundreds synthetically. Twelve cover the axes this prompt
   has (occasion, party size in digits and in words, diet, one constraint) and
   run in under a minute, which is the difference between a test that runs on
   every change and one that runs on Fridays. Generate more when a metric's
   spread is wider than the effect being measured.

8. **Consistency is measured elsewhere.** The Image tab's "same question three
   times, agreement counted" has no direct equivalent here; the framework
   would need each prompt duplicated and a standard deviation aggregated.
   Run-to-run spread is visible instead by running the suite more than once,
   which is how the table above was made.

One framework quirk to save a search: the report's transcript column shows an
empty `instructionText` even though the instructions were applied — the answers
carry the forms and quantities the prompt asks for, and a session built the
same way shows the instructions entry in its own `transcript`. The report's
extraction misses it; the model does not.

---

## Request Logging

Set `LOG_FILE` to append one JSON object per request. **Logging is off by
default** — without it the server never writes prompts, responses, or metadata
anywhere.

```bash
LOG_FILE=./inference.jsonl swift run --package-path Server
```

```json
{
  "ts": "2026-09-01T15:27:26.207Z",
  "endpoint": "/classify",
  "session_id": null,
  "instructions": null,
  "prompt": "Frame from a driveway camera.",
  "response": "none",
  "classes": ["deer","turkey","person","insect","vehicle","none"],
  "images": [{"sha256": "751a0828…", "bytes": 101886, "width": 1024, "height": 1024}],
  "duration_ms": 2086,
  "model_variant": "AFM 3 Core Advanced",
  "metadata": {"camera": "driveway", "reolink_class": "person"},
  "status": 200,
  "error": null
}
```

Every record carries every key, with `null` where a value is absent, so the file
loads as a table without special-casing. Failures are logged too, with the status
the caller saw and the error text.

**Images are identified, not stored.** The `sha256` of the submitted bytes lets
you correlate a log line back to the source frame and spot repeats, without the
log carrying image data.

### `metadata`

Accepted on both `/inference` and `/classify`. Any JSON object; recorded verbatim
and **never shown to the model**.

That last part is deliberate. If you pass the camera's own guess into the prompt
("the camera thinks this is a person"), you bias the model toward agreeing and
destroy the independence that makes the check worth running. Keeping it log-only
means you can still compute the comparison afterward:

```bash
jq -r 'select(.endpoint=="/classify" and .status==200)
       | "\(.metadata.reolink_class) -> \(.response)"' inference.jsonl
```

```
person -> none
pet    -> none
person -> none
```

That cross-tab — what the camera claimed versus what the model saw — is the
measurement that tells you whether the setup is reducing false positives.
It cannot be reconstructed later, so log `metadata` from the first event.

---

## Implementation Details

- **Web framework**: [Vapor](https://github.com/vapor/vapor) 4.89.0, in `Server` only
- **AI integration**: `FoundationModels` framework (Apple's on-device language model)
- **Architecture**: Async/await with Actor-based inference service for concurrency safety
- **Models**: `SystemLanguageModel.default` on device, the default everywhere,
  and `PrivateCloudComputeLanguageModel` when a request names `private_cloud`.
  There is no automatic fallback between them; a cloud fallback would mask the
  local failures this is built to surface.
- **Port**: 8080 (default Vapor HTTP port)
- **Context window**: reported by `/status` as `context_size` — 8192 tokens on
  current hardware. Don't hardcode it; read the endpoint.
- **Error mapping**: framework errors are translated rather than leaked as `500`.
  A full context window is `413` and carries both numbers
  (`Context exhausted: 24203 tokens used of 8192`); a safety refusal is `422`;
  rate limiting is `429`; a timeout is `504`. When probing a model, a refusal is
  a result worth recording, not a server fault.

### Model capabilities

The Apple Intelligence system language model excels at:
- Text generation
- Summarization
- Entity extraction
- Creative writing
- Classification
- Coarse image understanding (when `/status` reports `supports_vision`)

**Not suitable for**: Basic math, code generation, complex logical reasoning.

**On images specifically**, measurements on this hardware put it at coarse
categories — person vs. animal vs. vehicle — and *not* at species-level
identification: it reported three turkeys as "black dogs" consistently, and never
answered "turkey" even when offered the label. Answers also shift substantially
with phrasing and output format. Neither limit is visible without testing, so
read [Phrasing Changes the Answer](#phrasing-changes-the-answer--test-before-you-trust)
before relying on any vision result.

The on-device model is selected automatically by the OS — `SystemLanguageModel.default`
resolves to whatever the installed system ships, so upgrading macOS picks up a newer
model with no code change. Call `/status` to see which variant you actually got.

---

## Best Practices

### Performance tips

- Keep prompts focused and specific
- Limit prompt length for faster responses
- Use phrases like "in three sentences" to get concise responses
- Create a new session for each independent request, or omit `session_id` for a
  one-shot; use `reset` to recycle a long-running session instead of letting its
  transcript grow
- Stay within the context limit reported by `/status`
- Downscale images before sending; large photos cost tokens and upload time

---

## Troubleshooting

### Model not available

If you get `"Model is unavailable"` errors:

1. **Device not eligible**  
   Your device may not support Apple Intelligence. Check [Apple's compatibility list](https://www.apple.com/apple-intelligence/).

2. **Apple Intelligence not enabled**  
   Go to **System Settings → Apple Intelligence** and enable it.

3. **Model not ready**  
   The model may still be downloading. Wait a few minutes and try again.

### Build errors

If you encounter module import errors:

1. Ensure you're running **macOS 27.0+**
2. Verify the selected toolchain provides a **macOS 27 SDK**. This is the most
   common failure: with an older SDK selected the build dies on
   `value of type 'SystemLanguageModel' has no member 'variant'` and
   `cannot find 'Attachment' in scope`. Those symbols are absent from the
   macOS 26 SDK, and no availability guard helps — `#available` gates runtime
   behavior, not whether a symbol exists at compile time.

   Check what you have, then select an Xcode that reports 27.x:
   ```bash
   xcrun --show-sdk-version          # must print 27.x
   # list installed Xcodes and their versions
   for x in /Applications/Xcode*.app; do
       echo "$x $(defaults read "$x/Contents/Info" CFBundleShortVersionString)"
   done
   sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer  # adjust path
   sudo xcodebuild -license accept   # if you have never accepted it
   ```

   To switch for one shell instead of system-wide:
   ```bash
   export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
   ```
3. Re-resolve dependencies:
   ```bash
   swift package resolve --package-path Server
   ```
4. If necessary, clean and rebuild:
   ```bash
   swift package clean --package-path Server
   swift build --package-path Core
   swift build --package-path Server
   ```

---

## References

- [FoundationModels Framework Documentation](https://developer.apple.com/documentation/FoundationModels)
- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Apple Intelligence](https://www.apple.com/apple-intelligence/)
- [Evaluations framework](https://developer.apple.com/documentation/evaluations) and
  [Meet the Evaluations framework (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/298/)

---

## License

This project is licensed under the **MIT License**.  
See the [`LICENSE`](./LICENSE) file for details.
