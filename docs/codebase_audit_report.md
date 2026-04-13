# Codebase Audit Report

## Scope
- Reviewed files: `README.md`, `plugin/mdxsnap.lua`, `lua/mdxsnap/**/*.lua`, `scripts/**/*.ps1`, `scripts/**/*.applescript`, `docs/directory.md`
- Excluded from code review: `docs/*.gif`, `docs/*.mp4`, license texts
- This report is a static code review of the current repository snapshot. OS-specific clipboard behavior was read carefully but not runtime-verified on all platforms in this environment.

## Branch Update
- This document started as an audit of the pre-refactor implementation.
- In `refactor/overall-1`, the highest-priority issues called out here were addressed in code and covered by `scripts/verify_audit_findings.lua`.
- The detailed sections below remain useful as a record of what was wrong and why those changes were made.

## Verification Status
- Repository-provided automated tests: none found
- Runtime verification attempted: yes
- Runtime verification available in this environment: yes
- Commands attempted:
- Initial check: `where.exe nvim`, `where.exe lua`, `where.exe luajit` returned no executable on `PATH`
- Installed during this session: `Neovim.Neovim`, `DEVCOM.Lua`, `DEVCOM.LuaJIT` via `winget`
- Verified by absolute path because the current shell `PATH` has not refreshed yet:
- `C:\Program Files\Neovim\bin\nvim.exe --version`: succeeded (`NVIM v0.12.1`, `LuaJIT 2.1.1774638290`)
- `C:\Users\hide\AppData\Local\Programs\Lua\bin\lua.exe -v`: succeeded (`Lua 5.4.6`)
- `C:\Users\hide\AppData\Local\Programs\LuaJIT\bin\luajit.exe -v`: succeeded (`LuaJIT 2.1.1720049189`)
- `C:\Program Files\Neovim\bin\nvim.exe --headless -u NONE -c "lua dofile('scripts/verify_audit_findings.lua')" -c "qa!"`: succeeded
- Verification script result: all audit verification checks passed
- Consequence: the major findings in this report are now backed by both direct source inspection and headless Neovim runtime verification.
- Important: `scripts/verify_audit_findings.lua` confirms the current audit findings. It is not a correctness test suite for the desired future behavior of the plugin.

## Executive Summary
- The codebase is small and easy to read. The module split is mostly reasonable: command entrypoint, core workflow, editor helpers, filesystem helpers, and OS-specific clipboard backends are separated.
- The biggest problems are not architecture size but correctness gaps at the edges: wrong insertion behavior, weak input validation, unsafe filename handling, inconsistent platform behavior, and configuration state bugs.
- The plugin already reads like a working prototype, but it is not yet a hardened plugin. The most urgent fixes are in `core.lua`, `fs_utils.lua`, `editor_utils.lua`, `config.lua`, and the X11 / clipboard path handling.
- There are no tests. That makes regressions around clipboard parsing, import insertion, path formatting, and project override matching very likely.

## What The Plugin Currently Does
- It defines a global `:PasteImage [filename]` user command in `plugin/mdxsnap.lua:2-10`.
- Calling the command lazy-loads `mdxsnap.core` and runs `paste_image(opts.fargs[1])`.
- `core.lua` then performs this flow:
- Validate the current buffer and ensure it is `markdown` / `mdx` by filetype or extension: `lua/mdxsnap/core.lua:17-44`
- Ask the platform clipboard backend for either an image file path or a temporary file containing clipboard image data: `lua/mdxsnap/core.lua:52-64`, `lua/mdxsnap/clipboard.lua:8-34`
- Infer the file extension from the returned path: `lua/mdxsnap/core.lua:66-73`
- Resolve project-specific or default paste configuration: `lua/mdxsnap/editor_utils.lua:104-138`
- Resolve the final base path and ensure a subdirectory named after the current document stem exists: `lua/mdxsnap/fs_utils.lua:44-74`
- Copy the image into the target directory: `lua/mdxsnap/fs_utils.lua:76-154`
- For MDX only, insert configured imports if missing: `lua/mdxsnap/core.lua:138-140`, `lua/mdxsnap/editor_utils.lua:140-169`
- Format the reference text and insert it into the buffer: `lua/mdxsnap/core.lua:142-152`, `lua/mdxsnap/editor_utils.lua:171-183`

