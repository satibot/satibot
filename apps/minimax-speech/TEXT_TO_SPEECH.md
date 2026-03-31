> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Synchronous Text-to-Speech Guide (WebSocket)

> Synchronous TTS allows real-time text-to-speech synthesis, handling up to 10,000 characters per request.

## Supported Models

Below are the MiniMax speech models and their key features.

| Model            | Description                                                                                              |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| speech-2.8-hd    | Perfecting Tonal Nuances. Maximizing Timbre Similarity.                                                  |
| speech-2.6-hd    | Ultra-low latency, intelligence parsing, and enhanced naturalness.                                       |
| speech-2.8-turbo | Faster, more affordable, perfecting Tonal Nuances.                                                       |
| speech-2.6-turbo | Faster, more affordable, and ideal for your agent.                                                       |
| speech-02-hd     | Superior rhythm and stability, with outstanding performance in replication similarity and sound quality. |
| speech-02-turbo  | Superior rhythm and stability, with enhanced multilingual capabilities and excellent performance.        |

## Supported Languages

MiniMax TTS models provide strong cross-lingual capabilities, supporting 40 widely used global languages. Our goal is to break language barriers and build truly universal AI models.

| Support Languages |               |               |
| ----------------- | ------------- | ------------- |
| 1. Chinese        | 15. Turkish   | 28. Malay     |
| 2. Cantonese      | 16. Dutch     | 29. Persian   |
| 3. English        | 17. Ukrainian | 30. Slovak    |
| 4. Spanish        | 18. Thai      | 31. Swedish   |
| 5. French         | 19. Polish    | 32. Croatian  |
| 6. Russian        | 20. Romanian  | 33. Filipino  |
| 7. German         | 21. Greek     | 34. Hungarian |
| 8. Portuguese     | 22. Czech     | 35. Norwegian |
| 9. Arabic         | 23. Finnish   | 36. Slovenian |
| 10. Italian       | 24. Hindi     | 37. Catalan   |
| 11. Japanese      | 25. Bulgarian | 38. Nynorsk   |
| 12. Korean        | 26. Danish    | 39. Tamil     |
| 13. Indonesian    | 27. Hebrew    | 40. Afrikaans |
| 14. Vietnamese    |               |               |

## Streaming Request Example

This guide demonstrates streaming playback of synthesized audio while saving the full audio file.

⚠️ Note: To play audio streams in real-time, install [MPV player](https://mpv.io/installation/) first. Also, ensure your API key is set in the environment variable `MINIMAX_API_KEY`.

Request example:

<CodeGroup>
  ```python  theme={null}

  import asyncio
  import websockets
  import json
  import ssl
  import subprocess
  import os

  model = "speech-2.8-hd"
  file_format = "mp3"

  class StreamAudioPlayer:
      def __init__(self):
          self.mpv_process = None

      def start_mpv(self):
          """Start MPV player process"""
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
              print("Error: mpv not found. Please install mpv")
              return False
          except Exception as e:
              print(f"Failed to start mpv: {e}")
              return False

      def play_audio_chunk(self, hex_audio):
          """Play audio chunk"""
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
          """Stop player"""
          if self.mpv_process:
              if self.mpv_process.stdin and not self.mpv_process.stdin.closed:
                  self.mpv_process.stdin.close()
              try:
                  self.mpv_process.wait(timeout=20)
              except subprocess.TimeoutExpired:
                  self.mpv_process.terminate()

  async def establish_connection(api_key):
      """Establish WebSocket connection"""
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

  async def start_task(websocket):
      """Send task start request"""
      start_msg = {
          "event": "task_start",
          "model": model,
          "voice_setting": {
              "voice_id": "English_expressive_narrator",
              "speed": 1,
              "vol": 1,
              "pitch": 0,
              "english_normalization": False
          },
          "audio_setting": {
              "sample_rate": 32000,
              "bitrate": 128000,
              "format": file_format,
              "channel": 1
          }
      }
      await websocket.send(json.dumps(start_msg))
      response = json.loads(await websocket.recv())
      return response.get("event") == "task_started"

  async def continue_task_with_stream_play(websocket, text, player):
      """Send continue request and stream play audio"""
      await websocket.send(json.dumps({
          "event": "task_continue",
          "text": text
      }))

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
                  print(f"Audio synthesis completed: {chunk_counter-1} chunks")
                  if player.mpv_process and player.mpv_process.stdin:
                      player.mpv_process.stdin.close()

                  # Save audio to file
                  with open(f"output.{file_format}", "wb") as f:
                      f.write(audio_data)
                  print(f"Audio saved as output.{file_format}")

                  estimated_duration = total_audio_size * 0.0625 / 1000
                  wait_time = max(estimated_duration + 5, 10)
                  return wait_time

          except Exception as e:
              print(f"Error: {e}")
              break

      return 10

  async def close_connection(websocket):
      """Close connection"""
      if websocket:
          try:
              await websocket.send(json.dumps({"event": "task_finish"}))
              await websocket.close()
          except Exception:
              pass

  async def main():
      API_KEY = os.getenv("MINIMAX_API_KEY")
      TEXT = "The real danger is not that computers start thinking like people(sighs), but that people start thinking like computers. Computers can only help us with simple tasks."

      player = StreamAudioPlayer()

      try:
          if not player.start_mpv():
              return

          ws = await establish_connection(API_KEY)
          if not ws:
              return

          if not await start_task(ws):
              print("Task startup failed")
              return

          wait_time = await continue_task_with_stream_play(ws, TEXT, player)
          await asyncio.sleep(wait_time)

      except Exception as e:
          print(f"Error: {e}")
      finally:
          player.stop()
          if 'ws' in locals():
              await close_connection(ws)

  if __name__ == "__main__":
      asyncio.run(main())
  ```
</CodeGroup>

## Recommended Reading

<Columns cols={2}>
  <Card title="Text to Speech (T2A) WebSocket" icon="book-open" href="/api-reference/speech-t2a-websocket" arrow="true" cta="Click here">
    Use this API for synchronous t2a over WebSocket.
  </Card>

  <Card title="Text to Speech (T2A) HTTP" icon="book-open" href="/api-reference/speech-t2a-http" arrow="true" cta="Click here">
    Use this API for synchronous t2a over HTTP.
  </Card>

  <Card title="Pricing" icon="book-open" href="/guides/pricing-paygo#audio" arrow="true" cta="Click here">
    Detailed information on model pricing and API packages.
  </Card>

  <Card title="Rate Limits" icon="book-open" href="/guides/rate-limits#3-rate-limits-for-our-api#3-rate-limits-for-our-api" arrow="true" cta="Click here">
    Rate limits are restrictions that our API imposes on the number of times a user or client can access our services within a specified period of time.
  </Card>
</Columns>
