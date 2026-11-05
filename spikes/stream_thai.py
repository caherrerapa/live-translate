#!/usr/bin/env python3
"""Stream a Thai recording through Typhoon ASR Streaming 0.6B.

Mac spike from docs/PRD.md: cache-aware chunks, partials with timestamps,
time-to-first-piece, and real-time factor. The checkpoint is the .nemo file
in models/. ONNX export is the next gate after this loop produces Thai text.

The call order matches the Typhoon streaming engine
(warit-s/typhoon-asr-streaming demo/asr_engine.py, Apache-2.0): one encoder
frame is 80 ms, chunk 13 is the 1040 ms Accurate preset, prompt th-TH.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import soundfile as sf
import torch
from omegaconf import OmegaConf

import nemo.collections.asr as nemo_asr
from nemo.collections.asr.parts.utils.rnnt_utils import Hypothesis
from nemo.collections.asr.parts.utils.streaming_utils import (
    CacheAwareStreamingAudioBuffer,
)

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CHECKPOINT = ROOT / "models" / "typhoon-asr-streaming-nemotron-0.6b.nemo"
# 1 encoder frame = 80 ms. 13 frames is the Accurate preset (1040 ms).
CHUNK_FRAMES = {1040: 13, 480: 6, 80: 1}


def edit_distance(left: str, right: str) -> int:
    if left == right:
        return 0
    if not left:
        return len(right)
    if not right:
        return len(left)
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, start=1):
        current = [i]
        for j, b in enumerate(right, start=1):
            cost = 0 if a == b else 1
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + cost))
        previous = current
    return previous[-1]


def compact(text: str) -> str:
    return "".join(text.split())


def hypothesis_text(hypotheses) -> str:
    if not hypotheses:
        return ""
    first = hypotheses[0]
    return first.text if isinstance(first, Hypothesis) else str(first)


def pick_device(requested: str) -> str:
    if requested != "auto":
        return requested
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def stream_file(model, audio_path: Path, chunk_frames: int, device: str):
    model.encoder.setup_streaming_params(
        chunk_size=chunk_frames,
        left_chunks=2,
        shift_size=chunk_frames,
    )
    info = sf.info(str(audio_path))
    audio_s = info.frames / info.samplerate
    buffer = CacheAwareStreamingAudioBuffer(model=model, online_normalization=False)
    buffer.reset_buffer()
    buffer.append_audio_file(str(audio_path), stream_id=-1)

    cache_last_channel, cache_last_time, cache_len = model.encoder.get_initial_cache_state(
        batch_size=1
    )
    previous_hypotheses = None
    previous_pred_out = None
    text = ""
    first_piece_s = None
    started = time.perf_counter()
    partials = []

    for step, (chunk_audio, chunk_length) in enumerate(buffer):
        drop_extra = 0 if step == 0 else model.encoder.streaming_cfg.drop_extra_pre_encoded
        (
            previous_pred_out,
            hypotheses,
            cache_last_channel,
            cache_last_time,
            cache_len,
            previous_hypotheses,
        ) = model.conformer_stream_step(
            processed_signal=chunk_audio.to(device),
            processed_signal_length=chunk_length.to(device),
            cache_last_channel=cache_last_channel,
            cache_last_time=cache_last_time,
            cache_last_channel_len=cache_len,
            keep_all_outputs=buffer.is_buffer_empty(),
            previous_hypotheses=previous_hypotheses,
            previous_pred_out=previous_pred_out,
            drop_extra_pre_encoded=drop_extra,
            return_transcription=True,
        )
        elapsed = time.perf_counter() - started
        text = hypothesis_text(hypotheses)
        if text and first_piece_s is None:
            first_piece_s = elapsed
        partials.append((elapsed, text))

    total_s = time.perf_counter() - started
    return {
        "text": text,
        "partials": partials,
        "audio_s": audio_s,
        "elapsed_s": total_s,
        "first_piece_s": first_piece_s,
        "rtf": total_s / audio_s if audio_s else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path, help="16 kHz-capable wav (any rate soundfile can read)")
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--latency-ms", type=int, default=1040, choices=sorted(CHUNK_FRAMES))
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "mps"])
    parser.add_argument(
        "--expect",
        default="",
        help="Published 1040 ms text for this clip. Compared as a reproduction check, not a human reference.",
    )
    args = parser.parse_args()

    if not args.checkpoint.is_file():
        print(f"missing checkpoint: {args.checkpoint}", file=sys.stderr)
        return 1
    if not args.audio.is_file():
        print(f"missing audio: {args.audio}", file=sys.stderr)
        return 1

    device = pick_device(args.device)
    print(f"device {device}")
    print(f"checkpoint {args.checkpoint}")
    print(f"latency {args.latency_ms} ms")

    load_started = time.perf_counter()
    model = nemo_asr.models.ASRModel.restore_from(
        str(args.checkpoint), map_location=torch.device(device)
    )
    model.eval()
    model.change_decoding_strategy(OmegaConf.create({"strategy": "greedy_batch", "greedy": {}}))
    model.set_inference_prompt("th-TH")
    model.decoding.set_strip_lang_tags(True)
    print(f"load_s {time.perf_counter() - load_started:.2f}")

    result = stream_file(model, args.audio, CHUNK_FRAMES[args.latency_ms], device)
    for elapsed, text in result["partials"]:
        print(f"{elapsed:8.3f}s  {text}")
    print(f"audio_s {result['audio_s']:.3f}")
    first = result["first_piece_s"]
    print(f"first_piece_s {first:.3f}" if first is not None else "first_piece_s none")
    print(f"elapsed_s {result['elapsed_s']:.3f}")
    print(f"rtf {result['rtf']:.3f}" if result["rtf"] is not None else "rtf none")
    print(f"text {result['text']}")

    if args.expect:
        got = compact(result["text"])
        want = compact(args.expect)
        distance = edit_distance(got, want)
        cer = distance / len(want) if want else 0.0
        print(f"reproduction_cer {cer:.3f} distance {distance} against published 1040 ms text")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
