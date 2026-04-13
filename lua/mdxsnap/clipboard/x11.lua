local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

function M.fetch_image_path_from_clipboard_x11()
  if vim.fn.executable("xclip") == 0 then
    return nil, false, "X11 environment: xclip command not found."
  end

  -- Get available clipboard targets
  local targets_cmd = "xclip -selection clipboard -t TARGETS -o"
  local targets_handle = io.popen(targets_cmd)
  local targets_content = ""
  local is_cmd_failed = false

  if targets_handle then
    targets_content = targets_handle:read("*a")
    local is_close_ok, reason, code = targets_handle:close()
    if not is_close_ok or (reason == "exit" and code ~= 0) then
      vim.notify(string.format("X11: 'xclip -t TARGETS -o' command failed or returned non-zero. Status: %s, Code: %s. Output was: %s",
                               tostring(reason), tostring(code), targets_content), vim.log.levels.WARN)
      is_cmd_failed = true
      targets_content = ""
    end
  else
    vim.notify("X11: Failed to execute 'xclip -t TARGETS -o' (io.popen failed). Cannot determine available image types.", vim.log.levels.WARN)
    is_cmd_failed = true
  end

  local selected_target, selected_ext
  if not is_cmd_failed and targets_content ~= "" then
    selected_target, selected_ext = clipboard_utils.find_available_image_target(targets_content)
  end

  -- Try to save image data if found
  local image_error
  if selected_target and selected_ext then
    local tmp_path = clipboard_utils.save_image_to_tmp_file(selected_target, selected_ext, "xclip -selection clipboard -t %s -o > '%s'")
    if tmp_path then
      return tmp_path, true, nil
    end

    local failure_reason = "unknown reason"
    if vim.v.shell_error ~= 0 then
      failure_reason = "xclip command failed with shell_error: " .. vim.v.shell_error
    end
    vim.notify("X11: Failed to save clipboard image target. Falling back to text.", vim.log.levels.WARN)
    image_error = "X11: Found image target '" .. selected_target .. "' but failed to retrieve/save image data: " .. failure_reason
  end

  -- Fall back to text content
  local text_cmd = "xclip -selection clipboard -o"
  local text_handle = io.popen(text_cmd)

  if not text_handle then
    return nil, false, "X11: Failed to execute xclip command for text (io.popen failed)."
  end

  local text_result = text_handle:read("*a")
  local is_close_ok, close_reason, close_code = text_handle:close()
  text_result = text_result:gsub("[\r\n]", "")

  if text_result == "" then
    local error_detail = "X11: xclip did not return any text. Clipboard might be empty, or contain non-text data (e.g., image data that could not be processed via TARGETS)"
    if not is_close_ok or (close_reason == "exit" and close_code ~= 0) or close_reason == "signal" then
       error_detail = error_detail .. ". xclip (text mode) might also have encountered an error [status: " .. tostring(close_reason) .. " code: " .. tostring(close_code) .. "]"
    end
    if image_error then
      error_detail = image_error .. ". " .. error_detail
    end
    error_detail = error_detail .. "."
    return nil, false, error_detail
  end
  
  return clipboard_utils.process_clipboard_text(text_result, "X11")
end

return M
