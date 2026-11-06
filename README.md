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

The window shows the direction control and Listen. More holds Highlight, speakers, notes, Fast / Balanced / Accurate, Models, Type, Copy, and Save. Idle panels read "Listen to translate the room."

If the Mac pack is not installed, the panels name MacBook Pro M4 32GB, best, Listen stays disabled, and Models opens the pack list. Download that pack, press Listen, and allow the microphone. Speak. Committed words stay in the primary text and the live tail stays secondary. Direction stays fixed until Stop. Press Stop to end the session.

The iPhone scheme is `LiveTranslateiOS`. Run it on an iPhone 17 Pro Max. The simulator can show the screen. Listen stays off there until the int8 speech pack and the 4-bit models are installed. On the phone, direction stays in the navigation bar, Listen is the bottom button with Highlight beside it, and Conversation / Notes switches the page. Build one scheme at a time.
