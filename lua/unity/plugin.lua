local M = {}

local xmlHandler = require("unity.handler")
local config = require("unity.config")
local ok, utils = pcall(require, "unity.utils")
if not ok then
	vim.notify("[NvimUnity] Failed to load unity.utils", vim.log.levels.ERROR)
	return
end

-- Função setup (opcionalmente recebe overrides)
function M.setup(opts)
  opts = opts or {}
  M.server = vim.g.unity_server or "http://localhost:42069"
  print("[nvim-unity-handle] Server set to: " .. M.server)

  -- Permite sobrescrever valores do config se desejado
  if opts.unity_path then
    config.unity_path = opts.unity_path
  end

end

local unityProject = xmlHandler:new()
local api = require("nvim-tree.api")
local Event = api.events.Event
local lspAttached = false

local function trySaveProject()
	local saved, err = unityProject:save()
	if not saved and err then
		vim.notify("[NvimUnity] " .. err, vim.log.levels.ERROR)
	end
end

api.events.subscribe(Event.FileCreated, function(data)
	if lspAttached then
		return
	end
	if not unityProject:validateProject() or not utils.isCSFile(data.fname) then
		return
	end

	local folderName = utils.cutPath(utils.uriToPath(data.fname), "Assets") or ""
	if unityProject:addCompileTag(folderName) then
		utils.insertCSTemplate(data.fname)
		trySaveProject()
	end
end)

api.events.subscribe(Event.FileRemoved, function(data)
	if lspAttached then
		return
	end
	if not unityProject:validateProject() or not utils.isCSFile(data.fname) then
		return
	end

	local folderName = utils.cutPath(utils.uriToPath(data.fname), "Assets") or ""
	if unityProject:removeCompileTag(folderName) then
		trySaveProject()
	end
end)

api.events.subscribe(Event.WillRenameNode, function(data)
	if not unityProject:validateProject() then
		return
	end

	if utils.isDirectory(data.old_name) then
		local updatedFileNames = utils.getUpdatedCSFilesNames(data.old_name, data.new_name)
		if #updatedFileNames == 0 then
			return
		end

		local nameChanges = {}
		for _, file in ipairs(updatedFileNames) do
			table.insert(nameChanges, {
				old = utils.cutPath(utils.uriToPath(file.old), "Assets") or "",
				new = utils.cutPath(utils.uriToPath(file.new), "Assets") or "",
			})
		end

		unityProject:updateCompileTags(nameChanges)
		trySaveProject()
	else
		if lspAttached then
			return
		end

		local nameChanges = {
			{
				old = utils.cutPath(utils.uriToPath(data.old_name), "Assets") or "",
				new = utils.cutPath(utils.uriToPath(data.new_name), "Assets") or "",
			},
		}

		unityProject:updateCompileTags(nameChanges)
		trySaveProject()
	end
end)

api.events.subscribe(Event.FolderRemoved, function(data)
	if not unityProject:validateProject() or not data.folder_name then
		return
	end

	local folderName = utils.cutPath(utils.uriToPath(data.folder_name), "Assets") or ""
	if unityProject:removeCompileTagsByFolder(folderName) then
		trySaveProject()
	end
end)

vim.api.nvim_create_autocmd("LspNotify", {
	callback = function(args)
		if args.data.method ~= "workspace/didChangeWatchedFiles" then
			return
		end

		local changes = args.data.params.changes
		local needSave = false

		if #changes == 1 then
			if not utils.isCSFile(changes[1].uri) or not unityProject:validateProject() then
				return
			end

			local fileName = utils.cutPath(utils.uriToPath(changes[1].uri), "Assets") or ""
			if changes[1].type == 1 then
				utils.insertCSTemplate(utils.uriToPath(changes[1].uri))
				if unityProject:addCompileTag(fileName) then
					needSave = true
				end
			elseif changes[1].type == 3 then
				if unityProject:removeCompileTag(fileName) then
					needSave = true
				end
			end
		elseif #changes == 2 then
			if not utils.isCSFile(changes[1].uri) or not utils.isCSFile(changes[2].uri) then
				return
			end
			if not unityProject:validateProject() then
				return
			end

			if changes[1].type == 3 and changes[2].type == 1 then
				local nameChanges = {
					{
						old = utils.cutPath(utils.uriToPath(changes[1].uri), "Assets") or "",
						new = utils.cutPath(utils.uriToPath(changes[2].uri), "Assets") or "",
					},
				}
				if unityProject:updateCompileTags(nameChanges) then
					needSave = true
				end
			end
		end

		if needSave then
			trySaveProject()
		end
	end,
})

