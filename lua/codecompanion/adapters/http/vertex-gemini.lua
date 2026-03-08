local adapter_utils = require("codecompanion.utils.adapters")
local log = require("codecompanion.utils.log")

-- =============================================================================
-- HELPERS
-- =============================================================================

local function resolve_model_opts(adapter)
  local model = adapter.schema.model.default
  local choices = adapter.schema.model.choices
  if type(model) == "function" then
    model = model(adapter)
  end
  if type(choices) == "function" then
    choices = choices(adapter)
  end

  return choices and choices[model] or { opts = {} }
end

--- Transform tools for Google Gemini
local function transform_tools(tools)
  if not tools or vim.tbl_isempty(tools) then
    return nil
  end

  local declarations = {}
  for _, group in pairs(tools) do
    for _, tool in pairs(group) do
      local name = tool.name
      local description = tool.description
      local parameters = tool.parameters

      if tool["function"] then
        name = tool["function"].name
        description = tool["function"].description
        parameters = tool["function"].parameters
      end

      if parameters then
        local allowed = { type = true, properties = true, required = true }
        for key in pairs(parameters) do
          if not allowed[key] then
            parameters[key] = nil
          end
        end

        if parameters.properties then
          local allowed_props = { type = true, description = true, enum = true }
          for _, param in pairs(parameters.properties) do
            for key in pairs(param) do
              if not allowed_props[key] then
                param[key] = nil
              end
            end
            if param.type and type(param.type) == "table" and #param.type > 0 then
              param.type = param.type[1]
            end
          end
        end
      end

      table.insert(declarations, {
        name = name,
        description = description,
        parameters = parameters,
      })
    end
  end

  if #declarations == 0 then
    return nil
  end
  return { { functionDeclarations = declarations } }
end

--- Format messages for Google Gemini
local function transform_messages(messages, opts)
  local instruction = vim
    .iter(messages)
    :filter(function(m)
      return m.role == "system"
    end)
    :map(function(m)
      return m.content
    end)
    :totable()
  local system_instruction = #instruction > 0 and { parts = { { text = table.concat(instruction, "\n") } } } or nil

  local last_func_cycle = nil
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m.tools and m.tools.calls then
      last_func_cycle = m._meta and m._meta.cycle or nil
      break
    end
  end

  local contents = {}
  local i = 1
  while i <= #messages do
    local m = messages[i]
    if m.role ~= "system" then
      local role = (m.role == "user") and "user" or "model"
      local parts = {}

      if m.role == "function" then
        role = "user"
        while i <= #messages and messages[i].role == "function" do
          local current_f = messages[i]
          local response_content = current_f.content
          local ok, json_content = pcall(vim.json.decode, current_f.content)
          response_content = (ok and type(json_content) == "table") and json_content or { content = current_f.content }

          table.insert(parts, {
            functionResponse = {
              name = current_f.tools and current_f.tools.name or "unknown_function",
              response = response_content,
            },
          })
          i = i + 1
        end
        i = i - 1
      elseif m.tools and m.tools.calls then
        local tool_calls = vim
          .iter(m.tools.calls)
          :map(function(tool_call)
            return {
              functionCall = {
                name = tool_call["function"].name,
                args = vim.json.decode(tool_call["function"].arguments),
              },
              thoughtSignature = (m._meta and last_func_cycle == m._meta.cycle) and tool_call.thought_signature or nil,
            }
          end)
          :totable()

        for _, tc in ipairs(tool_calls) do
          table.insert(parts, tc)
        end
      elseif m._meta and m._meta.tag == "image" and (m.context and m.context.mimetype) then
        if opts and opts.vision then
          table.insert(parts, { { inline_data = { data = m.content, mime_type = m.context.mimetype } } })
        else
          log:warn("Vision is not enabled for this adapter, skipping image message.")
        end
      elseif m.content and m.content ~= "" then
        table.insert(parts, { text = m.content })
      end

      if #parts > 0 then
        table.insert(contents, { role = role, parts = parts })
      end
    end
    i = i + 1
  end

  return contents, system_instruction
