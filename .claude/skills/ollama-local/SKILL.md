---
name: ollama-local
description: Use this to write code to call an LLM using Ollama running locally.
---

# Calling an LLM using Ollama running locally

These instructions allow you to write code that calls an LLM using Ollama running locally.

# Setup
Use https://docs.ollama.com/docker to install Ollama locally. You can use the `ollama` CLI to run models locally.
Install it cpu only, on Mac host.

## Commands and code snippets

### Docker cpu only
docker run -d -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama

### Starting the container
docker run -d --gpus=all -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama

### Run model locally
docker exec -it ollama ollama run qwen2.5:1.5b
Use qwen2.5:1.5b. It is about 1GB, answers in well under a second on CPU, and is
the smallest model measured here that reliably returns structured output.

`smollm2:135m` is fine for a throwaway smoke test — it is 270MB and starts
instantly — but do not build on it. Measured on the extraction this project
actually does, it handled 4 of 18 cases against 18 of 18 for qwen2.5:1.5b at the
same latency, and it invents values rather than returning nothing. `qwen2.5:3b`
is twice the size and no better.

Ollama runs as its own service in the FinAlly compose stack, alongside the app
container, so within that network the address is `http://ollama:11434` — not
localhost, which would be the app container itself. Running the backend directly
with `uv run`, it is `http://localhost:11434`. Read it from `OLLAMA_URL` rather
than hardcoding either form.

### Example code to call the model using Python
```python
import httpx

response = httpx.post("http://localhost:11434/api/generate", json={
    "model": "qwen2.5:1.5b",
    "prompt": "What is the capital of France?",
    "stream": False,
})
print(response.json())
```

### Example code to call the chat API using Python
```python
import httpx

response = httpx.post("http://localhost:11434/api/chat", json={
    "model": "qwen2.5:1.5b",
    "messages": [
        {"role": "user", "content": "What is the capital of France?"}
    ],
    "stream": False,
})
print(response.json()["message"]["content"])
```

`httpx` is not yet a backend dependency here — add it with `uv add httpx` before
using these snippets. It is also the async client, which is what the FastAPI
routes will want: `await httpx.AsyncClient().post(...)`. Pass `"stream": False`
or the response arrives as a stream of JSON objects rather than one.

### Structured outputs

Pass a JSON schema as `format` and the model's content comes back as JSON
matching it. Use this whenever the result has to populate fields rather than be
read by a person.

```python
import json
import httpx

SCHEMA = {
    "type": "object",
    "properties": {
        "companyName": {"type": "string"},
        "governingLaw": {"type": "string"},
    },
}

response = httpx.post("http://localhost:11434/api/chat", json={
    "model": "qwen2.5:1.5b",
    "messages": [
        {"role": "system", "content": "Extract only what the user stated."},
        {"role": "user", "content": "We're Northwind Analytics, Delaware law."},
    ],
    "stream": False,
    "format": SCHEMA,
    "options": {"temperature": 0},
})
extracted = json.loads(response.json()["message"]["content"])
```

Four things that matter, each learned the hard way:

- **Leave `required` out.** A required field forces the model to produce a value
  it does not have. With `required` set, `"hello there"` yielded a company called
  `PARTYONE`; without it, the key is simply absent.
- **Keep the schema narrow.** Offered many fields at once, a small model fills in
  ones nobody asked about, borrowing words from the answer to a different
  question. Ask for what you need this turn.
- **Avoid array fields.** They let the model free-run. Asked for a list of
  companies in `"hello there"`, smollm2 produced Google, Microsoft, Amazon,
  Facebook, Apple, Tesla and Elon Musk.
- **Do not ask for dates or numbers.** Parse those yourself from the user's text.
  `"five years"` came back as `5000000000000000`, and `"next Monday"` as today.

### Verify the output, always

`format` constrains the shape, not the truth. Set `"temperature": 0`, wrap
`json.loads` in a `try` — models do return truncated JSON — and check each value
against real state before acting on it. In FinAlly that means a ticker the model
names must exist in the price cache, and a trade it proposes must clear the same
validation a manual trade does: enough cash to buy, enough shares to sell. A
model-invented ticker or quantity must never reach the trade path unchecked.
