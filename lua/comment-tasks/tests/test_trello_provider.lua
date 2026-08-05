local assert = require("luassert")

local function create_provider(config, http_mock, project_paths)
    package.loaded["comment-tasks.providers.trello"] = nil
    package.loaded["comment-tasks.core.http"] = {
        request = http_mock,
    }
    package.loaded["comment-tasks.core.project"] = {
        find_project_root = function()
            if type(project_paths) == "table" then
                return project_paths.project_root
            end
            return project_paths
        end,
        find_git_root = function()
            if type(project_paths) == "table" then
                return project_paths.git_root
            end
            return nil
        end,
    }

    local trello_provider = require("comment-tasks.providers.trello")
    return trello_provider:new(config)
end

describe("comment-tasks Trello provider defaults", function()
    local original_schedule

    before_each(function()
        vim.env.TRELLO_API_KEY = "test_trello_key"
        vim.env.TRELLO_API_TOKEN = "test_trello_token"

        original_schedule = vim.schedule
        vim.schedule = function(fn)
            fn()
        end
    end)

    after_each(function()
        vim.schedule = original_schedule
    end)

    it("adds current member when assign_to_me is enabled", function()
        local card_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            assign_to_me = true,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/members/me") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ id = "64f0000000000000000000ab" }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_1",
                        shortUrl = "https://trello.com/c/card_1",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        local card_url, err = nil, nil
        provider:create_task("Test card", "file.lua", function(url, create_err)
            card_url = url
            err = create_err
        end)

        assert.is_nil(err)
        assert.equals("https://trello.com/c/card_1", card_url)
        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("idMembers=64f0000000000000000000ab"))
    end)

    it("applies repo-name label from existing board labels", function()
        local card_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            add_repo_label = true,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels") and opts.method == "get" then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f0000000000000000000cd", name = "repo-root" } }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_2",
                        shortUrl = "https://trello.com/c/card_2",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, { git_root = "/tmp/repo-root", project_root = "/tmp/subproject" })

        provider:create_task("Repo label card", "file.lua", function(_url, err)
            assert.is_nil(err)
        end)

        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("idLabels=64f0000000000000000000cd"))
    end)

    it("auto-creates missing labels and applies card metadata defaults", function()
        local card_body = nil
        local position_update_called = false

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            default_label_names = { "backend" },
            auto_create_labels = true,
            default_label_color = "green",
            create_card_position = "top",
            default_due_in_days = 2,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels") and opts.method == "get" then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({}),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels$") and opts.method == "post" then
                assert.is_not_nil(opts.body:match("name=backend"))
                assert.is_not_nil(opts.body:match("color=green"))
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ id = "64f0000000000000000000ef" }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "64f0000000000000000000f3",
                        shortUrl = "https://trello.com/c/card_3",
                    }),
                })
                return
            end

            if opts.url:match("/1/cards/64f0000000000000000000f3$") and opts.method == "put" then
                position_update_called = true
                assert.is_not_nil(opts.body:match("pos=top"))
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ id = "64f0000000000000000000f3" }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        provider:create_task("Auto label card", "file.lua", function(_url, err)
            assert.is_nil(err)
        end)

        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("idLabels=64f0000000000000000000ef"))
        assert.is_not_nil(card_body:match("pos=top"))
        assert.is_not_nil(card_body:match("due="))
        assert.is_true(position_update_called)
    end)

    it("matches label names case-insensitively and with trimmed whitespace", function()
        local card_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            default_label_names = { "  backend api  " },
            default_due_in_days = 0,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels") and opts.method == "get" then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f0000000000000000000aa", name = "BackEnd   API" } }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_5",
                        shortUrl = "https://trello.com/c/card_5",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        provider:create_task("Normalized label card", "file.lua", function(_url, err)
            assert.is_nil(err)
        end)

        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("idLabels=64f0000000000000000000aa"))
        assert.is_nil(card_body:match("due="))
    end)

    it("matches compact repo label names against spaced board labels", function()
        local card_body = nil
        local create_label_called = false

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            default_label_names = { "ArbitrageReportGenerator" },
            auto_create_labels = true,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels") and opts.method == "get" then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f0000000000000000000cc", name = "Arbitrage Report Generator" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels$") and opts.method == "post" then
                create_label_called = true
                opts.callback({
                    status = 500,
                    body = "should not be called",
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_8",
                        shortUrl = "https://trello.com/c/card_8",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        provider:create_task("Compact label match", "file.lua", function(_url, err)
            assert.is_nil(err)
        end)

        assert.is_false(create_label_called)
        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("idLabels=64f0000000000000000000cc"))
    end)

    it("accepts 201 label create response and applies created label", function()
        local card_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            default_label_names = { "backend" },
            auto_create_labels = true,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels") and opts.method == "get" then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({}),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels$") and opts.method == "post" then
                opts.callback({
                    status = 201,
                    body = vim.fn.json_encode({ id = "64f0000000000000000000bb" }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_6",
                        shortUrl = "https://trello.com/c/card_6",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        provider:create_task("Create label 201", "file.lua", function(_url, err)
            assert.is_nil(err)
        end)

        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("idLabels=64f0000000000000000000bb"))
    end)

    it("continues card creation when label auto-creation fails", function()
        local card_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
            default_label_names = { "backend" },
            auto_create_labels = true,
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels") and opts.method == "get" then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({}),
                })
                return
            end

            if opts.url:match("/boards/board_123/labels$") and opts.method == "post" then
                opts.callback({
                    status = 500,
                    body = "label create failed",
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_4",
                        shortUrl = "https://trello.com/c/card_4",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        local card_url, err = nil, nil
        provider:create_task("Label failure should not block", "file.lua", function(url, create_err)
            card_url = url
            err = create_err
        end)

        assert.is_nil(err)
        assert.equals("https://trello.com/c/card_4", card_url)
        assert.is_not_nil(card_body)
        assert.is_nil(card_body:match("idLabels="))
    end)

    it("adds extra TODO description lines into Trello card description", function()
        local card_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            statuses = { new = "To Do" },
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ { id = "64f000000000000000000001", name = "To Do" } }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                card_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "card_7",
                        shortUrl = "https://trello.com/c/card_7",
                    }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        provider:create_task("Lifetime total site revenue", "pricing.py", function(_url, err)
            assert.is_nil(err)
        end, {
            comment_details = {
                "A combined total cost from all historically selected tariffs should be shown in the lifetime total site revenue",
            },
        })

        assert.is_not_nil(card_body)
        assert.is_not_nil(card_body:match("Details%%3A"))
        assert.is_not_nil(card_body:match("combined%%20total%%20cost"))
    end)

    it("moves cards with top position during status updates", function()
        local move_body = nil
        local enforce_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            move_card_position = "top",
            statuses = {
                in_progress = "In Progress",
                backlog = "Backlog",
            },
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        { id = "64f000000000000000000010", name = "In Progress" },
                        { id = "64f000000000000000000011", name = "Backlog" },
                    }),
                })
                return
            end

            if opts.url:match("/1/cards/xAqgxW5O$") and opts.method == "put" then
                if not move_body then
                    move_body = opts.body
                else
                    enforce_body = opts.body
                end
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ id = "xAqgxW5O" }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        local success, err = nil, nil
        provider:update_task_status("xAqgxW5O", "backlog", function(ok, update_err)
            success = ok
            err = update_err
        end)

        assert.is_nil(err)
        assert.is_true(success)
        assert.is_not_nil(move_body)
        assert.is_not_nil(move_body:match("idList=64f000000000000000000011"))
        assert.is_not_nil(move_body:match("pos=top"))
        assert.is_not_nil(enforce_body)
        assert.is_not_nil(enforce_body:match("pos=top"))
    end)

    it("uses card_position as fallback for create and move when specific settings are unset", function()
        local create_body = nil
        local create_enforce_body = nil
        local move_body = nil

        local provider = create_provider({
            enabled = true,
            board_id = "board_123",
            card_position = "bottom",
            statuses = {
                new = "To Do",
                backlog = "Backlog",
            },
        }, function(opts)
            if opts.url:match("/boards/board_123/lists") then
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        { id = "64f000000000000000000001", name = "To Do" },
                        { id = "64f000000000000000000011", name = "Backlog" },
                    }),
                })
                return
            end

            if opts.url:match("/1/cards$") and opts.method == "post" then
                create_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({
                        id = "64f000000000000000000099",
                        shortUrl = "https://trello.com/c/card_9",
                    }),
                })
                return
            end

            if opts.url:match("/1/cards/64f000000000000000000099$") and opts.method == "put" then
                create_enforce_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ id = "64f000000000000000000099" }),
                })
                return
            end

            if opts.url:match("/1/cards/xAqgxW5O$") and opts.method == "put" then
                move_body = opts.body
                opts.callback({
                    status = 200,
                    body = vim.fn.json_encode({ id = "xAqgxW5O" }),
                })
                return
            end

            error("Unexpected request: " .. opts.method .. " " .. opts.url)
        end, "/tmp/repo-test")

        provider:create_task("Fallback position", "file.lua", function(_url, err)
            assert.is_nil(err)
        end)

        local success, err = nil, nil
        provider:update_task_status("xAqgxW5O", "backlog", function(ok, update_err)
            success = ok
            err = update_err
        end)

        assert.is_nil(err)
        assert.is_true(success)
        assert.is_not_nil(create_body)
        assert.is_not_nil(create_body:match("pos=bottom"))
        assert.is_not_nil(create_enforce_body)
        assert.is_not_nil(create_enforce_body:match("pos=bottom"))
        assert.is_not_nil(move_body)
        assert.is_not_nil(move_body:match("pos=bottom"))
    end)
end)
