-- Trello provider for comment-tasks plugin

local http = require("comment-tasks.core.http")
local interface = require("comment-tasks.providers.interface")
local project = require("comment-tasks.core.project")

---@type Provider
local Provider = interface.Provider

local TrelloProvider = {}
TrelloProvider.__index = TrelloProvider
setmetatable(TrelloProvider, { __index = Provider })

local function notify_trello_warning(message)
	vim.notify("[comment-tasks][trello] " .. message, vim.log.levels.WARN)
end

local function is_trello_id(value)
	return type(value) == "string" and value:match("^[a-f0-9]+$") ~= nil and #value == 24
end

local function trim_string(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then
		return nil
	end
	return trimmed
end

local function normalize_label_name(value)
	local trimmed = trim_string(value)
	if not trimmed then
		return nil
	end
	-- Normalize whitespace + case so config names match Trello names reliably.
	return trimmed:lower():gsub("%s+", " ")
end

local function normalize_label_key(value)
	local normalized_name = normalize_label_name(value)
	if not normalized_name then
		return nil
	end
	-- Compact key helps match styles like "RepoName" vs "Repo Name".
	local compact = normalized_name:gsub("[^%w]", "")
	if compact == "" then
		return nil
	end
	return compact
end

local VALID_LABEL_COLORS = {
	green = true,
	yellow = true,
	orange = true,
	red = true,
	purple = true,
	blue = true,
	sky = true,
	lime = true,
	pink = true,
	black = true,
	null = true,
}

local function resolve_label_color(configured)
	local color = trim_string(configured)
	if not color then
		return "blue"
	end

	local normalized = color:lower()
	if VALID_LABEL_COLORS[normalized] then
		return normalized
	end

	notify_trello_warning("Invalid default_label_color '" .. color .. "', falling back to 'blue'")
	return "blue"
end

local function resolve_card_position(configured)
	if configured == nil then
		return nil
	end

	if type(configured) == "number" then
		return configured
	end

	local text = trim_string(tostring(configured))
	if not text then
		return nil
	end

	local lowered = text:lower()
	if lowered == "top" or lowered == "bottom" then
		return lowered
	end

	local numeric = tonumber(text)
	if numeric then
		return numeric
	end

	notify_trello_warning("Invalid card_position '" .. text .. "', ignoring it")
	return nil
end

local function parse_config_values(values)
	if values == nil then
		return {}
	end

	local result = {}
	if type(values) == "table" then
		for _, value in ipairs(values) do
			local trimmed = trim_string(value)
			if trimmed then
				table.insert(result, trimmed)
			end
		end
	elseif type(values) == "string" then
		for raw_value in values:gmatch("[^,]+") do
			local trimmed = trim_string(raw_value)
			if trimmed then
				table.insert(result, trimmed)
			end
		end
	end

	return result
end

local function add_unique(values, value)
	if not value then
		return
	end

	for _, existing in ipairs(values) do
		if existing == value then
			return
		end
	end

	table.insert(values, value)
end

local function build_encoded_params(params)
	local param_strings = {}
	for key, value in pairs(params) do
		table.insert(param_strings, key .. "=" .. vim.uri_encode(tostring(value)))
	end
	return table.concat(param_strings, "&")
end

--- Create a new Trello provider instance
function TrelloProvider:new(provider_config)
	local provider = Provider.new(self, provider_config)
	return provider
end

--- Check if provider is properly configured and enabled
function TrelloProvider:is_enabled()
	if not self.config.enabled then
		return false, "Trello provider is disabled"
	end

	if not self.config.board_id then
		return false, "Trello board_id not configured"
	end

	local api_key, error = self:get_api_key()
	if not api_key then
		return false, error
	end

	local api_token, token_error = self:get_api_token()
	if not api_token then
		return false, token_error
	end

	return true, nil
end

--- Get environment variable name for API key
function TrelloProvider:get_api_key_env()
	return self.config.api_key_env or "TRELLO_API_KEY"
end

--- Get API token from environment
function TrelloProvider:get_api_token()
	local env_var = self.config.api_token_env or "TRELLO_API_TOKEN"
	local api_token = vim.fn.getenv(env_var)

	if not api_token or api_token == vim.NIL then
		return nil, "API token not found in environment variable: " .. env_var
	end

	return api_token, nil
end

--- Get list ID for a given status
function TrelloProvider:get_list_id_for_status(status)
	if not self.config.statuses then
		return nil, "No status configuration found"
	end

	local statuses = self.config.statuses
	local list_name = statuses[status]
	if not list_name then
		return nil, "Status not configured: " .. status
	end

	return list_name, nil
end

--- Resolve a list identifier (ID or list name) to a Trello list ID.
function TrelloProvider:resolve_list_id(list_reference, api_key, api_token, callback)
	if is_trello_id(list_reference) then
		callback(list_reference, nil)
		return
	end

	local lists_url = "https://api.trello.com/1/boards/" .. self.config.board_id .. "/lists"
	local lists_params = "key=" .. api_key .. "&token=" .. api_token

	http.request({
		url = lists_url .. "?" .. lists_params,
		method = "get",
		callback = function(lists_result)
			vim.schedule(function()
				if lists_result.status ~= 200 then
					callback(nil, "Failed to get board lists")
					return
				end

				local success, lists_data = pcall(vim.fn.json_decode, lists_result.body)
				if not success then
					callback(nil, "Failed to parse lists response")
					return
				end

				if type(lists_data) ~= "table" then
					callback(nil, "No lists data returned")
					return
				end

				for _, list_item in ipairs(lists_data) do
					if list_item and type(list_item) == "table" and list_item.name == list_reference then
						callback(list_item.id, nil)
						return
					end
				end

				callback(nil, "List not found: " .. tostring(list_reference))
			end)
		end,
	})
end

--- Find the current repo/root folder name to use as a Trello label.
function TrelloProvider:get_repo_label_name()
	local start_path = vim.fn.expand("%:p:h")
	local root = nil

	-- Prefer the true git root so monorepo subproject markers don't win.
	if type(project.find_git_root) == "function" then
		root = project.find_git_root(start_path)
	end

	if not root and type(project.find_project_root) == "function" then
		root = project.find_project_root(start_path)
	end

	if not root then
		root = vim.fn.getcwd()
	end

	local repo_name = trim_string(vim.fn.fnamemodify(root, ":t"))
	return repo_name
end

--- Resolve "assign to me" into a Trello member ID.
function TrelloProvider:resolve_my_member_id(api_key, api_token, callback)
	local me_url = "https://api.trello.com/1/members/me"
	local me_params = "key=" .. api_key .. "&token=" .. api_token .. "&fields=id"

	http.request({
		url = me_url .. "?" .. me_params,
		method = "get",
		callback = function(result)
			vim.schedule(function()
				if result.status ~= 200 then
					callback(nil, "Failed to resolve current Trello member")
					return
				end

				local success, response = pcall(vim.fn.json_decode, result.body)
				if not success or not response or not response.id then
					callback(nil, "Failed to parse current Trello member")
					return
				end

				callback(response.id, nil)
			end)
		end,
	})
end

--- Resolve configured member defaults into a Trello idMembers value.
function TrelloProvider:resolve_default_members(api_key, api_token, callback)
	local member_ids = parse_config_values(self.config.default_member_ids)
	local should_assign_to_me = self.config.assign_to_me == true

	if not should_assign_to_me then
		if #member_ids == 0 then
			callback(nil, nil)
			return
		end
		callback(table.concat(member_ids, ","), nil)
		return
	end

	self:resolve_my_member_id(api_key, api_token, function(my_member_id, err)
		if err then
			callback(nil, err)
			return
		end

		add_unique(member_ids, my_member_id)
		callback(table.concat(member_ids, ","), nil)
	end)
end

function TrelloProvider:create_label(board_id, label_name, color, api_key, api_token, callback)
	local params_string = build_encoded_params({
		name = label_name,
		color = color,
		key = api_key,
		token = api_token,
	})

	http.request({
		url = "https://api.trello.com/1/boards/" .. board_id .. "/labels",
		method = "post",
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
		},
		body = params_string,
		callback = function(result)
			vim.schedule(function()
				if result.status < 200 or result.status >= 300 then
					local details = ""
					if result.body and result.body ~= "" then
						local parsed = nil
						local ok, decoded = pcall(vim.fn.json_decode, result.body)
						if ok and type(decoded) == "table" then
							parsed = decoded.message or decoded.error or decoded._message
						end
						details = " - " .. tostring(parsed or result.body)
					end
					callback(nil, "Failed to create label: " .. label_name .. " (status " .. tostring(result.status) .. ")" .. details)
					return
				end

				local success, response = pcall(vim.fn.json_decode, result.body)
				if not success or not response or not response.id then
					callback(nil, "Failed to parse created label response")
					return
				end

				callback(response.id, nil)
			end)
		end,
	})
