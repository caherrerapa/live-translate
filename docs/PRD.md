# Live Translate PRD

Status: accepted for the first build. This is the product document. It is not an implementation.

Working name: Live Translate. Repository: `caherrerapa/live-translate`.

## 1. Decision

Build one product in one repository. Two Apple targets share one Swift engine: a macOS app and an iOS app. The macOS window is two side-by-side panels. The iPhone stacks the same two panels. The iPad uses the Mac layout when the window is wide.

The engine is local. The microphone audio never leaves the device. There is no account, no cloud speech API, and no fallback that uploads audio when a model is missing. If the model for the chosen direction is not installed, Listen stays off.

Models are a catalog, not a single baked-in checkpoint. The app downloads the files the user picks from Hugging Face, checks the hash, and loads only a pack marked for that platform. Mac and iPhone do not default to the same weights. Mac defaults to the best streaming Thai model. iPhone defaults to the smaller streaming Thai model that can keep up.

v1 languages are Thai and English, both directions. v1 output is text. Spoken playback is later.

## 2. Who it is for

A person in the room with Thai and English speech, who wants to read both languages while people are still talking. Typical situations: a meeting, a conversation across a table, a talk, an interview. One microphone hears the room. The app separates speakers and shows each turn in both languages.

The user keeps the audio. They choose the model. They can delete it.

## 3. Reference product

The interaction to match is Soniox (spoken as Sonyox). Soniox already does the parts we would otherwise have to invent in the cloud:

- Live tokens while someone is speaking, including a revision of the recent tail.
- A speaker label on each token, in real time, for many speakers.
- A two-panel session: original on one side, translation on the other, with translation tokens arriving before the sentence ends.
- Their current speech-translation docs describe one-way and two-way text translation over the same stream as the transcript.

Soniox does that by receiving the audio. That is the part this product refuses. The missing product, for this user, is the same session running on the Mac and on the iPhone with weights stored on device.

"About one second" is the lag target for the balanced setting, not a second product. The balanced Thai model is built to look ahead about half a second to one second. Section 8 is the budget.

## 4. What the user can do in v1

1. Open the app and see which pack is installed, its size, its language, and its latency step.
2. Download, pause, resume, and delete a pack. The list is different on Mac and on iPhone.
3. Choose Thai → English or English → Thai.
4. Choose Fast, Balanced, or Accurate. That sets the streaming chunk. It does not download a different file.
5. Tap Listen. Partial text appears in the source panel while the person is talking. The translation panel follows the stable part of that text.
6. See a speaker chip on each turn. Rename the chip for this session ("Speaker 2" → a name). The rename sticks until the app quits or the user clears the session.
7. Stop. Scroll back through the session. Copy a turn or save the transcript as text. Saving stores text on device. It does not store the audio.
8. Change type size. On the Mac, drag the window; the two panels stay equal width.

## 5. Screens

### 5.1 Mac

One window, minimum 960 × 640.

Top bar, left to right: direction control (`Thai → English` / `English → Thai`), Listen / Stop, speaker toggle, latency (Fast / Balanced / Accurate), model menu, type size.

Body: two columns, equal width, one hairline between them.

| Source | Translation |
| --- | --- |
| Language name, then the turns | The other language, same turns, same order |

A turn is one block that exists in both columns. The columns do not scroll independently. A speaker change starts a new turn. A silence endpoint starts a new turn.

Inside a turn:

- Speaker chip, stable color from a palette of eight.
- Committed words in primary text.
- The live tail in secondary text, with a caret. The tail may be replaced. The committed prefix stays put.

Empty states, in order:

- No pack for this direction: the panels explain which pack to download, and the model screen is one click away. Listen is disabled.
- Pack installed, not listening: a one-line hint, "Listen to translate the room."
- Listening, silence: both panels stay on the last turn. No fake partials.
- Microphone denied: a button that opens System Settings.

### 5.2 iPhone

Same session, stacked. Source on top, translation below a divider, both bound to the same turn list so they do not drift. Direction sits in the navigation bar. Listen is the bottom button. Latency and the model pack live in a sheet, not in the reading surface. Type is large by default. Side-by-side on a phone is not the layout.

