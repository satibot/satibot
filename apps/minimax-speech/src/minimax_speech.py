#!/usr/bin/env python3
"""
MiniMax Text-to-Speech CLI

A command-line tool for generating speech from text using the MiniMax API via WebSocket.

Usage:
    python -m minimax_speech "Hello, world!" [api_key]
    python -m minimax_speech "Hello" --model speech-2.8-hd --voice English_expressive_narrator --speed 1.0
"""

import argparse
import asyncio
import json
import os
import ssl
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional

try:
    import websockets
except ImportError:
    print("Error: websockets package is required.")
    print("Install it with: pip install websockets")
    sys.exit(1)

DEFAULT_MODEL = "speech-2.8-hd"
DEFAULT_VOICE = "English_expressive_narrator"
DEFAULT_SPEED = 1.0
DEFAULT_VOL = 1.0
DEFAULT_PITCH = 0
DEFAULT_FORMAT = "mp3"
DEFAULT_SAMPLE_RATE = 32000
DEFAULT_BITRATE = 128000


@dataclass
class TTSConfig:
    model: str = DEFAULT_MODEL
    voice_id: str = DEFAULT_VOICE
    speed: float = DEFAULT_SPEED
    vol: float = DEFAULT_VOL
    pitch: float = DEFAULT_PITCH
    format: str = DEFAULT_FORMAT
    sample_rate: int = DEFAULT_SAMPLE_RATE
    bitrate: int = DEFAULT_BITRATE
    english_normalization: bool = False


