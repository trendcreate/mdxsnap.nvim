vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function normalize(path)
  return (path or ""):gsub("\\", "/")
end

local function assert_true(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function assert_contains(text, needle, message)
  assert_true(type(text) == "string" and text:find(needle, 1, true) ~= nil, message .. " | got: " .. tostring(text))
end

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function rm_rf(path)
  pcall(vim.fn.delete, path, "rf")
end

local function make_temp_dir(name)
  local root = normalize(vim.fn.tempname()) .. "_" .. name
  assert(vim.fn.mkdir(root, "p") == 1 or vim.fn.isdirectory(root) == 1, "failed to create temp dir: " .. root)
  return root
end

local function clear_modules(names)
  for _, name in ipairs(names) do
    package.loaded[name] = nil
  end
end

local function with_mocked_modules(mocks, fn)
  local saved = {}
  for name, value in pairs(mocks) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local saved_core = package.loaded["mdxsnap.core"]
  package.loaded["mdxsnap.core"] = nil

  local ok, result = xpcall(function()
    local core = require("mdxsnap.core")
    return fn(core)
  end, debug.traceback)

  package.loaded["mdxsnap.core"] = saved_core
  for name, value in pairs(saved) do
    package.loaded[name] = value
  end

  if not ok then
    error(result, 0)
  end

  return result
end

local failures = 0

local function run_test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    print("PASS " .. name)
    return
  end

  failures = failures + 1
  print("FAIL " .. name)
  print(err)
end

run_test("setup keeps options live and does not mutate input", function()
  clear_modules({ "mdxsnap", "mdxsnap.config" })
  local mdxsnap = require("mdxsnap")
  local user_options = {
    DefaultPastePath = "changed/path",
    ProjectOverrides = {
      {
        matchType = "projectName",
        matchValue = "demo",
        PastePath = "images",
        PastePathType = "relative",
      },
    },
  }
  local original = vim.deepcopy(user_options)

  local options = mdxsnap.setup(user_options)
  local config = require("mdxsnap.config")

  assert_true(options == config.options, "setup should return the live config table")
  assert_true(mdxsnap.options.DefaultPastePath == "changed/path", "exported options should stay current after setup")
  assert_true(vim.deep_equal(user_options, original), "setup should not mutate the caller's options table")
end)

run_test("setup rejects invalid customTextFormat", function()
  clear_modules({ "mdxsnap", "mdxsnap.config" })
  local mdxsnap = require("mdxsnap")
  local ok, err = pcall(mdxsnap.setup, { customTextFormat = "%s %s %s" })
  assert_true(not ok, "setup should reject formats with more than two placeholders")
  assert_contains(err, "must contain one or two %s placeholders", "unexpected setup error")
end)

run_test("relative path formatting uses file-relative paths", function()
  clear_modules({ "mdxsnap.editor_utils", "mdxsnap.utils", "mdxsnap.fs_utils" })
  local editor_utils = require("mdxsnap.editor_utils")
  local text = editor_utils.format_image_reference_text(
    "C:/proj/assets/post/img.png",
    "img.png",
    "![%s](%s)",
    "C:/proj/articles/post.md",
    "relative",
    nil
  )

  assert_true(text == "![img](../assets/post/img.png)", "unexpected formatted text: " .. text)
end)

run_test("frontmatter detection ignores body thematic breaks", function()
  clear_modules({ "mdxsnap.editor_utils", "mdxsnap.utils", "mdxsnap.fs_utils" })
  local editor_utils = require("mdxsnap.editor_utils")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Heading",
    "",
    "body",
    "---",
    "",
    "section",
    "---",
    "tail",
  })

  editor_utils.ensure_imports_are_present(buf, {
    { line = 'import Img from "./img"', checkRegex = 'import Img' },
  })

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_true(lines[1] == 'import Img from "./img"', "import should be inserted at the top of the file")
  assert_true(lines[2] == "# Heading", "existing content should stay after inserted import")
end)

