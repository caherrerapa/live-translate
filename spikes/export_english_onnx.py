#!/usr/bin/env python3
"""Export Nemotron 3.5 English streaming 0.6B at the Accurate 1120 ms point.

set_export_config runs first. It rebuilds the default streaming config, so the
trained context is applied after that: set_default_att_context_size([56, 13]).
1120 // 80 - 1 = 13. This is not Typhoon's setup_streaming_params override.
The cache width stays the trained left context, 56.
"""

from __future__ import annotations

import argparse
import inspect
import json
import os
from pathlib import Path

import nemo.collections.asr as nemo_asr
import onnx
import torch
from omegaconf import DictConfig, ListConfig, OmegaConf

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CHECKPOINT = ROOT / "models" / "nemotron-3.5-asr-streaming-0.6b.nemo"
# Trained right-context frames. 80 ms is [56, 0], 320 ms is [56, 3], 1120 ms is [56, 13].
RIGHT_CONTEXT_BY_MS = {80: 0, 320: 3, 560: 6, 1120: 13}
RIGHT_CONTEXT = 13  # 1120 ms
LATENCY_MS = 1120
PINNED_ACCURATE_DIR = "nemotron-en-1120"

ENCODER_INPUT_NAMES = [
    "audio_signal",
    "length",
    "cache_last_channel",
    "cache_last_time",
    "cache_last_channel_len",
    "prompt_index",
]
ENCODER_OUTPUT_NAMES = [
    "outputs",
    "encoded_lengths",
    "cache_last_channel_next",
    "cache_last_time_next",
    "cache_last_channel_next_len",
]


def plain(obj):
    if isinstance(obj, (DictConfig, ListConfig)):
        return OmegaConf.to_container(obj, resolve=True)
    return obj


class PromptedStreamingEncoder(torch.nn.Module):
    def __init__(self, asr_model):
        super().__init__()
        self.encoder = asr_model.encoder
        self.prompt_kernel = asr_model.prompt_kernel
        self.num_prompts = int(asr_model.num_prompts)

    def forward(
        self,
        audio_signal,
        length,
        cache_last_channel,
        cache_last_time,
        cache_last_channel_len,
        prompt_index,
    ):
        encoded, encoded_len, channel_next, time_next, channel_len_next = (
            self.encoder.forward_for_export(
                audio_signal=audio_signal,
                length=length,
                cache_last_channel=cache_last_channel,
                cache_last_time=cache_last_time,
                cache_last_channel_len=cache_last_channel_len,
            )
        )
        out_dtype = encoded.dtype
        encoded = encoded.transpose(1, 2)
        batch, time_steps, _ = encoded.shape
        prompt = torch.zeros(
            batch,
            time_steps,
            self.num_prompts,
            dtype=encoded.dtype,
            device=encoded.device,
        )
        prompt.scatter_(
            2,
            prompt_index.view(batch, 1, 1).expand(-1, time_steps, -1),
            1.0,
        )
        encoded = self.prompt_kernel(torch.cat([encoded, prompt], dim=-1)).to(out_dtype)
        encoded = encoded.transpose(1, 2)
        return encoded, encoded_len, channel_next, time_next, channel_len_next


def save_tokens(vocabulary: list[str], path: Path) -> None:
    bad = [token for token in vocabulary if any(ch.isspace() for ch in token)]
    if bad:
        raise SystemExit(f"{len(bad)} vocabulary tokens contain whitespace, for example {bad[:3]!r}")
    with path.open("w", encoding="utf-8") as handle:
        for index, token in enumerate(vocabulary):
            handle.write(f"{token} {index}\n")
        handle.write(f"<blk> {len(vocabulary)}\n")


def add_meta_data(path: Path, meta: dict) -> None:
    model = onnx.load(path)
    while len(model.metadata_props):
        model.metadata_props.pop()
    for key, value in meta.items():
        prop = model.metadata_props.add()
        prop.key = key
        prop.value = str(value)
    data_path = path.with_suffix(".data")
    data_path.unlink(missing_ok=True)
    onnx.save(
        model,
        path,
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location=data_path.name,
    )


def second(value):
    return value[1] if isinstance(value, list) else value


