# Live Translate

On-device live translation between Thai and English, for Mac and iPhone. The microphone audio stays on the device. The user chooses which model pack to download from Hugging Face.

One repository, two app targets, one Swift engine. The Mac window is two side-by-side panels. The iPhone stacks the same panels. The product document is [docs/PRD.md](docs/PRD.md). The downloadable models are [docs/model-catalog.json](docs/model-catalog.json).

Two machines. A MacBook Pro M4 with 32GB runs Typhoon ASR Streaming 0.6B and Nemotron 3.5 at full precision, ChindaMT-4B at 8-bit, and Typhoon 2 7B for live notes. An iPhone 17 Pro Max with 1TB storage and 12GB of RAM runs the same speech models in int8, ChindaMT-4B at 4-bit, and Typhoon 2 3B for the same live note. The 1TB holds the files. It does not make the Mac's 13–15GB resident set fit. Speakers are session labels from FluidAudio, not accounts.

The apps are in this tree. Open `LiveTranslate.xcodeproj`. The Mac target is `LiveTranslate`. The iPhone target is `LiveTranslateiOS`. Shared UI is in `Sources/LiveTranslateUI`. The session engine is `Packages/LiveTranslateCore`. Streaming checks live in `spikes/`.

Model weights, ONNX graphs, and Xcode build products stay on the machine that downloaded them. They are listed in `.gitignore`.

## Test

The session engine tests need no microphone and no model weights. From the repository root:

```
swift test --package-path Packages/LiveTranslateCore
```

The pass line is `Executed N tests, with 0 failures`. A later line, `Test run with 0 tests in 0 suites`, is an empty Swift Testing suite. It is not the result.

To try the Mac app, open `LiveTranslate.xcodeproj`, choose the `LiveTranslate` scheme and My Mac, and press Run. The same build from the terminal:

```
xcodebuild -project LiveTranslate.xcodeproj -scheme LiveTranslate -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/LiveTranslate.app
```

The window follows the "Mac app — live session" design (`docs/design/`, design renders beside app captures): a 52 pt header with the traffic lights, the sessions toggle, the session title, the language pill (spoken ⇄ translation), Copy ▾, and the summary toggle; the two-column transcript anchored to the bottom, where hovering a turn shows its time and a copy button beside each column; a floating pill with Listening, the time, the level bars, Pause, and Stop (idle: Microphone or System audio, captions, Listen); and the 300 pt summary panel with key points and action items. The sessions toggle opens session history with search, new session, and Manage languages. Idle panels read "Listen to translate the room."

Everything the design does not draw is in the menu bar: File → New Session (⌘N), Export (Markdown, text, JSON); Copy as Markdown (⌥⇧⌘C); Edit → Copy Original / Translation / Bilingual / Summary (⌥⌘1–4); Session → Listen/Stop (⌘↩), Pause (⇧⌘P), Listen To, Highlight (⇧⌘H), Manage Languages (⇧⌘M); View → Sessions (⌃⌘S), Summary (⌥⌘I), Floating Captions (⇧⌘K), Layout, Text Size.

If the Mac pack is not installed, the transcript says so and Manage languages opens the model screen. Press Listen and allow the microphone. Speak. Committed words stay in the primary text and the live tail stays secondary. Languages stay fixed until Stop.

Copy ▾ opens the design's Copy menu: Original (⌥⌘1), Translation (⌥⌘2), Bilingual line by line (⌥⌘3), and Summary (⌥⌘4), with speaker names, timestamps, and Markdown as options. Hover a turn to copy one column, right-click for both, or select any text.

Sessions are kept as text on this Mac (no audio) in Application Support/LiveTranslate/sessions, and can be deleted from the sidebar. System audio uses ScreenCaptureKit and asks for Screen Recording access the first time.

### Languages

Thai, English, Chinese, Japanese, Korean, Vietnamese, Indonesian, French, German, and Spanish, in any direction. Pick the spoken language and the translation language in the header. Thai and English speech come with the pack; the others use a streaming model from Models → Speech → that language. Thai ⇄ English translates with ChindaMT; other pairs use a multilingual Qwen Instruct model from Models → Translation (marked "Many languages").

### Models from Hugging Face

Models has Speech (with a language picker), Translation, Notes, and Packs. Each lists only Hugging Face repos that a runtime in this app can load:

