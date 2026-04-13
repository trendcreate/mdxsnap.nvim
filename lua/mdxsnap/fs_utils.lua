local utils = require("mdxsnap.utils")
local M = {}

local PROJECT_ROOT_MARKERS = { ".git", ".project", "_darcs", ".hg", ".bzr", ".svn" }

local function normalize_absolute_path(path)
  local normalized = utils.normalize_slashes(vim.fn.fnamemodify(path, ":p"))
  if normalized ~= "/" and not normalized:match("^%a:/$") then
    normalized = normalized:gsub("/$", "")
  end
  return normalized
end

local function path_exists(path)
  return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

local function trim(text)
  return (text or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function sanitize_filename_stem(desired_stem, file_ext)
  local stem = trim(desired_stem)
  if stem == "" then
    return nil, "Filename stem cannot be empty."
  end

  if stem:find("[/\\]") then
    return nil, "Filename must be a plain stem, not a path: " .. desired_stem
  end

  if stem == "." or stem == ".." then
    return nil, "Filename stem cannot be '.' or '..'."
  end

  if stem:find('[<>:"|%?%*]') then
    return nil, "Filename contains unsupported characters: " .. desired_stem
  end

  if file_ext ~= "" and stem:lower():sub(-#file_ext) == file_ext then
    stem = stem:sub(1, #stem - #file_ext)
  end

  if stem == "" then
    return nil, "Filename stem cannot be empty."
  end

  return stem
end

local function build_destination_path(target_dir, filename)
  return normalize_absolute_path(target_dir .. "/" .. filename)
end

local function generate_random_stem(source_path, attempt)
  local seed = table.concat({ tostring(vim.loop.now() or 0), tostring(os.time()), tostring(attempt or 0), source_path }, ":")
  local is_ok, hash = pcall(vim.fn.sha256, seed)
  if is_ok and type(hash) == "string" and hash ~= "" then
    return vim.fn.strcharpart(hash, 0, 8)
  end

  return string.format("clip_%d_%d", os.time(), attempt or 0)
end

function M.find_project_root_path(start_path)
  local current_path, err = utils.expand_shell_vars_in_path(vim.fn.fnamemodify(start_path, ":p:h"))
  if not current_path then return nil, err end

  current_path = normalize_absolute_path(current_path)

  if vim.fs and vim.fs.root then
    local project_root = vim.fs.root(current_path, PROJECT_ROOT_MARKERS)
    if project_root then
      return utils.normalize_slashes(project_root)
    end
    return current_path
  end

  for _ = 1, 64 do
    for _, marker in ipairs(PROJECT_ROOT_MARKERS) do
      if vim.fn.isdirectory(current_path .. "/" .. marker) == 1 or vim.fn.filereadable(current_path .. "/" .. marker) == 1 then
        return current_path
      end
    end
    local parent_path = vim.fn.fnamemodify(current_path, ":h")
    if parent_path == current_path then break end
    current_path = parent_path
  end

  return current_path
end

function M.get_tmp_dir()
  local data_path = vim.fn.stdpath("data")
  local tmp_dir = data_path .. "/mdxsnap_tmp"
  if vim.fn.isdirectory(tmp_dir) == 0 then
    vim.fn.mkdir(tmp_dir, "p")
    if vim.fn.isdirectory(tmp_dir) == 0 then
      vim.notify("Failed to create mdxsnap temp directory: " .. tmp_dir, vim.log.levels.ERROR)
      return nil -- Indicate failure
    end
  end
  return tmp_dir
end

function M.cleanup_tmp_file(file_path)
  if file_path and vim.fn.filereadable(file_path) == 1 then
    local is_ok, err = pcall(vim.fn.delete, file_path)
    if not is_ok then
      vim.notify("Failed to clean up temp file: " .. file_path .. " Error: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

function M.build_final_paste_base_path(paste_config)
  local paste_path = paste_config.path
  local path_type = paste_config.type
  local project_root = paste_config.project_root
  local resolved_path

  if path_type == "relative" then
    if not project_root then return nil, "Cannot resolve relative path: project root not found." end
    local clean_path = paste_path:gsub("^[/\\]+", "")
    resolved_path = project_root .. "/" .. clean_path
  elseif path_type == "absolute" then
    resolved_path = paste_path
  else
    return nil, "Invalid PastePathType: " .. tostring(path_type)
  end

  if not resolved_path or resolved_path == "" then return nil, "Resolved PastePath is empty." end
  return utils.normalize_slashes(vim.fn.fnamemodify(resolved_path, ":p"))
end

function M.ensure_target_directory_exists(base_path, filename_stem)
  local clean_filename = filename_stem:gsub("^[/\\]+", "")
  local target_dir = utils.normalize_slashes(base_path .. "/" .. clean_filename)
  if vim.fn.isdirectory(target_dir) == 0 then
    vim.fn.mkdir(target_dir, "p")
    if vim.fn.isdirectory(target_dir) == 0 then
      return nil, "Failed to create directory: " .. target_dir
    end
  end
  return target_dir
end

function M.copy_image_file(source_path, target_dir, file_ext, desired_stem)
  if not source_path or source_path == "" then
    return nil, nil, "Invalid source path (empty or nil)"
  end

  local filename, full_path
  if desired_stem and desired_stem ~= "" then
    local sanitized_stem, stem_err = sanitize_filename_stem(desired_stem, file_ext)
    if not sanitized_stem then
      return nil, nil, stem_err
    end

    filename = sanitized_stem .. file_ext
    full_path = build_destination_path(target_dir, filename)
    if path_exists(full_path) then
      return nil, nil, "Destination file already exists: " .. full_path
    end
  else
    for attempt = 1, 10 do
      local candidate_stem = generate_random_stem(source_path, attempt)
      local candidate_filename = candidate_stem .. file_ext
      local candidate_path = build_destination_path(target_dir, candidate_filename)
      if not path_exists(candidate_path) then
        filename = candidate_filename
        full_path = candidate_path
        break
      end
    end

    if not filename or not full_path then
      return nil, nil, "Failed to generate a unique filename."
    end
  end

  -- Copy file using Lua I/O
  local src_file, src_err = io.open(source_path, "rb")
  if not src_file then
    return nil, nil, "Failed to open source file: " .. tostring(src_err)
  end

  local dst_file, dst_err = io.open(full_path, "wb")
  if not dst_file then
    src_file:close()
    return nil, nil, "Failed to create destination file: " .. tostring(dst_err)
  end

  local is_success = true
  local error_msg
  local chunk_size = 8192 -- 8KB chunks for efficient copying

  while true do
    local chunk = src_file:read(chunk_size)
    if not chunk then break end -- EOF

    local is_ok = dst_file:write(chunk)
    if not is_ok then
      is_success = false
      error_msg = "Failed to write chunk to destination file"
      break
    end
  end

  -- Clean up
  src_file:close()
  dst_file:flush() -- Ensure all data is written
  dst_file:close()

  -- Handle errors
  if not is_success then
    pcall(vim.fn.delete, full_path) -- Try to clean up failed copy
    return nil, nil, error_msg
  end

  -- Verify copy was successful
  if vim.fn.filereadable(full_path) ~= 1 then
    return nil, nil, "Copied file is not readable: " .. full_path
  end

  if vim.fn.getfsize(full_path) <= 0 then
    pcall(vim.fn.delete, full_path)
    return nil, nil, "Copied file is empty"
  end

  return full_path, filename
end

return M
