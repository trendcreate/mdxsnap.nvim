local M = {}

M.defaults = {
  -- Base directory for saving images
  -- When PastePathType is "relative", this is relative to project root
  -- When PastePathType is "absolute", this is used as-is
  DefaultPastePath = "snaps/images/posts",
  DefaultPastePathType = "relative", -- "relative" or "absolute"

  -- Override default settings for specific projects
  -- Rules are evaluated in order, first match is used
  ProjectOverrides = {
    -- Example: Override by project directory name
    -- {
    --   matchType = "projectName",
    --   matchValue = "my-blog",
    --   PastePath = "public/images",
    --   PastePathType = "relative",
    --   customImports = {
    --     { line = 'import { SpecificImage } from "@/components/SpecificImage";', checkRegex = "SpecificImage" },
    --   },
    --   customTextFormat = "<SpecificImage src=\"%s\" alt=\"%s\" />",
    -- },
    -- Example: Override by project full path
    -- {
    --   matchType = "projectPath",
    --   matchValue = "~/projects/portfolio", -- Supports shell vars (~, $HOME)
    --   PastePath = "/var/www/portfolio/images",
    --   PastePathType = "absolute",
    --   customTextFormat = "![Portfolio Image: %s](%s)",
    -- },
  },

  -- Import statements to ensure in MDX files
  -- These are added if not already present
  customImports = {
  --  {
  --    line = 'import { Image } from "astro:assets";',
  --    checkRegex = 'astro:assets',
  --  },
  },

  -- Text format for image references
  -- Use %s for placeholders:
  -- One %s: Replaced with image path
  -- Two %s: First is alt text (filename stem), second is path
  customTextFormat = "![%s](%s)", -- Markdown format
}

M.options = vim.deepcopy(M.defaults)

local function count_placeholders(text_format)
  local count = 0
  for _ in string.gmatch(text_format or "", "%%s") do
    count = count + 1
  end
  return count
end

local function validate_path_type(path_type, label)
  if path_type ~= "relative" and path_type ~= "absolute" then
    return false, string.format("%s must be 'relative' or 'absolute'.", label)
  end
  return true
end

local function validate_text_format(text_format, label)
  if type(text_format) ~= "string" or text_format == "" then
    return false, string.format("%s must be a non-empty string.", label)
  end

  local placeholder_count = count_placeholders(text_format)
  if placeholder_count ~= 1 and placeholder_count ~= 2 then
    return false, string.format("%s must contain one or two %%s placeholders.", label)
  end

  return true
end

local function validate_imports(imports, label)
  if imports == nil then
    return true
  end

  if type(imports) ~= "table" then
    return false, string.format("%s must be a list of import configs.", label)
  end

  for index, import_cfg in ipairs(imports) do
    if type(import_cfg) ~= "table" then
      return false, string.format("%s[%d] must be a table.", label, index)
    end

    if type(import_cfg.line) ~= "string" or import_cfg.line == "" then
      return false, string.format("%s[%d].line must be a non-empty string.", label, index)
    end

    if type(import_cfg.checkRegex) ~= "string" or import_cfg.checkRegex == "" then
      return false, string.format("%s[%d].checkRegex must be a non-empty string.", label, index)
    end
  end

  return true
end

function M.validate(options)
  local is_valid, err = validate_path_type(options.DefaultPastePathType, "DefaultPastePathType")
  if not is_valid then
    return false, err
  end

  is_valid, err = validate_text_format(options.customTextFormat, "customTextFormat")
  if not is_valid then
    return false, err
  end

  is_valid, err = validate_imports(options.customImports, "customImports")
  if not is_valid then
    return false, err
  end

  for index, rule in ipairs(options.ProjectOverrides or {}) do
    if rule.PastePathType ~= nil then
      is_valid, err = validate_path_type(rule.PastePathType, string.format("ProjectOverrides[%d].PastePathType", index))
      if not is_valid then
        return false, err
      end
    end

    if rule.customTextFormat ~= nil then
      is_valid, err = validate_text_format(rule.customTextFormat, string.format("ProjectOverrides[%d].customTextFormat", index))
      if not is_valid then
        return false, err
      end
    end

    if rule.customImports ~= nil then
      is_valid, err = validate_imports(rule.customImports, string.format("ProjectOverrides[%d].customImports", index))
      if not is_valid then
        return false, err
      end
    end
  end

  return true
end

M.setup = function(user_options)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), vim.deepcopy(user_options or {}))
  local is_valid, err = M.validate(merged)
  if not is_valid then
    error(err)
  end

  for key in pairs(M.options) do
    M.options[key] = nil
  end

  for key, value in pairs(merged) do
    M.options[key] = value
  end

  return M.options
end

-- Backwards compatibility: Allow setup to be called directly on config module
-- This allows both require("mdxsnap").setup() and require("mdxsnap.config").setup()
setmetatable(M, {
  __call = function(_, user_options)
    M.setup(user_options)
  end
})

return M
