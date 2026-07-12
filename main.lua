local M = {}

local get_yanked_info = ya.sync(function()
	local cwd = cx.active.current.cwd
	local cut = cx.yanked.is_cut

	local yanked = {}
	for _, url in ipairs(cx.yanked:urls()) do
		yanked[#yanked + 1] = { url = url, name = tostring(url.name) }
	end

	return { cwd = cwd, cut = cut, yanked = yanked }
end)

local function rename_default(name, attempt)
	if attempt and attempt > 1 then
		local suffix = string.format("-%d", attempt)
		local stem = name:match("^(.+)%..-$") or name
		local ext = name:match("%.(.+)$") or ""
		if ext ~= "" then
			return stem .. suffix .. "." .. ext
		else
			return name .. suffix
		end
	end
	local suffix = os.date("-%y%m%d")
	local stem = name:match("^(.+)%..-$") or name
	local ext = name:match("%.(.+)$") or ""
	if ext ~= "" then
		return stem .. suffix .. "." .. ext
	else
		return name .. suffix
	end
end

--Choices:
-- 0: Merge       — merge directory contents, overwrite individual files
-- 1: Merge all   — same, applied to all remaining conflicts
-- 2: Replace     — replace destination entirely (delete then copy)
-- 3: Rename      — prompt for a new name
-- 4: Skip        — skip this item
-- 5: Cancel(nil) — abort
local function pick_conflict(name)
	return ya.pick({
		title = "Paste conflict: " .. name,
		items = {
			"Merge",
			"Merge all remaining",
			"Replace",
			"Rename",
			"Skip",
			"Cancel",
		},
	})
end

function M:entry(job)
	local info = get_yanked_info()
	local cwd, cut, yanked = info.cwd, info.cut, info.yanked

	if #yanked == 0 then
		return
	end

	local follow = job.args.follow or false
	local resolved = {}

	-- Partition: check each yanked item for conflicts
	local conflicts = {}
	for _, item in ipairs(yanked) do
		local dest = cwd:join(item.name)
		local cha = fs.cha(dest)
		if cha ~= nil then
			conflicts[#conflicts + 1] = { url = item.url, dest = dest, name = item.name }
		else
			resolved[#resolved + 1] = {
				from = tostring(item.url),
				to = tostring(dest),
				overwrite = false,
				replace = false,
			}
		end
	end

	-- Dispatch helper
	local function dispatch(items)
		if #items > 0 then
			ya.emit("paste_resolved", {
				cut = cut,
				follow = follow,
				items = items,
			})
		end
	end

	-- Process conflicts
	local merge_all = false
	for _, item in ipairs(conflicts) do
		if merge_all then
			resolved[#resolved + 1] = {
				from = tostring(item.url),
				to = tostring(item.dest),
				overwrite = true,
				replace = false,
			}
		else
			local choice = pick_conflict(item.name)

			if choice == nil or choice == 5 then
				-- Cancel: paste what we have so far, then abort
				dispatch(resolved)
				return

			elseif choice == 0 then
				-- Merge current
				resolved[#resolved + 1] = {
					from = tostring(item.url),
					to = tostring(item.dest),
					overwrite = true,
					replace = false,
				}

			elseif choice == 1 then
				-- Merge all remaining
				merge_all = true
				resolved[#resolved + 1] = {
					from = tostring(item.url),
					to = tostring(item.dest),
					overwrite = true,
					replace = false,
				}

			elseif choice == 2 then
				-- Replace
				resolved[#resolved + 1] = {
					from = tostring(item.url),
					to = tostring(item.dest),
					overwrite = true,
					replace = true,
				}

			elseif choice == 3 then
				-- Rename: loop until a non-conflicting name is chosen or cancelled
				local attempt = 0
				while true do
					attempt = attempt + 1
					local default = rename_default(item.name, attempt)
					local value, event = ya.input({
						title = "New name",
						value = default,
						pos = { "center", w = 60 },
					})
					if event ~= 1 then
						-- User cancelled the input — skip this item
						break
					end

					local new_dest = cwd:join(value)
					if fs.cha(new_dest) == nil then
						-- No conflict — add and continue
						resolved[#resolved + 1] = {
							from = tostring(item.url),
							to = tostring(new_dest),
							overwrite = false,
							replace = false,
						}
						break
					else
						-- New name also conflicts — show the conflict dialog again
						local sub_choice = pick_conflict(value)
						if sub_choice == nil or sub_choice == 5 then
							-- Cancel everything
							dispatch(resolved)
							return
						elseif sub_choice == 0 then
							resolved[#resolved + 1] = {
								from = tostring(item.url),
								to = tostring(new_dest),
								overwrite = true,
								replace = false,
							}
							break
						elseif sub_choice == 1 then
							merge_all = true
							resolved[#resolved + 1] = {
								from = tostring(item.url),
								to = tostring(new_dest),
								overwrite = true,
								replace = false,
							}
							break
						elseif sub_choice == 2 then
							resolved[#resolved + 1] = {
								from = tostring(item.url),
								to = tostring(new_dest),
								overwrite = true,
								replace = true,
							}
							break
						elseif sub_choice == 3 then
							-- Rename again — increment attempt for different default
							-- (loop continues)
						elseif sub_choice == 4 then
							-- Skip
							break
						end
					end
				end

			elseif choice == 4 then
				-- Skip: do nothing
			end
		end
	end

	-- Dispatch all resolved items
	dispatch(resolved)
end

return M
