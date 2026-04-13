local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

function M.fetch_image_path_from_clipboard_wayland()
  if vim.fn.executable("wl-paste") == 0 then
    return nil, false, "Wayland environment detected, but wl-paste command not found."
  end

  -- Try to get image data first
  local list_cmd = "wl-paste --list-types"
  local types_handle = io.popen(list_cmd)
  local types_str = ""
  if types_handle then
    types_str = types_handle:read("*a")
    types_handle:close()
  end

  local selected_mime, selected_ext = clipboard_utils.find_available_image_target(types_str)

  -- Try to save image data if found
  if selected_mime and selected_ext then
    local tmp_path = clipboard_utils.save_image_to_tmp_file(selected_mime, selected_ext, "wl-paste --type %s > '%s'")
    if tmp_path then
      return tmp_path, true, nil
    end
  end

  -- Fall back to text content
  local text_cmd = "wl-paste -n"
  local text_handle = io.popen(text_cmd)
  local text_result = ""
  if text_handle then
    text_result = text_handle:read("*a")
    text_handle:close()
    text_result = text_result:gsub("[\r\n]", "")
  end

  if text_result ~= "" then
    return clipboard_utils.process_clipboard_text(text_result, "Wayland")
  end
  
  return nil, false, "Wayland: wl-paste -n did not yield usable text from clipboard."
end

return M