end

function TrelloProvider:resolve_label_ids(api_key, api_token, callback)
	local label_ids = parse_config_values(self.config.default_label_ids)
	local label_names = parse_config_values(self.config.default_label_names)

	if self.config.add_repo_label == true then
		add_unique(label_names, self:get_repo_label_name())
	end

	if #label_ids == 0 and #label_names == 0 then
		callback(nil, nil)
		return
	end

	if #label_names == 0 then
		callback(table.concat(label_ids, ","), nil)
		return
	end

	local labels_url = "https://api.trello.com/1/boards/" .. self.config.board_id .. "/labels"
	local labels_params = "key=" .. api_key .. "&token=" .. api_token .. "&fields=name&limit=1000"

	http.request({
		url = labels_url .. "?" .. labels_params,
		method = "get",
		callback = function(result)
			vim.schedule(function()
				if result.status ~= 200 then
					notify_trello_warning("Failed to get board labels, creating card without label-name defaults")
					if #label_ids == 0 then
						callback(nil, nil)
						return
					end
					callback(table.concat(label_ids, ","), nil)
					return
				end

				local success, labels_data = pcall(vim.fn.json_decode, result.body)
				if not success or type(labels_data) ~= "table" then
					notify_trello_warning("Failed to parse board labels, creating card without label-name defaults")
					if #label_ids == 0 then
						callback(nil, nil)
						return
					end
					callback(table.concat(label_ids, ","), nil)
					return
				end

				local labels_by_name = {}
				local labels_by_key = {}
				for _, label in ipairs(labels_data) do
					if label and type(label) == "table" and label.id then
						local normalized_name = normalize_label_name(label.name)
						if normalized_name then
							labels_by_name[normalized_name] = label.id
							local key = normalize_label_key(normalized_name)
							if key then
								labels_by_key[key] = label.id
							end
						end
					end
				end

				local missing_labels = {}
				for _, label_name in ipairs(label_names) do
					local normalized_name = normalize_label_name(label_name)
					local found_id = labels_by_name[normalized_name]
					if not found_id then
						found_id = labels_by_key[normalize_label_key(normalized_name)]
					end
					if found_id then
						add_unique(label_ids, found_id)
					else
						table.insert(missing_labels, label_name)
					end
				end

				if #missing_labels == 0 then
					callback(table.concat(label_ids, ","), nil)
					return
				end

				if self.config.auto_create_labels == false then
					notify_trello_warning("Missing labels and auto_create_labels is disabled: " .. table.concat(missing_labels, ", "))
					if #label_ids == 0 then
						callback(nil, nil)
						return
					end
					callback(table.concat(label_ids, ","), nil)
					return
				end

				local color = resolve_label_color(self.config.default_label_color)
				local creation_errors = {}
				local function create_missing_label(index)
					if index > #missing_labels then
						if #creation_errors > 0 then
							notify_trello_warning("Some labels could not be created: " .. table.concat(creation_errors, "; "))
						end
						callback(table.concat(label_ids, ","), nil)
						return
					end

					local label_name = missing_labels[index]
					self:create_label(self.config.board_id, label_name, color, api_key, api_token, function(new_id, err)
						if err then
							table.insert(creation_errors, label_name .. " -> " .. tostring(err))
							create_missing_label(index + 1)
							return
						end

						add_unique(label_ids, new_id)
						create_missing_label(index + 1)
					end)
				end

				create_missing_label(1)
			end)
		end,
	})
