# MiniMax Music CLI

A command-line tool for generating music and lyrics using the MiniMax API.

## Features

- Generate lyrics from text prompts
- Generate music with customizable style, mood, and vocals
- Auto-generate lyrics from prompt using `lyrics_optimizer`
- Generate instrumental tracks using `is_instrumental` (music-2.5+ only)
- Support for both music-2.5 and music-2.5+ models
- Configurable audio output (URL or hex format)
- Automatic MP3 download from generated URLs
- Attempts to play MP3 with system default player
- Configuration file support for API key management
- Built-in request validation with helpful error messages

## Building

```bash
cd /path/to/satibot
zig build s-music
```

The binary will be created at `./zig-out/bin/s-music`.

## Usage

### 1. Using API Key Directly

Generate lyrics:
```bash
./zig-out/bin/s-music lyrics "A soulful blues song about a rainy night" <your-api-key>
```

Generate music:
```bash
./zig-out/bin/s-music music "Soulful Blues, Rainy Night, Melancholy" <your-api-key>
```

Generate music with custom lyrics:
```bash
./zig-out/bin/s-music music "Pop Rock, Upbeat" --lyrics "[Verse 1]\nCustom lyrics here" <your-api-key>
```

Generate music with auto-generated lyrics:
```bash
./zig-out/bin/s-music music "Pop Rock, Upbeat" --lyrics-optimizer <your-api-key>
```

Generate instrumental music:
```bash
./zig-out/bin/s-music music "Electronic, Ambient" --instrumental <your-api-key>
```

### 2. Using Configuration File

Create a `config.json` file in the current directory:
```json
{
  "providers": {
    "minimax": {
      "apiKey": "your-minimax-api-key-here"
    }
  }
}
```

Then run without the API key:
```bash
./zig-out/bin/s-music music "Jazz, Smooth, Evening"
```

## Output

- Lyrics are printed directly to the console
- Music files are downloaded as `generated_music_<timestamp>.mp3` in the current directory
- The CLI attempts to open the MP3 with your system's default player

### Example Output

```text
Downloading MP3 from: https://example.com/audio.mp3
Successfully downloaded to: generated_music_1234567890.mp3
Playing MP3 with default player...
```

```bash
zig build run-music -- lyrics "A soulful blues song about a rainy night"
```

```text
Generating lyrics for: A soulful blues song about a rainy night

Generated Lyrics:
==================

[Intro]

[Verse]
The sky is cryin' tonight, a steady pour
Each drop a memory knockin' at my door
This lonely room feels colder than before
Wishin' I could find what I'm lookin' for

[Chorus]
Oh, midnight rain, washin' over me
This heartache's a tide, pullin' me out to sea
Just the rhythm of the drops, a sad melody
Singin' the blues, just the rain and me

[Verse]
Streetlights bleedin' through the window pane
Reflectin' shadows, whisperin' your name
Every little sound just amplifies the pain
Stuck in this downpour, playin' this losing game

[Chorus]
Oh, midnight rain, washin' over me
This heartache's a tide, pullin' me out to sea
Just the rhythm of the drops, a sad melody
Singin' the blues, just the rain and me

[Bridge]
Used to love the sound, now it brings me down
Like a lost soul wanderin' through this ghost town
This heavy air, wearin' a weary frown
Prayin' for the sun, but the clouds just hang around

[Instrumental]

[Chorus]
Oh, midnight rain, washin' over me
This heartache's a tide, pullin' me out to sea
Just the rhythm of the drops, a sad melody
Singin' the blues, just the rain and me

[Outro]
```

## Test Script

Use the provided test script to try all features:
```bash
./test_music.sh <your-api-key>
```

## Add script to PATH

To make the CLI globally available, add the following to your shell profile (e.g., `~/.zshrc` or `~/.bashrc`):

```bash
# Option 1: Add project directory to PATH (easiest)
export PATH="/Users/username/w/satibot:$PATH"

# Option 2: If using zig build install (outputs to zig-out/bin)
export PATH="$PATH:$HOME/w/satibot/zig-out/bin"

# Option 3: Copy binary to system directory
sudo cp /Users/username/w/satibot/s-music /usr/local/bin/
```

Then reload your shell:
```bash
source ~/.zshrc # or source ~/.bashrc
```

## Examples

1. Generate upbeat pop music:
   ```bash
   s-music music "Upbeat Pop, Summer, Bright, Energetic"
   ```

2. Generate melancholic piano music:
   ```bash
   s-music music "Piano, Melancholy, Rain, Slow"
   ```

3. Generate lyrics first, then music:
   ```bash
   s-music lyrics "A song about coding late at night"
   s-music music "Electronic, Ambient, Focus" --lyrics "<paste generated lyrics>"
   ```

4. Generate music with auto-optimized lyrics:
   ```bash
   s-music music "Rock, Energetic, Stadium" --lyrics-optimizer
   ```

5. Generate instrumental music for meditation:
   ```bash
   s-music music "Ambient, Slow, Nature Sounds" --instrumental
   ```

6. Combine options for custom results:
   ```bash
   s-music music "Jazz, Smooth, Night City" --lyrics-optimizer --duration 120
   ```

## Advanced Music Generation Parameters

### lyrics_optimizer

When enabled, the MiniMax API will automatically generate lyrics based on your prompt. This is useful when you have a concept or theme but don't want to write specific lyrics.

- **Default**: `false`
- **Usage**: `--lyrics-optimizer`
- **Model requirement**: Works with all music models

Example:
```bash
s-music music "Rock song about overcoming challenges" --lyrics-optimizer
```

### is_instrumental

Generate music without vocals, creating purely instrumental tracks. This option is only available with music-2.5 and later models.

- **Default**: `false`
- **Usage**: `--instrumental`
- **Model requirement**: music-2.5+ only

Example:
```bash
s-music music "Classical piano, emotional, minor key" --instrumental
```

### Model Selection

The CLI defaults to using the `music-2.5+` model which offers:
- Enhanced audio quality
- Better instrument separation
- Extended duration support
- Hex output format for direct audio data

### Combining Parameters

You can use these parameters together with other options:

```bash
# Generate instrumental electronic music
s-music music "Synthwave, Retro, 80s" --instrumental

# Generate rock music with auto-optimized lyrics
s-music music "Alternative Rock, Grunge, 90s style" --lyrics-optimizer

# Note: lyrics_optimizer and is_instrumental are mutually exclusive
# Using both together will result in instrumental music (no lyrics)
```

## Requirements

- Zig 0.15.0 or later
- MiniMax API key (sign up at <https://api.minimax.io>)
- Internet connection for API calls and MP3 downloads

## Validation

The CLI validates all inputs before sending requests:
- Prompt: Maximum 2000 characters
- Lyrics: Maximum 3500 characters (if provided)
- Audio settings: Validated sample rates, bitrates, and formats

## Error Messages

Common errors and their solutions:

- `Prompt is required` - Provide a music style description
- `Lyrics required` - Provide lyrics with --lyrics or use --lyrics-optimizer
- `Prompt too long` - Keep prompt under 2000 characters
- `Invalid API key` - Check your API key configuration
