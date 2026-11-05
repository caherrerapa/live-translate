#!/usr/bin/env python3
"""Export Typhoon ASR Streaming 0.6B to a cache-aware ONNX transducer.

The prompted-encoder graph follows sherpa-onnx's Nemotron 3.5 exporter
(scripts/nemo/nemotron-3.5-asr-streaming-0.6b/export_onnx.py): prompt_index
is an input, and the encoder carries its attention and convolution caches.
The chunk is Typhoon's Accurate preset, not Nemotron's 1120 ms point:
setup_streaming_params(chunk_size=13) is 13 encoder frames, 1040 ms.
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
DEFAULT_CHECKPOINT = ROOT / "models" / "typhoon-asr-streaming-nemotron-0.6b.nemo"
# 1 encoder frame = 80 ms. 13 frames is the Accurate preset.
CHUNK_FRAMES = 13
LEFT_CHUNKS = 2
LATENCY_MS = CHUNK_FRAMES * 80

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


def add_meta_data(path: Path, meta: dict[str, str]) -> None:
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
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    model = nemo_asr.models.ASRModel.restore_from(str(args.checkpoint), map_location="cpu")
    model.eval()
    # set_export_config rebuilds the default streaming config. The Accurate
    # preset has to be applied after that, or the attention mask is sized for
    # the 320 ms default while the cache tensor is sized for 1040 ms.
    model.set_export_config({"cache_support": True})
    model.encoder.setup_streaming_params(
        chunk_size=CHUNK_FRAMES,
        left_chunks=LEFT_CHUNKS,
        shift_size=CHUNK_FRAMES,
    )
    streaming = model.encoder.streaming_cfg
    print("streaming_cfg", streaming)

    feature_chunk = second(streaming.chunk_size)
    pre_encode = second(streaming.pre_encode_cache_size)
    window_size = int(feature_chunk + pre_encode)
    print(
        "feature_chunk",
        feature_chunk,
        "pre_encode",
        pre_encode,
        "window",
        window_size,
        "cache_channel",
        streaming.last_channel_cache_size,
    )

    channel_dim1 = len(model.encoder.layers)
    channel_dim2 = int(streaming.last_channel_cache_size)
    channel_dim3 = int(model.encoder.d_model)
    time_dim1 = channel_dim1
    time_dim2 = channel_dim3
    time_dim3 = int(model.encoder.conv_context_size[0])
    feat_dim = int(model.cfg.preprocessor.features)
    prompt_id = int(plain(model.cfg.model_defaults.prompt_dictionary)["th-TH"])

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
    prompts = plain(model.cfg.model_defaults.prompt_dictionary)
    meta = {
        "vocab_size": model.decoder.vocab_size,
        "window_size": window_size,
        "chunk_size_ms": LATENCY_MS,
        "chunk_shift": int(feature_chunk),
        "encoder_chunk_frames": CHUNK_FRAMES,
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
        "model_author": "Typhoon",
        "url": "https://huggingface.co/typhoon-ai/typhoon-asr-streaming-nemotron-0.6b",
        "comment": "Transducer branch only. Accurate preset, 1040 ms.",
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
