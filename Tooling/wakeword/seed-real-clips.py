#!/usr/bin/env python3
"""Seeds recorded takes into a wake word model's positive/negative clip directories.

``livekit-wakeword``'s generate step counts existing ``clip_######.wav`` files in each split
directory and only synthesizes the remainder up to its target count (see ``_count_original_clips``
in its ``data/generate.py``) — that resume behaviour is the only place the trainer lets anything
other than its own TTS output into a split. This script exploits exactly that: it writes recorded
takes into the same directories, in the same filename convention, before ``livekit-wakeword run``
is invoked, so the synthesizer fills in only what real material didn't already cover.

Every take is resampled to 16 kHz mono and has leading/trailing silence stripped through the
trainer's own ``remove_silence`` (WebRTC VAD) — the exact function it runs its synthetic clips
through before writing them, since the augmentation step's end-alignment assumes a clip that is
mostly the spoken word.

Takes are split between the split's train and test directory. A manifest, if present, groups
takes (by whatever route/label fields it carries) so the split doesn't put every take from one
route or session on the same side; the split fraction is applied per group. With no manifest, or
a manifest missing those fields, everything falls into one group and the split is a plain shuffle.
"""

import argparse
import json
import random
import shutil
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
import soundfile as sf

SAMPLE_RATE = 16000

# Takes are expected to be WAV, matching every other recording this app writes — but the archive
# is read defensively against a couple of other formats a collection screen might reasonably
# export instead.
_AUDIO_EXTENSIONS = (".wav", ".m4a", ".caf", ".mp3", ".aac")


def _find_audio_files(root: Path) -> list[Path]:
    return sorted(p for ext in _AUDIO_EXTENSIONS for p in root.glob(f"**/*{ext}"))


def _first(d: dict, *keys: str) -> object | None:
    """Returns the first present key's value, trying several spellings the manifest might use."""
    for key in keys:
        if key in d and d[key] is not None:
            return d[key]
    return None


def _load_manifest(root: Path) -> dict[str, dict]:
    """Reads whatever manifest metadata is present, keyed by wav filename.

    Supports a single aggregate manifest (a JSON array of take objects, or an object with a
    "takes"/"recordings" list) and per-clip sidecar files (``<stem>.json`` next to the audio file).
    Either shape is optional — a clip with no matching entry just gets no metadata.
    """
    audio_stems = {p.stem for p in _find_audio_files(root)}
    entries: dict[str, dict] = {}

    for candidate in root.glob("**/*.json"):
        if candidate.stem in audio_stems:
            continue  # handled as a sidecar below
        try:
            data = json.loads(candidate.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        if isinstance(data, dict):
            data = _first(data, "takes", "recordings", "clips") or []
        if not isinstance(data, list):
            continue
        for item in data:
            if not isinstance(item, dict):
                continue
            filename = _first(item, "filename", "file", "name", "wav")
            if filename:
                entries[Path(str(filename)).stem] = item

    for audio_path in _find_audio_files(root):
        sidecar = audio_path.with_suffix(".json")
        if sidecar.exists() and audio_path.stem not in entries:
            try:
                entries[audio_path.stem] = json.loads(sidecar.read_text())
            except (json.JSONDecodeError, OSError):
                pass

    return entries


def _group_key(meta: dict) -> tuple[str, str]:
    route = _first(meta, "route", "audioRoute", "audio_route") or "unknown"
    label = _first(meta, "label", "runLabel", "run_label") or "unknown"
    return (str(route), str(label))


def _read_audio(path: Path) -> tuple[np.ndarray, int]:
    """Reads an audio file, falling back to ffmpeg for anything soundfile can't open directly.

    The takes are expected to be WAV, matching every other recording this app already writes —
    but a collection screen is free to export something else, and a decode failure here would
    otherwise silently drop a take rather than fail loudly.
    """
    try:
        return sf.read(str(path))
    except Exception:
        import subprocess

        with tempfile.NamedTemporaryFile(suffix=".wav") as converted:
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(path), "-ar", str(SAMPLE_RATE), "-ac", "1", converted.name],
                check=True,
                capture_output=True,
            )
            return sf.read(converted.name)