## Intended Specification Read From README
- The plugin is advertised as a Neovim plugin to paste clipboard images into Markdown and MDX files: `README.md:3`
- `:PasteImage [filename]` is documented as accepting an optional filename stem and alt text source: `README.md:21-23`, `README.md:69-79`
- The image should be saved into a configured directory, optionally with project overrides: `README.md:29-33`, `README.md:117-158`
- Custom imports are meant to be auto-inserted for MDX: `README.md:32`, `README.md:95-104`
- Custom text formatting is supported with one or two `%s` placeholders: `README.md:33`, `README.md:106-115`
- Relative paste paths are documented as relative to the project root: `README.md:89-93`, `README.md:146-153`

## Highest Priority Findings

### 1. The plugin does not insert text "at the cursor"
- Code: `lua/mdxsnap/core.lua:89-92`
- Spec conflict: `README.md:79`
- `insert_text_at_cursor` uses `nvim_buf_set_lines`, which inserts a full line at the current row and ignores the cursor column entirely.
- Practical impact: inline insertion does not work, insertion happens above the current line, and the README promise is false.
- Fix direction: use `nvim_buf_set_text`, `nvim_put`, or a cursor-aware helper that respects row and column.

### 2. Non-image files can be accepted and pasted as images
- Code: `lua/mdxsnap/clipboard/utils.lua:74-79`, `lua/mdxsnap/core.lua:66-72`
- Spec conflict: `README.md:21`, `README.md:67`
- `process_clipboard_text` accepts any readable file path. `core.determine_extension` only checks whether the path has an extension, not whether it is an image.
- Practical impact: a clipboard path to `notes.txt`, `report.pdf`, or any other readable file can be copied into the target image folder and inserted with Markdown image syntax.
- This is a real correctness bug, not just a style issue.
- Fix direction: centralize image validation and require either a supported extension or MIME-backed image source before copying.

### 3. User-provided filenames are unsafe and can overwrite or escape the intended target path
- Code: `lua/mdxsnap/fs_utils.lua:81-113`, `plugin/mdxsnap.lua:7-8`
- `desired_stem` is concatenated directly into the destination filename with no sanitization.
- Practical impact:
- `:PasteImage hero` silently overwrites an existing `hero.png` if it already exists.
- `:PasteImage ../shared/banner` can escape the document-specific directory.
- `complete = "file"` makes this worse because the command completion suggests path-like input even though the README describes a filename stem, not a path.
- Fix direction: sanitize to basename-only, strip separators, reject `..`, and fail when the destination already exists unless overwrite is explicitly requested.

### 4. X11 says it falls back to text but actually returns early
- Code: `lua/mdxsnap/clipboard/x11.lua:54-65`, text fallback only starts at `lua/mdxsnap/clipboard/x11.lua:68`
- The failure branch logs "Falling back to text" and then immediately returns `nil`.
- Practical impact: when image target discovery succeeds but temp-save fails, the code never executes the text fallback path.
- This is a direct logic bug.

### 5. `require("mdxsnap").options` becomes stale after `setup()`
- Code: `lua/mdxsnap/init.lua:19-20`, `lua/mdxsnap/config.lua:55`
- `init.lua` stores `M.options = config.options` once. Later `config.setup()` replaces `config.options` with a new table.
- Practical impact: callers reading `require("mdxsnap").options` after setup may observe pre-setup state.
- The comment in `init.lua` says this is exported for direct access, so the current behavior violates the stated intent.
- Fix direction: expose a getter, reference `config.options` dynamically, or mutate the existing table in place instead of rebinding it.

### 6. `customTextFormat` can crash on three or more `%s` placeholders
- Code: `lua/mdxsnap/editor_utils.lua:89-95`, `lua/mdxsnap/editor_utils.lua:171-183`
- The code counts `%s`, but if the count is `>= 2`, it always calls `string.format(text_format, alt_text, display_path)` with exactly two arguments.
- Practical impact: any format string with three `%s` placeholders throws at runtime.
- The README documents one or two placeholders, but the code does not validate that contract early, and the runtime failure happens after the file has already been copied.
- Fix direction: validate config at setup time and reject anything other than exactly one or two `%s` placeholders.

### 7. Project root fallback is wrong for standalone files
- Code: `lua/mdxsnap/fs_utils.lua:4-20`
- If no VCS / project marker is found, the function falls back to `vim.fn.getcwd()` instead of the buffer directory.
- Practical impact: editing `~/notes/post.md` while Neovim `cwd` is another project can send pasted images into the wrong tree.
- This conflicts with user expectation and makes relative mode unreliable outside repository-shaped projects.
- Fix direction: use `vim.fs.root` and fall back to the buffer's own directory when no root marker exists.

## Important But Secondary Problems