| Task | Runtime | What qualifies |
| --- | --- | --- |
| Speech, any language | sherpa-onnx, CPU | Streaming transducer with `encoder*/decoder*/joiner*.onnx` and `tokens.txt`, and sherpa metadata in the encoder (read with a ranged request before listing) |
| English streaming | Core ML, Neural Engine | FluidAudio Nemotron streaming layout (`nemotron_coreml_1120ms/`) |
| Translation, Notes | MLX, GPU | `config.json`, safetensors, tokenizer, an architecture the bundled mlx-lm has; ChindaMT / typhoon-translate for Thai ⇄ English, Qwen2.5 / Qwen3-2507 Instruct for other pairs, Typhoon or Qwen instruct for notes |

Downloads resume, check the Hub's sha256, install atomically, and are opened once in a child process before they can be selected. Nothing downloads while Listen is on. For English, the Neural Engine build uses about 0.02 of a CPU core against 0.3 for the ONNX graph.

Speech decoding runs on its own queue, never on the main thread. Both speech graphs stay loaded, the translator starts with the app, and notes passes run in the background.

To stream a recording through the same path without the microphone:

```
DerivedData/Build/Products/Debug/LiveTranslate.app/Contents/MacOS/LiveTranslate --session --audio spikes/fixtures/en-room.wav --language en
```

The iPhone scheme is `LiveTranslateiOS`. Run it on an iPhone 17 Pro Max. The simulator can show the screen. Listen stays off there until the int8 speech pack and the 4-bit models are installed. On the phone, direction stays in the navigation bar, Listen is the bottom button with Highlight beside it, and Conversation / Notes switches the page. Build one scheme at a time.

## Use your sessions with Claude

Live Translate is also an MCP server, so the Claude app you are signed into can read your sessions and use them with its other connectors (email, calendar, tasks, docs). Choose File → Connect to Claude… and press Add to Claude Desktop, or copy the Claude Code command:

```
claude mcp add --scope user live-translate -- "/Applications/Live Translate.app/Contents/MacOS/LiveTranslate" --mcp
```

Claude gets four read-only tools: `list_sessions`, `get_session` (Markdown with summary, action items and the bilingual transcript), `get_transcript` and `search_sessions`. `latest` is the most recent session, including one still being recorded. It cannot change or delete sessions and never gets audio.

## Google Calendar

File → Connect Google Calendar… (on iPhone: settings → Google Calendar). When a session starts, the meeting happening now names the session, and its attendees and agenda go to the summary and to the Markdown Claude reads. Access is read-only (`calendar.events.readonly`); the refresh token stays in the Keychain.

You need your own OAuth client ID once: in Google Cloud Console create a project, enable the Google Calendar API, configure the OAuth consent screen (add yourself as a test user), and create an OAuth client of type **iOS** with bundle ID `co.nimblehq.LiveTranslate`. The same client ID works on the Mac.

## Ask the meeting

The side panel on the Mac (Summary | Ask) and the session screen on iPhone (Summary | Transcript | Ask) answer questions about the meeting, citing the turns they come from, and can act in connected apps ("Add the action items to my Notion").

Settings → Connections (⌘, on the Mac; the gear on iPhone) chooses who answers Ask and writes the summary:

- **On this Mac / On device**: Apple Intelligence (falling back to the notes model on the Mac). Private, offline, no connections.
- **ChatGPT** or **Claude**: the question and the transcript go to that service. OpenAI and Anthropic don't let other apps use a ChatGPT or Claude.ai subscription, so these connect with an API key (kept in the Keychain). Claude uses `claude-opus-5-5` with the MCP connector; ChatGPT uses the Responses API with remote MCP tools.

**Connections** are remote MCP servers Ask can read from and add to. Notion and Linear sign in with one click (MCP OAuth with dynamic registration). Slack's server only signs in registered apps, so it asks for your Slack app's client ID (redirect `livetranslate://oauth/callback`). Google Drive and anything else: Add MCP server… with its URL. Tokens stay in the Keychain and refresh automatically.

## More

- **Find in transcript** — ⌘F on the Mac (⌘G / ⇧⌘G for next and previous), the search field in the iPhone Transcript tab. Ignores case and accents, in the original and the translation.
- **Subtitles** — File → Export → Subtitles (SRT) or (WebVTT), or Share on iPhone. Cues use each turn's times; WebVTT names the speaker. Export → Subtitles Show picks the translation, the original, or both.
- **Save sessions as Markdown to a folder** — Settings → General. Each finished session lands there (an Obsidian vault, iCloud Drive…), updated when the summary finishes and renamed with the title.
- **Menu bar and ⌃⌥Space** — Listen, Stop, Pause and the latest translated line from the menu bar; ⌃⌥Space starts and stops listening from any app (Settings → General to turn it off).
