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

The bar shows the direction, Listen / Stop (⌘↩), and Fast / Balanced / Accurate, then one-click icons for Highlight, speakers, notes, Models, type size, Copy, and Save. A status line under the bar names the speech and translation models and where each one runs (CPU, Neural Engine, or GPU). Idle panels read "Listen to translate the room."

If the Mac pack is not installed, the panels name MacBook Pro M4 32GB, best, Listen stays disabled, and Models opens the model screen. Press Listen and allow the microphone. Speak. Committed words stay in the primary text and the live tail stays secondary. Direction stays fixed until Stop. Press Stop to end the session.

Every turn's text is selectable. Hover a turn for copy buttons, right-click for Copy detected text / Copy translation / Copy both, or use the copy icons in each panel header (⇧⌘C copies all detected text).

### Models from Hugging Face

Models has one tab per task: Thai streaming, English streaming, Translation, Notes, plus the packs. Each tab lists only Hugging Face repos that a runtime in this app can load:

| Task | Runtime | What qualifies |
| --- | --- | --- |
| Thai / English streaming | sherpa-onnx, CPU | Streaming transducer with `encoder*/decoder*/joiner*.onnx` and `tokens.txt`, and sherpa metadata in the encoder (read with a ranged request before listing) |
| English streaming | Core ML, Neural Engine | FluidAudio Nemotron streaming layout (`nemotron_coreml_1120ms/`) |
| Translation, Notes | MLX, GPU | `config.json`, safetensors, tokenizer, an architecture the bundled mlx-lm has; ChindaMT / typhoon-translate for translation, Typhoon instruct for notes |

Downloads resume, check the Hub's sha256, install atomically, and are opened once in a child process before they can be selected. Nothing downloads while Listen is on. For English, the Neural Engine build uses about 0.02 of a CPU core against 0.3 for the ONNX graph.

Speech decoding runs on its own queue, never on the main thread. Both speech graphs stay loaded, the translator starts with the app, and notes passes run in the background.

To stream a recording through the same path without the microphone:

```
DerivedData/Build/Products/Debug/LiveTranslate.app/Contents/MacOS/LiveTranslate --session --audio spikes/fixtures/en-room.wav --language en
```

The iPhone scheme is `LiveTranslateiOS`. Run it on an iPhone 17 Pro Max. The simulator can show the screen. Listen stays off there until the int8 speech pack and the 4-bit models are installed. On the phone, direction stays in the navigation bar, Listen is the bottom button with Highlight beside it, and Conversation / Notes switches the page. Build one scheme at a time.