### 8. Frontmatter detection is too loose
- Code: `lua/mdxsnap/editor_utils.lua:23-35`
- The function treats any paired `---` lines anywhere in the file as frontmatter.
- Practical impact: normal thematic breaks later in a Markdown document can be mistaken for frontmatter, and imports may be inserted in the wrong place.
- Fix direction: only treat `---` as frontmatter when it starts at the beginning of the file, or after leading blank lines if that policy is intentional.

### 9. Relative display paths are emitted as root-relative paths
- Code: `lua/mdxsnap/editor_utils.lua:59-87`
- For `relative` mode, the inserted path is normalized to start with `/`.
- Practical impact: this is site-root semantics, not file-relative semantics. It works for some static-site pipelines but is a poor default for generic Markdown viewers and many MDX setups.
- The plugin README positions the plugin as generic Markdown/MDX support, so this behavior is more opinionated than the docs suggest.

### 10. `setup()` mutates the caller's table
- Code: `lua/mdxsnap/config.lua:50-56`
- `user_options.ProjectOverrides` is set to `nil` before `vim.tbl_deep_extend` runs.
- Practical impact: code that reuses the same config table elsewhere sees unexpected mutation.
- This is avoidable and makes the API harder to reason about.

### 11. Runtime notifications are too noisy
- Code: `lua/mdxsnap/editor_utils.lua:20`, `lua/mdxsnap/clipboard.lua:18-19`, `lua/mdxsnap/clipboard/windows.lua:30`, plus various warnings in platform files
- The plugin emits informational notifications for normal override selection and Windows fallback behavior.
- Practical impact: pasting an image can generate multiple notifications for one action.
- Fix direction: reserve notifications for user-visible failures and final success, or add a `debug` / `verbose` option.

### 12. `checkRegex` is documented as a regex, but the code uses Lua pattern matching
- Code: `lua/mdxsnap/editor_utils.lua:37-43`
- README wording: `README.md:96-104`, `README.md:155-157`
- `string.find` without `plain = true` uses Lua patterns, not general regex syntax.
- Practical impact: users may provide regex-like syntax that behaves differently from what they expect.
- Fix direction: either rename the option to `checkPattern`, switch to plain-string matching, or clearly document Lua pattern semantics.

### 13. Import insertion logic only partially understands existing import blocks
- Code: `lua/mdxsnap/editor_utils.lua:140-169`
- New imports are inserted after the last already-known configured import, or after detected frontmatter, or at top of file.
- Practical impact: if the file already has imports that are not covered by `customImports`, new imports can be inserted in a surprising place rather than after the existing import section.
- This is not always wrong, but it is brittle.

### 14. Path matching for `projectPath` is exact and unnormalized
- Code: `lua/mdxsnap/editor_utils.lua:6-13`, `lua/mdxsnap/editor_utils.lua:117-123`
- `project_root` and expanded `matchValue` are compared as raw strings.
- Practical impact: slash normalization, drive-letter casing, trailing slash differences, and symlinked paths can cause rules to miss unexpectedly.
- Fix direction: normalize both paths before comparing.

### 15. Configuration is validated too late
- Code: `lua/mdxsnap/editor_utils.lua:97-102`, `lua/mdxsnap/fs_utils.lua:44-62`, `lua/mdxsnap/editor_utils.lua:171-183`
- Invalid `checkRegex`, invalid `PastePathType`, and invalid text formats are only discovered while pasting.
- Practical impact: configuration errors surface during user actions instead of at startup.
- Fix direction: add a config normalization / validation pass inside `setup()`.

## Implementation Smells

### 16. Clipboard command execution is inconsistent across modules
- Code: `io.popen` in `lua/mdxsnap/clipboard/x11.lua`, `wayland.lua`, `windows.lua`, `macos.lua`; `vim.fn.system` in `lua/mdxsnap/clipboard/utils.lua` and `macos.lua`
- The code mixes `io.popen`, `vim.fn.system`, shell redirection, and direct command string building.
- Practical impact: error handling is inconsistent, quoting is fragile, and behavior differs by backend for reasons unrelated to the actual clipboard logic.
- Fix direction: centralize command execution behind one helper and use `vim.system` or a single safe wrapper with structured args where possible.

### 17. Shell quoting is fragile
- Code: `lua/mdxsnap/clipboard/macos.lua:8-10`, `lua/mdxsnap/clipboard/macos.lua:42-45`, `lua/mdxsnap/clipboard/utils.lua:43-45`, `lua/mdxsnap/clipboard/windows.lua:7-8`
- Several commands are composed by string concatenation.
- Practical impact: paths containing quotes or shell-sensitive characters can break command execution, especially for script paths or temp paths under unusual home directories.
- Fix direction: use argument arrays instead of shell-escaped strings whenever possible.

