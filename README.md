# Live Translate

On-device live translation between Thai and English, for Mac and iPhone. The microphone audio stays on the device. The user chooses which model pack to download from Hugging Face.

One repository, two app targets, one Swift engine. The Mac window is two side-by-side panels. The iPhone stacks the same panels. The product document is [docs/PRD.md](docs/PRD.md). The downloadable models are [docs/model-catalog.json](docs/model-catalog.json).

Two machines. A MacBook Pro M4 with 32GB runs Typhoon ASR Streaming 0.6B and Nemotron 3.5 at full precision, ChindaMT-4B at 8-bit, and Typhoon 2 7B for live notes. An iPhone 17 Pro Max with 1TB storage and 12GB of RAM runs the same speech models in int8, ChindaMT-4B at 4-bit, and Typhoon 2 3B for the same live note. The 1TB holds the files. It does not make the Mac's 13–15GB resident set fit. Speakers are session labels from FluidAudio, not accounts.

The apps are in this tree. Open `LiveTranslate.xcodeproj`. The Mac target is `LiveTranslate`. The iPhone target is `LiveTranslateiOS`. Shared UI is in `Sources/LiveTranslateUI`. The session engine is `Packages/LiveTranslateCore`. Streaming checks live in `spikes/`.

Model weights, ONNX graphs, and Xcode build products stay on the machine that downloaded them. They are listed in `.gitignore`.
