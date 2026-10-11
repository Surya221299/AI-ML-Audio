"""
MuseTalk Lip-Sync Pipeline.
Supports both CoreML (.mlpackage on Apple Silicon) and PyTorch (CUDA on Cloud GPU).

Accepts a static source portrait + audio file and renders lip-synced video.
"""

import math
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, Generator, Optional, Tuple

import cv2
import numpy as np
import torch
from transformers import WhisperModel

from backend.core.config import MODELS_DIR
from backend.lipsync.musetalk.models.unet import PositionalEncoding
from backend.lipsync.musetalk.utils.audio_processor import AudioProcessor
from backend.lipsync.musetalk.utils.face_parsing import FaceParsing
from backend.lipsync.musetalk.utils.blending import get_image_prepare_material, get_image_blending
from backend.lipsync.dwpose_onnx import DWPoseDetector, face_bbox_from_keypoints

WHISPER_DIR = str(MODELS_DIR / "whisper")
DWPOSE_DIR = str(MODELS_DIR / "dwpose_onnx")
MUSETALK_DIR = str(MODELS_DIR / "musetalkV15")
SD_VAE_DIR = str(MODELS_DIR / "sd-vae")

MAX_SIDE = 768
TARGET_ASPECT = 16 / 9


def _crop_to_aspect(img: np.ndarray, aspect: float) -> np.ndarray:
    h, w = img.shape[:2]
    if w / h > aspect:
        new_w = int(h * aspect) & ~1
        x0 = (w - new_w) // 2
        return img[:, x0:x0 + new_w]
    new_h = int(w / aspect) & ~1
    y0 = (h - new_h) // 2
    return img[y0:y0 + new_h, :]


def _cap_size(img: np.ndarray) -> np.ndarray:
    img = _crop_to_aspect(img, TARGET_ASPECT)
    h, w = img.shape[:2]
    longest = max(h, w)
    scale = MAX_SIDE / longest if longest > MAX_SIDE else 1.0
    nw = int(round(w * scale)) & ~1
    nh = int(round(nw / TARGET_ASPECT)) & ~1
    if (nw, nh) == (w, h):
        return img
    return cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)


def _ct_out(result) -> np.ndarray:
    """Extract single numpy array from CoreML prediction dict."""
    return np.asarray(next(iter(result.values())), dtype=np.float32)


def _preprocess_face(crop_bgr: np.ndarray, half_mask: bool) -> np.ndarray:
    """Prepare 256x256 RGB [-1, 1] face tensor with optional bottom mask."""
    img = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB)
    img = cv2.resize(img, (256, 256), interpolation=cv2.INTER_LANCZOS4)
    x = img.astype(np.float32) / 255.0
    if half_mask:
        x[128:, :, :] = 0.0
    x = (x - 0.5) / 0.5
    x = x.transpose(2, 0, 1)[None]  # [1, 3, 256, 256]
    return np.ascontiguousarray(x, dtype=np.float32)


