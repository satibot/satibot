> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Music Generation

> Use this API to generate a song from lyrics and a prompt.

## OpenAPI

````yaml POST /v1/music_generation
openapi: 3.1.0
info:
  title: MiniMax Music Generation API
  description: >-
    MiniMax music generation API with support for creating music from text
    prompts and lyrics
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.io
security:
  - bearerAuth: []
paths:
  /v1/music_generation:
    post:
      tags:
        - Music
      summary: Music Generation
      operationId: generateMusic
      parameters:
        - name: Content-Type
          in: header
          required: true
          description: >-
            The media type of the request body. Must be set to
            `application/json` to ensure the data is sent in JSON format.
          schema:
            type: string
            enum:
              - application/json
            default: application/json
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/GenerateMusicReq'
        required: true
      responses:
        '200':
          description: ''
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/GenerateMusicResp'
components:
  schemas:
    GenerateMusicReq:
      type: object
      required:
        - model
      properties:
        model:
          type: string
          description: 'The model name. Options: `music-2.5+` (recommended) or `music-2.5`.'
          enum:
            - music-2.5+
            - music-2.5
        prompt:
          type: string
          description: >-
            A description of the music, specifying style, mood, and scenario.


            For example: "`Pop, melancholic, perfect for a rainy night`".

            <br>

            Note:

            - For `music-2.5+` with `is_instrumental: true`: Required. Length:
            1–2000 characters.

            - For `music-2.5` / `music-2.5+` (non-instrumental): Optional.
            Length: 0–2000 characters.
          maxLength: 2000
        lyrics:
          type: string
          description: >-
            Song lyrics, using `\n` to separate lines. Supports structure tags:
            `[Intro]`, `[Verse]`, `[Pre Chorus]`, `[Chorus]`, `[Interlude]`,
            `[Bridge]`, `[Outro]`, `[Post Chorus]`, `[Transition]`, `[Break]`,
            `[Hook]`, `[Build Up]`, `[Inst]`, `[Solo]`.

            <br>

            Note:

            - For `music-2.5+` with `is_instrumental: true`: Not required.

            - For `music-2.5` / `music-2.5+` (non-instrumental): Required.
            Length: 1–3500 characters.

            - When `lyrics_optimizer: true` and `lyrics` is empty, the system
            will auto-generate lyrics from `prompt`.
          minLength: 1
          maxLength: 3500
        stream:
          type: boolean
          description: Whether to use streaming output.
          default: false
        output_format:
          type: string
          description: |-
            The output format of the audio. Options: `url` or `hex`.

            When `stream` is `true`, only `hex` is supported.

            ⚠️ Note: `url` links expire after 24 hours, so download promptly.
          enum:
            - url
            - hex
          default: hex
        audio_setting:
          $ref: '#/components/schemas/AudioSetting'
        lyrics_optimizer:
          type: boolean
          description: >-
            Whether to automatically generate lyrics based on the `prompt`
            description. Only supported on `music-2.5` and `music-2.5+`.


            When set to `true` and `lyrics` is empty, the system will
            automatically generate lyrics from the prompt. Default: `false`.
          default: false
        is_instrumental:
          type: boolean
          description: >-
            Whether to generate instrumental music (no vocals). Only supported
            on `music-2.5+`.


            When set to `true`, the `lyrics` field is not required. Default:
            `false`.
          default: false
      example:
        model: music-2.5+
        prompt: >-
          Indie folk, melancholic, introspective, longing, solitary walk, coffee
          shop
        lyrics: |-
          [verse]
          Streetlights flicker, the night breeze sighs
          Shadows stretch as I walk alone
          An old coat wraps my silent sorrow
          Wandering, longing, where should I go
          [chorus]
          Pushing the wooden door, the aroma spreads
          In a familiar corner, a stranger gazes
        audio_setting:
          sample_rate: 44100
          bitrate: 256000
          format: mp3
    GenerateMusicResp:
      type: object
      properties:
        data:
          $ref: '#/components/schemas/MusicData'
        base_resp:
          $ref: '#/components/schemas/BaseResp'
      example:
        data:
          audio: hex-encoded audio data
          status: 2
        trace_id: 04ede0ab069fb1ba8be5156a24b1e081
        extra_info:
          music_duration: 25364
          music_sample_rate: 44100
          music_channel: 2
          bitrate: 256000
          music_size: 813651
        analysis_info: null
        base_resp:
          status_code: 0
          status_msg: success
    AudioSetting:
      type: object
      description: Audio output configuration
      properties:
        sample_rate:
          type: integer
          description: 'Sampling rate. Options: `16000`, `24000`, `32000`, `44100`.'
        bitrate:
          type: integer
          description: 'Bitrate. Options: `32000`, `64000`, `128000`, `2560000`.'
        format:
          type: string
          description: 'Audio format. Options: `mp3`, `wav`, `pcm`.'
          enum:
            - mp3
            - wav
            - pcm
    MusicData:
      type: object
      properties:
        status:
          type: integer
          description: |-
            Music generation status:

            1: In progress

            2: Completed
        audio:
          type: string
          description: |-
            Returned when `output_format` is `hex`.

            Contains the audio file as a hexadecimal-encoded string.
    BaseResp:
      type: object
      description: Status code and details
      properties:
        status_code:
          type: integer
          description: >-
            Status codes and their meanings:


            `0`: Success


            `1002`: Rate limit triggered, retry later


            `1004`: Authentication failed, check API key


            `1008`: Insufficient balance


            `1026`: Content flagged for sensitive material


            `2013`: Invalid parameters, check input


            `2049`: Invalid API key


            For more information, please refer to the [Error Code
            Reference](/api-reference/errorcode).
        status_msg:
          type: string
          description: Detailed error message
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: >-
        `HTTP: Bearer Auth`

        - Security Scheme Type: http

        - HTTP Authorization Scheme: `Bearer API_key`, can be found in [Account
        Management>API
        Keys](https://platform.minimax.io/user-center/basic-information/interface-key).

````