end

--- Resolve all default card options (members, labels, due date, card position).
function TrelloProvider:resolve_card_defaults(api_key, api_token, callback)
	local defaults = {}
	local pending = 0
	local finished = false

	local function done_if_ready()
		if finished or pending ~= 0 then
			return
		end
		finished = true
		callback(defaults, nil)
	end

	pending = pending + 1
	self:resolve_default_members(api_key, api_token, function(member_ids, err)
		pending = pending - 1
		if err then
			notify_trello_warning("Could not resolve default Trello members: " .. tostring(err))
			done_if_ready()
			return
		end
		if member_ids and member_ids ~= "" then
			defaults.idMembers = member_ids
		end
		done_if_ready()
	end)

	pending = pending + 1
	self:resolve_label_ids(api_key, api_token, function(label_ids, err)
		pending = pending - 1
		if err then
			notify_trello_warning("Could not resolve default Trello labels: " .. tostring(err))
			done_if_ready()
			return
		end
		if label_ids and label_ids ~= "" then
			defaults.idLabels = label_ids
		end
		done_if_ready()
	end)

	local resolved_pos = resolve_card_position(self.config.card_position)
	if resolved_pos ~= nil then
		defaults.pos = resolved_pos
	end

	if type(self.config.default_due_in_days) == "number" and self.config.default_due_in_days > 0 then
		local now = os.time()
		local due_at = now + math.floor(self.config.default_due_in_days * 86400)
		defaults.due = os.date("!%Y-%m-%dT%H:%M:%SZ", due_at)
	end

	done_if_ready()
