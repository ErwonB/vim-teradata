local util = require('vim-teradata.util')

test("unique query id has expected format", function()
    local id1 = util.get_unique_query_id()
    local id2 = util.get_unique_query_id()
    assert(id1:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d_%d+$"), "id format unexpected: " .. id1)
    assert(id1 ~= id2, "ids must be unique: " .. id1 .. " vs " .. id2)
end)

test("jobs_cancel sets canceled flag", function()
    local fake_job = {
        id = "test_cancel_job",
        handle = {
            kill = function(self, sig)
                -- fake kill success
                return true
            end,
        },
        status = "running",
    }
    util.jobs_add(fake_job)
    assert(fake_job.canceled ~= true)
    local ok = util.jobs_cancel("test_cancel_job")
    assert(ok, "jobs_cancel should succeed")
    assert(fake_job.status == "canceled", "job status should be canceled")
    assert(fake_job.message == "Canceled", "job message should be Canceled")
    util.jobs_remove("test_cancel_job")
end)
