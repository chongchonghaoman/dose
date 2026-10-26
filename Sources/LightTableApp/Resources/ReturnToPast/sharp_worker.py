"""Local SHARP adapter. No network access; inputs and outputs stay in the job directory."""
import argparse
import gc
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import sys
import time

CHECKPOINT_SHA256 = "94211a75198c47f61fca7d739ba08a215418d8d398d48fddf023baccc24f073d"


def cancelled(_signal, _frame):
    raise KeyboardInterrupt("Generation cancelled")


signal.signal(signal.SIGTERM, cancelled)


def event(stage, **values):
    print(json.dumps(dict(stage=stage, **values)), flush=True)


def chunk_encoder(encoder, chunk_size):
    """Batch-independent evaluation, preserving all pixels and float32 weights."""
    import torch
    original = encoder.forward

    def forward(images):
        if len(images) <= chunk_size:
            return original(images)
        outputs, intermediates = [], {}
        for offset in range(0, len(images), chunk_size):
            features, layers = original(images[offset:offset + chunk_size])
            outputs.append(features)
            for key, value in layers.items():
                intermediates.setdefault(key, []).append(value)
            event("encoding", completed=min(offset + chunk_size, len(images)), total=len(images))
        return torch.cat(outputs, dim=0), {k: torch.cat(v, dim=0) for k, v in intermediates.items()}

    encoder.forward = forward


def load_predictor(checkpoint, create_predictor, params):
    """Create parameter shapes without allocating a second 2.6 GB weight copy."""
    import torch
    original_linspace = torch.linspace

    def cpu_linspace(*args, **kwargs):
        # timm reads scalar drop-path values during model construction.
        kwargs["device"] = "cpu"
        return original_linspace(*args, **kwargs)

    try:
        torch.linspace = cpu_linspace
        with torch.device("meta"):
            predictor = create_predictor(params)
    finally:
        torch.linspace = original_linspace
    weights = torch.load(checkpoint, map_location="cpu", weights_only=True, mmap=True)
    predictor.load_state_dict(weights, assign=True, strict=True)
    del weights
    if any(tensor.is_meta for tensor in list(predictor.parameters()) + list(predictor.buffers())):
        raise ValueError("模型包含尚未载入的参数，请重新下载运行环境。")
    return predictor.eval()


def unproject_in_chunks(gaussians, extrinsics, intrinsic, chunk_size=65536):
    """Bound covariance/SVD allocations without discarding any Gaussians."""
    import torch
    from sharp.utils.gaussians import Gaussians3D, unproject_gaussians
    count = gaussians.mean_vectors.shape[-2]
    result = Gaussians3D(*(torch.empty_like(tensor) for tensor in gaussians))
    for offset in range(0, count, chunk_size):
        end = min(offset + chunk_size, count)
        projected = unproject_gaussians(
            Gaussians3D(*(tensor[:, offset:end] for tensor in gaussians)),
            extrinsics, intrinsic, (1536, 1536),
        )
        for destination, source in zip(result, projected):
            destination[:, offset:end].copy_(source)
        event("projecting", completed=end, total=count)
    return result


def run(args):
    started = time.monotonic()
    event("loading")
    import numpy as np
    import torch
    import torch.nn.functional as F
    from sharp.models import PredictorParams, create_predictor
    from sharp.models.encoders.vit_encoder import TimmViT
    from sharp.utils import io
    from sharp.utils.gaussians import save_ply

    torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
    device = "cpu" if args.low_memory or not torch.backends.mps.is_available() else "mps"
    checkpoint = Path(args.checkpoint)
    if not checkpoint.is_file() or checkpoint.stat().st_size < 2_000_000_000:
        raise ValueError("SHARP 模型缺失或下载不完整。")
    # Production downloads are verified by the installer; direct runs can opt in.
    if args.verify_checkpoint:
        with checkpoint.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != CHECKPOINT_SHA256:
                raise ValueError("SHARP 模型校验失败，请重新下载。")
    predictor = load_predictor(checkpoint, create_predictor, PredictorParams())
    predictor.to(device)
    # Actual module boundaries; encoder completion is not overall progress.
    for name, stage in (("monodepth_model", "depth"), ("feature_model", "features"),
                        ("prediction_head", "gaussians"), ("gaussian_composer", "composing")):
        getattr(predictor, name).register_forward_pre_hook(
            lambda _module, _inputs, current_stage=stage: event(current_stage)
        )
    for module in predictor.modules():
        if isinstance(module, TimmViT):
            chunk_encoder(module, 1 if args.low_memory else 4)
    gc.collect()
    image, _, focal = io.load_rgb(Path(args.input))
    height, width = image.shape[:2]
    event("predicting", device=device, lowMemory=args.low_memory)
    with torch.inference_mode():
        pixels = torch.from_numpy(image.copy()).float().to(device).permute(2, 0, 1) / 255.0
        resized = F.interpolate(pixels[None], size=(1536, 1536), mode="bilinear", align_corners=True)
        disparity = torch.tensor([focal / width], device=device, dtype=torch.float32)
        gaussians_ndc = predictor(resized, disparity)
        # Inference is complete: release weights before covariance projection/PLY.
        gaussians_ndc = gaussians_ndc.to(torch.device("cpu"))
        del predictor, pixels, resized
        gc.collect()
        if device == "mps":
            torch.mps.empty_cache()
        event("projecting")
        intrinsic = torch.tensor([[focal, 0, width / 2, 0], [0, focal, height / 2, 0],
                                  [0, 0, 1, 0], [0, 0, 0, 1]]).float()
        intrinsic[0] *= 1536 / width
        intrinsic[1] *= 1536 / height
        gaussians = unproject_in_chunks(gaussians_ndc, torch.eye(4), intrinsic)
        del gaussians_ndc
        gc.collect()
        if device == "mps":
            torch.mps.empty_cache()
        for tensor in gaussians:
            if not torch.isfinite(tensor).all():
                raise ValueError("生成结果含无效数值，请更换照片重试。")
        event("saving")
        output = Path(args.output)
        output.mkdir(parents=True, exist_ok=True)
        temporary_ply = output / "scene.partial.ply"
        save_ply(gaussians, focal, (height, width), temporary_ply)
        os.replace(temporary_ply, output / "scene.ply")
        depth = float(gaussians.mean_vectors[..., 2].median())
    metadata = dict(width=width, height=height, focal=float(focal), depth=max(0.1, depth),
                    count=int(gaussians.mean_vectors.shape[-2]), device=device,
                    lowMemory=args.low_memory, seconds=time.monotonic() - started,
                    peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    temporary_metadata = output / "scene.partial.json"
    temporary_metadata.write_text(json.dumps(metadata))
    os.replace(temporary_metadata, output / "scene.json")
    event("complete", **metadata)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--low-memory", action="store_true")
    parser.add_argument("--verify-checkpoint", action="store_true")
    try:
        run(parser.parse_args())
    except KeyboardInterrupt:
        event("cancelled")
        sys.exit(130)
    except Exception as error:
        event("error", message=str(error))
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