end

function TrelloProvider:enforce_card_position(card_id, pos, api_key, api_token, callback)
	local update_params = {
		pos = pos,
		key = api_key,
		token = api_token,
	}

	http.request({
		url = "https://api.trello.com/1/cards/" .. card_id,
		method = "put",
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
		},
		body = build_encoded_params(update_params),
		callback = function(result)
			vim.schedule(function()
				if result.status < 200 or result.status >= 300 then
					callback("Failed to enforce card position (status " .. tostring(result.status) .. ")")
					return
				end
				callback(nil)
			end)
		end,
	})
end

--- Create a new Trello card
function TrelloProvider:create_task(task_name, filename, callback, options)
	local api_key, error = self:get_api_key()
	if not api_key then
		callback(nil, error)
		return
	end

	local api_token, token_error = self:get_api_token()
	if not api_token then
		callback(nil, token_error)
		return
	end

	-- Get list for new tasks
	local list_id, list_error = self:get_list_id_for_status("new")
	if not list_id then
		callback(nil, list_error or "Could not determine list for new tasks")
		return
	end

	-- Prepare card description
	local description = "Created from Neovim comment"

	if options and type(options) == "table" and type(options.comment_details) == "table" then
		local detail_lines = {}
		for _, line in ipairs(options.comment_details) do
			local cleaned = trim_string(line)
			if cleaned then
				table.insert(detail_lines, "- " .. cleaned)
			end
		end

		if #detail_lines > 0 then
			description = description .. "\n\n**Details:**\n" .. table.concat(detail_lines, "\n")
		end
	end

	if filename and filename ~= "" and filename ~= "[Unnamed Buffer]" then
		description = description .. "\n\n**Source Files:**\n- " .. filename
	end

	self:resolve_list_id(list_id, api_key, api_token, function(resolved_list_id, list_resolve_error)
		if list_resolve_error then
			callback(nil, list_resolve_error)
			return
		end

		self:resolve_card_defaults(api_key, api_token, function(card_defaults, defaults_error)
			if defaults_error then
				callback(nil, defaults_error)
				return
			end

			self:create_card_in_list(resolved_list_id, task_name, description, api_key, api_token, callback, card_defaults)
		end)
	end)
end

--- Create card in specific list (helper function)
function TrelloProvider:create_card_in_list(list_id, task_name, description, api_key, api_token, callback, card_defaults)
	local card_params = {
		name = task_name,
		desc = description,
		idList = list_id,
		key = api_key,
		token = api_token,
	}

	if type(card_defaults) == "table" then
		for key, value in pairs(card_defaults) do
			if value ~= nil and value ~= "" then
				card_params[key] = value
			end
		end
	end

	local params_string = build_encoded_params(card_params)

	http.request({
		url = "https://api.trello.com/1/cards",
		method = "post",
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
		},
		body = params_string,
		callback = function(result)
			vim.schedule(function()
				if result.status < 200 or result.status >= 300 then
					local error_msg = "Trello API request failed with status: " .. result.status
					if result.body then
						error_msg = error_msg .. " - " .. result.body
					end
					callback(nil, error_msg)
					return
				end

				local success, response = pcall(vim.fn.json_decode, result.body)
				if not success or not response then
					callback(nil, "Failed to parse JSON response")
					return
				end

				if response and response.id then
					local card_url = response.shortUrl
						or response.url
						or (response.shortLink and ("https://trello.com/c/" .. response.shortLink))

					local desired_pos = nil
					if type(card_defaults) == "table" then
						desired_pos = card_defaults.pos
					end

					if desired_pos ~= nil then
						self:enforce_card_position(response.id, desired_pos, api_key, api_token, function(position_err)
							if position_err then
								notify_trello_warning(position_err)
							end
							callback(card_url, nil)
						end)
						return
					end

					callback(card_url, nil)
				else
					callback(nil, "No card ID in response")
				end
			end)
		end,
	})
