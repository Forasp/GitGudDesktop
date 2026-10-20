#pragma once

// -----------------------------------------------------------------------------
// ClaudeTranscripts: the sessions Claude Code keeps on disk, read back for
// the sessions list and for showing a session before resuming it.
//
// Claude Code writes every session of a working folder to
// `<config>/projects/<folder>/<session id>.jsonl`, one JSON object a line:
// user and assistant messages (`message` with `role` and `content`), plus
// summaries and bookkeeping. `<config>` is CLAUDE_CONFIG_DIR, or `.claude`
// in the home folder; `<folder>` is the working folder with every character
// that isn't a letter or digit turned into '-'.
//
// Only the main conversation is read: sub-agents' lines (`isSidechain`),
// meta lines, and slash-command echoes are skipped. Read only, never
// written, but for Fork's new files.
//
// The folder name can't be turned back into the folder, so Projects()
// takes each project's folder from its transcripts' own lines (`cwd`).
// What a transcript's head says (its title and folder) is kept in memory
// by path, write time, and size, so listing again reads only new or
// changed files.
// -----------------------------------------------------------------------------

#include "app/Json.h"

#include <cstdint>
#include <string>
#include <vector>

namespace gitgud::agent
{

    struct TranscriptSummary
    {
        std::string m_Id;       // the session id (the file's name), for --resume
        std::string m_Title;    // its title (Claude Code's), summary, or the first thing you asked
        std::string m_Asked;    // the first thing asked ("" when none is near its start)
        int64_t m_iUpdated = 0; // last written, seconds since 1970
        int64_t m_iActive = 0;  // its last message (asked or answered); m_iUpdated when none says
        std::string m_Cwd;      // the working folder its lines name ("" if none)
    };

    struct ProjectSummary
    {
        std::string m_Cwd;    // the working folder, from its transcripts ("" if none says)
        std::string m_Folder; // its folder's name under projects/
        int64_t m_iUpdated = 0; // its most recently active conversation's m_iActive
        std::vector<TranscriptSummary> m_Sessions; // the most recently active first
    };

    struct TranscriptEntry
    {
        // "user", "assistant", "tool", "toolResult", or "compacted" (the
        // conversation was compacted there). A slash command reads as the
        // user's text as typed, its output as the assistant's.
        std::string m_Kind;
        // the text (user, assistant, toolResult); compacted: its trigger
        // ("manual" or "auto"), m_Input its compactMetadata
        std::string m_Text;
        std::string m_Id;      // tool and toolResult: the tool call's id
        std::string m_Name;    // tool: the tool's name
        app::Json m_Input;     // tool: its input; compacted: the metadata
        bool m_bError = false; // toolResult: the tool failed
        // user and toolResult: the images in it, as files (agent/ChatImages.h)
        std::vector<std::string> m_Images;
        // The line it's from: its uuid and the entry before it on its
        // branch ("" for the first, or a transcript without them).
        std::string m_Uuid;
        std::string m_ParentUuid;
    };

    struct ContextFile
    {
        // "user" (the config folder's CLAUDE.md), "userRule" (its rules/),
        // "project" (CLAUDE.md or .claude/CLAUDE.md in the folder or above),
        // "local" (CLAUDE.local.md there), "projectRule" (.claude/rules/
        // there), "memory" (the folder's auto memory), or "settings" (the
        // config folder's settings.json, the folder's .claude/settings.json
        // and settings.local.json: where hooks are set)
        std::string m_Kind;
        std::string m_Path;
    };

    class ClaudeTranscripts
    {
      public:
        // Where Claude Code keeps its data.
        static std::string ConfigDir();

        // The folder name Claude Code uses for a working folder.
        static std::string ProjectFolderName(const std::string& _WorkingDir);

        // The sessions of a working folder (the newest _nMax written), the
        // most recently active first.
        static std::vector<TranscriptSummary> List(
            const std::string& _WorkingDir, std::size_t _nMax = 50);

        // Every project with conversations, the most recently active first
        // (at most _nMaxProjects), each with its newest _nPerProject
        // conversations. Folders without a titled conversation are left out.
        static std::vector<ProjectSummary> Projects(
            std::size_t _nPerProject = 30, std::size_t _nMaxProjects = 100);

        // One session's conversation, oldest first (at most _nMax entries,
        // the latest ones). Empty for an unknown or malformed id. Looked
        // for under the working folder's project folder first, then in
        // every project folder (a session id is unique).
        //
        // Lines name the entry before them (`parentUuid`), so a session
        // resumed at an earlier entry (rewound) branches: only the branch
        // its last line is on is read, as Claude Code resumes it.
        static std::vector<TranscriptEntry> Read(
            const std::string& _WorkingDir, const std::string& _Id, std::size_t _nMax = 2000);

        // Read's work, on the file itself (Read keeps its last results for
        // files that haven't changed).
        static std::vector<TranscriptEntry> ReadFile(const std::string& _File, std::size_t _nMax);

        // Copy a session's conversation, up to and including the entry
        // `_UpTo` (its uuid; "" for all of it), into a new session of
        // another working folder: its lines on that branch, with the new
        // session's id and folder. The one place this writes, and only a
        // new file. Claude Code resumes a session only in its own folder,
        // so this is how a conversation moves to another. Returns the new
        // session's id, "" when there's no such session or entry.
        static std::string Fork(const std::string& _WorkingDir, const std::string& _Id,
            const std::string& _UpTo, const std::string& _ToDir);

        // A new session id: a random UUID, as Claude Code's are.
        static std::string NewId();

        // The transcript file of a session ("" when there's none).
        static std::string Find(const std::string& _WorkingDir, const std::string& _Id);

        // The instruction and memory files Claude Code loads for a working
        // folder (those that exist): the user's first, then the folder's and
        // its parents' (nearest last), then auto memory, then the settings
        // files. Rules sorted by name.
        static std::vector<ContextFile> ContextFiles(const std::string& _WorkingDir);

        // A title from a user message's text: its first line, without
        // surrounding spaces, cut to about 80 characters. Blocks put at the
        // start of a message by Claude Code, hooks or apps (system reminders,
        // task notifications, command output) are skipped: "" when that's
        // all there is.
        static std::string Title(const std::string& _Text);
    };

} // namespace gitgud::agent
