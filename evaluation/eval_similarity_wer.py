"""Voice-clone fidelity + intelligibility, duration-independent (unlike PESQ/STOI).

- Speaker similarity: cosine similarity between Resemblyzer embeddings.
- WER: Whisper-tiny transcribes the TTS wav, diffed against the intended text.

Usage: python eval_similarity_wer.py reference.wav tts.wav "intended text"
"""
import sys

import jiwer
from resemblyzer import VoiceEncoder, preprocess_wav
from transformers import pipeline


def speaker_similarity(ref_path, deg_path):
    encoder = VoiceEncoder()
    ref_emb = encoder.embed_utterance(preprocess_wav(ref_path))
    deg_emb = encoder.embed_utterance(preprocess_wav(deg_path))
    return float(ref_emb @ deg_emb)  # embeddings are unit-norm -> dot == cosine sim


NORMALIZE = jiwer.Compose([
    jiwer.ToLowerCase(),
    jiwer.RemovePunctuation(),
    jiwer.RemoveMultipleSpaces(),
    jiwer.Strip(),
    jiwer.ReduceToListOfListOfWords(),
])


def word_error_rate(deg_path, intended_text, model="openai/whisper-base"):
    # base beats tiny (too weak) and small/medium/large (hallucinate/truncate on
    # short <6s clips) for this Indonesian/English code-switched TTS output.
    asr = pipeline("automatic-speech-recognition", model=model)
    transcript = asr(deg_path, generate_kwargs={"language": "id", "task": "transcribe"})["text"]
    return jiwer.wer(intended_text, transcript, reference_transform=NORMALIZE, hypothesis_transform=NORMALIZE), transcript


if __name__ == "__main__":
    ref_path, deg_path, intended_text = sys.argv[1], sys.argv[2], sys.argv[3]

    sim = speaker_similarity(ref_path, deg_path)
    wer, transcript = word_error_rate(deg_path, intended_text)

    print(f"Speaker similarity: {sim:.3f}  (1=identical voice .. 0=unrelated; >0.75 is a strong clone)")
    print(f"WER: {wer:.3f}  (0=perfect .. 1=all words wrong)")
    print(f"  Whisper heard: {transcript!r}")
