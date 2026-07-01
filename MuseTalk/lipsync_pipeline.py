"""
MuseTalk lip-sync pipeline for a single static source image.

CoreML nets (UNet, VAE encoder/decoder) handle the per-frame hot path; the rest
(Whisper audio features, DWPose face crop, BiSeNet blending) runs in torch/ONNX
on CPU. Source is one portrait whose mouth is animated to the input audio.
"""
import math
import os
import subprocess
import tempfile

import cv2
import numpy as np
import torch

from transformers import WhisperModel

from musetalk.models.unet import PositionalEncoding
from musetalk.utils.audio_processor import AudioProcessor
from musetalk.utils.face_parsing import FaceParsing
from musetalk.utils.blending import get_image_prepare_material, get_image_blending
from dwpose_onnx import DWPoseDetector, face_bbox_from_keypoints

BASE = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(BASE, "..", "models")
WHISPER_DIR = os.path.join(MODELS_DIR, "whisper")
DWPOSE_DIR = os.path.join(MODELS_DIR, "dwpose_onnx")


# Cap the working resolution: per-frame PNG encode + mp4 mux cost scales with
# frame area, so a large source photo (e.g. 1376×768) pushes render past
# real-time. 768 on the long side keeps the face crisp and render sustainable.
MAX_SIDE = 768


def _cap_size(img):
    h, w = img.shape[:2]
    longest = max(h, w)
    scale = MAX_SIDE / longest if longest > MAX_SIDE else 1.0
    nw = int(round(w * scale)) & ~1   # force even — libx264 requires it
    nh = int(round(h * scale)) & ~1
    if (nw, nh) == (w, h):
        return img
    return cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)


def _ct_out(result):
    """Extract the single output array from a coremltools predict() result."""
    return np.asarray(next(iter(result.values())), dtype=np.float32)


def _preprocess_face(crop_bgr, half_mask):
    """Replicates VAE.preprocess_img: 256 RGB, [-1,1], optional bottom-half mask."""
    img = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB)
    img = cv2.resize(img, (256, 256), interpolation=cv2.INTER_LANCZOS4)
    x = img.astype(np.float32) / 255.0
    if half_mask:
        x[128:, :, :] = 0.0  # zero bottom half -> becomes -1 after normalize
    x = (x - 0.5) / 0.5
    x = x.transpose(2, 0, 1)[None]  # [1,3,256,256]
    return np.ascontiguousarray(x, dtype=np.float32)


