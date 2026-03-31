# MiniMax Music CLI

A command-line tool for generating music and lyrics using the MiniMax API.

## Features

- Generate lyrics from text prompts
- Generate music with customizable style, mood, and vocals
- Automatic MP3 download from generated URLs
- Attempts to play MP3 with system default player
- Configuration file support for API key management

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

## Requirements

- Zig 0.15.0 or later
- MiniMax API key (sign up at <https://api.minimax.io>)
- Internet connection for API calls and MP3 downloads
