// -----------------------------------------------------------------------------
// Repository — working-tree / index surgery: batch staging, line-level
// staging, discarding, and reading any version of a file.
//
// Line-level staging model. The UI shows the COMBINED diff (HEAD -> working
// tree) and lets the user include/exclude individual changed lines. Rather
// than juggling partial patches against the index, every operation here
// rebuilds the affected blob from scratch:
//
//     new index blob   = HEAD + (the chosen subset of the combined changes)
//     new working file = HEAD + (every combined change except discarded ones)
//
// ApplySubset() does that rebuild by walking the combined patch's hunks over
// the HEAD text. Lines are addressed by their position in the flattened list
// of the patch's lines, which is exactly what DiffFile(path, Head) returns
// (both come from CombinedPatch below), so the UI's indices always line up.
// Same layer rules as Repository.h: RAII, plain data out, GitError on failure.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        namespace fs = std::filesystem;

        // One version of a file: its (repository-normalized) bytes and mode.
        struct FileSide
        {
            std::string m_Text;
            bool m_bExists = false;
            uint32_t m_uiMode = GIT_FILEMODE_BLOB;
        };

        fs::path WorkPath(git_repository* _pRepo, const std::string& _Path)
        {
            const char* szwork = git_repository_workdir(_pRepo);
            if (!szwork)
            {
                throw GitError("This operation needs a working tree (bare repository)");
            }
            return fs::u8path(szwork) / fs::u8path(_Path);
        }

        std::string ReadWholeFile(const fs::path& _File)
        {
            std::ifstream in(_File, std::ios::binary);
            std::ostringstream ss;
            ss << in.rdbuf();
            return ss.str();
        }

        std::string BlobText(git_repository* _pRepo, const git_oid* _pId)
        {
            BlobPtr blob;
            if (git_blob_lookup(&blob.m_pP, _pRepo, _pId) < 0)
            {
                RaiseLastError("git_blob_lookup failed");
            }
            return std::string(static_cast<const char*>(git_blob_rawcontent(blob.m_pP)),
                static_cast<std::size_t>(git_blob_rawsize(blob.m_pP)));
        }

        FileSide ReadTreeSide(git_repository* _pRepo, git_tree* _pTree, const std::string& _Path)
        {
            FileSide side;
            if (!_pTree)
            {
                return side;
            }
            TreeEntryPtr entry;
            if (git_tree_entry_bypath(&entry.m_pP, _pTree, _Path.c_str()) != 0)
            {
                return side;
            }
            if (git_tree_entry_type(entry.m_pP) != GIT_OBJECT_BLOB)
            {
                return side; // submodule / directory: not line-diffable
            }
            side.m_Text = BlobText(_pRepo, git_tree_entry_id(entry.m_pP));
            side.m_bExists = true;
            side.m_uiMode = static_cast<uint32_t>(git_tree_entry_filemode(entry.m_pP));
            return side;
        }

        FileSide ReadHeadSide(git_repository* _pRepo, const std::string& _Path)
        {
            TreePtr tree = HeadTree(_pRepo);
            return ReadTreeSide(_pRepo, tree.m_pP, _Path);
        }

        FileSide ReadIndexSide(git_repository* _pRepo, git_index* _pIndex, const std::string& _Path)
        {
            FileSide side;
            const git_index_entry* pentry = git_index_get_bypath(_pIndex, _Path.c_str(), 0);
            if (!pentry)
            {
                return side;
            }
            side.m_Text = BlobText(_pRepo, &pentry->id);
            side.m_bExists = true;
            side.m_uiMode = pentry->mode;
            return side;
        }

        // The working-tree file run through the repository's "to ODB" filters
        // (autocrlf, .gitattributes) so it compares byte-for-byte with blobs.
        FileSide ReadWorkSide(git_repository* _pRepo, const std::string& _Path)
        {
            FileSide side;
            const fs::path abs = WorkPath(_pRepo, _Path);
            std::error_code ec;
            if (!fs::is_regular_file(abs, ec))
            {
                return side;
            }
            side.m_bExists = true;

            FilterListPtr filters;
            if (git_filter_list_load(&filters.m_pP, _pRepo, nullptr, _Path.c_str(),
                    GIT_FILTER_TO_ODB, GIT_FILTER_DEFAULT) < 0)
            {
                RaiseLastError("git_filter_list_load failed");
            }
            if (!filters.m_pP)
            {
                side.m_Text = ReadWholeFile(abs);
                return side;
            }
            Buf out;
            if (git_filter_list_apply_to_file(&out.m_B, filters.m_pP, _pRepo, _Path.c_str()) < 0)
            {
                RaiseLastError("Filtering '" + _Path + "' failed");
            }
            side.m_Text = out.Str();
            return side;
        }

        // Write repository-normalized text to the working tree ("to worktree"
        // filters applied), creating parent directories as needed.
        void WriteWorkFile(
            git_repository* _pRepo, const std::string& _Path, const std::string& _Text)
        {
            std::string bytes = _Text;
            FilterListPtr filters;
            if (git_filter_list_load(&filters.m_pP, _pRepo, nullptr, _Path.c_str(),
                    GIT_FILTER_TO_WORKTREE, GIT_FILTER_DEFAULT) < 0)
            {
                RaiseLastError("git_filter_list_load failed");
            }
            if (filters.m_pP)
            {
                Buf out;
                if (git_filter_list_apply_to_buffer(
                        &out.m_B, filters.m_pP, _Text.data(), _Text.size()) < 0)
                {
                    RaiseLastError("Filtering '" + _Path + "' failed");
                }
                bytes = out.Str();
            }

            const fs::path abs = WorkPath(_pRepo, _Path);
            std::error_code ec;
            fs::create_directories(abs.parent_path(), ec);
            std::ofstream outFile(abs, std::ios::binary | std::ios::trunc);
            if (!outFile)
            {
                throw GitError("Could not write '" + _Path + "'");
            }
            outFile.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        }

        // A patch between two buffers, with its lines flattened for addressing.
        struct FlatPatch
        {
            PatchPtr m_Patch;

            struct Hunk
            {
                int m_iOldStart = 0;
                int m_iOldLines = 0;
                std::size_t m_FirstLine = 0; // index into m_Lines
                std::size_t m_LineCount = 0;
            };

            struct Line
            {
                char m_cOrigin = ' ';
                int m_iOldLineno = -1;
                int m_iNewLineno = -1;
            };

            std::vector<Hunk> m_Hunks;
            std::vector<Line> m_Lines;
            bool m_bBinary = false;

            bool IsChange(std::size_t _Index) const
            {
                const char c = m_Lines[_Index].m_cOrigin;
                return c == GIT_DIFF_LINE_ADDITION || c == GIT_DIFF_LINE_DELETION;
            }
        };

        FlatPatch MakePatch(const std::string& _Path, const FileSide& _Old, const FileSide& _New,
            const DiffOptions& _Options)
        {
            git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
            ApplyDiffOptions(opts, _Options);

            FlatPatch fp;
            if (git_patch_from_buffers(&fp.m_Patch.m_pP, _Old.m_Text.data(), _Old.m_Text.size(),
                    _Path.c_str(), _New.m_Text.data(), _New.m_Text.size(), _Path.c_str(),
                    &opts) < 0)
            {
                RaiseLastError("git_patch_from_buffers failed");
            }

            const git_diff_delta* pdelta = git_patch_get_delta(fp.m_Patch.m_pP);
            fp.m_bBinary = pdelta && (pdelta->flags & GIT_DIFF_FLAG_BINARY) != 0;

            const std::size_t nhunks = git_patch_num_hunks(fp.m_Patch.m_pP);
            for (std::size_t h = 0; h < nhunks; ++h)
            {
                const git_diff_hunk* phunk = nullptr;
                std::size_t nlines = 0;
                if (git_patch_get_hunk(&phunk, &nlines, fp.m_Patch.m_pP, h) < 0)
                {
                    RaiseLastError("git_patch_get_hunk failed");
                }

                FlatPatch::Hunk hunk;
                hunk.m_iOldStart = phunk->old_start;
                hunk.m_iOldLines = phunk->old_lines;
                hunk.m_FirstLine = fp.m_Lines.size();
                hunk.m_LineCount = nlines;

                for (std::size_t l = 0; l < nlines; ++l)
                {
                    const git_diff_line* pline = nullptr;
                    if (git_patch_get_line_in_hunk(&pline, fp.m_Patch.m_pP, h, l) < 0)
                    {
                        RaiseLastError("git_patch_get_line_in_hunk failed");
                    }
                    fp.m_Lines.push_back({pline->origin, pline->old_lineno, pline->new_lineno});
                }
                fp.m_Hunks.push_back(hunk);
            }
            return fp;
        }

        // Split text into lines, each keeping its terminator.
        std::vector<std::string> SplitLines(const std::string& _Text)
        {
            std::vector<std::string> lines;
            std::size_t start = 0;
            while (start < _Text.size())
            {
                std::size_t nl = _Text.find('\n', start);
                if (nl == std::string::npos)
                {
                    lines.push_back(_Text.substr(start));
                    break;
                }
                lines.push_back(_Text.substr(start, nl - start + 1));
                start = nl + 1;
            }
            return lines;
        }

        // Rebuild the patch's OLD text with only the changes flagged in `_Take`
        // applied: a taken '-' drops the old line, a taken '+' inserts the new
        // one; untaken changes leave the old text as it was. Lines are copied
        // from the original buffers, so terminators (and a missing final
        // newline) survive exactly.
        std::string ApplySubset(const std::string& _OldText, const std::string& _NewText,
            const FlatPatch& _Patch, const std::vector<bool>& _Take)
        {
            const std::vector<std::string> oldLines = SplitLines(_OldText);
            const std::vector<std::string> newLines = SplitLines(_NewText);

            std::string out;
            out.reserve(_OldText.size() + _NewText.size());
            std::size_t oldPos = 0; // 0-based index of the next old line to copy

            auto copyOldUntil = [&](std::size_t _End)
            {
                while (oldPos < _End && oldPos < oldLines.size())
                {
                    out += oldLines[oldPos++];
                }
            };

            for (const FlatPatch::Hunk& hunk : _Patch.m_Hunks)
            {
                // A pure insertion ("-N,0") lands AFTER old line N; any other hunk
                // starts consuming at old line old_start.
                const std::size_t hunkStart = hunk.m_iOldLines == 0
                                                  ? static_cast<std::size_t>(hunk.m_iOldStart)
                                                  : static_cast<std::size_t>(hunk.m_iOldStart - 1);
                copyOldUntil(hunkStart);

                for (std::size_t i = 0; i < hunk.m_LineCount; ++i)
                {
                    const std::size_t index = hunk.m_FirstLine + i;
                    const FlatPatch::Line& line = _Patch.m_Lines[index];

                    if (line.m_cOrigin == GIT_DIFF_LINE_CONTEXT)
                    {
                        copyOldUntil(static_cast<std::size_t>(line.m_iOldLineno - 1));
                        if (oldPos < oldLines.size())
                        {
                            out += oldLines[oldPos++];
                        }
                    }
                    else if (line.m_cOrigin == GIT_DIFF_LINE_DELETION)
                    {
                        copyOldUntil(static_cast<std::size_t>(line.m_iOldLineno - 1));
                        if (oldPos < oldLines.size())
                        {
                            if (!_Take[index])
                            {
                                out += oldLines[oldPos];
                            }
                            ++oldPos;
                        }
                    }
                    else if (line.m_cOrigin == GIT_DIFF_LINE_ADDITION)
                    {
                        const std::size_t newIndex =
                            static_cast<std::size_t>(line.m_iNewLineno - 1);
                        if (_Take[index] && newIndex < newLines.size())
                        {
                            out += newLines[newIndex];
                        }
                    }
                    // EOF-newline markers carry no text of their own.
                }
            }
            copyOldUntil(oldLines.size());
            return out;
        }

        // Which combined-patch lines are currently staged. A deleted HEAD line is
        // staged when the index lacks it too (it's a '-' in HEAD -> index); an
        // added working-tree line is staged when the index already has it (it's
        // NOT a '+' in index -> working tree).
        std::vector<bool> ComputeStaged(const std::string& _Path, const FileSide& _Head,
            const FileSide& _Index, const FileSide& _Work, const FlatPatch& _Combined)
        {
            const DiffOptions noOptions;
            const FlatPatch staged = MakePatch(_Path, _Head, _Index, noOptions);
            const FlatPatch unstaged = MakePatch(_Path, _Index, _Work, noOptions);

            std::set<int> stagedDeletions;
            for (const auto& line : staged.m_Lines)
            {
                if (line.m_cOrigin == GIT_DIFF_LINE_DELETION)
                {
                    stagedDeletions.insert(line.m_iOldLineno);
                }
            }

            std::set<int> unstagedAdditions;
            for (const auto& line : unstaged.m_Lines)
            {
                if (line.m_cOrigin == GIT_DIFF_LINE_ADDITION)
                {
                    unstagedAdditions.insert(line.m_iNewLineno);
                }
            }

            std::vector<bool> out(_Combined.m_Lines.size(), false);
            for (std::size_t i = 0; i < _Combined.m_Lines.size(); ++i)
            {
                const auto& line = _Combined.m_Lines[i];
                if (line.m_cOrigin == GIT_DIFF_LINE_DELETION)
                {
                    out[i] = stagedDeletions.count(line.m_iOldLineno) != 0;
                }
                else if (line.m_cOrigin == GIT_DIFF_LINE_ADDITION)
                {
                    // Untracked files have no index side at all: nothing staged.
                    out[i] = _Index.m_bExists && unstagedAdditions.count(line.m_iNewLineno) == 0;
                }
            }
            return out;
        }

        void CheckLineCount(
            const FlatPatch& _Patch, std::size_t _Expected, const std::string& _Path)
        {
            if (_Patch.m_bBinary)
            {
                throw GitError("'" + _Path + "' is binary; it can only be staged as a whole");
            }
            if (_Patch.m_Lines.size() != _Expected)
            {
                throw GitError("'" + _Path + "' changed on disk; refresh and try again");
            }
        }

        uint32_t ModeFor(const FileSide& _Index, const FileSide& _Head)
        {
            if (_Index.m_bExists)
            {
                return _Index.m_uiMode;
            }
            if (_Head.m_bExists)
            {
                return _Head.m_uiMode;
            }
            return GIT_FILEMODE_BLOB;
        }

        // Put `_Text` into the index as `_Path` (no working-tree involvement).
        void WriteIndexBlob(git_index* _pIndex, const std::string& _Path, const std::string& _Text,
            uint32_t _uiMode)
        {
            git_index_entry entry = {};
            entry.path = _Path.c_str();
            entry.mode = _uiMode;
            if (git_index_add_from_buffer(_pIndex, &entry, _Text.data(), _Text.size()) < 0)
            {
                RaiseLastError("Updating the index entry for '" + _Path + "' failed");
            }
        }

        IndexPtr OpenIndex(git_repository* _pRepo)
        {
            IndexPtr index;
            if (git_repository_index(&index.m_pP, _pRepo) < 0)
            {
                RaiseLastError("git_repository_index failed");
            }
            return index;
        }

        void WriteIndex(git_index* _pIndex)
        {
            if (git_index_write(_pIndex) < 0)
            {
                RaiseLastError("git_index_write failed");
            }
        }

        void RemoveWorkFile(git_repository* _pRepo, const std::string& _Path,
            const std::function<bool(const std::string&)>& _RemoveFile)
        {
            const fs::path abs = WorkPath(_pRepo, _Path);
            std::error_code ec;
            if (!fs::exists(abs, ec))
            {
                return;
            }
            if (_RemoveFile)
            {
                if (!_RemoveFile(abs.u8string()))
                {
                    throw GitError("Could not remove '" + _Path + "'");
                }
                return;
            }
            fs::remove(abs, ec);
            if (ec)
            {
                throw GitError("Could not remove '" + _Path + "': " + ec.message());
            }
        }

        FileDiff DiffSides(const std::string& _OldPath, const FileSide& _Old,
            const std::string& _NewPath, const FileSide& _New, const DiffOptions& _Options);

    } // namespace

    namespace internal
    {

        FileDiff CombinedFileDiff(
            git_repository* _pRepo, const std::string& _Path, const DiffOptions& _Options)
        {
            const FileSide head = ReadHeadSide(_pRepo, _Path);
            const FileSide work = ReadWorkSide(_pRepo, _Path);
            return DiffSides(_Path, head, _Path, work, _Options);
        }

        FileVersion ReadVersion(
            git_repository* _pRepo, const std::string& _Path, const std::string& _Revision)
        {
            FileSide side;
            if (_Revision == "workdir")
            {
                side = ReadWorkSide(_pRepo, _Path);
            }
            else if (_Revision == "index")
            {
                IndexPtr index = OpenIndex(_pRepo);
                side = ReadIndexSide(_pRepo, index.m_pP, _Path);
            }
            else if (_Revision == "head")
            {
                side = ReadHeadSide(_pRepo, _Path);
            }
            else
            {
                ObjectPtr obj;
                ObjectPtr commit;
                TreePtr tree;
                // "<oid>^" on a root commit has no parent: the file didn't exist.
                if (git_revparse_single(&obj.m_pP, _pRepo, _Revision.c_str()) == 0 &&
                    git_object_peel(&commit.m_pP, obj.m_pP, GIT_OBJECT_COMMIT) == 0 &&
                    git_commit_tree(&tree.m_pP, reinterpret_cast<git_commit*>(commit.m_pP)) == 0)
                {
                    side = ReadTreeSide(_pRepo, tree.m_pP, _Path);
                }
            }
            return FileVersion{std::move(side.m_Text), side.m_bExists, side.m_uiMode};
        }

        void WriteWorkingFile(
            git_repository* _pRepo, const std::string& _Path, const std::string& _Text)
        {
            WriteWorkFile(_pRepo, _Path, _Text);
        }

        std::filesystem::path WorkingPath(git_repository* _pRepo, const std::string& _Path)
        {
            return WorkPath(_pRepo, _Path);
        }

        FileDiff DiffFileVersions(const std::string& _OldPath, const FileVersion& _Old,
            const std::string& _NewPath, const FileVersion& _New, const DiffOptions& _Options)
        {
            return DiffSides(_OldPath, FileSide{_Old.m_Text, _Old.m_bExists, _Old.m_uiMode},
                _NewPath, FileSide{_New.m_Text, _New.m_bExists, _New.m_uiMode}, _Options);
        }

    } // namespace internal

    namespace
    {

        // The structured diff between two file versions (the shape every diff
        // producer returns).
        FileDiff DiffSides(const std::string& _OldPath, const FileSide& _Old,
            const std::string& _NewPath, const FileSide& _New, const DiffOptions& _Options)
        {
            FileDiff out;
            out.m_Path = _NewPath;
            out.m_OldPath = _OldPath;
            out.m_cStatus = !_Old.m_bExists ? 'A' : (!_New.m_bExists ? 'D' : 'M');
            if (_Old.m_bExists && _New.m_bExists && _OldPath != _NewPath)
            {
                out.m_cStatus = 'R';
            }

            const FlatPatch fp = MakePatch(_NewPath, _Old, _New, _Options);
            out.m_bIsBinary = fp.m_bBinary;

            for (std::size_t h = 0; h < git_patch_num_hunks(fp.m_Patch.m_pP); ++h)
            {
                const git_diff_hunk* phunk = nullptr;
                std::size_t nlines = 0;
                git_patch_get_hunk(&phunk, &nlines, fp.m_Patch.m_pP, h);

                DiffHunk hunk;
                hunk.m_Header.assign(phunk->header, phunk->header_len);
                while (!hunk.m_Header.empty() &&
                       (hunk.m_Header.back() == '\n' || hunk.m_Header.back() == '\r'))
                {
                    hunk.m_Header.pop_back();
                }
                hunk.m_iOldStart = phunk->old_start;
                hunk.m_iOldLines = phunk->old_lines;
                hunk.m_iNewStart = phunk->new_start;
                hunk.m_iNewLines = phunk->new_lines;

                for (std::size_t l = 0; l < nlines; ++l)
                {
                    const git_diff_line* pline = nullptr;
                    git_patch_get_line_in_hunk(&pline, fp.m_Patch.m_pP, h, l);

                    DiffLine line;
                    line.m_cOrigin = pline->origin;
                    line.m_iOldLineno = pline->old_lineno;
                    line.m_iNewLineno = pline->new_lineno;
                    line.m_Content.assign(pline->content, pline->content_len);
                    if (!line.m_Content.empty() && line.m_Content.back() == '\n')
                    {
                        line.m_Content.pop_back();
                    }
                    hunk.m_Lines.push_back(std::move(line));
                }
                out.m_Hunks.push_back(std::move(hunk));
            }
            return out;
        }

    } // namespace

    // ---- Batch stage / unstage ---------------------------------------------------

    void Repository::Stage(const std::vector<std::string>& _Paths)
    {
        if (!m_pRepo)
        {
            throw GitError("stage() on an unopened repository");
        }

        IndexPtr index = OpenIndex(m_pRepo);
        for (const std::string& path : _Paths)
        {
            std::error_code ec;
            const bool bexists = fs::exists(WorkPath(m_pRepo, path), ec);
            const int irc = bexists ? git_index_add_bypath(index.m_pP, path.c_str())
                                    : git_index_remove_bypath(index.m_pP, path.c_str());
            if (irc < 0)
            {
                RaiseLastError("Failed to stage '" + path + "'");
            }
        }
        WriteIndex(index.m_pP);
    }

    void Repository::Unstage(const std::vector<std::string>& _Paths)
    {
        if (!m_pRepo)
        {
            throw GitError("unstage() on an unopened repository");
        }
        if (_Paths.empty())
        {
            return;
        }

        git_oid headOid;
        if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") != 0)
        {
            // Unborn branch: nothing to reset to, so unstaging = dropping entries.
            IndexPtr index = OpenIndex(m_pRepo);
            for (const std::string& path : _Paths)
            {
                git_index_remove_bypath(index.m_pP, path.c_str());
            }
            WriteIndex(index.m_pP);
            return;
        }

        ObjectPtr headCommit;
        if (git_object_lookup(&headCommit.m_pP, m_pRepo, &headOid, GIT_OBJECT_COMMIT) < 0)
        {
            RaiseLastError("git_object_lookup (HEAD) failed");
        }
        PathSpec spec(_Paths);
        if (git_reset_default(m_pRepo, headCommit.m_pP, &spec.m_A) < 0)
        {
            RaiseLastError("Failed to unstage");
        }
    }

    // ---- Line-level staging ------------------------------------------------------

    std::vector<std::size_t> Repository::StagedLines(const std::string& _Path) const
    {
        if (!m_pRepo)
        {
            throw GitError("stagedLines() on an unopened repository");
        }

        IndexPtr index = OpenIndex(m_pRepo);
        const FileSide head = ReadHeadSide(m_pRepo, _Path);
        const FileSide staged = ReadIndexSide(m_pRepo, index.m_pP, _Path);
        const FileSide work = ReadWorkSide(m_pRepo, _Path);
        const FlatPatch combined = MakePatch(_Path, head, work, DiffOptions());
        if (combined.m_bBinary)
        {
            return {};
        }

        const std::vector<bool> flags = ComputeStaged(_Path, head, staged, work, combined);
        std::vector<std::size_t> out;
        for (std::size_t i = 0; i < flags.size(); ++i)
        {
            if (flags[i])
            {
                out.push_back(i);
            }
        }
        return out;
    }

    void Repository::SetStagedLines(const std::string& _Path,
        const std::vector<std::size_t>& _Lines, std::size_t _ExpectedLineCount)
    {
        if (!m_pRepo)
        {
            throw GitError("setStagedLines() on an unopened repository");
        }

        IndexPtr index = OpenIndex(m_pRepo);
        const FileSide head = ReadHeadSide(m_pRepo, _Path);
        const FileSide staged = ReadIndexSide(m_pRepo, index.m_pP, _Path);
        const FileSide work = ReadWorkSide(m_pRepo, _Path);
        const FlatPatch combined = MakePatch(_Path, head, work, DiffOptions());
        CheckLineCount(combined, _ExpectedLineCount, _Path);

        std::vector<bool> take(combined.m_Lines.size(), false);
        bool bany = false;
        bool ballDeletions = true;
        for (std::size_t i : _Lines)
        {
            if (i < take.size() && combined.IsChange(i))
            {
                take[i] = true;
                bany = true;
            }
        }
        for (std::size_t i = 0; i < combined.m_Lines.size(); ++i)
        {
            if (combined.m_Lines[i].m_cOrigin == GIT_DIFF_LINE_DELETION && !take[i])
            {
                ballDeletions = false;
            }
        }

        if (!head.m_bExists && !bany)
        {
            // A new file with nothing selected goes back to being untracked.
            git_index_remove_bypath(index.m_pP, _Path.c_str());
        }
        else if (head.m_bExists && !work.m_bExists && ballDeletions)
        {
            // Every line of a deleted file selected: stage the deletion itself.
            git_index_remove_bypath(index.m_pP, _Path.c_str());
        }
        else
        {
            const std::string text = ApplySubset(head.m_Text, work.m_Text, combined, take);
            WriteIndexBlob(index.m_pP, _Path, text, ModeFor(staged, head));
        }
        WriteIndex(index.m_pP);
    }

    void Repository::DiscardLines(const std::string& _Path, const std::vector<std::size_t>& _Lines,
        std::size_t _ExpectedLineCount, const std::function<bool(const std::string&)>& _RemoveFile)
    {
        if (!m_pRepo)
        {
            throw GitError("discardLines() on an unopened repository");
        }

        IndexPtr index = OpenIndex(m_pRepo);
        const FileSide head = ReadHeadSide(m_pRepo, _Path);
        const FileSide staged = ReadIndexSide(m_pRepo, index.m_pP, _Path);
        const FileSide work = ReadWorkSide(m_pRepo, _Path);
        const FlatPatch combined = MakePatch(_Path, head, work, DiffOptions());
        CheckLineCount(combined, _ExpectedLineCount, _Path);

        const std::vector<bool> stagedFlags = ComputeStaged(_Path, head, staged, work, combined);
        std::vector<bool> discard(combined.m_Lines.size(), false);
        for (std::size_t i : _Lines)
        {
            if (i < discard.size())
            {
                discard[i] = true;
            }
        }

        std::vector<bool> keepInWork(combined.m_Lines.size(), false);
        std::vector<bool> keepInIndex(combined.m_Lines.size(), false);
        bool bworkHasChanges = false;
        bool bindexHasChanges = false;
        for (std::size_t i = 0; i < combined.m_Lines.size(); ++i)
        {
            if (!combined.IsChange(i) || discard[i])
            {
                continue;
            }
            keepInWork[i] = true;
            bworkHasChanges = true;
            if (stagedFlags[i])
            {
                keepInIndex[i] = true;
                bindexHasChanges = true;
            }
        }

        // Working tree.
        if (!head.m_bExists && !bworkHasChanges)
        {
            RemoveWorkFile(m_pRepo, _Path, _RemoveFile);
        }
        else
        {
            WriteWorkFile(
                m_pRepo, _Path, ApplySubset(head.m_Text, work.m_Text, combined, keepInWork));
        }

        // Index.
        if (!head.m_bExists && !bindexHasChanges)
        {
            git_index_remove_bypath(index.m_pP, _Path.c_str());
        }
        else if (staged.m_bExists || bindexHasChanges)
        {
            WriteIndexBlob(index.m_pP, _Path,
                ApplySubset(head.m_Text, work.m_Text, combined, keepInIndex),
                ModeFor(staged, head));
        }
        WriteIndex(index.m_pP);
    }

    // ---- Discard whole files -----------------------------------------------------

    void Repository::DiscardChanges(const std::vector<std::string>& _Paths,
        const std::function<bool(const std::string&)>& _RemoveFile)
    {
        if (!m_pRepo)
        {
            throw GitError("discardChanges() on an unopened repository");
        }

        TreePtr headTree = HeadTree(m_pRepo);
        std::vector<std::string> tracked;
        std::vector<std::string> added;
        for (const std::string& path : _Paths)
        {
            TreeEntryPtr entry;
            const bool binHead = headTree.m_pP && git_tree_entry_bypath(&entry.m_pP, headTree.m_pP,
                                                      path.c_str()) == 0;
            (binHead ? tracked : added).push_back(path);
        }

        if (!tracked.empty())
        {
            // Force-checkout exactly these paths from HEAD: rewrites both the
            // index entries and the working-tree files.
            PathSpec spec(tracked);
            git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
            opts.checkout_strategy = GIT_CHECKOUT_FORCE | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH;
            opts.paths = spec.m_A;
            if (git_checkout_tree(m_pRepo, reinterpret_cast<git_object*>(headTree.m_pP), &opts) < 0)
            {
                RaiseLastError("Discarding changes failed");
            }
        }

        if (!added.empty())
        {
            IndexPtr index = OpenIndex(m_pRepo);
            for (const std::string& path : added)
            {
                git_index_remove_bypath(index.m_pP, path.c_str());
            }
            WriteIndex(index.m_pP);
            for (const std::string& path : added)
            {
                RemoveWorkFile(m_pRepo, path, _RemoveFile);
            }
        }
    }

    // ---- .gitignore ----------------------------------------------------------------

    void Repository::AddToGitignore(const std::string& _Pattern)
    {
        if (!m_pRepo)
        {
            throw GitError("addToGitignore() on an unopened repository");
        }

        const fs::path file = WorkPath(m_pRepo, ".gitignore");
        std::string content = ReadWholeFile(file);
        if (!content.empty() && content.back() != '\n')
        {
            content += '\n';
        }
        content += _Pattern + "\n";

        std::ofstream out(file, std::ios::binary | std::ios::trunc);
        if (!out)
        {
            throw GitError("Could not write .gitignore");
        }
        out << content;
    }

    // ---- Reading any version of a file ---------------------------------------------

    bool Repository::ReadFileVersion(
        const std::string& _Path, const std::string& _Revision, std::string& _Out) const
    {
        if (!m_pRepo)
        {
            throw GitError("readFileVersion() on an unopened repository");
        }

        if (_Revision == "workdir")
        {
            const fs::path abs = WorkPath(m_pRepo, _Path);
            std::error_code ec;
            if (!fs::is_regular_file(abs, ec))
            {
                return false;
            }
            _Out = ReadWholeFile(abs);
            return true;
        }

        FileSide side;
        if (_Revision == "index")
        {
            IndexPtr index = OpenIndex(m_pRepo);
            side = ReadIndexSide(m_pRepo, index.m_pP, _Path);
        }
        else if (_Revision == "head")
        {
            side = ReadHeadSide(m_pRepo, _Path);
        }
        else
        {
            // "<oid>^" on a root commit has no parent: the file didn't exist.
            ObjectPtr obj;
            if (git_revparse_single(&obj.m_pP, m_pRepo, _Revision.c_str()) != 0)
            {
                return false;
            }
            ObjectPtr commit;
            if (git_object_peel(&commit.m_pP, obj.m_pP, GIT_OBJECT_COMMIT) < 0)
            {
                return false;
            }
            TreePtr tree;
            if (git_commit_tree(&tree.m_pP, reinterpret_cast<git_commit*>(commit.m_pP)) < 0)
            {
                return false;
            }
            side = ReadTreeSide(m_pRepo, tree.m_pP, _Path);
        }

        if (!side.m_bExists)
        {
            return false;
        }
        _Out = std::move(side.m_Text);
        return true;
    }

} // namespace gitgud::git
