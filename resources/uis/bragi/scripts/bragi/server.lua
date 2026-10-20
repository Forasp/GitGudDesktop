--- bragi/server.lua: where Bragi's tasks, boards, wikis, and agent session
-- records live, for the views that use them (Boards, Wiki, the Agent view's
-- task sessions). Views ask by API path, with callbacks:
--
--   server.info()                       { url, user, signedIn }; signedIn:
--                                       a store is there to answer
--   server.request(method, path, body, onDone, onError)
--       an API call; onDone(value) gets the decoded JSON (nil when empty),
--       onError(message) the store's message
--   server.setBackend(backend)          the store: { info = fn, request = fn,
--                                       repoOf = fn? } with the calls here
--   server.repoOf(path)                 "owner/name" for the repository at
--                                       path in the store, or nil
--
-- Signals (core/app.lua):
--   "bragi.server"       (info) when the store comes or goes
--   "bragi.serverEvent"  (event table) a change in the store (a card moved,
--                        a page saved), for the views to reload
--
-- The local store (bragi/store.lua: JSON files and wiki repositories in the
-- app data folder) plugs in with setBackend when the Bragi interface starts,
-- answers the paths and JSON the views use, and publishes its changes
-- through server.publishEvent. With no backend, info().signedIn is false,
-- every request fails with server.UNAVAILABLE, and the views say so.
--
-- UI tests replace server.request and server.info to serve canned answers.

local app = require("core.app")

local server = { name = "bragi.server" }

server.UNAVAILABLE = "Not in this build yet"

local NONE = {
    info = function()
        return { url = "", user = "", signedIn = false }
    end,
    request = function(_, _, _, _, onError)
        if onError then
            onError(server.UNAVAILABLE)
        end
    end,
}

local backend = NONE

function server.info()
    return backend.info()
end

function server.request(method, path, body, onDone, onError)
    backend.request(method, path, body, onDone, onError)
end

function server.repoOf(path)
    return backend.repoOf and backend.repoOf(path) or nil
end

--- Plug in a store (nil: none), and tell the views.
function server.setBackend(store)
    backend = store or NONE
    app.publish("bragi.server", server.info())
end

--- A store's change, for the views ("bragi.serverEvent").
function server.publishEvent(event)
    if type(event) == "table" then
        app.publish("bragi.serverEvent", event)
    end
end

function server.init()
end

return server