end

-- =============================================================================
-- ADAPTER DEFINITION
-- =============================================================================
return {
  name = "vertex_gemini",
  formatted_name = "Vertex AI (Gemini)",
  roles = {
    llm = "model",
    user = "user",
    tool = "function",
  },
  opts = {
    tools = true,
    stream = true,
    vision = true,
  },
  features = {
    text = true,
    tokens = true,
  },
  url = "https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${region}/publishers/google/models/${model}",
  env = {
    project_id = "YOUR_PROJECT_ID",
    region = "global",
    access_token = "", -- Resolved in setup
    model = "",
  },
  headers = {
    ["Authorization"] = "Bearer ${access_token}",
    ["Content-Type"] = "application/json",
  },

  handlers = {
    lifecycle = {
      setup = function(self)
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

        local model = self.schema.model.default
        if type(model) == "function" then
          model = model(self)
        end

        self.env.model = model

        if self.opts.stream then
          self.url = self.url .. ":streamGenerateContent?alt=sse"
        else
          self.url = self.url .. ":generateContent"
        end

        local model_opts = resolve_model_opts(self)
        self.opts.vision = model_opts.opts and model_opts.opts.has_vision or false

        return true
      end,
    },

    request = {
      build_parameters = function(self, params, messages)
        local model = self.schema.model.default
        local model_opts = resolve_model_opts(self)

        local generation_config = {}

        if params.max_tokens then
          generation_config.maxOutputTokens = params.max_tokens
        end
        if params.temperature then
          generation_config.temperature = params.temperature
        end
        if params.top_p then
          generation_config.topP = params.top_p
        end

        if model_opts.opts and model_opts.opts.can_reason then
          generation_config.thinkingConfig = { includeThoughts = params.include_thoughts }
          if params.reasoning_effort then
            if model:find("gemini%-3") then
              local effort = params.reasoning_effort == "none" and "minimal" or params.reasoning_effort
              if model:find("3%.1%-pro") and effort == "minimal" then
                effort = "low"
              elseif model:find("3%-pro") then
                if effort == "minimal" then
                  effort = "low"
                elseif effort == "medium" then
                  effort = "high"
                end
              end
              generation_config.thinkingConfig.thinkingLevel = effort
            else
              local is_pro = model:find("pro") ~= nil
              local budget_map =
                { none = is_pro and 1024 or 0, minimal = 1024, low = 1024, medium = 8192, high = 24576 }
              generation_config.thinkingConfig.thinkingBudget = budget_map[params.reasoning_effort]
            end
          end
        end

        return {
          generationConfig = vim.tbl_isempty(generation_config) and nil or generation_config,
        }
      end,

      build_messages = function(self, messages)
        local contents, system_instruction = transform_messages(messages, self.opts)

        return {
          contents = contents,
          systemInstruction = system_instruction,
        }
      end,

      build_tools = function(self, tools)
        local tools_gemini = transform_tools(tools)
        if not tools_gemini then
          return {}
        end

        return {
          tools = tools_gemini,
        }
      end,

      build_body = function(self, payload)
        return {}
      end,
    },

    response = {
      parse_tokens = function(self, data)
        if not data or data == "" then
          return nil
        end
        local data_mod = adapter_utils.clean_streamed_data(data)
        local ok, json = pcall(vim.json.decode, data_mod, { luanil = { object = true } })

        if ok and json.usageMetadata then
          return json.usageMetadata.totalTokenCount
        end
      end,

      parse_chat = function(self, data, tools)
        if not data or data == "" then
          return nil
        end

        local data_mod = adapter_utils.clean_streamed_data(data)
        local ok, json = pcall(vim.json.decode, data_mod, { luanil = { object = true } })

        if not ok or not json then
          return nil
        end

        local output_text = ""
        local output_reasoning = ""

        if json.candidates and #json.candidates > 0 then
          local candidate = json.candidates[1]
          if candidate.content and candidate.content.parts then
            for _, part in ipairs(candidate.content.parts) do
              if part.thought and part.text then
                output_reasoning = output_reasoning .. part.text
              end
              if part.text and not part.thought then
                output_text = output_text .. part.text
              end
              if part.functionCall then
                -- [API will wait a functionResponse for each functionCall in the same message]
                -- see interactions/chat/init.lua Chat:add_tool_output where tool output are merged by call_id

                -- we need to avoid call_id merging in order to be able to handle multiple function calls in the same message
                -- how? generating a unique call_id here for each function call
                local call_id = string.format("call_%s_%s", vim.uv.hrtime(), math.random(1000, 9999))
                table.insert(tools, {
                  id = call_id,
                  type = "function",
                  ["function"] = {
                    name = part.functionCall.name,
                    arguments = vim.json.encode(part.functionCall.args) or "",
                  },
                  thought_signature = part.thoughtSignature or nil,
                })
              end
            end
          end
        end

        if output_text == "" and output_reasoning == "" and (not tools or #tools == 0) then
          return nil
        end

        return {
          status = "success",
          output = {
            role = "assistant",
            content = output_text ~= "" and output_text or nil,
            reasoning = output_reasoning ~= "" and { content = output_reasoning } or nil,
          },
        }
      end,
    },
    tools = {
      format_calls = function(self, tools)
        return tools
      end,
      format_response = function(self, tool_call, output)
        return {
          role = self.roles.tool or "tool",
          tools = { call_id = tool_call.id, name = tool_call["function"].name },
          content = output,
          opts = { visible = false },
        }
      end,
    },
  },

  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "The model to use for completion.",
      default = "gemini-3-flash-preview",
      choices = {
        ["gemini-3.1-pro-preview"] = {
          formatted_name = "Gemini 3.1 Pro",
          opts = { can_reason = true, has_vision = true },
        },
        ["gemini-3-flash-preview"] = {
          formatted_name = "Gemini 3 Flash",
          opts = { can_reason = true, has_vision = true },
        },
        ["gemini-3.1-pro-preview-customtools"] = {
          formatted_name = "Gemini 3.1 Pro with Custom Tools",
          opts = { can_reason = true, has_vision = true },
        },
        ["gemini-3.1-flash-lite-preview"] = {
          formatted_name = "Gemini 3.1 Flash Lite",
          opts = { can_reason = true, has_vision = true },
        },
        ["gemini-3-pro-preview"] = {
          formatted_name = "Gemini 3 Pro",
          opts = { can_reason = true, has_vision = true },
        },
        -- -- Anthropic Models
        -- ["anthropic/claude-sonnet-4-6"] = {
        --   formatted_name = "Claude Sonnet 4.6",
        --   opts = { can_reason = true, has_vision = true },
        -- },
        -- ["anthropic/claude-opus-4-6"] = {
        --   formatted_name = "Claude Opus 4.6",
        --   opts = { can_reason = true, has_vision = true },
        -- },
      },
    },
    max_tokens = {
      order = 2,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = 4096,
      desc = "The maximum number of tokens to generate.",
    },
    temperature = {
      order = 3,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0.2,
      desc = "Controls the randomness of the output.",
    },
    top_p = {
      order = 4,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = nil,
      desc = "The maximum cumulative probability of tokens to consider when sampling.",
    },
    reasoning_effort = {
      order = 5,
      mapping = "parameters",
      type = "string",
      optional = true,
      enabled = function(self)
        local model_opts = resolve_model_opts(self)
        return model_opts.opts and model_opts.opts.can_reason
      end,
      default = "high",
      desc = "Constrains effort on reasoning for reasoning models.",
      choices = { "high", "medium", "low", "minimal", "none" },
    },
    include_thoughts = {
      order = 6,
      mapping = "parameters",
      type = "boolean",
      optional = true,
      enabled = function(self)
        local model_opts = resolve_model_opts(self)
        return model_opts.opts and model_opts.opts.can_reason
      end,
      default = true,
      desc = "Whether to include the model's thoughts in the response.",
    },
  },
}