### 18. Script path discovery is duplicated and fragile
- Code: `lua/mdxsnap/clipboard/macos.lua:8`, `lua/mdxsnap/clipboard/macos.lua:43`, `lua/mdxsnap/clipboard/windows.lua:7`
- `debug.getinfo(...):source:sub(2)` plus `:p:h:h:h:h` is repeated to locate `scripts/`.
- Practical impact: the depth assumption is brittle and harder to maintain than a single helper.

### 19. Wayland and X11 duplicate MIME-selection logic
- Code: `lua/mdxsnap/clipboard/wayland.lua:18-41`, `lua/mdxsnap/clipboard/x11.lua:29-51`
- The same preferred MIME selection pattern is implemented twice with slightly different control flow.
- Practical impact: bug fixes and MIME additions have to be repeated.
- Fix direction: extract a shared helper that picks the first supported preferred type from an available list.

### 20. Windows duplicates clipboard text parsing that already exists in shared utils
- Code: `lua/mdxsnap/clipboard/windows.lua:47-72`, overlap with `lua/mdxsnap/clipboard/utils.lua:55-84`
- The Windows backend reimplements file-URI decoding and readable-path checks instead of sharing the generic text path pipeline.
- Practical impact: behavior diverges across platforms and future bug fixes will likely be applied unevenly.

### 21. Project root discovery is hand-rolled despite Neovim already shipping helpers
- Code: `lua/mdxsnap/fs_utils.lua:4-20`
- The traversal is manual, marker-based, capped at 64 levels, and uses a fallback that is not ideal.
- Fix direction: replace with `vim.fs.root` and a simpler fallback rule.

## Places Where Code Can Be Reduced

### 22. Centralize clipboard text path parsing
- Current duplication: `lua/mdxsnap/clipboard/utils.lua:55-84` and `lua/mdxsnap/clipboard/windows.lua:47-72`
- Reduction: keep one shared function that accepts platform-specific URI quirks as parameters.

### 23. Centralize MIME selection
- Current duplication: `lua/mdxsnap/clipboard/wayland.lua:18-41` and `lua/mdxsnap/clipboard/x11.lua:29-51`
- Reduction: move "pick the best available MIME and extension" into `clipboard/utils.lua`.

### 24. Centralize script path building
- Current duplication: `lua/mdxsnap/clipboard/macos.lua:8,43`, `lua/mdxsnap/clipboard/windows.lua:7`
- Reduction: one helper like `get_repo_script_path(relpath)` removes repeated `debug.getinfo` path slicing.

### 25. Collapse config derivation into one normalization pass
- Current spread: defaults in `config.lua`, runtime merge in `config.lua`, runtime override selection in `editor_utils.lua`, runtime validation elsewhere
- Reduction: normalize once at setup, then read a clean config structure during paste.

### 26. Simplify import insertion
- Current behavior re-reads the full buffer after every inserted import: `lua/mdxsnap/editor_utils.lua:160-163`
- Reduction: compute insertion point once, build a list of missing imports once, insert them in one buffer write.

### 27. Simplify random filename generation
- Current code: `lua/mdxsnap/fs_utils.lua:85-99`
- Reduction: this is overbuilt for the actual need. A simpler collision-resistant strategy plus existence check would be easier to reason about.

## File-By-File Notes

### `plugin/mdxsnap.lua`
- Good: tiny entrypoint, lazy-loads the heavy module.
- Problem: `complete = "file"` suggests path input, but the argument is documented as a filename stem. This increases the chance of unsafe or malformed filenames.

### `lua/mdxsnap/init.lua`
- Good: minimal public API.
- Problem: exporting `M.options = config.options` creates stale state after `setup()`.
- Problem: the comments say this export exists for backwards compatibility, but the behavior is not actually stable.

### `lua/mdxsnap/config.lua`
- Good: defaults are easy to find.
- Problem: `setup()` mutates `user_options`.
- Problem: the module rebinds `M.options`, which contributes to stale references.
- Problem: there is no config validation pass.

### `lua/mdxsnap/core.lua`
- Good: orchestration is linear and readable.
- Problem: insertion is line-based, not cursor-based.
- Problem: it trusts downstream helpers too much and does not defend against invalid text formats or non-image clipboard paths.
- Problem: it notifies success with `new_path`, which may be absolute even when the user-facing inserted path is different.

