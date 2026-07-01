# Journal

- 2026-06-30: Simple TTS generation tuning added.
- `InterviewTime/SimpleTTSView.swift` now exposes CFG, STEPS, MAX TOKENS, and WARMUP sliders. Fast-balanced defaults: `2.5`, `8`, `800`, `1`.
- `InterviewTime/SimpleTTSService.swift` sends those values per request as `cfg_value`, `inference_timesteps`, `max_tokens`, and `warmup_patches`.
- `server_mlx.py` accepts the optional request fields and applies them to `/speak_stream`; stream fallback defaults match the Swift defaults.
- Verification: `python3 -m py_compile server_mlx.py` passes. Xcode build in sandbox is blocked by Swift preview macro/plugin execution; unsandboxed rerun was not approved.
