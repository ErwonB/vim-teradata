local config = require('vim-teradata.config')

test("validate_user validates valid user table", function()
    local ok, err = config.validate_user({ log_mech = "TD2", user = "ALICE", tdpid = "PROD" })
    assert(ok, "valid user should pass validation: " .. tostring(err))
end)

test("validate_user rejects invalid user table", function()
    local ok, err = config.validate_user({ user = "ALICE" })
    assert(not ok, "user without tdpid/log_mech should fail validation")
end)

test("setup populates default options", function()
    config.setup({
        timeout_ms = 12345,
        history_max = 300,
    })
    assert(config.options.timeout_ms == 12345, "timeout_ms not configured")
    assert(config.options.history_max == 300, "history_max not configured")
    assert(config.options.sql_detection == "always", "default sql_detection mismatch")
end)
