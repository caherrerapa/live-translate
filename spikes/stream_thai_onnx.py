#!/usr/bin/env python3
"""Stream a wav through the exported Typhoon 0.6B ONNX transducer.

The graph is models/onnx/typhoon-0.6b-1040, produced by export_typhoon_onnx.py.
sherpa-onnx feeds 16 kHz audio and keeps the cache. Language is th-TH.
"""

from __future__ import annotations

import argparse
import time
from datetime import datetime
from pathlib import Path

import sherpa_onnx
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = ROOT / "models" / "onnx" / "typhoon-0.6b-1040"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--language", default="th-TH")
    args = parser.parse_args()

    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=str(args.model / "tokens.txt"),
        encoder=str(args.model / "encoder.onnx"),
        decoder=str(args.model / "decoder.onnx"),
        joiner=str(args.model / "joiner.onnx"),
        num_threads=4,
        sample_rate=16000,
        feature_dim=128,
        decoding_method="greedy_search",
        provider="cpu",
    )
    audio, sample_rate = sf.read(args.audio, dtype="float32")
    if sample_rate != 16000:
        raise SystemExit(f"{args.audio} is {sample_rate} Hz, expected 16000")

    stream = recognizer.create_stream()
    stream.set_option("language", args.language)
    chunk = int(1.040 * sample_rate)
    started = time.perf_counter()
    first_piece = None
    previous = ""
    for start in range(0, len(audio), chunk):
        stream.accept_waveform(sample_rate, audio[start : start + chunk])
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        text = recognizer.get_result(stream).strip()
        if text and text != previous:
            now = time.perf_counter() - started
            if first_piece is None:
                first_piece = now
            stamp = datetime.now().isoformat(timespec="milliseconds")
            print(f"{stamp} +{now:8.3f}s  {text}", flush=True)
            previous = text
    stream.input_finished()
    while recognizer.is_ready(stream):
        recognizer.decode_stream(stream)
    elapsed = time.perf_counter() - started
    audio_s = len(audio) / sample_rate
    text = recognizer.get_result(stream).strip()
    if text and text != previous:
        stamp = datetime.now().isoformat(timespec="milliseconds")
        print(f"{stamp} +{elapsed:8.3f}s  {text}", flush=True)
    rtf = elapsed / audio_s if audio_s else 99
    print(f"audio_s {audio_s:.3f}")
    print(f"first_piece_s {first_piece:.3f}" if first_piece is not None else "first_piece_s none")
    print(f"elapsed_s {elapsed:.3f}")
    print(f"rtf {rtf:.3f}")
    print(f"text {text}")
    thai = [ch for ch in text if "\u0e00" <= ch <= "\u0e7f"]
    if not thai:
        raise SystemExit("thai text was empty")
    if rtf >= 0.5:
        raise SystemExit(f"rtf {rtf:.3f} is not under 0.5")


if __name__ == "__main__":
    main()