### 5.3 iPad

Regular width uses the Mac columns. Compact width uses the iPhone stack. Rotation switches layout without clearing the session.

### 5.4 Model screen

A list of packs the catalog allows on this platform. Each row shows:

- Name and one-line description.
- Tasks in the pack (Thai speech, English speech, translation, speakers).
- Download size, once known. The size comes from the file headers at download time. The UI does not invent a size.
- Latency steps that pack supports.
- License name.
- Download, pause, resume, delete.

The recommended pack is marked. The user can install another eligible pack and select it. Selecting a pack while listening stops the session, loads, and leaves Listen ready. A pack the spike has not cleared for this device class is visible and disabled, with the reason ("too slow on this iPhone" or "export not ready").

A free-text Hugging Face repo id is a developer switch, off in the shipping app. A random repo will not match the runtime.

## 6. Session behavior

### 6.1 Audio

`AVAudioEngine` captures the microphone at the hardware rate and converts to 16 kHz mono float. The session consumes 10–20 ms buffers and groups them into the model's chunk. Voice-processing (echo cancellation, gain) is measured before it is turned on. If it adds more than 20 ms or warps the levels the recognizer was trained on, it stays off.

v1 hears the room through the microphone. Capturing system audio (a Meet call playing on the Mac) is a later Mac feature. It needs a Core Audio process tap and a permission prompt, and it is a different product surface.

### 6.2 Direction

v1 loads one speech model, the one for the source language, plus the translation model, plus the speaker model. The user swaps direction. On a Mac with enough memory the other speech model may stay loaded so the swap is immediate. On iPhone only one speech model stays resident.

Automatic language switching inside one session is not in v1. Thai speech with English words mixed in is still Thai mode. The Mac model is chosen because it keeps those English words. The small iPhone model is weaker on that mix, and the model row says so.

### 6.3 Partials and commits

The recognizer is a streaming transducer. It emits pieces as audio arrives and it is allowed to change the recent tail. The UI copies that behavior.

- Source committed prefix: pieces that have survived two chunks, or that are older than 0.4 s.
- Source live tail: everything after that prefix. Drawn in secondary text. Replaceable.
- Endpoint: the recognizer's endpoint, or about 0.4 s of silence after speech. The endpoint commits the whole turn, including the tail, and starts the next turn.

Thai has no spaces between words. Stability is tracked on the model's pieces and on time. It is not tracked on whitespace.

### 6.4 Translation policy

Translation is a second model, run on text. It does not run on every audio chunk. Running it on every chunk would burn the latency budget and thrash the sentence.

Rules:

- Translate the current turn only. A turn is the speech since the last endpoint, for one speaker. The prompt is never the whole meeting.
- Call the translator when the committed source prefix grows by about 12 Thai characters or about 4 English words, and when the endpoint fires. Skip the call if one translation is already running.
- If the prefix moved while the call was running, drop the stale result and translate the new prefix.
- Local agreement: a translation of the prefix becomes committed after it has been unchanged across one more recognizer chunk. Until then it is the secondary line in the translation panel.
- The translation panel shows the committed translation, then the provisional translation of the uncommitted prefix. The committed translation does not jump.
- On endpoint, flush the turn: one last translation, then both sides commit.
- The prompt asks for the translation only, in the target language, with numerals kept as digits. That matches the instruction style ChindaMT was trained on. No extra rules in v1.

This is simultaneous translation by policy. It is the practical on-device substitute for a dedicated simultaneous speech-translation model. SeamlessStreaming is the research reference for that policy (a learned read/write decision, lag around two seconds, broad language coverage). Its runtime is not something we can ship inside an iPhone app. We keep the policy and use a Thai–English text model.

### 6.5 Speakers

"Identify who is speaking" means speaker diarization. It does not mean an account, a login, or a voice database.

v1:

- Anonymous labels, `Speaker 1` onward, in order of first appearance.
- The label is attached to recognizer pieces by overlapping time. Text shows immediately. The chip can change until the diarizer settles, then it locks for that turn.
- At endpoint the label freezes with the turn.
- The user can rename a label for the rest of the session.
- The toggle hides chips. The text keeps streaming.
- Target up to 8 speakers in a session. More than that still transcribes; extra speakers may share a chip. The model we start from claims up to 10.

