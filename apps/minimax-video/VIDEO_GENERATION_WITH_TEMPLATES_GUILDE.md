> ## Documentation Index
>
> Fetch the complete documentation index at: <https://platform.minimax.io/docs/llms.txt>
> Use this file to discover all available pages before exploring further.

# Video Generation with Templates Guide

> Video Agent generation service allows you to quickly create videos with a consistent style by filling predefined templates with assets such as images or text.

## Workflow

Template-based video generation is an asynchronous process with the following steps:

1. **Create a template generation task**: Submit a task using a specified `template_id` along with the assets to be filled, and receive a `task_id`.
2. **Check task status and retrieve result**: Use the `task_id` to poll task status. Unlike general video generation, when this task completes, the API directly returns a downloadable `video_url` in the response.

For more templates, see the [Video Agent Template List](/faq/video-agent-templates).

## Generate a "Run for Life" Video

### Example Code

```python  theme={null}
import os
import time
import requests

api_key = os.environ["MINIMAX_API_KEY"]
headers = {"Authorization": f"Bearer {api_key}"}

# --- Step 1: Submit a video generation task ---
# This function calls the API to start an asynchronous template-based video generation task.
# Upon success, the API immediately returns a task_id for querying task status.
def invoke_template_task() -> str:
    """Submit a template-based video generation task and return the task ID"""
    url = "https://api.minimax.io/v1/video_template_generation"
    payload = {
        # 'template_id' specifies the base video template.
        "template_id": "393769180141805569",  # Example: Run for Life style
        # Media assets such as images or videos to fill in the template
        "media_inputs": [
            {
                "value": "https://cdn.hailuoai.com/prod/2024-09-18-16/user/multi_chat_file/9c0b5c14-ee88-4a5b-b503-4f626f018639.jpeg"
            }
        ],
        # Text inputs for filling text placeholders in the template
        "text_inputs": [{"value": "Lion"}],
    }
    response = requests.post(url, headers=headers, json=payload)
    response.raise_for_status()
    task_id = response.json()["task_id"]
    return task_id

# --- Step 2: Poll task status ---
# Since video generation is asynchronous, you need to check status periodically using task_id.
# Once status becomes "Success", the function returns the video URL; if failed, an exception is raised.
def query_task_status(task_id: str):
    url = "https://api.minimax.io/v1/query/video_template_generation"
    params = {"task_id": task_id}
    while True:
        # A reasonable polling interval is recommended to avoid excessive requests.
        time.sleep(10)
        response = requests.get(url, headers=headers, params=params)
        response.raise_for_status()
        response_json = response.json()
        status = response_json["status"]
        print(f"Current task status: {status}")
        if status == "Success":
            return response_json["video_url"]
        elif status == "Fail":
            raise Exception(f"Video generation failed: {response_json}")

# --- Step 3: Save the video file ---
# This helper function downloads the generated video from the provided URL and saves it locally.
def save_video_from_url(video_url: str):
    print(f"Downloading video from {video_url}...")
    response = requests.get(video_url)
    response.raise_for_status()
    with open("output.mp4", "wb") as f:
        f.write(response.content)
    print("Video successfully saved as output.mp4")

# --- Main process: Full workflow ---
# Execute the entire flow in the order: submit -> poll -> save.
if __name__ == "__main__":
    task_id = invoke_template_task()
    print(f"Video generation task submitted successfully, task_id: {task_id}")
    final_video_url = query_task_status(task_id)
    print(f"Task completed successfully, video URL: {final_video_url}")
    save_video_from_url(final_video_url)
```

### Example Output

<video controls src="https://filecdn.minimax.chat/public/92ed8c3b-8173-4ed6-86e3-7860fecb2c7c.mp4" />
