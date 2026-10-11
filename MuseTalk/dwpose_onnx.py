"""
DWPose face detector via ONNX Runtime (CoreML EP) — drop-in replacement for
MuseTalk's mmpose-based get_landmark_and_bbox (mmpose/mmcv won't build on Mac).

Pipeline: yolox_l (person detection) -> dw-ll_ucoco_384 (133-keypoint wholebody
pose) -> face landmarks (kpts[23:91]) -> MuseTalk crop bbox.

Postprocessing follows the canonical DWPose/controlnet-aux ONNX demo.
"""
import cv2
import numpy as np
import onnxruntime as ort


# ── YOLOX person detection ──────────────────────────────────────────────────

def _yolox_preprocess(img, input_size=(640, 640)):
    padded = np.ones((input_size[0], input_size[1], 3), dtype=np.uint8) * 114
    r = min(input_size[0] / img.shape[0], input_size[1] / img.shape[1])
    resized = cv2.resize(
        img,
        (int(img.shape[1] * r), int(img.shape[0] * r)),
        interpolation=cv2.INTER_LINEAR,
    ).astype(np.uint8)
    padded[: resized.shape[0], : resized.shape[1]] = resized
    padded = padded.transpose(2, 0, 1)  # HWC -> CHW
    return np.ascontiguousarray(padded, dtype=np.float32), r


