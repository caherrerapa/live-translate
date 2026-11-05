#!/usr/bin/env python3
"""Time ChindaMT on a growing turn, both directions, 8-bit and bf16.

Calls follow the shipped rule: about 12 Thai characters, about 4 English
words, or the endpoint. Frames that have not grown that far are skipped.
One translation runs at a time. Lag is the generate time after the model
is loaded and one warmup call has finished.
"""

from __future__ import annotations

import gc
import sys
import time
from pathlib import Path

import mlx.core as mx
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

ROOT = Path(__file__).resolve().parents[1]
MODELS = [
    ("chindamt-4b-8bit", ROOT / "models" / "chindamt-4b-8bit"),
    ("chindamt-4b-bf16", ROOT / "models" / "chindamt-4b-bf16"),
]
ENGLISH = (
    "The meeting starts at nine. Please send the notes today. "
    "We decided to ship the translation on this machine."
)
THAI = "การประชุมเริ่มตอนเก้าโมง กรุณาส่งบันทึกในวันนี้ เราตัดสินใจว่าจะส่งการแปลบนเครื่องนี้"
ACCURATE_LAG_S = 2.0
SAMPLER = make_sampler(temp=0.0)


def english_units(text: str) -> int:
    return len([part for part in text.split() if part])


def thai_units(text: str) -> int:
    return sum(1 for ch in text if not ch.isspace())


def english_frames(text: str) -> list[str]:
    words = text.split()
    return [" ".join(words[:i]) for i in range(1, len(words) + 1)]


def thai_frames(text: str, step: int = 6) -> list[str]:
    frames: list[str] = []
    count = 0
    for index, ch in enumerate(text):
        if not ch.isspace():
            count += 1
        if count > 0 and count % step == 0 and not ch.isspace():
            frames.append(text[: index + 1])
    if not frames or frames[-1] != text:
        frames.append(text)
    return frames


def prompt_body(source: str, direction: str) -> str:
    if direction == "en-th":
        return f"Translate English to Thai.\n\nEN: {source}"
    return f"Translate Thai to English.\n\nTH: {source}"


def format_prompt(tokenizer, body: str) -> str:
    messages = [{"role": "user", "content": body}]
    return tokenizer.apply_chat_template(
        messages, add_generation_prompt=True, tokenize=False
    )


def visible(text: str) -> str:
    if "</think>" in text:
        text = text.split("</think>", 1)[1]
    return text.strip()


def has_thai(text: str) -> bool:
    return any("\u0e00" <= ch <= "\u0e7f" for ch in text)


def has_english(text: str) -> bool:
    return any(ch.isascii() and ch.isalpha() for ch in text)


def translate(model, tokenizer, source: str, direction: str) -> tuple[str, float]:
    body = prompt_body(source, direction)
    started = time.perf_counter()
    raw = generate(
        model,
        tokenizer,
        format_prompt(tokenizer, body),
        max_tokens=80,
        sampler=SAMPLER,
        verbose=False,
    )
    lag = time.perf_counter() - started
    return visible(raw or ""), lag


def accept(direction: str, source: str, translation: str) -> str | None:
    if not translation:
        return "empty translation"
    if translation.strip() == source.strip():
        return "translation copied the source"
    if direction == "en-th" and not has_thai(translation):
        return "english-to-thai result has no Thai"
    if direction == "th-en" and not has_english(translation):
        return "thai-to-english result has no English"
    if direction == "th-en" and has_thai(translation) and not has_english(translation):
        return "thai-to-english result stayed in Thai"
    return None


def run_direction(model, tokenizer, label: str, direction: str, frames: list[str], units) -> list[float]:
    threshold = 12 if direction == "th-en" else 4
    counted = 0
    lags: list[float] = []
    calls = 0
    skips = 0
    for index, frame in enumerate(frames):
        endpoint = index == len(frames) - 1
        grown = units(frame) - counted
        due = bool(frame) if endpoint else grown >= threshold
        if not due:
            skips += 1
            print(
                f"frame model={label} direction={direction} units={units(frame)} "
                f"growth={grown} action=skip",
                flush=True,
            )
            continue
        reason = "endpoint" if endpoint else "prefix-growth"
        translation, lag = translate(model, tokenizer, frame, direction)
        calls += 1
        counted = units(frame)
        problem = accept(direction, frame, translation)
        print(
            f"call model={label} direction={direction} reason={reason} "
            f"units={units(frame)} growth={grown} lag_s={lag:.3f} "
            f"in_flight=1 source={frame!r} translation={translation!r}",
            flush=True,
        )
        if problem:
            raise SystemExit(f"{label} {direction}: {problem}")
        lags.append(lag)
    print(
        f"summary model={label} direction={direction} frames={len(frames)} "
        f"calls={calls} skipped={skips} max_lag_s={max(lags):.3f}",
        flush=True,
    )
    if calls == 0 or skips == 0:
        raise SystemExit(f"{label} {direction}: expected skips and calls, calls={calls} skips={skips}")
    return lags


def run_model(label: str, path: Path) -> float:
    if not path.is_dir():
        raise SystemExit(f"missing model {path}")
    print(f"load {label} {path}", flush=True)
    model, tokenizer = load(str(path))
    warmup_source = "Hello."
    _, warmup = translate(model, tokenizer, warmup_source, "en-th")
    print(f"warmup model={label} lag_s={warmup:.3f} excluded_from_decision=1", flush=True)
    lags = []
    lags += run_direction(model, tokenizer, label, "en-th", english_frames(ENGLISH), english_units)
    lags += run_direction(model, tokenizer, label, "th-en", thai_frames(THAI), thai_units)
    peak = max(lags)
    print(f"model_max_lag_s {label} {peak:.3f}", flush=True)
    del model
    del tokenizer
    gc.collect()
    mx.metal.clear_cache()
    return peak


def main() -> None:
    peaks: dict[str, float] = {}
    for label, path in MODELS:
        peaks[label] = run_model(label, path)
    bf16 = peaks["chindamt-4b-bf16"]
    decision = "chindamt-4b-bf16" if 0 <= bf16 < ACCURATE_LAG_S else "chindamt-4b-8bit"
    print(f"bf16_max_lag_s {bf16:.3f}", flush=True)
    print(f"accurate_lag_s {ACCURATE_LAG_S:.1f}", flush=True)
    print(f"decision {decision}", flush=True)
    print("catalog_pack_stays chindamt-4b-8bit", flush=True)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(1)
