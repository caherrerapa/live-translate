# Live Translate

On-device live translation between Thai and English, for Mac and iPhone. The microphone audio stays on the device. The user chooses which model pack to download from Hugging Face.

One repository, two app targets, one Swift engine. The Mac window is two side-by-side panels. The iPhone stacks the same panels. The product document is [docs/PRD.md](docs/PRD.md). The downloadable models are [docs/model-catalog.json](docs/model-catalog.json).

The Mac pack targets a MacBook Pro M4 with 32GB. It downloads Typhoon ASR Streaming 0.6B for Thai, at the 1040 ms chunk, with its n-gram, and keeps Nemotron 3.5 ASR Streaming loaded for English. Translation is ChindaMT-4B 8-bit. iPhone defaults to Typhoon ASR Streaming 115M and ChindaMT 0.8B. Speakers are session labels from FluidAudio, not accounts.

No application code yet. The first build is a streaming spike, described in the PRD, before any window.