v1 does not enroll a voice, does not remember a person across sessions, and does not try to name someone from a saved embedding. That is biometric identification. It needs its own consent, storage, and deletion design, and it is out of this version.

Real-time diarization will sometimes flip and then settle. Soniox documents the same limit. The UI is built for a chip that can change before the turn commits. It is not built to rewrite a committed turn's speaker.

### 6.6 What is stored

| Data | v1 |
| --- | --- |
| Microphone audio | Memory only, discarded with the buffer |
| Live transcript | Memory for the session |
| Saved transcript | On device, only after the user saves. Text, speaker label, times, direction. No audio. |
| Downloaded weights | On device, the app's container, deleted when the user deletes the pack |
| Account | None |

## 7. Model catalog

The catalog is `docs/model-catalog.json`. The app ships a copy. An entry the runtime cannot load is not offered.

Each model record has: id, Hugging Face repo, pinned revision, file list, sha256 per file, runtime, platforms, languages, task, allowed chunk sizes, default chunk, quality tier, license, and a note. Packs point at model ids. A pack has platforms and directions.

Download:

- Public Hugging Face resolve URLs. No token in v1, because every shipping model is public.
- Resumable. Check the hash before the pack is marked installed. A bad hash is deleted and offered again.
- Atomic install: the session can only see a finished directory.
- The model manager is the only code allowed to open a network connection. Listening refuses to start a download, and a download does not run during Listen.

The user controls the pack and the latency step. They do not control the chunk math. Fast, Balanced, and Accurate map onto the chunk sizes that model was trained with.

### 7.1 Thai speech, Mac default

`typhoon-ai/typhoon-asr-streaming-nemotron-0.6b`

Cache-aware FastConformer transducer, about 0.6B parameters, language prompt `th-TH` required. SCB 10X / Typhoon adapted NVIDIA's streaming Nemotron model and extended the tokenizer with the Thai pieces from Typhoon ASR Real-time, so English words inside Thai can still be written. License: OpenMDW-1.1.

Published streaming operating points (arXiv:2609.14991):

| Look-ahead | TVSpeech CER | GigaSpeech2-Thai CER | First token, from the paper |
| --- | --- | --- | --- |
| 1040 ms | 14.1% | 9.3% | about 1.07 s |
| 480 ms | between the 80 ms and 1040 ms points | same shape | about 0.49 s |
| 80 ms | usable, worse | usable, worse | under 0.2 s plus compute |

At 3200 ms the same model reaches 13.0% CER on TVSpeech. The paper's shallow-fusion n-gram raises keyword recall on a held-out TVSpeech slice from 16.6% to 20.7% at the 1040 ms point, at no CER cost. The n-gram is a second file (`typhoon-ai/typhoon-asr-streaming-nemotron-0.6b-ngram`) and is optional. v1 ships the acoustic model first. Fusion is turned on only if the on-device decoder can apply it inside the chunk budget.

Balanced on Mac uses the 480 ms chunk. Accurate uses 1040 ms. Fast uses 80 ms and is labeled as the lower-accuracy step.

### 7.2 Thai speech, iPhone default

`typhoon-ai/typhoon-asr-streaming-115m`

Same streaming family, 115M parameters, Thai tokenizer only, CC-BY-4.0. Streaming CER on TVSpeech is 19.4% at 1040 ms and 16.4% at 3200 ms. The model card says to use this one when English mixed into the Thai is light, and to use the 0.6B model when that mix matters.

This is the iPhone default because it is the one most likely to run faster than real time next to a translation model and a speaker model. A later "Quality" pack may install the 0.6B model on an iPhone that passed the spike.

### 7.3 Why the other Thai checkpoints are not the live model

`typhoon-ai/typhoon-asr-realtime` is the full-context 115M model the streaming 115M was converted from. The streaming paper says that checkpoint falls apart when it is forced to stream: CER goes from 11.0% offline to 62.8% at a 1040 ms look-ahead, and to 100% at 80 ms. It is a good offline model. It is the wrong live model.

