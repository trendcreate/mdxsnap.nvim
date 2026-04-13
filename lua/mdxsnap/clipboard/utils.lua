local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local M = {}

-- Helper function to check if file extension is a supported image format
function M.is_supported_image_extension(file_path)
  if not file_path then return false end
  local ext_match = file_path:match("%.([^%./\\]+)$")
  return ext_match and ({
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    webp = true,
    tif = true,
    tiff = true,
    bmp = true,
    heic = true,
    heif = true,
  })[ext_match:lower()]
end

-- Helper function to validate and check if path is a readable image file
function M.validate_image_path(file_path)
  if not file_path then return nil end
  if vim.fn.filereadable(file_path) == 1 and M.is_supported_image_extension(file_path) then
    return file_path
  end
  return nil
end

-- Common MIME type to extension mapping
function M.get_image_mime_map()
  return {
    ["image/png"] = ".png",
    ["image/jpeg"] = ".jpg",
    ["image/gif"] = ".gif",
    ["image/webp"] = ".webp",
    ["image/tiff"] = ".tiff",
    ["image/heic"] = ".heic",
    ["image/heif"] = ".heic",
  }
end

-- Common preferred MIME types order
function M.get_preferred_mimes()
  return {"image/png", "image/jpeg", "image/webp", "image/gif", "image/tiff", "image/heic", "image/heif"}
end

function M.find_available_image_target(types_output)
  local available = {}
  for line in (types_output or ""):gmatch("([^\r\n]+)") do
    available[line:match("^%s*(.-)%s*$")] = true
  end

  local mime_map = M.get_image_mime_map()
  for _, mime in ipairs(M.get_preferred_mimes()) do
    if available[mime] and mime_map[mime] then
      return mime, mime_map[mime]
    end
  end

  for mime_type, extension in pairs(mime_map) do
    if available[mime_type] then
      return mime_type, extension
    end
  end

  return nil, nil
end

-- Common function to save image data to temporary file
function M.save_image_to_tmp_file(selected_mime, selected_ext, paste_cmd_template)
  local tmp_dir = fs_utils.get_tmp_dir()
  if not tmp_dir then return nil end
  
  local timestamp = tostring(vim.loop.now())
  local tmp_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. selected_ext)
  local paste_cmd = string.format(paste_cmd_template, selected_mime, tmp_path)
  
  vim.fn.system(paste_cmd)
  if vim.v.shell_error == 0 and vim.fn.filereadable(tmp_path) == 1 and vim.fn.getfsize(tmp_path) > 0 then
    return tmp_path
  else
    fs_utils.cleanup_tmp_file(tmp_path)
    return nil
  end
end

-- Common function to process text from clipboard and return file path
function M.process_clipboard_text(text_result, platform_name)
  if text_result == "" then return nil, false, platform_name .. ": No text content in clipboard." end
  
  local path_candidate = text_result
  
  -- Handle file:// URLs
  if path_candidate:match("^file:///%a:") then
    path_candidate = path_candidate:sub(9)
    path_candidate = utils.url_decode(path_candidate)
    if not path_candidate then
       return nil, false, platform_name .. ": Failed to URL decode file URI from clipboard."
    end
  elseif path_candidate:match("^file://") then
    path_candidate = path_candidate:sub(8)
    path_candidate = utils.url_decode(path_candidate)
    if not path_candidate then
       return nil, false, platform_name .. ": Failed to URL decode file URI from clipboard."
    end
  end
  
  -- Check for HTML/XML content in Wayland
  if platform_name == "Wayland" and path_candidate:match("<[a-zA-Z%s\"'=/%;:%-_%.%?#&]+>") and not path_candidate:match("%.[a-zA-Z0-9]+$") then
    return nil, false, "Wayland: Clipboard text appears to be HTML/XML, not a file path."
  end

  local expanded_path, expand_err = utils.expand_shell_vars_in_path(path_candidate)
  if expanded_path then
    if vim.fn.filereadable(expanded_path) == 1 then
      local validated_path = M.validate_image_path(expanded_path)
      if validated_path then
        return validated_path, false, nil
      end

      return nil, false, platform_name .. ": Clipboard text points to a readable file, but it is not a supported image: '" .. expanded_path .. "'."
    else
      return nil, false, platform_name .. ": Clipboard text (path candidate) '" .. expanded_path .. "' is not a readable file."
    end
  else
    return nil, false, platform_name .. ": Failed to expand clipboard text path: " .. (expand_err or "unknown error")
  end
end

return M
