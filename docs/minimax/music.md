> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Music Generation

> Use the prompt parameter to define the music's style, mood, and scenario, and the lyrics parameter to provide the vocal content. This feature is ideal for quickly generating unique theme songs for videos, games, or applications.

## Music 2.5:  Full-Dimensional Breakthrough

Music 2.5 achieves a full-dimensional breakthrough with "High Fidelity + Strong Control", bringing significant improvements across four key dimensions: **Instrumentation & Mixing, Vocal Performance, Structural Precision, and Sound Design**.

<AccordionGroup>
  <Accordion title=" Instrumentation & Mixing">
    Expanded high-sample-rate sound library (including orchestral and traditional instruments); optimized soundstage algorithms for more rational spectral distribution, allowing vocals and accompaniment to achieve complete spectral characteristics independently for a more transparent listening experience.
  </Accordion>

  <Accordion title=" Vocal Performance">
    Deep optimization targeting AI synthesis artifacts, introducing humanized timbre simulation with significantly enhanced Flow expressiveness, achieving physically authentic "real voice" quality.
  </Accordion>

  <Accordion title=" Structural Precision">
    * **Full Section Tag Control**: Precise support for 14+ music structure variants including Intro / Bridge / Interlude / Build-up / Hook, meeting the creative logic of complex compositions
    * **Dynamic Evolution Control**: Vocals can be fine-tuned for emotion and singing techniques section by section; instruments now feature precise control over orchestration, articulation, and sound texture—every sonic detail at your fingertips
  </Accordion>

  <Accordion title=" Sound Design">
    Stylized filters for music—delivering more genre-specific mixing characteristics based on different music styles. The system can automatically identify and reproduce the physical characteristics of specific genres, such as:

    * Rock's saturated distortion
    * The "Minneapolis Sound" of the 80s
    * Modern electronic's wide-frequency transients
    * Classic jazz's warm low-pass feel
  </Accordion>
</AccordionGroup>

## Music Generation Example

Let's walk through how to create a soulful blues track from scratch in two simple steps: first, use the Lyrics Generation API to write lyrics based on a theme; then, feed those lyrics into the Music Generation API to compose and produce a complete song.

