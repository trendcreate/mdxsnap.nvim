local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")

local M = {}

local function normalize_path(path)
  local normalized = utils.normalize_slashes(vim.fn.fnamemodify(path, ":p"))
  if normalized ~= "/" and not normalized:match("^%a:/$") then
    normalized = normalized:gsub("/$", "")
  end
  return normalized
end

local function normalize_path_for_compare(path)
  local normalized = normalize_path(path)
  if normalized:match("^%a:/") then
    return normalized:sub(1, 1):lower() .. normalized:sub(2)
  end
  return normalized
end

local function split_path(path)
  local normalized = normalize_path(path)
  local root = ""

  if normalized:match("^%a:/") then
    root = normalized:sub(1, 3)
    normalized = normalized:sub(4)
  elseif normalized:sub(1, 1) == "/" then
    root = "/"
    normalized = normalized:sub(2)
  end

  local parts = {}
  for part in normalized:gmatch("[^/]+") do
    table.insert(parts, part)
  end

  return root, parts
end

local function roots_match(left_root, right_root)
  if left_root:match("^%a:/") or right_root:match("^%a:/") then
    return left_root:lower() == right_root:lower()
  end

  return left_root == right_root
end

local function make_relative_path(from_dir, to_path)
  local from_root, from_parts = split_path(from_dir)
  local to_root, to_parts = split_path(to_path)

  if not roots_match(from_root, to_root) then
    return nil
  end

  local case_insensitive = from_root:match("^%a:/") ~= nil
  local common_length = 0

  while common_length < #from_parts and common_length < #to_parts do
    local from_part = from_parts[common_length + 1]
    local to_part = to_parts[common_length + 1]

    if case_insensitive then
      from_part = from_part:lower()
      to_part = to_part:lower()
    end

    if from_part ~= to_part then
      break
    end

    common_length = common_length + 1
  end

  local relative_parts = {}
  for index = common_length + 1, #from_parts do
    relative_parts[#relative_parts + 1] = ".."
  end

  for index = common_length + 1, #to_parts do
    relative_parts[#relative_parts + 1] = to_parts[index]
  end

  if #relative_parts == 0 then
    return "."
  end

  return table.concat(relative_parts, "/")
end

local function count_placeholders(text_format)
  local count = 0
  for _ in string.gmatch(text_format or "", "%%s") do
    count = count + 1
  end
  return count
end

local function rule_matches_project(rule, root_name, project_root, match_value)
  if rule.matchType == "projectName" then
    return root_name == match_value
  elseif rule.matchType == "projectPath" then
    return normalize_path_for_compare(project_root) == normalize_path_for_compare(match_value)
  end
  return false
end

local function apply_override(rule, state)
  state.paste_path = rule.PastePath or state.paste_path
  state.path_type = rule.PastePathType or state.path_type
  state.imports = rule.customImports or state.imports
  state.text_format = rule.customTextFormat or state.text_format
end

local function find_frontmatter_end(lines)
  if lines[1] ~= "---" then
    return nil
  end

  for line_idx = 2, #lines do
    if lines[line_idx]:match("^---$") then
      return line_idx - 1 -- zero-based closing line index
    end
  end

  return nil
end

local function find_existing_import(lines, import_cfg)
  for line_idx, line_text in ipairs(lines) do
    if import_cfg.checkRegex and line_text:find(import_cfg.checkRegex) then
      return true, line_idx - 1 -- zero-based index
    end
  end
  return false, nil
end

local function resolve_insert_index(lines, last_import_idx)
  if last_import_idx then
    return last_import_idx + 1
  end

  local frontmatter_end = find_frontmatter_end(lines)
  if frontmatter_end then
    return frontmatter_end + 1
  end

  return 0
end

local function build_display_path(full_path, current_file_path, path_type)
  local normalized_path = normalize_path(full_path)

  if path_type ~= "relative" or not current_file_path or current_file_path == "" then
    return normalized_path
  end

  local current_dir = normalize_path(vim.fn.fnamemodify(current_file_path, ":p:h"))
  local relative_path = make_relative_path(current_dir, normalized_path)
  if not relative_path then
    return normalized_path
  end

  return utils.normalize_slashes(relative_path)
end

local function validate_import_cfg(import_cfg)
  if not import_cfg.checkRegex or import_cfg.checkRegex == "" then
    return false, "customImports entry is missing required field 'checkRegex'; skipping to prevent duplicate insertions."
  end
  return true
end

function M.determine_active_paste_config(buf_path, opts)
  local project_root, root_err = fs_utils.find_project_root_path(buf_path)
  if not project_root then return nil, root_err end
  local root_name = vim.fn.fnamemodify(project_root, ":t")

  local state = {
    paste_path = opts.DefaultPastePath,
    path_type = opts.DefaultPastePathType,
    imports = opts.customImports,
    text_format = opts.customTextFormat,
  }

  for _, rule in ipairs(opts.ProjectOverrides or {}) do
    local match_value, expand_err = utils.expand_shell_vars_in_path(rule.matchValue)
    if not match_value then
      vim.notify("Error expanding override rule matchValue: " .. (expand_err or "unknown"), vim.log.levels.WARN)
    elseif rule_matches_project(rule, root_name, project_root, match_value) then
      apply_override(rule, state)
      break
    end
  end

  local expanded_path, expand_err = utils.expand_shell_vars_in_path(state.paste_path)
  if not expanded_path then
    return nil, "Error expanding active PastePath: " .. (expand_err or "unknown error")
  end

  local placeholder_count = count_placeholders(state.text_format)
  if placeholder_count ~= 1 and placeholder_count ~= 2 then
    return nil, "customTextFormat must contain one or two %s placeholders."
  end

  return {
    path = expanded_path,
    type = state.path_type,
    project_root = project_root,
    customImports = state.imports,
    customTextFormat = state.text_format,
  }
end

function M.ensure_imports_are_present(buf_nr, imports)
  if not imports or #imports == 0 then return end -- No imports to check

  local lines = vim.api.nvim_buf_get_lines(buf_nr, 0, -1, false)
  local import_line_idx = nil

  for _, import_cfg in ipairs(imports) do
    local is_valid, err = validate_import_cfg(import_cfg)
    if not is_valid then
      vim.notify(err, vim.log.levels.ERROR)
      goto continue
    end

    local exists, existing_idx = find_existing_import(lines, import_cfg)
    if exists and existing_idx then
      if not import_line_idx or existing_idx > import_line_idx then
        import_line_idx = existing_idx
      end
    end
    if not exists then
      local insert_idx = resolve_insert_index(lines, import_line_idx)
      vim.api.nvim_buf_set_lines(buf_nr, insert_idx, insert_idx, false, { import_cfg.line })
      lines = vim.api.nvim_buf_get_lines(buf_nr, 0, -1, false) -- Refresh lines
      if not import_line_idx or insert_idx > import_line_idx then
        import_line_idx = insert_idx
      end
    end
    ::continue::
  end
end

function M.format_image_reference_text(full_path, filename, text_format, current_file_path, path_type, desired_stem)
  local display_path = build_display_path(full_path, current_file_path, path_type)
  local alt_text = desired_stem ~= nil and desired_stem ~= "" and utils.extract_filename_stem(desired_stem) or utils.extract_filename_stem(filename)
  local placeholder_count = count_placeholders(text_format)

  if placeholder_count == 1 then
    return string.format(text_format, display_path)
  elseif placeholder_count == 2 then
    return string.format(text_format, alt_text, display_path)
  end

  error("customTextFormat must contain one or two %s placeholders.")
end

return M