class LipSyncPipeline:
    def __init__(self, coreml_models):
        """coreml_models: dict with 'unet', 'vae_encoder', 'vae_decoder' MLModels."""
        self.unet = coreml_models["unet"]
        self.vae_enc = coreml_models["vae_encoder"]
        self.vae_dec = coreml_models["vae_decoder"]

        print("Loading DWPose ONNX...", flush=True)
        self.dwpose = DWPoseDetector(
            os.path.join(DWPOSE_DIR, "yolox_l.onnx"),
            os.path.join(DWPOSE_DIR, "dw-ll_ucoco_384.onnx"),
        )
        print("Loading Whisper...", flush=True)
        self.audio_processor = AudioProcessor(feature_extractor_path=WHISPER_DIR)
        self.whisper = WhisperModel.from_pretrained("openai/whisper-tiny").to("cpu").eval()
        self.whisper.requires_grad_(False)
        self.pe = PositionalEncoding(d_model=384)
        print("Loading FaceParsing...", flush=True)
        self.face_parser = FaceParsing(left_cheek_width=90, right_cheek_width=90)
        self._warmup()
        print("Pipeline ready.", flush=True)

    def _warmup(self):
        """Run each model once with synthetic inputs so the first real request
        doesn't pay cold-start latency (first CoreML predict / whisper pass)."""
        from PIL import Image
        print("Warming up models...", flush=True)
        for _ in range(2):
            self.vae_enc.predict({"image": np.zeros((1, 3, 256, 256), np.float32)})
            self.unet.predict({"sample": np.zeros((1, 8, 32, 32), np.float32),
                               "audio": np.zeros((1, 50, 384), np.float32)})
            self.vae_dec.predict({"latent": np.zeros((1, 4, 32, 32), np.float32)})
        with torch.no_grad():
            self.whisper.encoder(torch.zeros(1, 80, 3000))
        self.face_parser(Image.new("RGB", (256, 256)), mode="jaw")

    # ── source preparation (once per image) ──────────────────────────────────

    def _prepare_source(self, image_bgr):
        kpts, _ = self.dwpose.detect(image_bgr)
        bbox = face_bbox_from_keypoints(kpts, image_bgr.shape)
        x1, y1, x2, y2 = bbox
        crop = image_bgr[y1:y2, x1:x2]

        masked_lat = _ct_out(self.vae_enc.predict({"image": _preprocess_face(crop, True)}))
        ref_lat = _ct_out(self.vae_enc.predict({"image": _preprocess_face(crop, False)}))
        latent8 = np.concatenate([masked_lat, ref_lat], axis=1).astype(np.float32)

        mask, crop_box = get_image_prepare_material(
            image_bgr, bbox, fp=self.face_parser, mode="jaw"
        )
        return bbox, latent8, mask, crop_box

    # ── audio features (once per clip) ───────────────────────────────────────

    def _audio_chunks(self, wav_path, fps):
        feats, length = self.audio_processor.get_audio_feature(
            wav_path, weight_dtype=torch.float32
        )
        chunks = self.audio_processor.get_whisper_chunk(
            feats, "cpu", torch.float32, self.whisper, length, fps=fps,
            audio_padding_length_left=2, audio_padding_length_right=2,
        )
        return chunks  # [T, 50, 384]

    # ── per-frame inference ──────────────────────────────────────────────────

    def _render_frame(self, audio_chunk, latent8, ori_frame, bbox, mask, crop_box):
        audio = self.pe(audio_chunk.unsqueeze(0)).numpy().astype(np.float32)  # [1,50,384]
        pred = _ct_out(self.unet.predict({"sample": latent8, "audio": audio}))
        img = _ct_out(self.vae_dec.predict({"latent": pred.astype(np.float32)}))
        img = (img[0] / 2 + 0.5).clip(0, 1)
        img = (img.transpose(1, 2, 0) * 255).round().astype(np.uint8)[:, :, ::-1]  # RGB->BGR
        x1, y1, x2, y2 = bbox
        res = cv2.resize(img.astype(np.uint8), (x2 - x1, y2 - y1))
        return get_image_blending(ori_frame, res, bbox, mask, crop_box)

    # ── public entry ─────────────────────────────────────────────────────────

    def run(self, image_path, audio_path, out_path, fps=25):
        image_bgr = cv2.imread(image_path)
        if image_bgr is None:
            raise ValueError(f"could not read image {image_path}")
        image_bgr = _cap_size(image_bgr)

        bbox, latent8, mask, crop_box = self._prepare_source(image_bgr)
        chunks = self._audio_chunks(audio_path, fps)
        num_frames = len(chunks)
        if num_frames == 0:
            raise ValueError("no audio frames produced")

        tmp = tempfile.mkdtemp(prefix="musetalk_")
        for i in range(num_frames):
            frame = self._render_frame(
                chunks[i], latent8, image_bgr.copy(), bbox, mask, crop_box
            )
            cv2.imwrite(os.path.join(tmp, f"{i:08d}.png"), frame)

        silent = os.path.join(tmp, "silent.mp4")
        subprocess.run(
            ["ffmpeg", "-y", "-v", "warning", "-r", str(fps), "-f", "image2",
             "-i", os.path.join(tmp, "%08d.png"),
             "-vcodec", "libx264", "-vf", "format=yuv420p", "-crf", "18", silent],
            check=True,
        )
        subprocess.run(
            ["ffmpeg", "-y", "-v", "warning", "-i", audio_path, "-i", silent,
             "-c:v", "copy", "-c:a", "aac", "-shortest", out_path],
            check=True,
        )
        return out_path, num_frames

    def run_segments(self, image_path, audio_path, fps=10, seg_frames=10):
        """Generator: render in groups of seg_frames, yielding a self-contained
        mp4 (video slice + matching audio slice) per group for low-latency
        streaming playback. Source preparation + audio features happen once."""
        image_bgr = cv2.imread(image_path)
        if image_bgr is None:
            raise ValueError(f"could not read image {image_path}")
        image_bgr = _cap_size(image_bgr)

        bbox, latent8, mask, crop_box = self._prepare_source(image_bgr)
        chunks = self._audio_chunks(audio_path, fps)
        num_frames = len(chunks)
        if num_frames == 0:
            raise ValueError("no audio frames produced")

        # Ramp segment sizes: small first segments → playback starts sooner,
        # then full seg_frames to keep AVQueuePlayer boundaries infrequent.
        sizes, remaining = [], num_frames
        for r in (3, 6):
            if remaining <= 0:
                break
            s = min(r, remaining)
            sizes.append(s)
            remaining -= s
        while remaining > 0:
            s = min(seg_frames, remaining)
            sizes.append(s)
            remaining -= s

        h, w = image_bgr.shape[:2]
        tmp = tempfile.mkdtemp(prefix="musetalk_seg_")
        seg_start = 0
        for idx, size in enumerate(sizes):
            seg_end = seg_start + size
            n = seg_end - seg_start
            t0 = seg_start / fps
            dur = n / fps
            seg_mp4 = os.path.join(tmp, f"seg{idx}.mp4")

            # Pipe raw BGR frames straight into ffmpeg (no PNG encode/decode) —
            # this is what keeps per-frame cost near the model floor.
            proc = subprocess.Popen(
                ["ffmpeg", "-y", "-v", "error",
                 "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}",
                 "-r", str(fps), "-i", "-",
                 "-ss", f"{t0:.3f}", "-i", audio_path, "-t", f"{dur:.3f}",
                 "-map", "0:v", "-map", "1:a",
                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                 "-shortest", seg_mp4],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            for i in range(seg_start, seg_end):
                frame = self._render_frame(
                    chunks[i], latent8, image_bgr.copy(), bbox, mask, crop_box
                )
                proc.stdin.write(np.ascontiguousarray(frame, dtype=np.uint8).tobytes())
            proc.stdin.close()
            if proc.wait() != 0:
                raise RuntimeError("ffmpeg segment encode failed")

            with open(seg_mp4, "rb") as f:
                yield f.read()
            seg_start = seg_end


if __name__ == "__main__":
    # quick standalone test
    import sys, time
    import coremltools as ct

    pkg = os.path.join(BASE, "mlpackage")
    models = {
        n: ct.models.MLModel(os.path.join(pkg, f"{n}.mlpackage"),
                             compute_units=ct.ComputeUnit.ALL)
        for n in ["vae_encoder", "unet", "vae_decoder"]
    }
    pipe = LipSyncPipeline(models)
    img, wav, out = sys.argv[1], sys.argv[2], sys.argv[3]
    t0 = time.time()
    _, n = pipe.run(img, wav, out)
    dt = time.time() - t0
    print(f"Rendered {n} frames in {dt:.1f}s ({n/dt:.1f} fps) -> {out}")
