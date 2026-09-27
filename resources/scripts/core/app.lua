--- core/app.lua — the tiny framework every module plugs into.
--
-- Responsibilities:
--   * a module registry: app.use(module) collects view modules; app.start()
--     initialises them in the order they were added
--   * one refresh pipeline: anything that changes repository state calls
--     app.requestRefresh(); requests arriving in the same frame collapse into
--     a single pass that reloads the repository snapshot (core/repo.lua) and
--     then calls every module's refresh()
--   * in-script signals: app.publish / app.subscribe for module-to-module
--     notifications that don't belong on the C++ event bus
--
-- A module is a plain table; every field is optional:
--
--     local M = { name = "example" }
--     M.layout = "mods/example.xml"      -- attached under M.parent (or Root)
--     function M.init() ... end          -- once, after layouts are attached
--     function M.refresh(state) ... end  -- after every repository refresh
--     return M
--
-- See docs/MODDING.md for a complete example.

local app = {}

local modules = {}
local listeners = {}
local refreshPending = false
local started = false

--- Register a module (see the header for its shape).
-- @param module  the module table; returned unchanged so calls can chain
-- @return module
function app.use(module)
    modules[#modules + 1] = module

    return module
end

--- All registered modules, in registration order.
-- @return array of module tables
function app.modules()
    return modules
end

--- Subscribe to an in-script signal.
-- @param signal   name, e.g. "selection.changed"
-- @param handler  function(...) receiving whatever publish() passed
function app.subscribe(signal, handler)
    listeners[signal] = listeners[signal] or {}
    table.insert(listeners[signal], handler)
end

--- Deliver an in-script signal to every subscriber, synchronously.
-- @param signal  name
-- @param ...     arguments passed through to the handlers
function app.publish(signal, ...)
    for _, handler in ipairs(listeners[signal] or {}) do
        handler(...)
    end
end

--- Ask for a refresh. Cheap to call often: requests in the same frame run
-- as one pass, after the current event handler returns.
function app.requestRefresh()
    if refreshPending then
        return
    end

    refreshPending = true
    gitgud.emit("app.refresh", "")
end

--- Run a refresh right now (normally use requestRefresh).
function app.refreshNow()
    refreshPending = false

    local repo = require("core.repo")
    local state = repo.load()

    for _, module in ipairs(modules) do
        if module.refresh then
            module.refresh(state)
        end
    end

    app.publish("refreshed", state)
end

--- Attach layouts, initialise every module, and paint the first frame.
-- Called once, at the end of main.lua.
function app.start()
    if started then
        return
    end
    started = true

    for _, module in ipairs(modules) do
        if module.layout then
            local ok = gitgud.loadLayout(module.layout, module.parent or "Root")
            if not ok then
                print("[app] could not load layout " .. module.layout
                    .. " for module " .. tostring(module.name))
            end
        end
    end

    for _, module in ipairs(modules) do
        if module.init then
            module.init()
        end
    end

    gitgud.on("app.refresh", function()
        app.refreshNow()
    end)

    app.refreshNow()
end

return app
