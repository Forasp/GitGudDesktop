#pragma once

// -----------------------------------------------------------------------------
// LuaBindings — shared helpers for the `gitgud` binding implementation files
// (LuaRepoBindings.cpp, LuaUiBindings.cpp, LuaFeatureBindings.cpp,
// LuaAppBindings.cpp, LuaUpdateBindings.cpp, LuaJsonBindings.cpp,
// LuaVoiceBindings.cpp, LuaAgentBindings.cpp). Internal to src/lua/.
//
// Every binding is a plain lua_CFunction whose first upvalue is the owning
// LuaEngine (see LuaEngine::InstallBindings), reached through Self().
// -----------------------------------------------------------------------------

#include <functional>
#include <memory>
#include <string>
#include <vector>

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}

#include "git/Repository.h"
#include "lua/LuaEngine.h"

namespace gitgud::git
{
    struct FileDiff;
}

namespace gitgud::app
{
    class Json;
}

namespace gitgud::voice
{
    class ILink;
}

namespace gitgud::platform
{
    class IAudioCapture;
    class IAudioPlayback;
} // namespace gitgud::platform

namespace gitgud::lua::bindings
{

    inline LuaEngine* Self(lua_State* _pL)
    {
        return static_cast<LuaEngine*>(lua_touserdata(_pL, lua_upvalueindex(1)));
    }

    inline void SetField(lua_State* _pL, const char* _szKey, const std::string& _V)
    {
        lua_pushlstring(_pL, _V.data(), _V.size());
        lua_setfield(_pL, -2, _szKey);
    }

    inline void SetField(lua_State* _pL, const char* _szKey, bool _bV)
    {
        lua_pushboolean(_pL, _bV);
        lua_setfield(_pL, -2, _szKey);
    }

    inline void SetField(lua_State* _pL, const char* _szKey, lua_Integer _V)
    {
        lua_pushinteger(_pL, _V);
        lua_setfield(_pL, -2, _szKey);
    }

    inline void SetField(lua_State* _pL, const char* _szKey, const char* _szV)
    {
        lua_pushstring(_pL, _szV);
        lua_setfield(_pL, -2, _szKey);
    }

    // Sync actions share the (nil, message) failure convention.
    inline int FailWith(lua_State* _pL, const std::string& _Message)
    {
        lua_pushnil(_pL);
        lua_pushlstring(_pL, _Message.data(), _Message.size());
        return 2;
    }

    inline int NoRepo(lua_State* _pL)
    {
        return FailWith(_pL, "No repository is open");
    }

    // A string argument or an array of strings, as a vector.
    std::vector<std::string> StringList(lua_State* _pL, int _iArg);

    // Push an array of strings.
    void PushStringArray(lua_State* _pL, const std::vector<std::string>& _Items);

    // Push a FileDiff as a Lua table (hunks -> lines, 1-based like all of Lua).
    void PushFileDiff(lua_State* _pL, const gitgud::git::FileDiff& _Diff);

    // Each file appends its functions to the `gitgud` table's registry.
    void AddRepoBindings(std::vector<luaL_Reg>& _Out);
    void AddUiBindings(std::vector<luaL_Reg>& _Out);
    void AddStoreBindings(std::vector<luaL_Reg>& _Out);

    // Config names (LuaUiBindings.cpp): a name scripts may use for a file or
    // folder in the config folder ("bragi/wikis/x.wiki.git"), and its path.
    bool IsConfigName(const char* _szName);
    std::string ConfigFile(const std::string& _Name);
    void AddFeatureBindings(std::vector<luaL_Reg>& _Out);
    void AddAppBindings(std::vector<luaL_Reg>& _Out);
    void AddUpdateBindings(std::vector<luaL_Reg>& _Out);
    void AddP4Bindings(std::vector<luaL_Reg>& _Out);
    void AddJsonBindings(std::vector<luaL_Reg>& _Out);

    // A Lua value as JSON (LuaJsonBindings.cpp); throws std::runtime_error on
    // what JSON can't hold.
    app::Json LuaToJson(lua_State* _pL, int _iIndex);

    // Values from large sorted key/value files (LuaLookupBindings.cpp).
    void AddLookupBindings(std::vector<luaL_Reg>& _Out);

    // Voice (LuaVoiceBindings.cpp).
    void AddVoiceBindings(std::vector<luaL_Reg>& _Out);
    // The local app data folder, downloads, archives (LuaLocalDataBindings.cpp).
    void AddLocalDataBindings(std::vector<luaL_Reg>& _Out);
    // Close the voice channels and devices (the Lua engine is going away).
    void StopVoice();
    // The speech engine's links (voice/Link.h): the app's own engine unless
    // this is called; tests pass an in-memory one. Stops voice first.
    void SetVoiceLink(std::function<std::unique_ptr<voice::ILink>(const std::string&)> _MakeLink);
    // Tests: where voice gets its microphone and speaker (empty: the real
    // devices).
    void SetVoiceAudio(std::function<std::unique_ptr<platform::IAudioCapture>()> _MakeCapture,
        std::function<std::unique_ptr<platform::IAudioPlayback>()> _MakePlayback);

    void AddAgentBindings(std::vector<luaL_Reg>& _Out);
    void AddAgentHistoryBindings(std::vector<luaL_Reg>& _Out);
    // Pictures in a conversation: the clipboard, image files shown at a size
    // (LuaImageBindings.cpp).
    void AddImageBindings(std::vector<luaL_Reg>& _Out);
    // Show the pictures decoded since the last call (gitgud.showImage
    // decodes on a worker thread). True when any was shown. UI thread.
    bool ShowDecodedImages(gitgud::ui::IUiBackend* _pUi);
    // End every Claude Code session (the engine is going away).
    void StopAgents();

    // The credential provider worker jobs use (credential store, then a
    // "credential.missing" event). LuaRepoBindings.cpp.
    gitgud::git::CredentialProvider MakeCredentialProvider(
        gitgud::platform::ICredentialStore* _pStore, gitgud::app::EventBus* _pBus);

} // namespace gitgud::lua::bindings
