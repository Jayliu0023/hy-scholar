#!/usr/bin/python3
"""Install the pinned local translation runtime from two upstream downloads."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

MODEL = "Hy-MT2-7B-Q4_K_M.gguf"
MODEL_SHA = "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b"
ARCHIVE_SHA = "e234070cbde0c8b0d30f79fa08ff8246abe22c72acb752619349b8d9c46f7839"
RUNTIME = "llama-b11457"
HELPER = Path(__file__).resolve().parent / "runtime" / "hy-mt2-7b"

def sha256(path):
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()

def verify(path, expected):
    if sha256(path) != expected:
        raise ValueError("SHA-256 mismatch: " + str(path))

def install(model, archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        verify(archive, ARCHIVE_SHA)
        with tempfile.TemporaryDirectory(dir=destination) as temporary:
            stage = Path(temporary)
            target_model = destination / MODEL
            if not target_model.is_file() or sha256(target_model) != MODEL_SHA:
                shutil.copyfile(model, stage / MODEL)
                verify(stage / MODEL, MODEL_SHA)
            subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(stage),
                            "--include", RUNTIME + "/LICENSE", "--include", RUNTIME + "/llama-server",
                            "--include", RUNTIME + "/*.dylib"], check=True)
            subprocess.run([str(stage / RUNTIME / "llama-server"), "--version"], check=True)
            shutil.copy2(HELPER, stage / "hy-mt2-7b")
            target_runtime = destination / RUNTIME
            if target_runtime.exists():
                # Preserve running instances when repairing individual files of this same pinned build.
                for component in (stage / RUNTIME).iterdir():
                    target = target_runtime / component.name
                    if component.is_symlink():
                        if target.is_symlink() and os.readlink(component) == os.readlink(target):
                            continue
                    elif target.is_file() and not target.is_symlink() and sha256(target) == sha256(component):
                        continue
                    os.replace(component, target)
            else:
                os.rename(stage / RUNTIME, target_runtime)
            if (stage / MODEL).exists():
                os.replace(stage / MODEL, target_model)
            os.replace(stage / "hy-mt2-7b", destination / "hy-mt2-7b")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path, help="Tencent Hy-MT2-7B Q4_K_M GGUF file")
    parser.add_argument("archive", type=Path, help="llama.cpp b11457 macOS arm64 tar.gz")
    args = parser.parse_args()
    try:
        install(args.model.resolve(), args.archive.resolve(), Path.home() / ".local/share/hy-mt2-7b")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")
    print("Hy-MT2-7B is ready. Open Hy-translator.app and select English text to translate.")
