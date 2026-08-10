-- Markdown provider for comment-tasks plugin

local interface = require("comment-tasks.providers.interface")
local config = require("comment-tasks.core.config")
local project = require("comment-tasks.core.project")
local utils = require("comment-tasks.core.utils")

---@type Provider
local Provider = interface.Provider

local MarkdownProvider = {}
MarkdownProvider.__index = MarkdownProvider
setmetatable(MarkdownProvider, { __index = Provider })

local function get_cwd()
    if vim.uv and vim.uv.cwd then
        return vim.uv.cwd()
    end
    if vim.loop and vim.loop.cwd then
        return vim.loop.cwd()
    end
    return vim.fn.getcwd()
end

local function current_hrtime_suffix()
    local hrtime = nil
    if vim.uv and vim.uv.hrtime then
        hrtime = vim.uv.hrtime()
    elseif vim.loop and vim.loop.hrtime then
        hrtime = vim.loop.hrtime()
    end

    local token = tostring(hrtime or vim.fn.localtime())
    if #token > 6 then
        return token:sub(-6)
    end
    return token
end

local function generate_task_id()
    return "md-" .. os.date("%Y%m%d%H%M%S") .. "-" .. current_hrtime_suffix()
end

local function parse_files_line(line)
    local files_blob = line:match("^%s*%- files:%s*(.+)$")
    if not files_blob then
        return {}
    end

    local files = {}
    for raw in files_blob:gmatch("[^,]+") do
        table.insert(files, vim.trim(raw))
    end

    return utils.normalize_and_dedupe_files(files)
end

--- Create a new Markdown provider instance
function MarkdownProvider:new(provider_config)
    local provider = Provider.new(self, provider_config)
    return provider
end

--- Markdown provider does not require API credentials.
function MarkdownProvider:validate_config()
    return true, nil
end

--- Check if provider is properly configured and enabled
function MarkdownProvider:is_enabled()
    if not self.config.enabled then
        return false, "Markdown provider is disabled"
    end

    local file_path = self.config.file_path
    if file_path ~= nil and (type(file_path) ~= "string" or vim.trim(file_path) == "") then
        return false, "Markdown file_path must be a non-empty string"
    end

    return true, nil
end

function MarkdownProvider:get_root_path()
    local start_path = vim.fn.expand("%:p:h")
    local root = project.find_project_root(start_path)
    if root then
        return root
    end

    local git_root = project.find_git_root(start_path)
    if git_root then
        return git_root
    end

    return get_cwd()
end

function MarkdownProvider:get_task_file_path()
    local file_path = self.config.file_path or "TASKS.md"
    if file_path:match("^/") then
        return file_path
    end

    return self:get_root_path() .. "/" .. file_path
end

function MarkdownProvider:read_lines(file_path)
    if vim.fn.filereadable(file_path) == 1 then
        return vim.fn.readfile(file_path)
    end
    return {}
end

function MarkdownProvider:write_lines(file_path, lines)
    local parent = vim.fn.fnamemodify(file_path, ":h")
    if parent ~= "" and vim.fn.isdirectory(parent) == 0 then
        vim.fn.mkdir(parent, "p")
    end
    vim.fn.writefile(lines, file_path)
end

function MarkdownProvider:ensure_heading(lines)
    local heading = self.config.section_heading or "## Comment Tasks"

    local heading_index = nil
    for i, line in ipairs(lines) do
        if vim.trim(line) == heading then
            heading_index = i
            break
        end
    end

    if heading_index then
        return heading_index
    end

    if #lines > 0 and lines[#lines] ~= "" then
        table.insert(lines, "")
    end

    table.insert(lines, heading)
    table.insert(lines, "")
    return #lines - 1
end

function MarkdownProvider:find_insert_index(lines, heading_index)
    local section_end = #lines + 1
    for i = heading_index + 1, #lines do
        if lines[i]:match("^##%s+") then
            section_end = i
            break
        end
    end

    local insert_index = section_end
    while insert_index > heading_index + 1 and lines[insert_index - 1] == "" do
        insert_index = insert_index - 1
    end

    return insert_index
