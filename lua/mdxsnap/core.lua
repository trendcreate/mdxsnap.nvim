local config_module = require("mdxsnap.config")
local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local clipboard = require("mdxsnap.clipboard")
local clipboard_utils = require("mdxsnap.clipboard.utils")
local editor_utils = require("mdxsnap.editor_utils")

local M = {}

local function trimmed_lower(str)
  return string.lower((str or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function is_markdown_buffer(filetype, file_ext)
  return filetype == "mdx" or filetype == "markdown" or file_ext == "mdx" or file_ext == "md"
end

local function build_buffer_context(buf_nr)
  local buf_path_raw = vim.api.nvim_buf_get_name(buf_nr)
  if buf_path_raw == "" then
    return nil, "Current buffer has no name.", vim.log.levels.ERROR
  end

  local buf_path, expand_err = utils.expand_shell_vars_in_path(buf_path_raw)
  if not buf_path then
    return nil, "Error expanding buffer path: " .. (expand_err or "unknown"), vim.log.levels.ERROR
  end

  local filetype_raw = vim.bo[buf_nr].filetype
  local filetype = trimmed_lower(filetype_raw)
  local file_ext = trimmed_lower(vim.fn.fnamemodify(buf_path_raw, ":e"))

  if not is_markdown_buffer(filetype, file_ext) then
    local warn = "Command only for MDX/Markdown files. Detected filetype: '" .. filetype_raw .. "' (processed as: '" .. filetype .. "'), Extension: '" .. file_ext .. "'"
    return nil, warn, vim.log.levels.WARN
  end

  return {
    path = buf_path,
    buf_nr = buf_nr,
    filetype = filetype,
    file_ext = file_ext,
    filename_stem = vim.fn.fnamemodify(buf_path, ":t:r"),
  }
end

local function cleanup_temp_image(image_path, is_temp)
  if is_temp then
    fs_utils.cleanup_tmp_file(image_path)
  end
end

local function resolve_clipboard_image()
  local image_path, is_temp, clip_err = clipboard.fetch_image_path_from_clipboard()
  if not image_path then
    return nil, nil, clip_err or "Failed to get image/path from clipboard."
  end

  if vim.fn.filereadable(image_path) == 0 then
    cleanup_temp_image(image_path, is_temp)
    return nil, nil, "Obtained clipboard image path is not a readable file: " .. image_path
  end

  if not clipboard_utils.validate_image_path(image_path) then
    cleanup_temp_image(image_path, is_temp)
    return nil, nil, "Obtained clipboard path is not a supported image file: " .. image_path
  end

  return image_path, is_temp, nil
end

local function determine_extension(image_path)
  local ext_match = image_path:match("%.([^%./\\]+)$")
  if not ext_match then
    return nil, "Cannot determine image extension from path: " .. image_path
  end

  return "." .. ext_match:lower()
end

local function ensure_target_dir(paste_config, filename_stem)
  local base_path, base_err = fs_utils.build_final_paste_base_path(paste_config)
  if not base_path then
    return nil, base_err
  end

  local target_dir, dir_err = fs_utils.ensure_target_directory_exists(base_path, filename_stem)
  if not target_dir then
    return nil, dir_err
  end

  return target_dir
end

local function insert_text_at_cursor(buf_nr, text)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local row = cursor_pos[1] - 1
  local col = cursor_pos[2]
  vim.api.nvim_buf_set_text(buf_nr, row, col, row, col, { text })
end

-- Main Function
M.paste_image = function(desired_filename_stem)
  local opts = config_module.options
  local ctx, ctx_err, ctx_level = build_buffer_context(vim.api.nvim_get_current_buf())
  if not ctx then
    vim.notify(ctx_err, ctx_level or vim.log.levels.ERROR)
    return
  end

  local image_path, is_temp, clip_err = resolve_clipboard_image()
  if not image_path then
    vim.notify(clip_err, vim.log.levels.ERROR)
    return
  end

  local ext, ext_err = determine_extension(image_path)
  if not ext then
    vim.notify(ext_err, vim.log.levels.ERROR)
    cleanup_temp_image(image_path, is_temp)
    return
  end

  local paste_config, config_err = editor_utils.determine_active_paste_config(ctx.path, opts)
  if not paste_config then
    vim.notify(config_err or "Failed to get active paste configuration.", vim.log.levels.ERROR)
    cleanup_temp_image(image_path, is_temp)
    return
  end

  local target_dir, dir_err = ensure_target_dir(paste_config, ctx.filename_stem)
  if not target_dir then
    vim.notify(dir_err, vim.log.levels.ERROR)
    cleanup_temp_image(image_path, is_temp)
    return
  end

  local new_path, new_filename, copy_err = fs_utils.copy_image_file(image_path, target_dir, ext, desired_filename_stem)
  cleanup_temp_image(image_path, is_temp)

  if not new_path then
    vim.notify(copy_err or "Failed to copy image to final destination.", vim.log.levels.ERROR)
    return
  end

  if ctx.filetype == "mdx" or ctx.file_ext == "mdx" then
    editor_utils.ensure_imports_are_present(ctx.buf_nr, paste_config.customImports or opts.customImports)
  end

  local text_to_insert = editor_utils.format_image_reference_text(
    new_path,
    new_filename,
    paste_config.customTextFormat or opts.customTextFormat,
    ctx.path,
    paste_config.type,
    desired_filename_stem
  )

  insert_text_at_cursor(ctx.buf_nr, text_to_insert)
  vim.notify("Image pasted: " .. new_path, vim.log.levels.INFO)
end

return M
