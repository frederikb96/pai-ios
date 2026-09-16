#!/usr/bin/env python3
"""Writes the training config for one voice command.

Every command's model treats the other commands as hard negatives, so saying one never fires
another. Phrases live in phrases.json; the preset decides how much synthetic data is generated.
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).parent

PRESETS = {
    # A few minutes end to end: proves the pipeline runs, not that the model is any good.
    "test": {"n_samples": 200, "n_samples_val": 50, "n_background": 50, "n_background_val": 10,
             "steps": 1000, "model_type": "dnn", "model_size": "small", "fp_target": 1.0},
    "full": {"n_samples": 10000, "n_samples_val": 2000, "n_background": 1000, "n_background_val": 250,
             "steps": 50000, "model_type": "conv_attention", "model_size": "small", "fp_target": 0.2},
}

# Things said constantly that share a word with a command, plus near-homophones of the name.
SHARED_NEGATIVES = [
    "kai", "hi", "hey", "okay", "high", "guy", "sky", "my", "why", "try", "tie",
    "start", "stop", "send", "skip", "end",
    "car start", "high stop", "i said", "okay then", "the end", "just stop",
    "kaiser", "kite", "kind", "and then", "get started", "stop it",
]


def main() -> None:
    name, preset_name, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    phrases = json.loads((HERE / "phrases.json").read_text())
    preset = PRESETS[preset_name]
    others = [p for key, values in phrases.items() if key != name for p in values]
    negatives = sorted(set(SHARED_NEGATIVES + others) - set(phrases[name]))
    config = {
        "model_name": name,
        "target_phrases": phrases[name],
        "n_samples": preset["n_samples"],
        "n_samples_val": preset["n_samples_val"],
        "n_background_samples": preset["n_background"],
        "n_background_samples_val": preset["n_background_val"],
        "tts_batch_size": 20,
        "custom_negative_phrases": negatives,
        "model": {"model_type": preset["model_type"], "model_size": preset["model_size"]},
        "steps": preset["steps"],
        "target_fp_per_hour": preset["fp_target"],
    }
    # JSON is valid YAML, and the trainer reads YAML.
    out.write_text(json.dumps(config, indent=2))


if __name__ == "__main__":
    main()
