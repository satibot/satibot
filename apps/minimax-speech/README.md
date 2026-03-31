# MiniMax Speech CLI

A Python command-line tool for text-to-speech synthesis using the MiniMax API via WebSocket.

## Features

- Text-to-speech synthesis with WebSocket streaming
- Multiple voice models (speech-2.8-hd, speech-2.6-turbo, etc.)
- Customizable voice settings (speed, pitch, volume)
- Streaming audio playback with MPV player
- Automatic audio file saving
- Configuration file support

## Installation

```bash
pip install websockets
```

Or install the required dependency:
```bash
pip install websockets
```

For audio playback, install MPV:
```bash
# macOS
brew install mpv

# Linux
sudo apt install mpv

# Windows
winget install mpv
```

## Usage

### Basic Usage

```bash
python -m minimax_speech "Hello, world!" YOUR_API_KEY
```

### With Environment Variable

```bash
export MINIMAX_API_KEY=your_api_key
python -m minimax_speech "Hello, world!"
```

### With Configuration File

Create `config.json`:
```json
{
  "providers": {
    "minimax": {
      "apiKey": "your_api_key"
    }
  }
}
```

Then run:
```bash
python -m minimax_speech "Hello, world!"
```

### Options

```bash
# Specify model and voice
python -m minimax_speech "Hello" --model speech-2.8-hd --voice English_expressive_narrator

# Adjust speed and pitch
python -m minimax_speech "Hello" --speed 1.2 --pitch 0.5

# Save to specific file
python -m minimax_speech "Hello" -o output.mp3

# Skip auto-play
python -m minimax_speech "Hello" --no-play -o output.mp3
```

### All Options

| Option | Description | Default |
|--------|-------------|---------|
| `-m, --model` | Voice model | `speech-2.8-hd` |
| `-v, --voice` | Voice ID | `English_expressive_narrator` |
| `-s, --speed` | Speech speed (0.5-2.0) | `1.0` |
| `--vol` | Volume (0.0-2.0) | `1.0` |
| `--pitch` | Pitch adjustment | `0` |
| `-f, --format` | Audio format (mp3, wav, pcm) | `mp3` |
| `--sample-rate` | Sample rate | `32000` |
| `--bitrate` | Audio bitrate | `128000` |
| `-o, --output` | Output file path | `output.mp3` |
| `--no-play` | Skip auto-play | `False` |
| `--english-normalization` | Enable EN text normalization | `False` |

## Voice Models

| Model | Description |
|-------|-------------|
| `speech-2.8-hd` | Perfecting tonal nuances, maximizing timbre similarity |
| `speech-2.6-hd` | Ultra-low latency, enhanced naturalness |
| `speech-2.8-turbo` | Faster, more affordable |
| `speech-2.6-turbo` | Faster, ideal for agents |
| `speech-02-hd` | Superior rhythm and stability |
| `speech-02-turbo` | Superior rhythm, enhanced multilingual |

## Available Voices

The API supports 40+ languages. Example voice IDs:
- `English_expressive_narrator`
- `Chinese_neural`
- `Japanese_neural`
- `Spanish_expressive`
- `French_neural`
- `German_expressive`
- `Korean_expressive`
- `Portuguese_expressive`
- `Italian_expressive`
- `Hindi_expressive`

## Requirements

- Python 3.8+
- `websockets` package
- `mpv` player (for streaming playback)