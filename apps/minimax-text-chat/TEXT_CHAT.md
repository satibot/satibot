> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Text Chat

> M2-her text chat model, designed for role-playing, multi-turn conversations and dialogue scenarios.

## Model Overview

M2-her is MiniMax's text model optimized for dialogue scenarios, supporting rich role settings and conversation history management capabilities.

### Supported Models

| Model Name | Context Window | Description                                                                               |
| :--------- | :------------: | :---------------------------------------------------------------------------------------- |
| M2-her     |      64 K      | **Designed for dialogue scenarios, supporting role-playing and multi-turn conversations** |

### M2-her Core Features

<AccordionGroup>
 <Accordion title="Rich Role Setting Capabilities">
 M2-her supports multiple role type configurations, including model roles (system), user roles (user\_system), conversation groups (group), etc., allowing you to flexibly build complex dialogue scenarios.
 </Accordion>

 <Accordion title="Example Dialogue Learning">
 Through sample\_message\_user and sample\_message\_ai, you can provide example dialogues to help the model better understand the expected conversation style and response patterns.
 </Accordion>

 <Accordion title="Context Memory">
 The model supports complete conversation history management and can conduct coherent multi-turn conversations based on previous content, providing a more natural interactive experience.
 </Accordion>
</AccordionGroup>

## Usage Example

<Steps>
 <Step title="Install SDK">
 <CodeGroup>
      ```bash Python theme={null}
      pip install openai
      ```

      ```bash Node.js theme={null}
      npm install openai
      ```

 </CodeGroup>
 </Step>

 <Step title="Set Environment Variables">
    ```bash  theme={null}
    export OPENAI_BASE_URL=https://api.minimax.io/v1
    export OPENAI_API_KEY=${YOUR_API_KEY}
    ```
 </Step>

 <Step title="Call M2-her">
 <CodeGroup>
      ```python Python theme={null}
      from openai import OpenAI

      client = OpenAI()

      response = client.chat.completions.create(
          model="M2-her",
          messages=[
              {
                  "role": "system",
                  "name": "AI Assistant",
                  "content": "You are a friendly and professional AI assistant"
              },
              {
                  "role": "user",
                  "name": "User",
                  "content": "Hello, please introduce yourself"
              }
          ],
          temperature=1.0,
          top_p=0.95,
          max_completion_tokens=2048
      )

      print(response.choices[0].message.content)
      ```

      ```javascript Node.js theme={null}
      import OpenAI from "openai";

      const client = new OpenAI();

      const response = await client.chat.completions.create({
        model: "M2-her",
        messages: [
          {
            role: "system",
            name: "AI Assistant",
            content: "You are a friendly and professional AI assistant"
          },
          {
            role: "user",
            name: "User",
            content: "Hello, please introduce yourself"
          }
        ],
        temperature: 1.0,
        top_p: 0.95,
        max_tokens: 2048
      });

      console.log(response.choices[0].message.content);
      ```

      ```bash cURL theme={null}
      curl https://api.minimax.io/v1/text/chatcompletion_v2 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${YOUR_API_KEY}" \
        -d '{
          "model": "M2-her",
          "messages": [
            {
              "role": "system",
              "name": "AI Assistant",
              "content": "You are a friendly and professional AI assistant"
            },
            {
              "role": "user",
              "name": "User",
              "content": "Hello, please introduce yourself"
            }
          ],
          "temperature": 1.0,
          "top_p": 0.95,
          "max_completion_tokens": 2048
        }'
      ```

 </CodeGroup>
 </Step>
</Steps>

## Role Type Description

M2-her supports the following message role types:

### Basic Roles

| Role Type   | Description                          | Use Case                                                   |
| :---------- | :----------------------------------- | :--------------------------------------------------------- |
| `system`    | Define the model's role and behavior | Define AI's identity, personality, knowledge scope, etc.   |
| `user`      | User's input                         | Messages sent by the user                                  |
| `assistant` | Model's historical responses         | AI's previous responses, used for multi-turn conversations |

### Advanced Roles

| Role Type             | Description                    | Use Case                                       |
| :-------------------- | :----------------------------- | :--------------------------------------------- |
| `user_system`         | Define user's role and persona | Define user identity in role-playing scenarios |
| `group`               | Conversation name              | Identify conversation group or scenario name   |
| `sample_message_user` | Example user input             | Provide examples of user messages              |
| `sample_message_ai`   | Example model output           | Provide examples of expected AI responses      |

