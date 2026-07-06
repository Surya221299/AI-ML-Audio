"""TTS voice-clone evaluation: speaker similarity + WER.

Run with no args to evaluate the bundled Gemala reference/clone pair:
    python evaluate.py
Or pass your own files:
    python evaluate.py reference.wav tts.wav "intended text"

PESQ/STOI were tried first but need frame-aligned, matched-duration audio
(they're built for codec/enhancement comparisons, not TTS vs. natural
speech) — Gemala's natural pacing vs. the TTS clone made them meaningless,
so this uses duration-independent metrics instead.
"""
import sys
from pathlib import Path

import jiwer
from resemblyzer import VoiceEncoder, preprocess_wav
from transformers import pipeline

EVAL_DIR = Path(__file__).parent
DEFAULT_REF = EVAL_DIR / "gemala_reference.wav"
DEFAULT_DEG = EVAL_DIR / "gemala_tts.wav"
DEFAULT_TEXT = "Halo nama saya gemala, saya mentor machine learning engineer di apple academy institute at UC"

NORMALIZE = jiwer.Compose([
    jiwer.ToLowerCase(),
    jiwer.RemovePunctuation(),
    jiwer.RemoveMultipleSpaces(),
    jiwer.Strip(),
    jiwer.ReduceToListOfListOfWords(),
])


def speaker_similarity(ref_path, deg_path):
    encoder = VoiceEncoder()
    ref_emb = encoder.embed_utterance(preprocess_wav(str(ref_path)))
    deg_emb = encoder.embed_utterance(preprocess_wav(str(deg_path)))
    return float(ref_emb @ deg_emb)  # unit-norm embeddings -> dot == cosine sim


def word_error_rate(deg_path, intended_text, model="openai/whisper-base"):
    # base beats tiny (too weak) and small/medium/large (hallucinate/truncate on
    # short <6s clips) for this Indonesian/English code-switched TTS output.
    asr = pipeline("automatic-speech-recognition", model=model)
    transcript = asr(str(deg_path), generate_kwargs={"language": "id", "task": "transcribe"})["text"]
    return jiwer.wer(intended_text, transcript, reference_transform=NORMALIZE, hypothesis_transform=NORMALIZE), transcript


if __name__ == "__main__":
    if len(sys.argv) == 4:
        ref_path, deg_path, intended_text = sys.argv[1], sys.argv[2], sys.argv[3]
    else:
        ref_path, deg_path, intended_text = DEFAULT_REF, DEFAULT_DEG, DEFAULT_TEXT

    sim = speaker_similarity(ref_path, deg_path)
    wer, transcript = word_error_rate(deg_path, intended_text)

    print(f"Speaker similarity: {sim:.3f}  (1=identical voice .. 0=unrelated; >0.75 is a strong clone)")
    print(f"WER: {wer:.3f}  (0=perfect .. 1=all words wrong)")
    print(f"  Whisper heard: {transcript!r}")
