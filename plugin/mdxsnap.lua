-- Only create the command, don't auto-initialize
vim.api.nvim_create_user_command("PasteImage", function(opts)
	-- Lazy load core module when command is actually used
	local core = require("mdxsnap.core")
	core.paste_image(opts.fargs[1])
end, {
	nargs = "?", -- 0 or 1 argument
	desc = "Paste image from clipboard and insert into MDX/Markdown (mdxsnap) [filename]",
})
