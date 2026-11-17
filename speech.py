import os
from pathlib import Path
import subprocess
import sys


def transcribe(wav, model, language):
    prefix = wav.parent / "transcript"
    # Read the text output file: whisper-cli also writes progress to its console.
    command = ["whisper-cli", "-m", str(model), "-l", language, "-np",
               "-nt", "-sns", "-otxt", "-of", str(prefix), "-f", str(wav)]
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if result.returncode:
        print("Whisper could not use its default backend. Retrying on the CPU.", file=sys.stderr, flush=True)
        subprocess.run([*command, "-ng"], stdout=subprocess.DEVNULL, check=True)
    transcript = prefix.with_suffix(".txt").read_text(encoding="utf-8")
    return " ".join(transcript.split())


if __name__ == "__main__":
    try:
        model = Path(os.environ.get("WHISPER_MODEL", "~/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin")).expanduser()
        if not model.is_file():
            sys.exit(f"Whisper model missing at {model}")
        print(transcribe(Path(sys.argv[1]), model, sys.argv[2]))
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