end

--- Update Trello card status (move to different list)
function TrelloProvider:update_task_status(card_id, status, callback)
	local api_key, error = self:get_api_key()
	if not api_key then
		callback(nil, error)
		return
	end

	local api_token, token_error = self:get_api_token()
	if not api_token then
		callback(nil, token_error)
		return
	end

	-- Get target list for the status
	local list_id, list_error = self:get_list_id_for_status(status)
	if not list_id then
		callback(nil, list_error or ("Could not determine target list for status: " .. status))
		return
	end

	self:resolve_list_id(list_id, api_key, api_token, function(resolved_list_id, list_resolve_error)
		if list_resolve_error then
			callback(nil, list_resolve_error)
			return
		end

		self:move_card_to_list(card_id, resolved_list_id, api_key, api_token, callback)
	end)
end

--- Move card to different list (helper function)
function TrelloProvider:move_card_to_list(card_id, list_id, api_key, api_token, callback)
	local update_params = {
		idList = list_id,
		key = api_key,
		token = api_token,
	}

	local params_string = build_encoded_params(update_params)

	http.request({
		url = "https://api.trello.com/1/cards/" .. card_id,
		method = "put",
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
		},
		body = params_string,
		callback = function(result)
			vim.schedule(function()
				if result.status ~= 200 then
					callback(nil, "Failed to move card: " .. (result.body or "Unknown error"))
					return
				end
				callback(true, nil)
			end)
		end,
	})
end

--- Add file reference to Trello card
function TrelloProvider:add_file_to_task(card_id, filename, callback)
	local api_key, error = self:get_api_key()
	if not api_key then
		callback(nil, error)
		return
	end

	local api_token, token_error = self:get_api_token()
	if not api_token then
		callback(nil, token_error)
		return
	end

	-- Get current card to append to existing description
	local get_params = "key=" .. api_key .. "&token=" .. api_token .. "&fields=desc"

	http.request({
		url = "https://api.trello.com/1/cards/" .. card_id .. "?" .. get_params,
		method = "get",
		callback = function(get_result)
			vim.schedule(function()
				if get_result.status ~= 200 then
					callback(nil, "Failed to get current card")
					return
				end

				local success, card_data = pcall(vim.fn.json_decode, get_result.body)
				if not success then
					callback(nil, "Failed to parse card data")
					return
				end

				-- Update description with file reference
				local current_description = (card_data and card_data.desc) or ""
				local updated_description = current_description

				-- Add source files section if it doesn't exist
				if not updated_description:match("Source Files:") then
					updated_description = updated_description .. "\n\n**Source Files:**\n"
				end

				-- Add file if not already present
				if not updated_description:match(vim.pesc(filename)) then
					updated_description = updated_description .. "- " .. filename .. "\n"
				end

				-- Update the card
				local update_params = {
					desc = updated_description,
					key = api_key,
					token = api_token,
				}

				local param_strings = {}
				for key, value in pairs(update_params) do
					table.insert(param_strings, key .. "=" .. vim.uri_encode(tostring(value)))
				end
				local params_string = table.concat(param_strings, "&")

				http.request({
					url = "https://api.trello.com/1/cards/" .. card_id,
					method = "put",
					headers = {
						["Content-Type"] = "application/x-www-form-urlencoded",
					},
					body = params_string,
					callback = function(update_result)
						vim.schedule(function()
							if update_result.status ~= 200 then
								callback(nil, "Failed to update card with file")
								return
							end
							callback(true, nil)
						end)
					end,
				})
			end)
		end,
	})
end

--- Extract Trello card ID from URL
function TrelloProvider:extract_task_identifier(url)
	if not url then
		return nil
	end
	-- Trello URLs: https://trello.com/c/CARD_ID or short URLs
	return url:match("/c/([a-zA-Z0-9]+)")
end

--- Check if URL belongs to Trello
function TrelloProvider:matches_url(url)
	if not url then
		return false
	end
	return url:match("trello%.com/c/") ~= nil
end

--- Get Trello URL pattern for extraction
function TrelloProvider:get_url_pattern()
	return "(https://trello%.com/c/[a-zA-Z0-9]+[^%s]*)"
end

-- Register the Trello provider
interface.register_provider("trello", TrelloProvider)

return TrelloProvider