def _demo_postprocess(outputs, img_size, strides=(8, 16, 32)):
    grids, expanded_strides = [], []
    hsizes = [img_size[0] // s for s in strides]
    wsizes = [img_size[1] // s for s in strides]
    for hsize, wsize, stride in zip(hsizes, wsizes, strides):
        xv, yv = np.meshgrid(np.arange(wsize), np.arange(hsize))
        grid = np.stack((xv, yv), 2).reshape(1, -1, 2)
        grids.append(grid)
        expanded_strides.append(np.full((*grid.shape[:2], 1), stride))
    grids = np.concatenate(grids, 1)
    expanded_strides = np.concatenate(expanded_strides, 1)
    outputs[..., :2] = (outputs[..., :2] + grids) * expanded_strides
    outputs[..., 2:4] = np.exp(outputs[..., 2:4]) * expanded_strides
    return outputs


def _nms(boxes, scores, nms_thr):
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1 + 1)
        h = np.maximum(0.0, yy2 - yy1 + 1)
        inter = w * h
        ovr = inter / (areas[i] + areas[order[1:]] - inter)
        order = order[np.where(ovr <= nms_thr)[0] + 1]
    return keep


# ── DWPose top-down keypoint decode ─────────────────────────────────────────

def _bbox_xyxy2cs(bbox, padding=1.25):
    x1, y1, x2, y2 = bbox[:4]
    center = np.array([(x1 + x2) * 0.5, (y1 + y2) * 0.5], dtype=np.float32)
    scale = np.array([x2 - x1, y2 - y1], dtype=np.float32) * padding
    return center, scale


def _fix_aspect_ratio(scale, aspect_ratio):
    w, h = scale
    if w > h * aspect_ratio:
        h = w / aspect_ratio
    else:
        w = h * aspect_ratio
    return np.array([w, h], dtype=np.float32)


def _rotate_point(pt, angle_rad):
    sn, cs = np.sin(angle_rad), np.cos(angle_rad)
    return np.array([pt[0] * cs - pt[1] * sn, pt[0] * sn + pt[1] * cs])


def _get_3rd_point(a, b):
    direction = a - b
    return b + np.r_[-direction[1], direction[0]]


def _get_warp_matrix(center, scale, rot, output_size):
    src_w = scale[0]
    dst_w, dst_h = output_size
    rot_rad = np.deg2rad(rot)
    src_dir = _rotate_point(np.array([0.0, src_w * -0.5]), rot_rad)
    dst_dir = np.array([0.0, dst_w * -0.5])
    src = np.zeros((3, 2), dtype=np.float32)
    src[0, :] = center
    src[1, :] = center + src_dir
    src[2, :] = _get_3rd_point(src[0, :], src[1, :])
    dst = np.zeros((3, 2), dtype=np.float32)
    dst[0, :] = [dst_w * 0.5, dst_h * 0.5]
    dst[1, :] = np.array([dst_w * 0.5, dst_h * 0.5]) + dst_dir
    dst[2, :] = _get_3rd_point(dst[0, :], dst[1, :])
    return cv2.getAffineTransform(np.float32(src), np.float32(dst))


def _top_down_affine(input_size, scale, center, img):
    w, h = input_size
    scale = _fix_aspect_ratio(scale, w / h)
    warp_mat = _get_warp_matrix(center, scale, 0, (w, h))
    warped = cv2.warpAffine(img, warp_mat, (int(w), int(h)), flags=cv2.INTER_LINEAR)
    return warped, scale


def _get_simcc_maximum(simcc_x, simcc_y):
    N, K, _ = simcc_x.shape
    x_locs = np.argmax(simcc_x.reshape(N * K, -1), axis=1)
    y_locs = np.argmax(simcc_y.reshape(N * K, -1), axis=1)
    locs = np.stack((x_locs, y_locs), axis=-1).astype(np.float32)
    max_val_x = np.amax(simcc_x.reshape(N * K, -1), axis=1)
    max_val_y = np.amax(simcc_y.reshape(N * K, -1), axis=1)
    vals = np.minimum(max_val_x, max_val_y)
    locs[vals <= 0.0] = -1
    return locs.reshape(N, K, 2), vals.reshape(N, K)


class DWPoseDetector:
    def __init__(self, det_path, pose_path, providers=None):
        if providers is None:
            providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"]
        opts = ort.SessionOptions()
        self.det = ort.InferenceSession(det_path, sess_options=opts, providers=providers)
        self.pose = ort.InferenceSession(pose_path, sess_options=opts, providers=providers)
        # pose model input shape: [N, 3, H, W]
        ph, pw = self.pose.get_inputs()[0].shape[2:]
        self.pose_input_size = (int(pw), int(ph))  # (W, H) = (288, 384)

    def _detect_person(self, img, score_thr=0.3, nms_thr=0.45):
        inp, ratio = _yolox_preprocess(img)
        out = self.det.run(None, {self.det.get_inputs()[0].name: inp[None, :]})[0]
        preds = _demo_postprocess(out, (640, 640))[0]
        boxes = preds[:, :4]
        scores = preds[:, 4:5] * preds[:, 5:]
        # xywh -> xyxy
        xyxy = np.empty_like(boxes)
        xyxy[:, 0] = boxes[:, 0] - boxes[:, 2] / 2
        xyxy[:, 1] = boxes[:, 1] - boxes[:, 3] / 2
        xyxy[:, 2] = boxes[:, 0] + boxes[:, 2] / 2
        xyxy[:, 3] = boxes[:, 1] + boxes[:, 3] / 2
        xyxy /= ratio
        person = scores[:, 0]  # class 0 = person
        mask = person > score_thr
        if not mask.any():
            return None
        b, s = xyxy[mask], person[mask]
        keep = _nms(b, s, nms_thr)
        if not keep:
            return None
        b, s = b[keep], s[keep]
        return b[np.argmax(s)]  # highest-confidence person

    def _estimate_pose(self, img, bbox):
        center, scale = _bbox_xyxy2cs(bbox, padding=1.25)
        warped, scale = _top_down_affine(self.pose_input_size, scale, center, img)
        mean = np.array([123.675, 116.28, 103.53])
        std = np.array([58.395, 57.12, 57.375])
        inp = ((warped - mean) / std).transpose(2, 0, 1).astype(np.float32)
        names = [o.name for o in self.pose.get_outputs()]
        simcc_x, simcc_y = self.pose.run(names, {self.pose.get_inputs()[0].name: inp[None, :]})
        locs, vals = _get_simcc_maximum(simcc_x, simcc_y)
        keypoints = locs / 2.0  # simcc_split_ratio = 2.0
        # map back from model input space to original image
        w, h = self.pose_input_size
        keypoints = keypoints / np.array([w, h]) * scale + (center - scale / 2)
        return keypoints[0], vals[0]

    def detect(self, img_bgr):
        """Returns (keypoints[133,2], scores[133]) in original-image pixels."""
        bbox = self._detect_person(img_bgr)
        if bbox is None:
            h, w = img_bgr.shape[:2]
            bbox = np.array([0, 0, w, h], dtype=np.float32)
        return self._estimate_pose(img_bgr, bbox)


def face_bbox_from_keypoints(keypoints, frame_shape, bbox_shift=0, extra_margin=10):
    """Replicates MuseTalk get_landmark_and_bbox + v15 extra_margin crop logic."""
    face = keypoints[23:91].astype(np.int32)  # 68 face landmarks
    half_face_coord = face[29].copy()
    if bbox_shift != 0:
        half_face_coord[1] += bbox_shift
    half_face_dist = np.max(face[:, 1]) - half_face_coord[1]
    upper_bond = max(0, half_face_coord[1] - half_face_dist)
    x1 = int(np.min(face[:, 0]))
    y1 = int(upper_bond)
    x2 = int(np.max(face[:, 0]))
    y2 = int(np.max(face[:, 1]))
    y2 = min(y2 + extra_margin, frame_shape[0])  # v15 extra margin
    return [x1, y1, x2, y2]