`nvidia/nemotron-3.5-asr-streaming-0.6b` lists Thai as adaptation-ready. Out of the box it is not a production Thai recognizer. The Typhoon 0.6B checkpoint is that adaptation. We use Typhoon for Thai.

Whisper-family Thai models (Pathumma Whisper, Typhoon Whisper large, Biodatlab) are the accuracy ceiling on a finished recording. They read a window of audio before they write. They are not the live engine. A later "clean up this saved transcript" action could run one offline. v1 does not.

The sherpa-onnx Thai Zipformer (`sherpa-onnx-zipformer-thai-2024-06-20`) is offline. There is no streaming Thai Zipformer in that catalog to download and ship. We do not pretend there is.

### 7.4 English speech

`nvidia/nemotron-3.5-asr-streaming-0.6b` with prompt `en-US`.

English is in the transcription-ready tier. Same cache-aware FastConformer transducer family as the Thai 0.6B model, which is why one decoder loop can serve both. Chunks the model was trained for: 80, 160, 320, 560, and 1120 ms. Balanced uses 320 ms. License: OpenMDW-1.1.

Community conversions already exist (ONNX int4, Core ML int8 around 612 MB, MLX). They are spike inputs. The shipping files are ones we export and pin by hash, or an upstream file whose hash we have checked against the NVIDIA weights. A third-party conversion is not the release artifact until that check exists.

### 7.5 Translation

Default: the ChindaMT family from iApp, Apache-2.0, Thai and English only, both directions.

| Pack | Model | Where |
| --- | --- | --- |
| Mac quality | `iapp/ChindaMT-4B`, 4-bit | Mac |
| Mac lighter | `iapp/ChindaMT-2B` quantized | Mac, if 4B misses the lag budget |
| Phone | `iapp/ChindaMT-0.8B` quantized | iPhone |

ChindaMT is a causal text model. A 4B 4-bit MLX conversion is on the order of a few gigabytes and on the order of 100 tokens/s on a recent Mac in the community conversion notes. That is fast enough to translate a turn. It is not fast enough to translate every audio frame. The policy in section 6.4 is what makes it a live translator. iApp's "about 0.4 s a sentence" figure is their server API. It is not our on-device number. We measure ours.

Hold: `tencent/Hy-MT2-1.8B`. It includes Thai among 30+ languages, and the GGUF builds go down to a 1.25-bit file Tencent describes as 440 MB. It is the escape hatch if ChindaMT-0.8B misses quality on the phone. Its license is not Apache. The pack stays disabled until someone reads the license and writes the name into the catalog.

### 7.6 Speakers

FluidAudio, Apache-2.0, Swift, Core ML, Neural Engine, macOS and iOS. The online diarizer to start from is LS-EEND: one model, streaming, up to 10 speakers, frame updates around 100 ms, with a tentative preview before the label locks. Sortformer is the overlap alternative in the same library. v1 integrates one of them. The spike picks the one that attaches stable labels to our turns with less flicker. We do not ship both.

### 7.7 Default packs

| Pack | Platform | Thai speech | English speech | Translation | Speakers |
| --- | --- | --- | --- | --- | --- |
| Mac, best | macOS | Typhoon streaming 0.6B | Nemotron 3.5 streaming 0.6B | ChindaMT-4B 4-bit | FluidAudio LS-EEND |
| iPhone, default | iOS | Typhoon streaming 115M | Nemotron 3.5 streaming, int8 | ChindaMT-0.8B | FluidAudio LS-EEND |
| iPhone, quality | iOS, only after the spike passes | Typhoon streaming 0.6B | same English model | ChindaMT-0.8B or 2B | FluidAudio LS-EEND |

## 8. Latency budget

Balanced is the default. The user's "about one second" maps to this column. Times are the product targets, measured on device, from speech to pixels. Paper numbers above are the model's look-ahead, not yet our end-to-end measurement.