class StreamAudioPlayer:
    def __init__(self):
        self.mpv_process: Optional[subprocess.Popen] = None

    def start_mpv(self) -> bool:
        try:
            mpv_command = ["mpv", "--no-cache", "--no-terminal", "--", "fd://0"]
            self.mpv_process = subprocess.Popen(
                mpv_command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            print("MPV player started")
            return True
        except FileNotFoundError:
            print(
                "Error: mpv not found. Please install mpv: https://mpv.io/installation/"
            )
            return False
        except Exception as e:
            print(f"Failed to start mpv: {e}")
            return False

    def play_audio_chunk(self, hex_audio: str) -> bool:
        try:
            if self.mpv_process and self.mpv_process.stdin:
                audio_bytes = bytes.fromhex(hex_audio)
                self.mpv_process.stdin.write(audio_bytes)
                self.mpv_process.stdin.flush()
                return True
        except Exception as e:
            print(f"Play failed: {e}")
            return False
        return False

    def stop(self):
        if self.mpv_process:
            if self.mpv_process.stdin and not self.mpv_process.stdin.closed:
                self.mpv_process.stdin.close()
            try:
                self.mpv_process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.mpv_process.terminate()


async def establish_connection(api_key: str):
    url = "wss://api.minimax.io/ws/v1/t2a_v2"
    headers = {"Authorization": f"Bearer {api_key}"}

    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    try:
        ws = await websockets.connect(url, additional_headers=headers, ssl=ssl_context)
        connected = json.loads(await ws.recv())
        if connected.get("event") == "connected_success":
            print("Connection successful")
            return ws
        return None
    except Exception as e:
        print(f"Connection failed: {e}")
        return None


async def start_task(websocket, config: TTSConfig):
    start_msg = {
        "event": "task_start",
        "model": config.model,
        "voice_setting": {
            "voice_id": config.voice_id,
            "speed": config.speed,
            "vol": config.vol,
            "pitch": config.pitch,
            "english_normalization": config.english_normalization,
        },
        "audio_setting": {
            "sample_rate": config.sample_rate,
            "bitrate": config.bitrate,
            "format": config.format,
            "channel": 1,
        },
    }
    await websocket.send(json.dumps(start_msg))
    response = json.loads(await websocket.recv())
    return response.get("event") == "task_started"


async def continue_task_with_stream_play(
    websocket, text: str, player: StreamAudioPlayer, output_file: Optional[str] = None
):
    await websocket.send(
        json.dumps(
            {
                "event": "task_continue",
                "text": text,
            }
        )
    )

    chunk_counter = 1
    total_audio_size = 0
    audio_data = b""

    while True:
        try:
            response = json.loads(await websocket.recv())

            if "data" in response and "audio" in response["data"]:
                audio = response["data"]["audio"]
                if audio:
                    print(f"Playing chunk #{chunk_counter}")
                    audio_bytes = bytes.fromhex(audio)
                    if player.play_audio_chunk(audio):
                        total_audio_size += len(audio_bytes)
                        audio_data += audio_bytes
                        chunk_counter += 1

            if response.get("is_final"):
                print(f"Audio synthesis completed: {chunk_counter - 1} chunks")
                if player.mpv_process and player.mpv_process.stdin:
                    player.mpv_process.stdin.close()

                if output_file:
                    with open(output_file, "wb") as f:
                        f.write(audio_data)
                    print(f"Audio saved as {output_file}")
                elif output_file is None:
                    ext = "mp3" if player.mpv_process else "mp3"
                    filename = f"output.{ext}"
                    with open(filename, "wb") as f:
                        f.write(audio_data)
                    print(f"Audio saved as {filename}")

                estimated_duration = total_audio_size * 0.0625 / 1000
                wait_time = max(estimated_duration + 5, 10)
                return wait_time

        except Exception as e:
            print(f"Error: {e}")
            break

    return 10


async def close_connection(websocket):
    if websocket:
        try:
            await websocket.send(json.dumps({"event": "task_finish"}))
            await websocket.close()
        except Exception:
            pass


async def synthesize(
    api_key: str,
    text: str,
    config: TTSConfig,
    output_file: Optional[str] = None,
    play: bool = True,
):
    player = StreamAudioPlayer() if play else None

    try:
        if play:
            if not player.start_mpv():
                return False

        ws = await establish_connection(api_key)
        if not ws:
            return False

        if not await start_task(ws, config):
            print("Task startup failed")
            return False

        wait_time = await continue_task_with_stream_play(ws, text, player, output_file)
        await asyncio.sleep(wait_time)

        return True

    except Exception as e:
        print(f"Error: {e}")
        return False
    finally:
        if play:
            player.stop()
        if "ws" in locals():
            await close_connection(ws)


def get_api_key_from_config() -> Optional[str]:
    config_path = "config.json"
    if not os.path.exists(config_path):
        return None
    try:
        with open(config_path, "r") as f:
            import json

            config = json.load(f)
            return config.get("providers", {}).get("minimax", {}).get("apiKey")
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(
        description="MiniMax Text-to-Speech CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s "Hello, world!"                            # Basic usage
  %(prog)s "Hello" --model speech-2.8-hd             # Specify model
  %(prog)s "Hello" --voice English_expressive_narrator --speed 1.2
  %(prog)s "Hello" -o output.mp3                     # Save to file
  %(prog)s "Hello" --no-play                          # Don't auto-play

Config:
  Set API key via MINIMAX_API_KEY env or config.json:
  { "providers": { "minimax": { "apiKey": "your-key" } } }
        """,
    )

    parser.add_argument("text", nargs="?", help="Text to synthesize")
    parser.add_argument(
        "api_key", nargs="?", help="MiniMax API key (or set MINIMAX_API_KEY)"
    )
    parser.add_argument(
        "-m",
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model to use (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "-v",
        "--voice",
        default=DEFAULT_VOICE,
        help=f"Voice ID (default: {DEFAULT_VOICE})",
    )
    parser.add_argument(
        "-s",
        "--speed",
        type=float,
        default=DEFAULT_SPEED,
        help=f"Speech speed (default: {DEFAULT_SPEED})",
    )
    parser.add_argument(
        "--vol",
        type=float,
        default=DEFAULT_VOL,
        help=f"Volume (default: {DEFAULT_VOL})",
    )
    parser.add_argument(
        "--pitch",
        type=float,
        default=DEFAULT_PITCH,
        help=f"Pitch adjustment (default: {DEFAULT_PITCH})",
    )
    parser.add_argument(
        "-f",
        "--format",
        default=DEFAULT_FORMAT,
        help=f"Audio format: mp3, wav, pcm (default: {DEFAULT_FORMAT})",
    )
    parser.add_argument(
        "--sample-rate",
        type=int,
        default=DEFAULT_SAMPLE_RATE,
        help=f"Sample rate (default: {DEFAULT_SAMPLE_RATE})",
    )
    parser.add_argument(
        "--bitrate",
        type=int,
        default=DEFAULT_BITRATE,
        help=f"Bitrate (default: {DEFAULT_BITRATE})",
    )
    parser.add_argument("-o", "--output", help="Output file path")
    parser.add_argument("--no-play", action="store_true", help="Don't auto-play audio")
    parser.add_argument(
        "--english-normalization",
        action="store_true",
        help="Enable English text normalization",
    )

    args = parser.parse_args()

    if not args.text:
        parser.print_help()
        sys.exit(1)

    api_key = args.api_key or os.getenv("MINIMAX_API_KEY") or get_api_key_from_config()

    if not api_key:
        print("Error: No API key provided. Set MINIMAX_API_KEY or pass as argument.")
        sys.exit(1)

    config = TTSConfig(
        model=args.model,
        voice_id=args.voice,
        speed=args.speed,
        vol=args.vol,
        pitch=args.pitch,
        format=args.format,
        sample_rate=args.sample_rate,
        bitrate=args.bitrate,
        english_normalization=args.english_normalization,
    )

    print(f"Synthesizing text: {args.text[:50]}{'...' if len(args.text) > 50 else ''}")
    print(f"Model: {config.model}, Voice: {config.voice_id}, Speed: {config.speed}")

    success = asyncio.run(
        synthesize(
            api_key=api_key,
            text=args.text,
            config=config,
            output_file=args.output,
            play=not args.no_play,
        )
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
