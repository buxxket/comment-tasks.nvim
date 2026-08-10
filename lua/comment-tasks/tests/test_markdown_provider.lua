local assert = require("luassert")

local function create_provider(config, project_root)
    package.loaded["comment-tasks.providers.markdown"] = nil
    package.loaded["comment-tasks.core.project"] = {
        find_project_root = function()
            return project_root
        end,
        find_git_root = function()
            return nil
        end,
    }

    local markdown_provider = require("comment-tasks.providers.markdown")
    return markdown_provider:new(config)
end

describe("comment-tasks Markdown provider", function()
    local tmp_root

    before_each(function()
        tmp_root = vim.fn.tempname()
        vim.fn.mkdir(tmp_root, "p")
    end)

    after_each(function()
        if tmp_root then
            vim.fn.delete(tmp_root, "rf")
        end
    end)

    it("creates checklist tasks in markdown file", function()
        local provider = create_provider({
            enabled = true,
            file_path = "TASKS.md",
            section_heading = "## Comment Tasks",
        }, tmp_root)

        local task_url, err = nil, nil
        provider:create_task("Implement markdown integration", "config.lua", function(url, create_err)
            task_url = url
            err = create_err
        end)

        assert.is_nil(err)
        assert.is_not_nil(task_url)
        assert.is_not_nil(task_url:match("^markdown://task/"))

        local lines = vim.fn.readfile(tmp_root .. "/TASKS.md")
        local body = table.concat(lines, "\n")
        assert.is_not_nil(body:match("## Comment Tasks"))
        assert.is_not_nil(body:match("%- %[ %]"))
        assert.is_not_nil(body:match("markdown://task/"))
        assert.is_not_nil(body:match("Implement markdown integration"))
        assert.is_not_nil(body:match("%- files: config%.lua"))
    end)

    it("updates markdown task checkbox status", function()
        local provider = create_provider({
            enabled = true,
            file_path = "TASKS.md",
        }, tmp_root)

        local task_url
        provider:create_task("Finish docs", nil, function(url, _)
            task_url = url
        end)

        local task_id = provider:extract_task_identifier(task_url)
        assert.is_not_nil(task_id)

        local ok, err = nil, nil
        provider:update_task_status(task_id, "completed", function(success, update_err)
            ok = success
            err = update_err
        end)

        assert.is_true(ok)
        assert.is_nil(err)

        local lines = vim.fn.readfile(tmp_root .. "/TASKS.md")
        local body = table.concat(lines, "\n")
        assert.is_not_nil(body:match("%- %[x%]"))
    end)

    it("adds and deduplicates files for existing task", function()
        local provider = create_provider({
            enabled = true,
            file_path = "TASKS.md",
        }, tmp_root)

        local task_url
        provider:create_task("Track touched files", "init.lua", function(url, _)
            task_url = url
        end)

        local task_id = provider:extract_task_identifier(task_url)

        provider:add_file_to_task(task_id, "init.lua", function(_, add_err)
            assert.is_nil(add_err)
        end)
        provider:add_file_to_task(task_id, "core/config.lua", function(_, add_err)
            assert.is_nil(add_err)
        end)

        local lines = vim.fn.readfile(tmp_root .. "/TASKS.md")
        local files_line = nil
        for _, line in ipairs(lines) do
            if line:match("^%s*%- files:%s*") then
                files_line = line
                break
            end
        end

        assert.is_not_nil(files_line)
        assert.is_not_nil(files_line:match("core/config%.lua"))

        local init_count = 0
        for _ in files_line:gmatch("init%.lua") do
            init_count = init_count + 1
        end
        assert.equals(1, init_count)
    end)
end)