| Stage | Fast | Balanced | Accurate |
| --- | --- | --- | --- |
| Thai look-ahead | 80 ms | 480 ms | 1040 ms |
| English look-ahead | 80 ms | 320 ms | 560 ms |
| Recognizer compute | under the chunk length | under the chunk length | under the chunk length |
| First source glyphs | under 0.4 s | under 0.8 s | under 1.4 s |
| Translation of a short stable prefix | under 0.8 s after the prefix commits | under 1.5 s | under 2.0 s |
| Speaker chip settles | may lag the text | may lag the text | may lag the text |

Compute rule: if a model cannot finish a chunk before the next chunk arrives (real-time factor under 1, target under 0.5 on Mac and under 0.7 on the iPhone we claim), that pack is disabled on that device. The catalog does not offer a model that falls behind the speaker.

Diarization is allowed to be later than the text. A missing chip is acceptable. Late text is not.

## 9. Runtime

One engine, used by both apps. Swift. The apps are thin: window or screen, permissions, and the model screen.

```
Microphone → 16 kHz frames → chunker
                              ├─ streaming recognizer → turn builder → panels
                              ├─ diarizer → speaker chips on those turns
                              └─ (on a stable prefix) translator → translation side
```

The recognizer and the translator need a runtime that exists on both platforms. The weights we want are NeMo and a Qwen-family text model. Neither ships as an iPhone framework.

The runtime plan, in order:

1. Streaming speech: ONNX Runtime, called through sherpa-onnx's Swift API if the exported transducer loads there, otherwise a small Swift wrapper over the same ONNX Runtime. One streaming loop for the Typhoon models and for Nemotron English. Cache tensors are inputs and outputs, so a chunk does not re-encode the whole minute.
2. Translation: a quantized causal model through a Swift LLM runtime that already runs on Mac and iOS (MLX Swift or llama.cpp). Pick the one that hits the section 8 lag on both platforms for the 0.8B phone model and the 4B Mac model. One wrapper, two backends only if one runtime cannot host both.
3. Speakers: FluidAudio, linked from both apps.
4. Download: URLSession, our catalog, our hashes.

The first milestone is not the window. It is a command-line spike that streams a Thai recording through the exported 115M model and the exported 0.6B model on a Mac, prints partials with timestamps, and records real-time factor and time-to-first-piece. The iPhone spike is the same binary path on a device. The UI milestone starts after those two numbers exist.

Export notes the spike has to settle:

- The 0.6B Thai model is a prompt-conditioned NeMo transducer with a 15,135-piece tokenizer. The export must carry the `th-TH` prompt and the cache.
- The 115M model is the converted Typhoon ASR Real-time streaming checkpoint, with a different context schedule (`att_context_size` pairs in the model card). It may need its own export.
- A full-context ONNX file that only accepts a whole utterance fails the spike, even if the character error rate looks good.

Intel Macs are out. The floor is Apple silicon. The oldest iPhone we name in the App Store text is the oldest phone that finishes the 10-minute test in section 11. Until that test exists, the claim is "iPhone that passes the spike."

## 10. Privacy

- The microphone is used to translate on this device.
- Audio is not uploaded, not written to a file, and not put in a crash log.
- Transcripts are kept only if the user saves them, and then only as text on device.
- Model downloads are the only network use. The host is Hugging Face. During Listen, the model manager opens no connection.
- Speaker labels are session-local. No voiceprint is stored.
- The first-run microphone prompt says this in one sentence. The model screen says weights are downloaded to this device.

A test in the suite watches the process during a one-minute Listen and fails if any socket opens.

## 11. Acceptance tests

Speech fixtures, checked in as audio plus a reference transcript. Short, so they can run on every spike. A longer file is the endurance test.

| Fixture | What it protects |
| --- | --- |
| Thai monologue, clean | Basic Thai partials and a finished turn |
| Thai with English product names and numbers | The reason the Mac pack is the 0.6B model |
| English monologue | The other direction |
| Two speakers, taking turns | Chips, turn breaks, both panels stay aligned |
| Overlap of about one second | The app does not crash or merge the turn forever |
| Cafe noise | Partials still commit |
| Ten minutes, two speakers | Memory is flat. Real-time factor stays under the gate. No socket opens |

