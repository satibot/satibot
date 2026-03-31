> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Async Long TTS Guide

> MiniMax provides an asynchronous TTS for long-form audio synthesis tasks, with a maximum limit of 1M characters per request for text input.

1. Supports 100+ system voices and custom cloned voices.
2. Supports adjustment of pitch, speech rate, volume, bitrate, sample rate, and output format.
3. Supports returning parameters such as audio duration and audio size.
4. Supports timestamp (subtitles) return, accurate to the sentence level.
5. Supports two input methods for text to be synthesized: direct string input and uploading a text file via file\_id.
6. Supports detection of invalid characters: if invalid characters do not exceed 10% (including 10%), audio will be generated normally and the proportion of invalid characters will be returned; if invalid characters exceed 10%, the interface will not return a result (error code will be returned), please check and submit the request again. \[Invalid characters definition: ASCII control characters in ASCII code (excluding tabs (`\t`) and newlines (`\n`))].

Applicable scenario: Speech generation for long texts, such as entire books.

## Models

| Model            | Description                                                                                              |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| speech-2.8-hd    | Perfecting Tonal Nuances. Maximizing Timbre Similarity.                                                  |
| speech-2.6-hd    | Ultra-low latency, intelligence parsing, and enhanced naturalness.                                       |
| speech-2.8-turbo | Faster, more affordable, perfecting Tonal Nuances.                                                       |
| speech-2.6-turbo | Faster, more affordable, and ideal for your agent.                                                       |
| speech-02-hd     | Superior rhythm and stability, with outstanding performance in replication similarity and sound quality. |
| speech-02-turbo  | Superior rhythm and stability, with enhanced multilingual capabilities and excellent performance.        |

## Supported Languages

MiniMax’s speech synthesis models offer outstanding multilingual capabilities, with full support for 40 widely used languages worldwide. Our goal is to break down language barriers and build a truly universal AI model.

Currently supported languages include:

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

## Usage Workflow

1. **File Input (Optional):**\
   If you are using a file as input, first call the [File Upload API](/api-reference/file-management-upload) to upload the text and obtain a `file_id`.\
   If you are passing raw text as input, you can skip this step.
2. **Create a Speech Generation Task:**\
   Call the [Create Speech Generation Task](/api-reference/speech-t2a-async-create) to create a task and retrieve a `task_id`.
3. **Check Task Status:**\
   Use the [Query Speech Generation Task Status](/api-reference/speech-t2a-async-query) with the `task_id` to check the task progress.
4. **Retrieve the Audio File:**\
   Once the task is complete, the returned `file_id` can be used with the [File Retrieve API](/api-reference/file-management-retrieve) to download the audio result.\
   **Note:** The download URL is valid for **9 hours (32,400 seconds)** from the time it is generated. After expiration, the file becomes unavailable and the generated audio will be lost. Please make sure to download the file in time.

## Use Case

### Get file\_id

<CodeGroup>
  ```python Python theme={null}
  """
  This example demonstrates how to obtain the `file_id` for the text to be synthesized.
  Note: Make sure to set your API key in the environment variable `MINIMAX_API_KEY` before running.
  """
  import requests
  import os

  api_key = os.environ.get("MINIMAX_API_KEY")
  url = "<https://api.minimax.io/v1/files/upload>"

  payload = {'purpose': 't2a_async_input'}
  files = [
      ('file', ('input_files.zip', open('path/to/input_files.zip', 'rb'), 'application/zip'))
  ]
  headers = {
      'authority': 'api.minimax.io',
      'Authorization': f'Bearer {api_key}'
  }

  response = requests.request("POST", url, headers=headers, data=payload, files=files)

  print(response.text)
  ```

  ```bash curl theme={null}
  curl --location 'https://api.minimax.io/v1/files/upload' \
    --header 'authority: api.minimax.io' \
    --header "Authorization: Bearer $MINIMAX_API_KEY" \
    --form 'purpose=t2a_async_input' \
    --form 'file=@test-json.zip'
  ```
</CodeGroup>

### Create Speech Generation Task