<Steps>
  <Step title="Call the Lyrics Generation API to generate lyrics from a theme (optional)">
    Simply tell the model what you're looking for — for example, "a soulful blues song about a rainy night" — and the Lyrics Generation API will automatically write complete lyrics with proper song structure (Verse, Chorus, Bridge, etc.). If you already have your own lyrics, feel free to skip this step.

    <CodeGroup>
      ```python Lyrics Generation theme={null}
      import requests
      import os

      url = "https://api.minimax.io/v1/lyrics_generation"
      api_key = os.environ.get("MINIMAX_API_KEY")

      payload = {
          "mode": "write_full_song",
          "prompt": "A soulful blues song about a rainy night"
      }
      headers = {
          "Content-Type": "application/json",
          "Authorization": f"Bearer {api_key}"
      }

      response = requests.post(url, json=payload, headers=headers)

      print(response.text)
      ```
    </CodeGroup>
  </Step>

  <Step title="Call the Music Generation API to compose and produce the full song">
    Once you have your lyrics, set the music style via the `prompt` parameter (e.g., "Blues, Soulful, Rainy Night, Electric Guitar"), pass the lyrics into the `lyrics` parameter, and the Music Generation API will arrange, perform, and output a complete song.

    <CodeGroup>
      ```python Music Generation theme={null}
      import requests
      import json
      import os

      url = "https://api.minimax.io/v1/music_generation"
      api_key = os.environ.get("MINIMAX_API_KEY")

      headers = {
          "Content-Type": "application/json",
          "Authorization": f"Bearer {api_key}"
      }

      payload = {
          "model": "music-2.5",
          "prompt": "Soulful Blues, Rainy Night, Melancholy, Male Vocals, Slow Tempo",
          "lyrics": "[Intro]\n(Ooh, yeah)\n(Listen to that rain)\nOh, Lord...\nIt's fallin' down so hard tonight...\n\n[Verse 1]\nThe sky is cryin', Lord, I can hear it on the roof\n(Hear it on the roof)\nEach drop a memory, ain't that the mournful truth?\nThis old guitar is my only friend in this lonely room\nSingin' the midnight rain blues, lost in the gloom\nStreetlights paintin' shadows, dancin' on the wall\nWishin' I could wash away this feelin' with it all\n(Wash it all away)\n\n[Chorus]\nMidnight rain, fallin' down on me\n(Fallin' on me)\nLike tears I can't cry, for all the world to see\nThis ain't just water, baby, it's a soulful sound\nWashin' over my heart, nowhere to be found\n(Nowhere to be found)\nJust the rhythm of the rain, and the blues in my soul\nTryna make me feel whole, but it's takin' its toll\n\n[Verse 2]\nRemember when we danced in the summer shower?\n(Summer shower)\nLaughin' like fools, in that golden hour\nNow the cold, hard rain, it chills me to the bone\nReminds me that I'm standin' here, all alone\nEvery rumble of thunder, shakes me deep inside\nGot nowhere to run, baby, nowhere left to hide\n(Nowhere to hide)\n\n[Pre-Chorus]\nThis lonely melody, it keeps playin' on\n(On and on)\nEver since you been gone\n(You been gone)\nOh, this rainy night, it just won't let me be\n\n[Chorus]\nMidnight rain, fallin' down on me\n(Fallin' on me)\nLike tears I can't cry, for all the world to see\nThis ain't just water, baby, it's a soulful sound\nWashin' over my heart, nowhere to be found\n(Nowhere to be found)\nJust the rhythm of the rain, and the blues in my soul\nTryna make me feel whole, but it's takin' its toll\n\n[Bridge]\n(Oh, the rain...)\nIs it washin' away the good times?\nOr just remindin' me of all the past crimes?\nThis emptiness inside, it cuts me like a knife\nJust me and this rain, livin' this lonely life\n(Lonely life)\nI need a little sunshine, Lord, to dry these tears\nChase away these lonely, rainy night fears\n\n[Solo]\n(Guitar solo - slow, mournful, bluesy)\n(Yeah... play it, boy)\n(Feel that rain)\n(Mmm-hmm)\n\n[Chorus]\nMidnight rain, fallin' down on me\n(Fallin' on me)\nLike tears I can't cry, for all the world to see\nThis ain't just water, baby, it's a soulful sound\nWashin' over my heart, nowhere to be found\n(Nowhere to be found)\nJust the rhythm of the rain, and the blues in my soul\nTryna make me feel whole, but it's takin' its toll\n\n[Outro]\n(Midnight rain...)\nOh, the rain...\n(Fallin' down)\nJust keep fallin'...\n(Wash me clean)\nLord, wash me clean...\n(Yeah...)\n(Blues...\nFade out...)",
          "audio_setting": {
              "sample_rate": 44100,
              "bitrate": 256000,
              "format": "mp3"
          },
          "output_format": "url"
      }

      response = requests.post(url, headers=headers, json=payload)
      result = response.json()

      print(json.dumps(result, ensure_ascii=False, indent=2))
      ```
    </CodeGroup>
  </Step>

  <Step title="Listen to the result">
    After completing the steps above, you'll have a complete song:

    <video controls className="w-full aspect-video rounded-xl audio-container" src="https://file.cdn.minimax.io/public/71fa0e3f-6ea2-4ecf-b2e7-89ee3815fdc3.mp3" />
  </Step>
</Steps>

## Recommended Reading

<Columns cols={2}>
  <Card title="Music Generation API" icon="book-open" href="/api-reference/music-generation" arrow="true" cta="Click here">
    Use this API to generate a song from lyrics and a prompt.
  </Card>

  <Card title="Lyrics Generation API" icon="book-open" href="/api-reference/lyrics-generation" arrow="true" cta="Click here">
    Use this API to generate or edit lyrics from a song description.
  </Card>

  <Card title="Pricing" icon="book-open" href="/guides/pricing-paygo#music" arrow="true" cta="Click here">
    Detailed information on model pricing and API packages.
  </Card>

  <Card title="Rate Limits" icon="book-open" href="/guides/rate-limits#3-rate-limits-for-our-api" arrow="true" cta="Click here">
    Rate limits are restrictions that our API imposes on the number of times a user or client can access our services within a specified period of time.
  </Card>
</Columns>