Measures on each streaming fixture: time to first source piece, time to first committed translation, character error rate on Thai, word error rate on English, and a short human read of the translation (a saved note in the spike report, not a BLEU gate). Diarization error on the two-speaker fixture is recorded. We do not block the first UI on a leaderboard number. We block it on "keeps up" and "the text is the right language and the panels match."

UI checks before calling the Mac app done:

- Listen, talk, see both panels update, stop, text remains.
- Swap direction, talk, the panels swap roles.
- Kill the download halfway, resume, the hash still gates install.
- Delete the pack, Listen disables.
- Deny the microphone, the empty state opens Settings.
- Rename a speaker, later turns of that voice keep the name.
- Shrink the window to the minimum, both panels remain readable.

UI checks for iPhone: the same session on a phone, stacked, plus rotation on an iPad between columns and stack without clearing the transcript.

## 12. Build order

Each step is shippable on its own. Later steps do not start by rewriting the engine.

1. Catalog file and a downloader that checks hashes. No audio yet.
2. Mac spike: export and stream Typhoon 115M and Typhoon 0.6B. Record the section 11 numbers.
3. Mac spike: Nemotron English through the same loop.
4. Translation spike: ChindaMT on a growing Thai prefix, measured lag, both directions. Drop to the 2B or 0.8B model if the 4B model misses Balanced.
5. iPhone spike: 115M speech plus 0.8B translation plus FluidAudio, 10 minutes, unplugged.
6. Mac app: the two panels, Listen, direction, latency, model screen.
7. iPhone app: the stacked panels on the same engine. iPad columns.
8. Speaker chips and rename.
9. Save transcript. Copy a turn.

Step 6 waits on steps 2 and 4. Step 7 waits on step 5. If step 2 cannot export the 0.6B model, the Mac pack temporarily uses the 115M model and the model row says the best Thai model is not on device yet. We do not fill the gap with Whisper or with a cloud call.

## 13. Out of this version

- Accounts, sync, sharing, and a server.
- Any path that uploads audio, including "just for a hard clip."
- Spoken translation. Text first. A local voice can be added later as a third model with its own lag.
- Android, Windows, Intel Macs, visionOS.
- System-audio capture and call bots.
- Automatic language flip inside a session.
- Voice enrollment and naming people across days.
- More languages. The catalog can grow after Thai and English hit the budget. Hy-MT2 is the likely translation model on that day, after the license is written down.
- Fine-tuning.
- A custom glossary. ChindaMT can take terminology rules. v1 always sends the same plain prompt.

## 14. Risks

| Risk | What we will do |
| --- | --- |
| The Typhoon streaming checkpoints do not export to a cache-aware ONNX file | The spike stops the UI. We adapt the export NVIDIA's Nemotron streaming model already has, since the 0.6B Thai model is that architecture with a longer tokenizer. We do not swap in an offline model and call it live. |
| The 0.6B model plus ChindaMT-4B plus diarization do not fit a 16 GB Mac | The Mac pack drops to ChindaMT-2B, then to 0.8B. Speech quality stays on the 0.6B model. |
| The 115M iPhone model mangles English words inside Thai | The row says so. The quality pack is the 0.6B model on phones that pass the spike. |
| Real-time speaker labels flicker | The chip is allowed to change until the turn commits. Committed turns stay. |
| A community Core ML file is convenient and wrong | Hashes are pinned to files we verified. Convenience builds do not ship. |
| Hy-MT2's license is awkward | It stays out of the default packs. |
| CC-BY-4.0 on the 115M model requires attribution | The model screen lists the license and the authors. |

## 15. Repo shape

```
docs/PRD.md                 this document
docs/model-catalog.json     packs and models the app is allowed to download
apps/macos                  later, after the spikes
apps/ios                    later
Packages/LiveTranslateCore  later: audio, catalog, streaming, turns
```

Downloaded weights are not committed.

## 16. Open points

These do not block the spikes. They need an answer before a public TestFlight build.

- Distribution: Developer ID for the Mac, TestFlight for the iPhone. No cloud account to register.
- The oldest iPhone we are willing to buy hardware for. The budget in section 8 decides the rest.
- Whether a saved transcript should survive a reinstall. v1 can keep it in the app container and lose it on uninstall.
- The product name on the home screen. The repo stays `live-translate` either way.
