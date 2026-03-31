> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Lyrics Generation

> Use this API to generate lyrics, supporting full song creation and lyrics editing/continuation.

## OpenAPI

````yaml POST /v1/lyrics_generation
openapi: 3.1.0
info:
  title: MiniMax Lyrics Generation API
  description: >-
    MiniMax Lyrics Generation API with support for full song creation and lyrics
    editing/continuation
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.io
security:
  - bearerAuth: []
paths:
  /v1/lyrics_generation:
    post:
      tags:
        - Music
      summary: Lyrics Generation
      operationId: generateLyrics
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
              $ref: '#/components/schemas/GenerateLyricsReq'
        required: true
      responses:
        '200':
          description: Successful response
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/GenerateLyricsResp'
components:
  schemas:
    GenerateLyricsReq:
      type: object
      required:
        - mode
      properties:
        mode:
          type: string
          description: >-
            Generation mode.<br>`write_full_song`: Write a complete
            song<br>`edit`: Edit/continue existing lyrics
          enum:
            - write_full_song
            - edit
        prompt:
          type: string
          description: >-
            Prompt/instruction describing the song theme, style, or editing
            direction. If empty, a random song will be generated.
          maxLength: 2000
        lyrics:
          type: string
          description: >-
            Existing lyrics content. Only effective in `edit` mode. Can be used
            for continuation or modification of existing lyrics.
          maxLength: 3500
        title:
          type: string
          description: Song title. If provided, the output will keep this title unchanged.
      example:
        mode: write_full_song
        prompt: A cheerful love song about a summer day at the beach
    GenerateLyricsResp:
      type: object
      properties:
        song_title:
          type: string
          description: >-
            Generated song title. If `title` was provided in the request, it
            will be preserved.
        style_tags:
          type: string
          description: >-
            Style tags, comma-separated. For example: `Pop, Upbeat, Female
            Vocals`
        lyrics:
          type: string
          description: >-
            Generated lyrics with structure tags. Can be directly used in the
            `lyrics` parameter of the [Music Generation
            API](/api-reference/music-generation) to generate
            songs.<br>Supported structure tags (14 types): `[Intro]`, `[Verse]`,
            `[Pre-Chorus]`, `[Chorus]`, `[Hook]`, `[Drop]`, `[Bridge]`,
            `[Solo]`, `[Build-up]`, `[Instrumental]`, `[Breakdown]`, `[Break]`,
            `[Interlude]`, `[Outro]`
        base_resp:
          $ref: '#/components/schemas/BaseResp'
      example:
        song_title: Summer Breeze Promise
        style_tags: Pop, Summer Vibe, Romance, Lighthearted, Beach Pop
        lyrics: |-
          [Intro]
          (Ooh-ooh-ooh)
          (Yeah)
          Sunlight dancing on the waves

          [Verse 1]
          Sea breeze gently through your hair
          Smiling face, like a summer dream
          Waves are crashing at our feet
          Leaving footprints, you and me
          Laughter echoes on the sand
          Every moment, a sweet melody
          I see the sparkle in your eyes
          Like the stars in the deep blue sea

          [Pre-Chorus]
          You say this feeling is so wonderful
          (So wonderful)
          Want to stay in this moment forever
          (Right here, right now)
          Heartbeat racing like the ocean waves

          [Chorus]
          Oh, summer by the sea, our promise true
          In the sunlight, your silhouette so beautiful
          The breeze blows away our worries, leaving only sweet
          This moment, I just want to be with you, eternally
          (Forever with you)

          [Verse 2]
          ...
        base_resp:
          status_code: 0
          status_msg: success
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


            `1026`: Input contains sensitive content


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