vim.api.nvim_create_autocmd("LspAttach", {
	once = true,
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if unityProject and client and client.name == unityProject:getLspName() then
			if unityProject:validateProject() then
				lspAttached = true
				vim.notify("[NvimUnity] LSP " .. client.name .. " is ready to go, happy coding!", vim.log.levels.INFO)
			end
		end
	end,
})

vim.api.nvim_create_autocmd("LspDetach", {
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if client and client.name == unityProject:getLspName() then
			if unityProject:validateProject() then
				lspAttached = false
			end
		end
	end,
})

vim.api.nvim_create_autocmd("VimEnter", {
	callback = function()
		unityProject:updateRoot()
		if unityProject:validateProject() then
			vim.notify("[NvimUnity] Unity project detected at " .. unityProject:getRoot(), vim.log.levels.INFO)
		end
	end,
})

vim.api.nvim_create_autocmd("DirChanged", {
	callback = function()
		unityProject:updateRoot()
	end,
})

vim.api.nvim_create_user_command("Uadd", function()
	local bufname = vim.api.nvim_buf_get_name(0)

	if not unityProject:validateProject() then
		vim.api.nvim_err_writeln("[NvimUnity] This is not a Unity project, try to regenerate the csproj files in Unity")
		return
	end

	if not utils.isCSFile(bufname) then
		vim.api.nvim_err_writeln("[NvimUnity] Open a script '.cs' file ")
		return
	end

	if vim.fn.filereadable(bufname) == 1 then
		local fileName = utils.cutPath(bufname, "Assets")
		fileName = utils.uriToPath(fileName)
		local added, msg = unityProject:addCompileTag(fileName)
		if added then
			trySaveProject()
		else
			vim.notify(msg, vim.log.levels.WARN)
		end
	end
end, { nargs = 0 })

vim.api.nvim_create_user_command("Uaddall", function()
	if not unityProject:validateProject() then
		vim.api.nvim_err_writeln(
			"[NvimUnity] This is not an Unity project, try to regenerate the csproj files in Unity"
		)
		return
	end

	local reseted, msg = unityProject:resetCompileTags(9)
	if reseted then
		trySaveProject()
	else
		vim.notify("[NvimUnity] " .. msg, vim.log.levels.WARN)
	end
end, { nargs = 0 })

vim.api.nvim_create_user_command("Ustatus", function()
	if not unityProject:validateProject() then
		vim.notify("[NvimUnity] This is not a valid Unity project.", vim.log.levels.WARN)
		return
	end

	local msg = {
		"🧠 [NvimUnity] Project Status:",
		"📁 Root: " .. unityProject:getRoot(),
		"🔌 LSP Active: " .. (lspAttached and "Yes" or "No"),
	}

	vim.notify(table.concat(msg, "\n"), vim.log.levels.INFO)
end, { nargs = 0 })

vim.api.nvim_create_user_command("Uregenerate", function()
	vim.fn.jobstart({
		"curl",
		"-X",
		"POST",
    M.server .. "/regenerate"
	}, {
		on_exit = function(_, code)
			if code == 0 then
				print("[Unity] Project files regenerated!")
			else
				print("[Unity] Failed to contact Unity server.")
			end
		end,
	})
end, {})

vim.api.nvim_create_user_command("Uopen", function()
	if not unityProject:validateProject() then
		vim.notify("[NvimUnity] This is not a Unity project ", vim.log.levels.ERROR)
		return
	end
	unityProject:openProject()
end, {
	desc = "Open Unity Editor from Neovim",
})
