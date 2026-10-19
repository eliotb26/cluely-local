#!/usr/bin/env bash
# One-time setup: whisper.cpp, ffmpeg, the audiotee binary and the speech model (574 MB).
set -euo pipefail

# Pinned to a commit, and checked, so the model can't change under you.
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
MODEL_SHA256="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
MODEL_PATH="models/ggml-large-v3-turbo-q5_0.bin"
WISPR_MODEL="../wispr-local/$MODEL_PATH"   # reuse wispr-local's copy if it sits next to this repo
AUDIOTEE_URL="https://registry.npmjs.org/audiotee/-/audiotee-0.0.7.tgz"
AUDIOTEE_SHA256="c4bbed2fbc750203510cc7df492ccc5c2b8b9ef310798f33d5d8c9b10c9eebe3"

cd "$(dirname "$0")/.."

if ! command -v brew >/dev/null; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi
if ! command -v swift >/dev/null; then
  echo "Swift is required: install Xcode or run xcode-select --install" >&2
  exit 1
fi
command -v whisper-cli >/dev/null || { echo "Installing whisper.cpp..."; brew install whisper-cpp; }
command -v ffmpeg >/dev/null || { echo "Installing ffmpeg..."; brew install ffmpeg; }

if [ ! -x bin/audiotee ]; then
  echo "Fetching audiotee 0.0.7 (system audio capture)..."
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -L --proto '=https' --fail --silent --show-error -o "$tmp/audiotee.tgz" "$AUDIOTEE_URL"
  echo "$AUDIOTEE_SHA256  $tmp/audiotee.tgz" | shasum -a 256 -c - >/dev/null
  tar -xzf "$tmp/audiotee.tgz" -C "$tmp" package/bin/audiotee
  mkdir -p bin
  mv "$tmp/package/bin/audiotee" bin/audiotee
  chmod +x bin/audiotee
fi

# A link left behind after wispr-local moved points nowhere: replace it.
[ -L "$MODEL_PATH" ] && [ ! -e "$MODEL_PATH" ] && rm "$MODEL_PATH"
if [ ! -e "$MODEL_PATH" ]; then
  mkdir -p models
  if [ -f "$WISPR_MODEL" ] && echo "$MODEL_SHA256  $WISPR_MODEL" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "Linking the speech model from wispr-local (checksum matches)..."
    ln -s "$(cd "$(dirname "$WISPR_MODEL")" && pwd)/$(basename "$WISPR_MODEL")" "$MODEL_PATH"
  else
    echo "Downloading the speech model (574 MB)..."
    curl -L --proto '=https' --fail --progress-bar -o "$MODEL_PATH.part" "$MODEL_URL"
    echo "Checking it..."
    echo "$MODEL_SHA256  $MODEL_PATH.part" | shasum -a 256 -c - >/dev/null
    mv "$MODEL_PATH.part" "$MODEL_PATH"
  fi
fi

if ! command -v claude >/dev/null; then
  echo "Note: the Claude Code CLI isn't on your PATH. Asking needs it, or ANTHROPIC_API_KEY: https://claude.com/claude-code"
fi

echo "Building..."
swift build -c release

echo
echo "Done. Start it with:  .build/release/cluely-local"