def _prepare_clip(audio_path: Path) -> np.ndarray:
    """Reads a take, resamples to 16 kHz mono, and trims silence. Returns int16 PCM samples.

    Peak-normalizes before the int16 conversion and trims through the same ``remove_silence``
    (WebRTC VAD) the trainer runs its own synthetic clips through, so a real take reaches the
    augmentation step looking like one — same loudness convention, same "mostly just the word"
    shape the end-alignment in ``augment.py`` assumes.
    """
    from livekit.wakeword.data.piper import remove_silence
    from livekit.wakeword.data.piper.vits_utils import audio_float_to_int16

    audio, sr = _read_audio(audio_path)
    if audio.ndim > 1:
        audio = audio[:, 0]
    audio = audio.astype(np.float32)
    if sr != SAMPLE_RATE:
        import librosa

        audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
    return remove_silence(audio_float_to_int16(audio))


def _write_clip(samples: np.ndarray, out_path: Path) -> None:
    with wave.open(str(out_path), "wb") as wav_file:
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.setsampwidth(2)
        wav_file.setnchannels(1)
        wav_file.writeframes(samples.tobytes())


def _split_groups(
    groups: dict[tuple[str, str], list[Path]],
    val_fraction: float,
    seed: int,
) -> tuple[list[Path], list[Path]]:
    train: list[Path] = []
    test: list[Path] = []
    rng = random.Random(seed)
    for key in sorted(groups):
        members = sorted(groups[key])
        rng.shuffle(members)
        n_val = round(len(members) * val_fraction)
        test.extend(members[:n_val])
        train.extend(members[n_val:])
    return train, test


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="Path to the wake word config YAML written by make-config.py")
    parser.add_argument("archive", help="Path to the downloaded archive of recorded takes")
    parser.add_argument(
        "--target",
        default="positive",
        choices=["positive", "negative"],
        help="Which split the takes belong to (default: positive)",
    )
    parser.add_argument(
        "--val-fraction",
        type=float,
        default=0.2,
        help="Fraction of each group held out for the test split (default: 0.2, matching the "
        "synthetic n_samples_val:n_samples ratio)",
    )
    parser.add_argument("--seed", type=int, default=0, help="Shuffle seed for the train/test split")
    parser.add_argument(
        "--oversample",
        type=int,
        default=1,
        help="Repeat each take this many times before splitting (default: 1, no repeat). Each "
        "repeat still gets independently randomized augmentation per round, so this raises a "
        "real take's share of the training set without adding new TTS synthesis — it does not "
        "add acoustic diversity beyond what the original take already has.",
    )
    args = parser.parse_args()

    from livekit.wakeword.config import load_config

    config = load_config(args.config)

    with tempfile.TemporaryDirectory() as tmp:
        extract_dir = Path(tmp)
        shutil.unpack_archive(args.archive, extract_dir)

        manifest = _load_manifest(extract_dir)
        audio_paths = _find_audio_files(extract_dir)
        if not audio_paths:
            print("No audio files found in the archive — nothing to seed.", file=sys.stderr)
            return

        groups: dict[tuple[str, str], list[Path]] = {}
        for audio_path in audio_paths:
            meta = manifest.get(audio_path.stem, {})
            groups.setdefault(_group_key(meta), []).append(audio_path)

        # Split on the unique takes first, then oversample the train side only — a duplicate of a
        # training take must never also land in test (that would just be memorization), and test
        # stays one real measurement per take rather than a repeated one inflating its own count.
        train_paths, test_paths = _split_groups(groups, args.val_fraction, args.seed)
        train_paths = train_paths * args.oversample

        train_dir = config.model_output_dir / f"{args.target}_train"
        test_dir = config.model_output_dir / f"{args.target}_test"
        train_dir.mkdir(parents=True, exist_ok=True)
        test_dir.mkdir(parents=True, exist_ok=True)

        for out_dir, paths in ((train_dir, train_paths), (test_dir, test_paths)):
            for i, audio_path in enumerate(paths):
                samples = _prepare_clip(audio_path)
                _write_clip(samples, out_dir / f"clip_{i:06d}.wav")

    print(
        f"Seeded {len(train_paths)} real {args.target} clips into {train_dir} "
        f"and {len(test_paths)} into {test_dir} ({len(groups)} group(s) from the manifest)."
    )


if __name__ == "__main__":
    main()