### `lua/mdxsnap/editor_utils.lua`
- Good: clear separation of config selection and text formatting.
- Problem: frontmatter detection is heuristic and too loose.
- Problem: path display behavior is opinionated and not generic.
- Problem: import detection uses Lua patterns while the README says regex.
- Problem: it emits an info notification for a normal project override match.

### `lua/mdxsnap/fs_utils.lua`
- Good: filesystem responsibilities are separated cleanly.
- Problem: project root fallback should be buffer-dir, not `cwd`.
- Problem: destination filenames are unsanitized and can overwrite existing files.
- Problem: a simpler and safer naming strategy would be easier to maintain.

### `lua/mdxsnap/utils.lua`
- Mostly fine.
- Minor note: `expand_shell_vars_in_path` is just `vim.fn.expand`; the name sounds more powerful than what it actually does.
- Minor note: `get_os_type` maps BSD to `linux`, which is a pragmatic hack but should be documented if kept.

### `lua/mdxsnap/clipboard.lua`
- Good: single dispatch point by OS.
- Problem: it mixes returning errors with notifying directly, which makes notification policy inconsistent.

### `lua/mdxsnap/clipboard/utils.lua`
- Good: clearly intended as the shared layer.
- Problem: `process_clipboard_text` does not enforce image validation.
- Problem: command execution still relies on shell strings.
- Problem: supported extension coverage and MIME coverage are not aligned with the macOS backend.

### `lua/mdxsnap/clipboard/macos.lua`
- Good: it supports both file-path and raw-image clipboard approaches.
- Problem: the AppleScript file-URL helper is only attempted when the `pbpaste` result contains no `/`, which makes the fallback logic oddly narrow.
- Problem: command strings are shell-concatenated.
- Problem: script path resolution is repeated.

### `lua/mdxsnap/clipboard/wayland.lua`
- Good: clear preference order for MIME types.
- Problem: logic is duplicated with X11.
- Problem: command execution is shell-string based.

### `lua/mdxsnap/clipboard/x11.lua`
- Good: it tries image targets first and then text.
- Problem: the failure branch says it falls back but does not.
- Problem: the file is noisier than necessary due to detailed notify calls instead of consistent error returns.
- Problem: MIME-selection logic duplicates Wayland.

### `lua/mdxsnap/clipboard/windows.lua`
- Good: it cleanly separates image extraction and text fallback.
- Problem: it duplicates URI and path parsing already available in shared utilities.
- Problem: it accepts readable non-image paths.
- Problem: the backend is explicitly marked untested in the README, so this path is high-risk.

### `scripts/applescript/*.applescript`
- Good: the scripts are short and focused.
- Problem: they are tightly coupled to the Lua side through shell-invoked string commands rather than safer argument passing patterns.

### `scripts/powershell/save_clipboard_image_as_png.ps1`
- Good: short and straightforward.
- Risk: it assumes the PowerShell clipboard image API works in the current session model; this is reasonable but unverified here.

### `docs/directory.md`
- Good: it gives a quick overview.
- Problem: it is already incomplete relative to the actual tree because the clipboard submodules and `plugin/` entrypoint are not covered.

## Testing And Documentation Gaps
- There are no test files in the repository.
- The highest-value tests would cover:
- `format_image_reference_text` with one, two, zero, and invalid placeholder counts
- import insertion in files with top frontmatter, no frontmatter, existing imports, and thematic breaks inside the body
- project override matching for normalized paths, name matches, and no-root fallbacks
- clipboard text path validation rejecting non-images
- filename sanitization and overwrite prevention
- README should document whether inserted paths are expected to be root-relative or file-relative. The current behavior is not obvious from the configuration names alone.

## Recommended Fix Order
1. Fix cursor insertion so the README claim matches real behavior.
2. Reject non-image clipboard paths and validate image input centrally.
3. Sanitize `desired_stem`, reject traversal, and prevent silent overwrite.
4. Fix the X11 false-fallback bug.
5. Repair config state handling so `require("mdxsnap").options` is never stale.
6. Add setup-time config validation for `PastePathType`, `customImports`, and `customTextFormat`.
7. Replace the project-root fallback rule with `buffer_dir` when no marker exists.
8. Reduce duplication in clipboard backends.
9. Add tests for editor behavior, path logic, and config matching.

## Overall Assessment
- The repository is small enough that a cleanup can be done quickly.
- The main value of the current implementation is its clear module split and easy-to-follow control flow.
- The main weakness is that several edge cases were left as runtime assumptions instead of validated contracts.
- This is not a "rewrite needed" codebase. It is a "tighten correctness, remove duplication, and add tests" codebase.
