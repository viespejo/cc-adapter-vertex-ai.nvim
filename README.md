## Vertex AI Adapters for CodeCompanion

A collection of adapters that connect [CodeCompanion.nvim](https://codecompanion.olimorris.dev) to Google Cloud's Vertex AI platform. Supports **Gemini** (native API), **Anthropic** (Claude), and **Model-as-a-Service (MaaS)** third-party models — all authenticated via `gcloud`.

### Adapters

| Adapter | Name | Description |
|---|---|---|
| `vertex-gemini` | Vertex AI (Gemini) | Native Gemini API (`generateContent`). Supports vision, tools, and thinking. |
| `vertex-anthropic` | Vertex AI (Anthropic) | Claude models via Vertex AI (`rawPredict`). Extends the base Anthropic adapter. |
| `vertex-maas` | Vertex AI (MaaS) | Third-party models via the OpenAI-compatible MaaS endpoint. |

### Available Models

**vertex-gemini** (default: `gemini-3-flash-preview`)
- `gemini-3.1-pro-preview`, `gemini-3-pro-preview`, `gemini-3-flash-preview`, `gemini-3.1-flash-lite-preview`, `gemini-3.1-pro-preview-customtools`

**vertex-anthropic** (default: `claude-sonnet-4-6`)
- `claude-opus-4-6`, `claude-sonnet-4-6`

**vertex-maas** (default: `zai-org/glm-5-maas`)
- `moonshotai/kimi-k2-thinking-maas`, `minimaxai/minimax-m2-maas`, `zai-org/glm-5-maas`, `deepseek-v3.2-maas`

### File Structure

```text
lua/codecompanion/adapters/http/
├── vertex-gemini.lua
├── vertex-anthropic.lua
└── vertex-maas.lua
```

### Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    -- ... other dependencies ...
    "viespejo/cc-adapter-vertex-ai.nvim",
  },
}
```

### Configuration

All three adapters require a Google Cloud Project ID and authenticate via `gcloud auth print-access-token`.

#### vertex-gemini

```lua
require("codecompanion").setup({
  adapters = {
    vertex_gemini = function()
      return require("codecompanion.adapters").extend("vertex-gemini", {
        env = {
          project_id = "your-gcp-project-id",
          region = "global", -- default
        },
      })
    end,
  },
  interactions = {
    chat = { adapter = "vertex_gemini" },
  },
})
```

#### vertex-anthropic

```lua
require("codecompanion").setup({
  adapters = {
    vertex_anthropic = function()
      return require("codecompanion.adapters").extend("vertex-anthropic", {
        env = {
          project_id = "your-gcp-project-id",
          region = "global",
        },
      })
    end,
  },
  interactions = {
    chat = { adapter = "vertex_anthropic" },
  },
})
```

#### vertex-maas

```lua
require("codecompanion").setup({
  adapters = {
    vertex_maas = function()
      return require("codecompanion.adapters").extend("vertex-maas", {
        env = {
          project_id = "your-gcp-project-id",
          region = "global",
        },
      })
    end,
  },
  interactions = {
    chat = { adapter = "vertex_maas" },
  },
})
```

#### Using Multiple Adapters

You can register all three adapters and switch between them:

```lua
require("codecompanion").setup({
  adapters = {
    vertex_gemini = function()
      return require("codecompanion.adapters").extend("vertex-gemini", {
        env = { project_id = "my-project" },
      })
    end,
    vertex_anthropic = function()
      return require("codecompanion.adapters").extend("vertex-anthropic", {
        env = { project_id = "my-project" },
      })
    end,
    vertex_maas = function()
      return require("codecompanion.adapters").extend("vertex-maas", {
        env = { project_id = "my-project" },
      })
    end,
  },
  interactions = {
    chat = { adapter = "vertex_gemini" },
    inline = { adapter = "vertex_anthropic" },
  },
})
```

### Key Features

- **Reasoning / Thinking**: Gemini models support `reasoning_effort` (`high`, `medium`, `low`, `minimal`, `none`) and `include_thoughts`. Anthropic models support extended thinking via the base adapter. MaaS reasoning models are also supported.
- **Vision**: Automatically detected per model in `vertex-gemini`. Supported via the base adapter in `vertex-anthropic`.
- **Tools**: All three adapters are compatible with CodeCompanion's Agents and Tools ecosystem.
- **Streaming**: Enabled by default on all adapters.

### Requirements

- **`gcloud` CLI** installed and authenticated (`gcloud auth login`).
- A **Google Cloud Project** with the relevant APIs enabled:
  - For Gemini: "Vertex AI API"
  - For Anthropic: "Vertex AI API" with Claude model access granted
  - For MaaS: "Vertex AI API" with the corresponding third-party model enabled
- **CodeCompanion** v18.0.0 or later.
- **Neovim** 0.10.0 or later.

### Troubleshooting

- **Authentication errors**: Run `gcloud auth print-access-token` in your terminal to verify your credentials are valid.
- **Model not found**: Ensure the model is available in your selected `region`. See [Vertex AI locations](https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations).
- **Logs**: Use `:CodeCompanionLog` to inspect detailed request/response data.

### 🙏 Acknowledgements

- [Oli Morris](https://github.com/olimorris) for creating [CodeCompanion.nvim](https://codecompanion.olimorris.dev).