<CodeGroup>
  ```python Python theme={null}
  """
  This example demonstrates how to create a speech synthesis task.
  If using a file as input, replace <text_file_id> with the file_id of the text file.
  If using raw text as input, set the "text" field instead.
  Note: Make sure to set your API key in the environment variable MINIMAX_API_KEY.
  """
  import requests
  import json
  import os

  api_key = os.environ.get("MINIMAX_API_KEY")
  url = "<https://api.minimax.io/v1/t2a_async_v2>"

  payload = json.dumps({
      "model": "speech-2.8-hd",
      "text_file_id": <text_file_id>,  # file as input

      # "text": "A gentle breeze sweeps across the soft grass, carrying a fresh fragrance along with the songs of birds — omg it's so beautiful.",  # text as input
      
      "language_boost": "auto",
      "voice_setting": {
          "voice_id": "English_expressive_narrator",
          "speed": 1,
          "vol": 10,
          "pitch": 1
      },
      "pronunciation_dict": {
          "tone": [
              "omg/oh my god"
          ]
      },
      "audio_setting": {
          "audio_sample_rate": 32000,
          "bitrate": 128000,
          "format": "mp3",
          "channel": 2
      },
      "voice_modify": {
          "pitch": 0,
          "intensity": 0,
          "timbre": 0,
          "sound_effects": "spacious_echo"
      }
  })
  headers = {
      'Authorization': f'Bearer {api_key}',
      'Content-Type': 'application/json'
  }

  response = requests.request("POST", url, headers=headers, data=payload)

  print(response.text)
  ```

  ```bash curl theme={null}
  # If using a file as input, replace <text_file_id> with the file_id of the text file.
  # If using raw text as input, set the "text" field instead.
  # Note: Make sure to set your API key in the environment variable MINIMAX_API_KEY.
  curl --location 'https://api.minimax.io/v1/t2a_async_v2' \
    --header "authorization: Bearer ${MINIMAX_API_KEY}" \
    --header 'Content-Type: application/json' \
    --data '{
      "model": "speech-2.8-hd",
      "text_file_id": <Your file_id>,
      "language_boost": "auto",
      "voice_setting": {
        "voice_id": "English_expressive_narrator",
        "speed": 1,
        "vol": 10,
        "pitch": 1
      },
      "pronunciation_dict": {
        "tone": [
          "omg/oh my god"
        ]
      },
      "audio_setting": {
        "audio_sample_rate": 32000,
        "bitrate": 128000,
        "format": "mp3",
        "channel": 2
      },
        "voice_modify":{
          "pitch":0,
          "intensity":0,
          "timbre":0,
          "sound_effects":"spacious_echo"
        }
    }'
  ```
</CodeGroup>

### Query of Generation Status

<CodeGroup>
  ```python Python theme={null}
  """
  This example is used to check the progress of a speech synthesis task.
  Note: Make sure to set your API key in the environment variable MINIMAX_API_KEY, and the task ID to be queried in the environment variable TASK_ID.
  """
  import requests
  import json
  import os

  task_id = os.environ.get("TASK_ID")
  api_key = os.environ.get("MINIMAX_API_KEY")
  url = f"<https://api.minimax.io/v1/query/t2a_async_query_v2?task_id={task_id}>"

  payload = {}
  headers = {
      'Authorization': f'Bearer {api_key}',
      'content-type': 'application/json',
  }

  response = requests.request("GET", url, headers=headers, data=payload)

  print(response.text)
  ```

  ```bash curl theme={null}
  curl --location "https://api.minimax.io/v1/query/t2a_async_query_v2?task_id=${TASK_ID}" \
    --header "authorization: Bearer ${MINIMAX_API_KEY}" \
    --header 'content-type: application/json'
  ```
</CodeGroup>

### Retrieve the Download URL of the Audio File

<CodeGroup>
  ```python Python theme={null}
  """
  This example is used to download a speech synthesis file.
  Note: Make sure to set your API key in the environment variable MINIMAX_API_KEY, and the file ID to be downloaded in the environment variable FILE_ID.
  """
  import requests
  import os

  api_key = os.environ.get("MINIMAX_API_KEY")
  file_id = os.environ.get("FILE_ID")

  url = f"<https://api.minimax.io/v1/files/retrieve_content?file_id={file_id}>"

  payload = {}
  headers = {
      'content-type': 'application/json',
      'Authorization': f'Bearer {api_key}'
  }

  response = requests.request("GET", url, headers=headers, data=payload)

  with open(<output_filename>, 'wb') as f:
      f.write(response.content)
  ```

  ```bash  theme={null}
  curl --location "https://api.minimax.io/v1/files/retrieve_content?file_id=${FILE_ID}" \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${MINIMAX_API_KEY}" \
    --output "${FILE_NAME}" \
  ```
</CodeGroup>

## Recommended Reading

<Columns cols={2}>
  <Card title="Create Speech Generation Task" icon="book-open" href="/api-reference/speech-t2a-async-create" cta="Click here">
    Use this API to create an asynchronous Text-to-Speech task.
  </Card>

  <Card title="Text to Speech (T2A) HTTP" icon="book-open" href="/api-reference/speech-t2a-http" cta="Click here">
    Use this API for synchronous t2a over HTTP.
  </Card>

  <Card title="Pricing" icon="book-open" href="/guides/pricing-paygo#audio" cta="Click here">
    Detailed information on model pricing and API packages.
  </Card>

  <Card title="Rate Limits" icon="book-open" href="/guides/rate-limits#3-rate-limits-for-our-api" cta="Click here">
    Rate limits are restrictions that our API imposes on the number of times a user or client can access our services within a specified period of time.
  </Card>
</Columns>
