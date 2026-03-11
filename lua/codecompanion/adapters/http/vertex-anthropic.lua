local anthropic_base = require("codecompanion.adapters.http.anthropic")
local log = require("codecompanion.utils.log")

-- Clone the original adapter to avoid mutating the global state
local adapter = vim.deepcopy(anthropic_base)

-- 1. Overwrite identity and URL
adapter.name = "vertex_anthropic"
adapter.formatted_name = "Vertex AI (Anthropic)"
adapter.url =
  "https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${region}/publishers/anthropic/models/${model}"

-- 2. Overwrite environment variables (removing api_key)
adapter.env = {
  project_id = "YOUR_PROJECT_ID",
  region = "global",
  access_token = "", -- Resolved during setup
  model = "", -- Resolved during setup
}

-- Deshabilitar las herramientas nativas en beta de Anthropic (usaremos las estándar de CodeCompanion)
adapter.available_tools = {}

-- 3. Overwrite headers
-- Vertex uses Bearer Token and does not use 'x-api-key'.
adapter.headers = {
  ["Authorization"] = "Bearer ${access_token}",
  ["content-type"] = "application/json",
}

-- 4. Intercept setup for Google authentication
local base_setup = adapter.handlers.setup

---@param self CodeCompanion.HTTPAdapter
---@return nil
adapter.handlers.setup = function(self)
  -- Vertex authentication (gcloud)
  local cmd = "gcloud auth print-access-token 2>&1"
  local handle = io.popen(cmd, "r")
  if handle then
    local token = handle:read("*a")
    handle:close()
    token = token:gsub("%s+$", "")
    if token and token ~= "" then
      self.env.access_token = token
    else
      log:error("Vertex AI: Failed to retrieve access token via gcloud")
      return false
    end
  end

  -- URL formatting (streaming vs non-streaming)
  local model = self.schema.model.default
  if type(model) == "function" then
    model = model(self)
  end
  self.env.model = model

  if self.opts.stream then
    self.url = self.url .. ":streamRawPredict"
  else
    self.url = self.url .. ":rawPredict"
  end

  -- Call the original Anthropic setup to configure
  -- vision headers, extended thinking, and token-efficient tools
  if base_setup then
    return base_setup(self)
  end

  return true
end

-- 5. Intercept parameters to inject the version
-- Vertex AI requires the Anthropic version to be in the payload (body), not in the headers
local base_form_parameters = adapter.handlers.form_parameters
adapter.handlers.form_parameters = function(self, params, messages)
  -- Get base parameters (like max_tokens, temperature, thinking)
  local p = base_form_parameters(self, params, messages) or params
  p.model = nil
  -- Inject the Vertex requirement
  p.anthropic_version = "vertex-2023-10-16"

  return p
end

-- 7. Replace models with exact Google Cloud nomenclature
adapter.schema.model.default = "claude-sonnet-4-6"
adapter.schema.model.choices = {
  ["claude-opus-4-6"] = {
    formatted_name = "Claude Opus 4.6",
    opts = { can_reason = true, has_vision = true },
  },
  ["claude-sonnet-4-6"] = {
    formatted_name = "Claude Sonnet 4.6",
    opts = { can_reason = true, has_vision = true },
  },
}

return adapter