class LipSyncPipeline:
    def __init__(self, coreml_models: Optional[Dict] = None, device: str = "cpu"):
        self.device = device
        self.coreml_models = coreml_models
        self.is_coreml = coreml_models is not None

        if self.is_coreml:
            self.unet = coreml_models["unet"]
            self.vae_enc = coreml_models["vae_encoder"]
            self.vae_dec = coreml_models["vae_decoder"]
        else:
            # PyTorch CUDA / CPU mode
            from backend.lipsync.musetalk.models.vae import VAE
            from backend.lipsync.musetalk.models.unet import UNet
            print(f"[LipSyncPipeline] Initializing PyTorch models on {self.device}...", flush=True)
            self.pt_vae = VAE(model_path=SD_VAE_DIR)
            self.pt_unet = UNet(
                unet_config=os.path.join(MUSETALK_DIR, "musetalk.json"),
                model_path=os.path.join(MUSETALK_DIR, "unet.pth"),
                device=torch.device(self.device),
            )
            self.pt_timesteps = torch.tensor([0], device=self.device)

        print("[LipSyncPipeline] Loading DWPose ONNX...", flush=True)
        self.dwpose = DWPoseDetector(
            os.path.join(DWPOSE_DIR, "yolox_l.onnx"),
            os.path.join(DWPOSE_DIR, "dw-ll_ucoco_384.onnx"),
        )

        print("[LipSyncPipeline] Loading Whisper...", flush=True)
        self.audio_processor = AudioProcessor(feature_extractor_path=WHISPER_DIR)
        self.whisper = WhisperModel.from_pretrained("openai/whisper-tiny").to("cpu").eval()
        self.whisper.requires_grad_(False)
        self.pe = PositionalEncoding(d_model=384)

        print("[LipSyncPipeline] Loading FaceParsing...", flush=True)
        self.face_parser = FaceParsing(left_cheek_width=90, right_cheek_width=90)
        self._warmup()
        print("[LipSyncPipeline] ✓ Ready.", flush=True)

    def _warmup(self):
        from PIL import Image
        print("[LipSyncPipeline] Warming up...", flush=True)
        if self.is_coreml:
            for _ in range(2):
                self.vae_enc.predict({"image": np.zeros((1, 3, 256, 256), np.float32)})
                self.unet.predict({
                    "sample": np.zeros((1, 8, 32, 32), np.float32),
                    "audio": np.zeros((1, 50, 384), np.float32),
                })
                self.vae_dec.predict({"latent": np.zeros((1, 4, 32, 32), np.float32)})
        with torch.no_grad():
            self.whisper.encoder(torch.zeros(1, 80, 3000))
        self.face_parser(Image.new("RGB", (256, 256)), mode="jaw")

    def _prepare_source(self, image_bgr: np.ndarray):
        kpts, _ = self.dwpose.detect(image_bgr)
        bbox = face_bbox_from_keypoints(kpts, image_bgr.shape)
        x1, y1, x2, y2 = bbox
        crop = image_bgr[y1:y2, x1:x2]

        if self.is_coreml:
            masked_lat = _ct_out(self.vae_enc.predict({"image": _preprocess_face(crop, True)}))
            ref_lat = _ct_out(self.vae_enc.predict({"image": _preprocess_face(crop, False)}))
            latent8 = np.concatenate([masked_lat, ref_lat], axis=1).astype(np.float32)
        else:
            with torch.no_grad():
                img_masked = torch.from_numpy(_preprocess_face(crop, True)).to(self.device)
                img_ref = torch.from_numpy(_preprocess_face(crop, False)).to(self.device)
                m_lat = self.pt_vae.vae.encode(img_masked).latent_dist.sample() * 0.18215
                r_lat = self.pt_vae.vae.encode(img_ref).latent_dist.sample() * 0.18215
                latent8 = torch.cat([m_lat, r_lat], dim=1)

        mask, crop_box = get_image_prepare_material(
            image_bgr, bbox, fp=self.face_parser, mode="jaw"
        )
        return bbox, latent8, mask, crop_box

    def _audio_chunks(self, wav_path: str, fps: int):
        feats, length = self.audio_processor.get_audio_feature(
            wav_path, weight_dtype=torch.float32
        )
        chunks = self.audio_processor.get_whisper_chunk(
            feats, "cpu", torch.float32, self.whisper, length, fps=fps,
            audio_padding_length_left=2, audio_padding_length_right=2,
        )
        return chunks

    def _render_frame(self, audio_chunk, latent8, ori_frame, bbox, mask, crop_box) -> np.ndarray:
        if self.is_coreml:
            audio = self.pe(audio_chunk.unsqueeze(0)).numpy().astype(np.float32)
            pred = _ct_out(self.unet.predict({"sample": latent8, "audio": audio}))
            img = _ct_out(self.vae_dec.predict({"latent": pred.astype(np.float32)}))
            img = (img[0] / 2 + 0.5).clip(0, 1)
            img = (img.transpose(1, 2, 0) * 255).round().astype(np.uint8)[:, :, ::-1]
        else:
            with torch.no_grad():
                audio = self.pe(audio_chunk.unsqueeze(0)).to(self.device)
                pred = self.pt_unet.model(
                    latent8, self.pt_timesteps, encoder_hidden_states=audio
                ).sample
                dec = self.pt_vae.vae.decode(pred / 0.18215).sample
                img = (dec[0] / 2 + 0.5).clamp(0, 1).cpu().numpy()
                img = (img.transpose(1, 2, 0) * 255).round().astype(np.uint8)[:, :, ::-1]

        x1, y1, x2, y2 = bbox
        res = cv2.resize(img.astype(np.uint8), (x2 - x1, y2 - y1))
        return get_image_blending(ori_frame, res, bbox, mask, crop_box)

    def run(self, image_path: str, audio_path: str, out_path: str, fps: int = 25) -> Tuple[str, int]:
        image_bgr = cv2.imread(image_path)
        if image_bgr is None:
            raise ValueError(f"Could not read image {image_path}")
        image_bgr = _cap_size(image_bgr)

        bbox, latent8, mask, crop_box = self._prepare_source(image_bgr)
        chunks = self._audio_chunks(audio_path, fps)
        num_frames = len(chunks)
        if num_frames == 0:
            raise ValueError("No audio frames produced")

        tmp = tempfile.mkdtemp(prefix="musetalk_")
        for i in range(num_frames):
            frame = self._render_frame(
                chunks[i], latent8, image_bgr.copy(), bbox, mask, crop_box
            )
            cv2.imwrite(os.path.join(tmp, f"{i:08d}.png"), frame)

        silent = os.path.join(tmp, "silent.mp4")
        subprocess.run(
            [
                "ffmpeg", "-y", "-v", "warning", "-r", str(fps), "-f", "image2",
                "-i", os.path.join(tmp, "%08d.png"),
                "-vcodec", "libx264", "-vf", "format=yuv420p", "-crf", "18", silent,
            ],
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg", "-y", "-v", "warning", "-i", audio_path, "-i", silent,
                "-c:v", "copy", "-c:a", "aac", "-shortest", out_path,
            ],
            check=True,
        )
        return out_path, num_frames

    def run_segments(
        self, image_path: str, audio_path: str, fps: int = 10, seg_frames: int = 10
    ) -> Generator[bytes, None, None]:
        """Low-latency streaming generator yielding standalone MP4 chunks."""
        image_bgr = cv2.imread(image_path)
        if image_bgr is None:
            raise ValueError(f"Could not read image {image_path}")
        image_bgr = _cap_size(image_bgr)

        bbox, latent8, mask, crop_box = self._prepare_source(image_bgr)
        chunks = self._audio_chunks(audio_path, fps)
        num_frames = len(chunks)
        if num_frames == 0:
            raise ValueError("No audio frames produced")

        # Ramp segment sizes (e.g. 3, 6, then seg_frames) for fast startup
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

            proc = subprocess.Popen(
                [
                    "ffmpeg", "-y", "-v", "error",
                    "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}",
                    "-r", str(fps), "-i", "-",
                    "-ss", f"{t0:.3f}", "-i", audio_path, "-t", f"{dur:.3f}",
                    "-map", "0:v", "-map", "1:a",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-shortest", seg_mp4,
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
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
