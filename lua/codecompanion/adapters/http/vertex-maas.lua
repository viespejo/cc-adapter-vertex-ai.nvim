local adapter_utils = require("codecompanion.utils.adapters")
local adapters = require("codecompanion.adapters")
local gemini = require("codecompanion.adapters.http.gemini")

local CONSTANTS = {
  STANDARD_MESSAGE_FIELDS = {
    -- fields that are defined in the standard openai chat-completion API (inc. streaming and non-streaming)
    "content",
    "function_call",
    "refusal",
    "role",
    "tool_calls",
    "annotations",
    "audio",
  },
}

---Find the non-standard fields in the `message` or `delta` that are not in the standard OpenAI chat-completion specs.
---@param delta table?
---@return table|nil
local function find_extra_fields(delta)
  if delta == nil then
    return nil
  end
  local extra = {}
  vim.iter(delta):each(function(k, v)
    if not vim.list_contains(CONSTANTS.STANDARD_MESSAGE_FIELDS, k) then
      extra[k] = v
    end
  end)
  if not vim.tbl_isempty(extra) then
    return extra
  end
end

local M = adapters.extend(gemini, {
  name = "vertex",
  formatted_name = "Vertex AI",
  -- Availability of models: https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations
  url = "https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${region}/endpoints/openapi/chat/completions",
  env = {
    project_id = "YOUR_PROJECT_ID",
    region = "global",
    access_token = nil,
  },
  headers = {
    Authorization = "Bearer ${access_token}",
    ["Content-Type"] = "application/json",
  },
  features = {
    show_reasoning = false,
  },
  handlers = {
    setup = function(self)
      local cmd = "gcloud auth print-access-token 2>&1"
      local handle = io.popen(cmd, "r")
      if handle then
        local token = handle:read("*a")
        handle:close()
        token = token:gsub("%s+$", "")
        if token and token ~= "" then
          self.env.access_token = token
        end
      end

      gemini.handlers.setup(self)

      local model = self.schema.model.default
      local choices = self.schema.model.choices
      if type(model) == "function" then
        model = model()
      end
      if type(choices) == "function" then
        choices = choices()
      end

      if
        choices[model]
        and choices[model].opts.can_reason
        and choices[model].opts.use_thinking_level
        and self.features.show_reasoning
      then
        self.parameters = self.parameters or {}
        self.parameters.extra_body = self.parameters.extra_body or {}
        self.parameters.extra_body.google = {
          thinking_config = {
            include_thoughts = true,
            thinking_level = self.parameters.reasoning_effort or "high",
          },
        }
        self.parameters.reasoning_effort = nil
      end

      return true
    end,

    chat_output = function(self, data, tools)
      if not data or data == "" then
        return nil
      end

      -- Handle both streamed data and structured response
      local data_mod = type(data) == "table" and data.body or adapter_utils.clean_streamed_data(data)
      local ok, json = pcall(vim.json.decode, data_mod, { luanil = { object = true } })

      if not ok or not json.choices or #json.choices == 0 then
        return nil
      end

      -- Define standard tool_call fields
      local STANDARD_TOOL_CALL_FIELDS = {
        "id",
        "type",
        "function",
        "index",
      }

      ---Helper to create any tool data
      ---@param tool table
      ---@param index number
      ---@param id string
      ---@return table
      local function create_tool_data(tool, index, id)
        local tool_data = {
          _index = index,
          id = id,
          type = tool.type,
          ["function"] = {
            name = tool["function"]["name"],
            arguments = tool["function"]["arguments"] or "",
          },
        }

        -- Preserve any non-standard fields as-is
        for key, value in pairs(tool) do
          if not vim.tbl_contains(STANDARD_TOOL_CALL_FIELDS, key) then
            tool_data[key] = value
          end
        end

        return tool_data
      end

      -- Process tool calls from all choices
      if self.opts.tools and tools then
        for _, choice in ipairs(json.choices) do
          local delta = self.opts.stream and choice.delta or choice.message

          if delta and delta.tool_calls and #delta.tool_calls > 0 then
            for i, tool in ipairs(delta.tool_calls) do
              local tool_index = tool.index and tonumber(tool.index) or i

              -- Some endpoints like Gemini do not set this (why?!)
              local id = tool.id
              if not id or id == "" then
                id = string.format("call_%s_%s", json.created, i)
              end

              if self.opts.stream then
                local found = false
                for _, existing_tool in ipairs(tools) do
                  if existing_tool._index == tool_index then
                    -- Append to arguments if this is a continuation of a stream
                    if tool["function"] and tool["function"]["arguments"] then
                      existing_tool["function"]["arguments"] = (existing_tool["function"]["arguments"] or "")
                        .. tool["function"]["arguments"]
                    end
                    found = true
                    break
                  end
                end

                if not found then
                  table.insert(tools, create_tool_data(tool, tool_index, id))
                end
              else
                table.insert(tools, create_tool_data(tool, i, id))
              end
            end
          end
        end
      end

      -- Process message content from the first choice
      local choice = json.choices[1]
      local delta = self.opts.stream and choice.delta or choice.message

      if not delta then
        return nil
      end

      local reasoning_text = ""
      local output_text = ""
      if
        self.features.show_reasoning
        and delta.extra_content
        and delta.extra_content.google
        and delta.extra_content.google.thought
        and delta.extra_content.google.thought == true
      then
        if delta.content then
          reasoning_text = reasoning_text .. delta.content
        end
      elseif self.features.show_reasoning and delta.reasoning_content then
        reasoning_text = reasoning_text .. delta.reasoning_content
      else
        if delta.content then
          output_text = output_text .. delta.content
        end
      end
      return {
        status = "success",
        output = {
          role = delta.role,
          content = output_text ~= "" and output_text or nil,
          reasoning = reasoning_text ~= "" and { content = reasoning_text } or nil,
        },
        extra = find_extra_fields(delta),
      }
    end,
  },
})

M.schema.model.default = "zai-org/glm-5-maas"
M.schema.model.choices = {
  ["moonshotai/kimi-k2-thinking-maas"] = {
    formatted_name = "Kimi K2 Thinking",
    opts = { can_reason = true },
  },
  ["minimaxai/minimax-m2-maas"] = {
    formatted_name = "Minimax M2",
    opts = { can_reason = true },
  },
  ["zai-org/glm-5-maas"] = { formatted_name = "GLM 5", opts = { can_reason = true } },
  ["deepseek-v3.2-maas"] = { formatted_name = "Deepseek v3.2", opts = { can_reason = true } },
}

return M
