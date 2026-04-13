local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

function M.fetch_image_path_from_clipboard_windows()
  -- Attempt to get image directly using PowerShell
  local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scripts/powershell/save_clipboard_image_as_png.ps1"
  local image_cmd = "powershell -ExecutionPolicy Bypass -NoProfile -NonInteractive -File \"" .. script_path .. "\""
  
  local image_handle = io.popen(image_cmd)
  local image_result = ""
  if image_handle then
    image_result = image_handle:read("*a")
    image_handle:close()
    image_result = image_result:gsub("[\r\n]", "")
  else
    vim.notify("Windows: Failed to execute PowerShell for image extraction (io.popen failed).", vim.log.levels.WARN)
  end

  if image_result ~= "" and image_result ~= "NoImage" and image_result ~= "ErrorSavingImage" then
    if vim.fn.filereadable(image_result) == 1 then
      return image_result, true, nil -- path, is_temporary, error_message
    else
      vim.notify("Windows: PowerShell reported image saved to '" .. image_result .. "', but file is not readable.", vim.log.levels.WARN)
    end
  elseif image_result == "ErrorSavingImage" then
      vim.notify("Windows: PowerShell script encountered an error while saving the image.", vim.log.levels.WARN)
  end
  -- If image extraction failed or no image, fall back to text-based clipboard
  vim.notify("Windows: No image found in clipboard via PowerShell or error occurred, trying text.", vim.log.levels.INFO)

  local text_cmd = "powershell -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command \"Get-Clipboard -Format Text -Raw\""
  local text_handle = io.popen(text_cmd)
  if not text_handle then return nil, false, "Windows: Failed to execute PowerShell Get-Clipboard (text fallback)." end
  local text_result = text_handle:read("*a")
  local is_close_ok, _, close_code = text_handle:close()
  text_result = text_result:gsub("[\r\n]", "")

  if text_result == "" then
      local error_detail = "Windows: PowerShell Get-Clipboard (text fallback) returned no text (clipboard might be empty)"
      if not is_close_ok or (close_code and close_code ~= 0) then
          error_detail = error_detail .. " or PowerShell command failed [code: " .. tostring(close_code) .. "]"
      end
      return nil, false, error_detail .. "."
  end

  return clipboard_utils.process_clipboard_text(text_result, "Windows")
end

return M
