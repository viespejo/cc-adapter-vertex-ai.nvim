local anthropic_base = require("codecompanion.adapters.http.anthropic")
local log = require("codecompanion.utils.log")

-- Clonamos el adapter original para no mutar el global
local adapter = vim.deepcopy(anthropic_base)

-- 1. Sobrescribimos la identidad y URL
adapter.name = "vertex_anthropic"
adapter.formatted_name = "Vertex AI (Anthropic)"
adapter.url =
  "https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${region}/publishers/anthropic/models/${model}"

-- 2. Sobrescribimos las variables de entorno (quitando api_key)
adapter.env = {
  project_id = "YOUR_PROJECT_ID",
  region = "global",
  access_token = "", -- Se resuelve en el setup
  model = "", -- Se resuelve en el setup
}

-- Deshabilitar las herramientas nativas en beta de Anthropic (usaremos las estándar de CodeCompanion)
adapter.available_tools = {}

-- 3. Sobrescribimos los headers
-- Vertex usa Bearer Token y no usa 'x-api-key'.
adapter.headers = {
  ["Authorization"] = "Bearer ${access_token}",
  ["content-type"] = "application/json",
}

-- 4. Interceptamos el setup para la autenticación de Google
local base_setup = adapter.handlers.setup
adapter.handlers.setup = function(self)
  -- Autenticación Vertex (gcloud)
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

  -- Formateo de URL (streaming vs non-streaming)
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

  -- Llamamos al setup original de Anthropic para que configure
  -- los headers de vision, extended thinking, y token-efficient tools
  if base_setup then
    return base_setup(self)
  end

  return true
end

-- 5. Interceptamos los parámetros para inyectar la versión
-- Vertex AI requiere que la versión de Anthropic vaya en el payload (body), no en los headers
local base_form_parameters = adapter.handlers.form_parameters
adapter.handlers.form_parameters = function(self, params, messages)
  -- Obtenemos los parámetros base (como max_tokens, temperature, thinking)
  local p = base_form_parameters(self, params, messages) or params
  p.model = nil
  -- Inyectamos el requerimiento de Vertex
  p.anthropic_version = "vertex-2023-10-16"
  return p
end

-- 6. Reemplazamos los modelos por la nomenclatura exacta de Google Cloud
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