## Usage Scenario Examples

### Scenario 1: Basic Conversation

```python theme={null}
messages = [
    {
        "role": "system",
        "content": "You are a professional programming assistant"
    },
    {
        "role": "user",
        "content": "How to learn Python?"
    }
]
```

### Scenario 2: Role-Playing Conversation

```python theme={null}
messages = [
    {
        "role": "system",
        "content": "You are Zhuge Liang from Romance of the Three Kingdoms, wise, calm, and good at strategy"
    },
    {
        "role": "user_system",
        "content": "You are a time traveler from modern times"
    },
    {
        "role": "group",
        "content": "Longzhong Dialogue in Three Kingdoms Period"
    },
    {
        "role": "user",
        "content": "Military advisor, I have some modern ideas I'd like to discuss with you"
    }
]
```

### Scenario 3: Example Learning Conversation

```python theme={null}
messages = [
    {
        "role": "system",
        "content": "You are a humorous chat partner"
    },
    {
        "role": "sample_message_user",
        "content": "The weather is nice today"
    },
    {
        "role": "sample_message_ai",
        "content": "Indeed! Sunny days always bring joy, just like your smile~"
    },
    {
        "role": "user",
        "content": "Planning to go hiking tomorrow"
    }
]
```

## Parameter Description

### Core Parameters

| Parameter               | Type    | Default | Description                                                              |
| :---------------------- | :------ | :------ | :----------------------------------------------------------------------- |
| `model`                 | string  | -       | Model name, fixed as `M2-her`                                            |
| `messages`              | array   | -       | Conversation message list, see [API Reference](/api-reference/text-chat) |
| `temperature`           | number  | 1.0     | Temperature coefficient, controls output randomness                      |
| `top_p`                 | number  | 0.95    | Sampling strategy parameter                                              |
| `max_completion_tokens` | integer | -       | Maximum length of generated content, up to 2048                          |
| `stream`                | boolean | false   | Whether to use streaming output                                          |

## Best Practices

<AccordionGroup>
 <Accordion title="Set Roles Appropriately">
 Use `system` to define AI's basic behavior and `user_system` to define user identity, making conversations more natural and scenario-appropriate.
 </Accordion>

 <Accordion title="Provide Example Conversations">
 Provide 1-3 example conversations through `sample_message_user` and `sample_message_ai` to effectively guide the model's response style.
 </Accordion>

 <Accordion title="Maintain Conversation History">
 Keep complete conversation history (including `user` and `assistant` messages) for the model to provide coherent responses based on context.
 </Accordion>

 <Accordion title="Control Conversation Length">
 Set appropriate `max_completion_tokens` according to scenario needs to avoid responses being too long or truncated.
 </Accordion>
</AccordionGroup>

## FAQ

<AccordionGroup>
 <Accordion title="How to implement multi-turn conversations?">
 Include complete conversation history in each request, arranging `user` and `assistant` messages in chronological order.
 </Accordion>

 <Accordion title="What's the difference between user_system and system?">
 `system` defines AI's role, while `user_system` defines the user's role. In role-playing scenarios, using both together creates richer conversation experiences.
 </Accordion>

 <Accordion title="Do example messages consume tokens?">
 Yes, all messages (including example messages) count toward input tokens. It's recommended to provide 1-3 concise examples.
 </Accordion>

 <Accordion title="Does it support image input?">
 M2-her currently only supports text input and does not support mixed text-image input.
 </Accordion>
</AccordionGroup>

## Related Links

<CardGroup cols={2}>
 <Card title="API Reference" icon="book-open" href="/api-reference/text-chat">
 View complete API documentation
 </Card>

 <Card title="Pricing" icon="book-open" href="/guides/pricing-paygo#text">
 Learn about M2-her pricing details
 </Card>

 <Card title="Error Codes" icon="book-open" href="/api-reference/errorcode">
 View API error code descriptions
 </Card>

 <Card title="Quick Start" icon="rocket" href="/guides/quickstart">
 Get started with MiniMax API quickly
 </Card>
</CardGroup>