@torch.no_grad()
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--latency-ms", type=int, required=True, choices=sorted(RIGHT_CONTEXT_BY_MS))
    args = parser.parse_args()
    if args.out.name == PINNED_ACCURATE_DIR:
        raise SystemExit(f"refusing to overwrite the pinned Accurate graph {args.out}")
    global RIGHT_CONTEXT, LATENCY_MS
    LATENCY_MS = args.latency_ms
    RIGHT_CONTEXT = RIGHT_CONTEXT_BY_MS[args.latency_ms]
    args.out.mkdir(parents=True, exist_ok=True)

    model = nemo_asr.models.ASRModel.restore_from(str(args.checkpoint), map_location="cpu")
    model.eval()
    model.set_export_config({"cache_support": True})
    model.encoder.set_default_att_context_size([56, RIGHT_CONTEXT])
    streaming = model.encoder.streaming_cfg
    att = [int(v) for v in model.encoder.att_context_size]
    cache = int(streaming.last_channel_cache_size)
    print("att_context_size", att)
    print("last_channel_cache_size", cache)
    print("streaming_cfg", streaming)
    if att != [56, RIGHT_CONTEXT] or cache != 56:
        raise SystemExit(
            f"refusing to export att={att} cache={cache}; expected [56, {RIGHT_CONTEXT}] with cache 56"
        )

    feature_chunk = second(streaming.chunk_size)
    pre_encode = second(streaming.pre_encode_cache_size)
    window_size = int(feature_chunk + pre_encode)
    print("feature_chunk", feature_chunk, "pre_encode", pre_encode, "window", window_size)

    channel_dim1 = len(model.encoder.layers)
    channel_dim2 = cache
    channel_dim3 = int(model.encoder.d_model)
    time_dim1 = channel_dim1
    time_dim2 = channel_dim3
    time_dim3 = int(model.encoder.conv_context_size[0])
    feat_dim = int(model.cfg.preprocessor.features)
    prompts = plain(model.cfg.model_defaults.prompt_dictionary)
    prompt_id = int(prompts["en-US"])
    print("en-US", prompt_id)

    device, dtype = next(model.encoder.parameters()).device, next(model.encoder.parameters()).dtype
    audio = torch.zeros(1, feat_dim, window_size, dtype=dtype, device=device)
    length = torch.full((1,), window_size, dtype=torch.int64, device=device)
    cache_channel = torch.zeros(1, channel_dim1, channel_dim2, channel_dim3, dtype=dtype, device=device)
    cache_time = torch.zeros(1, time_dim1, time_dim2, time_dim3, dtype=dtype, device=device)
    cache_len = torch.zeros(1, dtype=torch.int64, device=device)
    prompt_index = torch.full((1,), prompt_id, dtype=torch.int64, device=device)

    os.chdir(args.out)
    export_kwargs = {}
    signature = inspect.signature(torch.onnx.export)
    if "dynamo" in signature.parameters:
        export_kwargs["dynamo"] = False
    if "external_data" in signature.parameters:
        export_kwargs["external_data"] = True

    torch.onnx.export(
        PromptedStreamingEncoder(model).eval(),
        (audio, length, cache_channel, cache_time, cache_len, prompt_index),
        "encoder.export.onnx",
        input_names=ENCODER_INPUT_NAMES,
        output_names=ENCODER_OUTPUT_NAMES,
        opset_version=13,
        dynamic_axes={
            "audio_signal": {0: "batch", 2: "time"},
            "length": {0: "batch"},
            "cache_last_channel": {0: "batch"},
            "cache_last_time": {0: "batch"},
            "cache_last_channel_len": {0: "batch"},
            "prompt_index": {0: "batch"},
            "outputs": {0: "batch", 2: "time"},
            "encoded_lengths": {0: "batch"},
            "cache_last_channel_next": {0: "batch"},
            "cache_last_time_next": {0: "batch"},
            "cache_last_channel_next_len": {0: "batch"},
        },
        **export_kwargs,
    )
    exported = onnx.load("encoder.export.onnx", load_external_data=True)
    onnx.save_model(
        exported,
        "encoder.onnx",
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location="encoder.data",
        size_threshold=0,
    )
    for scratch in Path(".").glob("encoder.export.onnx*"):
        scratch.unlink()

    model.decoder.export("decoder.onnx")
    model.joint.export("joiner.onnx")
    save_tokens(list(model.joint.vocabulary), Path("tokens.txt"))

    normalize = model.cfg.preprocessor.normalize
    if normalize == "NA":
        normalize = ""
    meta = {
        "vocab_size": model.decoder.vocab_size,
        "window_size": window_size,
        "chunk_size_ms": LATENCY_MS,
        "chunk_shift": int(feature_chunk),
        "normalize_type": normalize,
        "cache_last_channel_dim1": channel_dim1,
        "cache_last_channel_dim2": channel_dim2,
        "cache_last_channel_dim3": channel_dim3,
        "cache_last_time_dim1": time_dim1,
        "cache_last_time_dim2": time_dim2,
        "cache_last_time_dim3": time_dim3,
        "pred_rnn_layers": model.decoder.pred_rnn_layers,
        "pred_hidden": model.decoder.pred_hidden,
        "subsampling_factor": 8,
        "feat_dim": feat_dim,
        "model_type": type(model).__name__,
        "version": "1",
        "model_author": "NVIDIA",
        "url": "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b",
        "comment": f"Transducer branch only. Trained chunk {LATENCY_MS} ms, prompt en-US.",
        "prompt_dictionary": json.dumps({str(k): int(v) for k, v in prompts.items()}, sort_keys=True),
        "auto_prompt_id": int(prompts["auto"]),
    }
    print("meta", {k: v for k, v in meta.items() if k != "prompt_dictionary"})
    add_meta_data(Path("encoder.onnx"), meta)
    for name in ("encoder.onnx", "encoder.data", "decoder.onnx", "joiner.onnx", "tokens.txt"):
        path = Path(name)
        print(f"{name} {path.stat().st_size if path.exists() else 'MISSING'}")


if __name__ == "__main__":
    main()