run_test("clipboard text rejects readable non-image files", function()
  clear_modules({ "mdxsnap.clipboard.utils", "mdxsnap.utils", "mdxsnap.fs_utils" })
  local clipboard_utils = require("mdxsnap.clipboard.utils")
  local temp_dir = make_temp_dir("clipboard_text")
  local text_path = temp_dir .. "/note.txt"
  write_file(text_path, "hello")

  local returned_path, is_temp, err = clipboard_utils.process_clipboard_text(text_path, "Test")
  assert_true(returned_path == nil, "non-image paths should be rejected")
  assert_true(is_temp == false, "text fallback should not mark files as temporary")
  assert_contains(err, "not a supported image", "unexpected clipboard rejection message")
  rm_rf(temp_dir)
end)

run_test("clipboard file URI handling supports Windows drive paths", function()
  clear_modules({ "mdxsnap.clipboard.utils", "mdxsnap.utils", "mdxsnap.fs_utils" })
  local clipboard_utils = require("mdxsnap.clipboard.utils")
  local temp_dir = make_temp_dir("file_uri")
  local image_path = temp_dir .. "/clip.png"
  write_file(image_path, "png")

  local uri = "file:///" .. normalize(image_path):gsub(" ", "%%20")
  local returned_path = assert(clipboard_utils.process_clipboard_text(uri, "Windows"))
  assert_true(normalize(returned_path) == normalize(image_path), "Windows file URI should resolve to the original file")
  rm_rf(temp_dir)
end)

run_test("project root fallback uses buffer directory", function()
  clear_modules({ "mdxsnap.fs_utils", "mdxsnap.utils" })
  local fs_utils = require("mdxsnap.fs_utils")
  local old_cwd = vim.fn.getcwd()
  local temp_dir = make_temp_dir("root_fallback")
  local nested_dir = temp_dir .. "/notes"
  assert_true(vim.fn.mkdir(nested_dir, "p") == 1 or vim.fn.isdirectory(nested_dir) == 1, "failed to create nested dir")
  local file_path = nested_dir .. "/post.md"
  write_file(file_path, "# post")

  vim.cmd("cd " .. vim.fn.fnameescape(vim.fn.getcwd()))
  local root = assert(fs_utils.find_project_root_path(file_path))
  assert_true(normalize(root) == normalize(nested_dir), "expected buffer directory fallback, got: " .. normalize(root))

  vim.cmd("cd " .. vim.fn.fnameescape(old_cwd))
  rm_rf(temp_dir)
end)

run_test("copy_image_file rejects path traversal in desired_stem", function()
  clear_modules({ "mdxsnap.fs_utils", "mdxsnap.utils" })
  local fs_utils = require("mdxsnap.fs_utils")
  local temp_dir = make_temp_dir("path_traversal")
  local target_dir = temp_dir .. "/posts/current"
  assert_true(vim.fn.mkdir(target_dir, "p") == 1 or vim.fn.isdirectory(target_dir) == 1, "failed to create target dir")

  local source = temp_dir .. "/source.png"
  write_file(source, "img")

  local new_path, _, err = fs_utils.copy_image_file(source, target_dir, ".png", "../shared/banner")
  assert_true(new_path == nil, "path traversal should be rejected")
  assert_contains(err, "plain stem, not a path", "unexpected traversal rejection message")
  rm_rf(temp_dir)
end)

run_test("copy_image_file refuses to overwrite existing files", function()
  clear_modules({ "mdxsnap.fs_utils", "mdxsnap.utils" })
  local fs_utils = require("mdxsnap.fs_utils")
  local temp_dir = make_temp_dir("overwrite")
  local target_dir = temp_dir .. "/images"
  assert_true(vim.fn.mkdir(target_dir, "p") == 1 or vim.fn.isdirectory(target_dir) == 1, "failed to create target dir")

  local source = temp_dir .. "/source.png"
  local destination = target_dir .. "/hero.png"
  write_file(source, "new-content")
  write_file(destination, "old-content")

  local new_path, _, err = fs_utils.copy_image_file(source, target_dir, ".png", "hero")
  assert_true(new_path == nil, "existing destination should not be overwritten")
  assert_contains(err, "already exists", "unexpected overwrite rejection message")
  assert_true(read_file(destination) == "old-content", "existing file contents should be preserved")
  rm_rf(temp_dir)
end)

