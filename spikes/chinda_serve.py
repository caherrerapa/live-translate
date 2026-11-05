#!/usr/bin/env python3
"""Translate one prompt at a time from a local ChindaMT directory.

The process reads JSON lines and writes JSON lines. It does not read audio
and it does not open a network connection. Start it with HF_HUB_OFFLINE=1.
"""

from __future__ import annotations

import json
import sys

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


def visible(text: str) -> str:
    if "</think>" in text:
        text = text.split("</think>", 1)[1]
    return text.strip()


def main() -> None:
    model, tokenizer = load(sys.argv[1])
    sampler = make_sampler(temp=0.0)
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        if message.get("cmd") == "stop":
            break
        body = message.get("prompt") or ""
        formatted = tokenizer.apply_chat_template(
            [{"role": "user", "content": body}],
            add_generation_prompt=True,
            tokenize=False,
        )
        raw = generate(
            model,
            tokenizer,
            formatted,
            max_tokens=80,
            sampler=sampler,
            verbose=False,
        )
        print(
            json.dumps({"id": message.get("id"), "text": visible(raw or "")}),
            flush=True,
        )


if __name__ == "__main__":
    main()
