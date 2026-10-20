--- bragi/claude.lua: the Claude Code program Bragi runs.
--
-- bragi.claudeProgram when set, else GITGUD_TEST_CLAUDE (UI tests: so
-- nothing starts the real program before a test points the setting at the
-- fake; 2026-10-15, the startup `--help` read wrote into the test's
-- scratch config), else "claude".
--
-- Public API: claude.program()

local settings = require("core.settings")

local claude = {}

function claude.program()
    return settings.get("bragi.claudeProgram", os.getenv("GITGUD_TEST_CLAUDE") or "claude")
end

return claude