run_test("x11 falls back to text when image extraction fails", function()
  local temp_dir = make_temp_dir("x11")
  local script_path = temp_dir .. "/xclip.cmd"
  write_file(script_path, table.concat({
    "@echo off",
    "if \"%4\"==\"TARGETS\" echo image/png",
    "if not \"%4\"==\"TARGETS\" echo fallback-text",
  }, "\r\n"))

  local old_path = vim.env.PATH
  vim.env.PATH = temp_dir .. ";" .. old_path

  local mock_utils = {
    find_available_image_target = function()
      return "image/png", ".png"
    end,
    save_image_to_tmp_file = function()
      return nil
    end,
    process_clipboard_text = function(text, platform_name)
      assert_true(text == "fallback-text", "unexpected fallback clipboard text")
      assert_true(platform_name == "X11", "unexpected platform name")
      return "fallback.txt", false, nil
    end,
  }

  local old_notify = vim.notify
  vim.notify = function() end

  package.loaded["mdxsnap.clipboard.utils"] = mock_utils
  package.loaded["mdxsnap.clipboard.x11"] = nil
  local x11 = require("mdxsnap.clipboard.x11")
  local path, is_temp, err = x11.fetch_image_path_from_clipboard_x11()

  vim.notify = old_notify
  package.loaded["mdxsnap.clipboard.utils"] = nil
  package.loaded["mdxsnap.clipboard.x11"] = nil
  vim.env.PATH = old_path
  rm_rf(temp_dir)

  assert_true(path == "fallback.txt", "expected text fallback path")
  assert_true(is_temp == false, "text fallback should not be temporary")
  assert_true(err == nil, "text fallback should not return an error")
end)

run_test("core paste inserts inline text at the cursor", function()
  local temp_dir = make_temp_dir("core_insert")
  local image_path = temp_dir .. "/clip.png"
  write_file(image_path, "png")

  local mock_config = { options = {} }
  local mock_utils = {
    expand_shell_vars_in_path = function(path)
      return path
    end,
  }
  local mock_clipboard_utils = {
    validate_image_path = function()
      return image_path
    end,
  }
  local mock_fs = {
    cleanup_tmp_file = function() end,
    build_final_paste_base_path = function()
      return temp_dir
    end,
    ensure_target_directory_exists = function()
      return temp_dir
    end,
    copy_image_file = function()
      return temp_dir .. "/final.png", "final.png"
    end,
  }
  local mock_clipboard = {
    fetch_image_path_from_clipboard = function()
      return image_path, false, nil
    end,
  }
  local mock_editor = {
    determine_active_paste_config = function()
      return {
        customImports = {},
        customTextFormat = "![%s](%s)",
        project_root = temp_dir,
        type = "relative",
      }, nil
    end,
    ensure_imports_are_present = function() end,
    format_image_reference_text = function()
      return "INSERTED"
    end,
  }

  local old_notify = vim.notify
  vim.notify = function() end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, temp_dir .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcde" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })

  with_mocked_modules({
    ["mdxsnap.config"] = mock_config,
    ["mdxsnap.utils"] = mock_utils,
    ["mdxsnap.clipboard.utils"] = mock_clipboard_utils,
    ["mdxsnap.fs_utils"] = mock_fs,
    ["mdxsnap.clipboard"] = mock_clipboard,
    ["mdxsnap.editor_utils"] = mock_editor,
  }, function(core)
    core.paste_image(nil)
  end)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.notify = old_notify

  assert_true(#lines == 1, "inline insertion should not create a new line")
  assert_true(lines[1] == "abINSERTEDcde", "unexpected inline insertion result: " .. lines[1])
  rm_rf(temp_dir)
end)

if failures > 0 then
  error(string.format("%d test(s) failed", failures))
end

print("ALL_TESTS_PASSED")
