"""
Fold constant Sqrt nodes that block Apple Neural Engine (ANE) compilation.

Root cause: CoreML MLProgram can't compile fp16 Sqrt ops on ANE.
In transformer attention blocks the pattern is:
  Shape(K) → Gather(-1) → Cast(float16) → Sqrt → scale factor
Since our ONNX models have STATIC shapes, Shape outputs are constants.
We trace each Sqrt input back through the graph, compute sqrt in float32,
and replace the Sqrt node with a pre-computed constant initializer.

Run AFTER export_onnx_static.py.
"""
from pathlib import Path
import numpy as np
import onnx
from onnx import numpy_helper, shape_inference, TensorProto

DTYPE_MAP = {
    TensorProto.FLOAT:   np.float32,
    TensorProto.FLOAT16: np.float16,
    TensorProto.INT64:   np.int64,
    TensorProto.INT32:   np.int32,
    TensorProto.BOOL:    np.bool_,
}


def _load_and_infer(path: str):
    print(f"  Loading + running shape inference (may take ~30s for UNet)...", flush=True)
    # infer_shapes_path writes to a temp file and returns the path; use in-memory version
    model = onnx.load(path)
    model = shape_inference.infer_shapes(model, check_type=False, strict_mode=False)
    return model


def _build_index(model):
    graph = model.graph
    inits = {i.name: numpy_helper.to_array(i) for i in graph.initializer}
    out2node = {o: n for n in graph.node for o in n.output}

    # value_info gives shapes for intermediate tensors after shape inference
    vi_shape = {}
    for vi in list(graph.value_info) + list(graph.input) + list(graph.output):
        tt = vi.type.tensor_type
        if tt.HasField("shape"):
            vi_shape[vi.name] = [d.dim_value for d in tt.shape.dim]

    return inits, out2node, vi_shape


def _eval(name, inits, out2node, vi_shape):
    """Try to evaluate `name` as a constant numpy array. Returns None if not constant."""
    if name in inits:
        return inits[name]
    if name not in out2node:
        return None
    node = out2node[name]

    if node.op_type == "Constant":
        for a in node.attribute:
            if a.name == "value":
                return numpy_helper.to_array(a.t)

    if node.op_type == "Shape":
        shape = vi_shape.get(node.input[0])
        if shape is None:
            return None
        start = next((a.i for a in node.attribute if a.name == "start"), 0)
        end   = next((a.i for a in node.attribute if a.name == "end"), len(shape))
        return np.array(shape[start:end], dtype=np.int64)

    if node.op_type == "Gather":
        data    = _eval(node.input[0], inits, out2node, vi_shape)
        indices = _eval(node.input[1], inits, out2node, vi_shape)
        if data is None or indices is None:
            return None
        axis = next((a.i for a in node.attribute if a.name == "axis"), 0)
        return np.take(data, indices, axis=axis)

    if node.op_type == "Cast":
        v = _eval(node.input[0], inits, out2node, vi_shape)
        if v is None:
            return None
        to = next(a.i for a in node.attribute if a.name == "to")
        return v.astype(DTYPE_MAP.get(to, np.float32))

    if node.op_type == "Unsqueeze":
        v = _eval(node.input[0], inits, out2node, vi_shape)
        if v is None:
            return None
        if len(node.input) > 1:
            axes = _eval(node.input[1], inits, out2node, vi_shape)
        else:
            axes = next((list(a.ints) for a in node.attribute if a.name == "axes"), None)
        if axes is None:
            return None
        result = v
        for ax in sorted(int(a) for a in axes):
            result = np.expand_dims(result, axis=ax)
        return result

    if node.op_type == "Squeeze":
        v = _eval(node.input[0], inits, out2node, vi_shape)
        if v is None:
            return None
        if len(node.input) > 1:
            axes = _eval(node.input[1], inits, out2node, vi_shape)
        else:
            axes = next((list(a.ints) for a in node.attribute if a.name == "axes"), None)
        if axes is None:
            return None
        return np.squeeze(v, axis=tuple(int(a) for a in axes))

    if node.op_type == "Reshape":
        v     = _eval(node.input[0], inits, out2node, vi_shape)
        shape = _eval(node.input[1], inits, out2node, vi_shape)
        if v is None or shape is None:
            return None
        return v.reshape(shape)

    return None


def fold_model(input_path: str, output_path: str) -> int:
    model = _load_and_infer(input_path)
    graph = model.graph
    inits, out2node, vi_shape = _build_index(model)

    to_remove = []
    new_inits = []
    folded = 0

    for node in graph.node:
        if node.op_type != "Sqrt":
            continue
        inp_val = _eval(node.input[0], inits, out2node, vi_shape)
        if inp_val is None:
            print(f"    [skip] {node.output[0][:60]} — input not constant", flush=True)
            continue

        result = np.sqrt(inp_val.astype(np.float32)).astype(inp_val.dtype)
        new_inits.append(numpy_helper.from_array(result, name=node.output[0]))
        # make folded value available for downstream nodes
        inits[node.output[0]] = result
        to_remove.append(node)
        folded += 1

    for node in to_remove:
        graph.node.remove(node)
    graph.initializer.extend(new_inits)

    print(f"  Folded {folded} Sqrt nodes.", flush=True)

    if folded:
        print(f"  Saving → {output_path}", flush=True)
        onnx.save(model, output_path)
    else:
        import shutil
        shutil.copy(input_path, output_path)

    return folded


MODELS = [
    ("onnx_models/vae_encoder_fp16_static.onnx",
     "onnx_models/vae_encoder_fp16_ane.onnx"),
    ("onnx_models/vae_decoder_fp16_static.onnx",
     "onnx_models/vae_decoder_fp16_ane.onnx"),
    ("onnx_models/unet_fp16_static.onnx",
     "onnx_models/unet_fp16_ane.onnx"),
]

if __name__ == "__main__":
    import os
    os.chdir(Path(__file__).parent)

    total = 0
    for inp, out in MODELS:
        if not Path(inp).exists():
            print(f"\n[skip] {inp} not found")
            continue
        print(f"\n=== {Path(inp).name} ===")
        total += fold_model(inp, out)

    print(f"\nDone — {total} Sqrt nodes folded across all models.")
    print("Next: run bench_coreml_ane.py to verify ANE compilation succeeds.")