end

function MarkdownProvider:find_task_line(lines, task_identifier)
    local needle = "markdown://task/" .. task_identifier
    for i, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return i
        end
    end
    return nil
end

--- Create a new markdown checklist item
function MarkdownProvider:create_task(task_name, filename, callback)
    local file_path = self:get_task_file_path()
    local task_id = generate_task_id()
    local task_url = "markdown://task/" .. task_id

    local lines = self:read_lines(file_path)
    local heading_index = self:ensure_heading(lines)
    local insert_index = self:find_insert_index(lines, heading_index)

    local task_line = "- [ ] [" .. task_id .. "](" .. task_url .. ") " .. task_name
    table.insert(lines, insert_index, task_line)

    if filename and filename ~= "" and filename ~= "[Unnamed Buffer]" then
        table.insert(lines, insert_index + 1, "  - files: " .. filename)
    end

    local ok, err = pcall(function()
        self:write_lines(file_path, lines)
    end)

    if not ok then
        callback(nil, "Failed to write markdown task file: " .. tostring(err))
        return
    end

    callback(task_url, nil)
end

--- Update checklist state for a markdown task
function MarkdownProvider:update_task_status(task_identifier, status, callback)
    local file_path = self:get_task_file_path()
    local lines = self:read_lines(file_path)
    local line_index = self:find_task_line(lines, task_identifier)

    if not line_index then
        callback(nil, "Markdown task not found: " .. task_identifier)
        return
    end

    local resolved_status = config.get_provider_status("markdown", status)
    local status_key = tostring(resolved_status):lower()
    local is_complete = status_key == "completed"
        or status_key == "complete"
        or status_key == "done"
        or status_key == "closed"

    if is_complete then
        lines[line_index] = lines[line_index]:gsub("%- %[[xX ]%]", "- [x]", 1)
    else
        lines[line_index] = lines[line_index]:gsub("%- %[[xX ]%]", "- [ ]", 1)
    end

    local ok, err = pcall(function()
        self:write_lines(file_path, lines)
    end)

    if not ok then
        callback(nil, "Failed to update markdown task: " .. tostring(err))
        return
    end

    callback(true, nil)
end

--- Add file reference metadata to markdown task
function MarkdownProvider:add_file_to_task(task_identifier, filename, callback)
    local file_path = self:get_task_file_path()
    local lines = self:read_lines(file_path)
    local line_index = self:find_task_line(lines, task_identifier)

    if not line_index then
        callback(nil, "Markdown task not found: " .. task_identifier)
        return
    end

    local files_line_index = nil
    if lines[line_index + 1] and lines[line_index + 1]:match("^%s*%- files:%s*") then
        files_line_index = line_index + 1
    end

    if files_line_index then
        local existing_files = parse_files_line(lines[files_line_index])
        table.insert(existing_files, filename)
        existing_files = utils.normalize_and_dedupe_files(existing_files)

        lines[files_line_index] = "  - files: " .. table.concat(existing_files, ", ")
    else
        table.insert(lines, line_index + 1, "  - files: " .. filename)
    end

    local ok, err = pcall(function()
        self:write_lines(file_path, lines)
    end)

    if not ok then
        callback(nil, "Failed to update markdown task files: " .. tostring(err))
        return
    end

    callback(true, nil)
end

--- Extract markdown task ID from markdown:// URL
function MarkdownProvider:extract_task_identifier(url)
    if not url then
        return nil
    end

    return url:match("markdown://task/([%w%-%._]+)")
end

--- Check if URL belongs to markdown provider
function MarkdownProvider:matches_url(url)
    if not url then
        return false
    end

    return url:match("^markdown://task/") ~= nil
end

--- Get markdown URL pattern for extraction
function MarkdownProvider:get_url_pattern()
    return "(markdown://task/[%w%-%._]+)"
end

-- Register the markdown provider
interface.register_provider("markdown", MarkdownProvider)

return MarkdownProvider
