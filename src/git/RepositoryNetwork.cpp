// -----------------------------------------------------------------------------
// Repository — networked operations: Fetch, Push, Pull, Clone.
//
// These BLOCK on the network. Per docs/PRINCIPLES.md they must run on a
// worker thread (see src/app/TaskRunner.h); the worker opens its OWN
// Repository handle — libgit2 objects are not shared across threads.
//
// Authentication goes through the CredentialProvider callback so the engine
// stays free of UI and of credential-storage policy (see src/platform/).
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <git2/sys/errors.h> // git_error_set_str (public "sys" API in 1.8+)

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        namespace fs = std::filesystem;

        const char kBase64Alphabet[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        std::string HomeDir()
        {
            const char* szhome = std::getenv("USERPROFILE");
            if (!szhome)
            {
                szhome = std::getenv("HOME");
            }
            return szhome ? szhome : "";
        }

        std::string Base64(const unsigned char* _pData, std::size_t _nLength)
        {
            std::string out;
            out.reserve((_nLength + 2) / 3 * 4);
            for (std::size_t i = 0; i < _nLength; i += 3)
            {
                unsigned uivalue = static_cast<unsigned>(_pData[i]) << 16;
                if (i + 1 < _nLength)
                {
                    uivalue |= static_cast<unsigned>(_pData[i + 1]) << 8;
                }
                if (i + 2 < _nLength)
                {
                    uivalue |= static_cast<unsigned>(_pData[i + 2]);
                }
                out.push_back(kBase64Alphabet[(uivalue >> 18) & 63]);
                out.push_back(kBase64Alphabet[(uivalue >> 12) & 63]);
                out.push_back(i + 1 < _nLength ? kBase64Alphabet[(uivalue >> 6) & 63] : '=');
                out.push_back(i + 2 < _nLength ? kBase64Alphabet[uivalue & 63] : '=');
            }
            return out;
        }

        std::string Unbase64(const std::string& _Text)
        {
            std::string out;
            unsigned uibuffer = 0;
            int ibits = 0;
            for (const char c : _Text)
            {
                const char* szpos = std::strchr(kBase64Alphabet, c);
                if (c == '\0' || !szpos)
                {
                    break; // '=' padding or junk ends the data
                }
                uibuffer = (uibuffer << 6) | static_cast<unsigned>(szpos - kBase64Alphabet);
                ibits += 6;
                if (ibits >= 8)
                {
                    ibits -= 8;
                    out.push_back(static_cast<char>((uibuffer >> ibits) & 0xFF));
                }
            }
            return out;
        }

        std::string ReadAll(const fs::path& _File)
        {
            std::ifstream in(_File, std::ios::binary);
            std::ostringstream ss;
            ss << in.rdbuf();
            return ss.str();
        }

        // Does this private key file need a passphrase? PEM keys say
        // ENCRYPTED; OpenSSH-format keys name their cipher right after the
        // "openssh-key-v1" magic ("none" when unencrypted).
        bool IsEncryptedKey(const fs::path& _File)
        {
            const std::string text = ReadAll(_File);
            if (text.find("ENCRYPTED") != std::string::npos)
            {
                return true;
            }
            const std::string header = "-----BEGIN OPENSSH PRIVATE KEY-----";
            const auto nbegin = text.find(header);
            if (nbegin == std::string::npos)
            {
                return false;
            }
            std::string encoded;
            for (std::size_t i = nbegin + header.size(); i < text.size() && text[i] != '-'; ++i)
            {
                if (!std::isspace(static_cast<unsigned char>(text[i])))
                {
                    encoded.push_back(text[i]);
                }
            }
            const std::string decoded = Unbase64(encoded.substr(0, 64));
            const std::size_t nmagic = 15; // "openssh-key-v1" + NUL
            if (decoded.size() < nmagic + 8)
            {
                return false;
            }
            const std::size_t ncipherLength =
                (static_cast<std::size_t>(static_cast<unsigned char>(decoded[nmagic])) << 24) |
                (static_cast<std::size_t>(static_cast<unsigned char>(decoded[nmagic + 1])) << 16) |
                (static_cast<std::size_t>(static_cast<unsigned char>(decoded[nmagic + 2])) << 8) |
                static_cast<std::size_t>(static_cast<unsigned char>(decoded[nmagic + 3]));
            const std::string cipher = decoded.substr(nmagic + 4, ncipherLength);
            return !cipher.empty() && cipher != "none";
        }

        // The usual private keys in ~/.ssh, most modern first.
        std::vector<fs::path> SshKeyFiles()
        {
            std::vector<fs::path> out;
            const std::string home = HomeDir();
            if (home.empty())
            {
                return out;
            }
            std::error_code ec;
            for (const char* szname : {"id_ed25519", "id_ecdsa", "id_rsa"})
            {
                const fs::path key = fs::u8path(home) / ".ssh" / szname;
                if (fs::exists(key, ec))
                {
                    out.push_back(key);
                }
            }
            return out;
        }

        // Offer the next SSH identity: the agent first (Pageant or the Windows
        // OpenSSH agent), then each key file in ~/.ssh. Every call means the
        // previous offer was rejected.
        int OfferSshKey(git_credential** _ppOut, const std::string& _User, RemoteContext* _pCtx)
        {
            const std::vector<fs::path> keys = SshKeyFiles();
            while (_pCtx)
            {
                const int istage = _pCtx->m_iSshStage++;
                if (istage == 0)
                {
                    if (git_credential_ssh_key_from_agent(_ppOut, _User.c_str()) == 0)
                    {
                        return 0;
                    }
                    continue;
                }

                const std::size_t nindex = static_cast<std::size_t>(istage - 1);
                if (nindex >= keys.size())
                {
                    break;
                }
                const fs::path& key = keys[nindex];
                fs::path pub = key;
                pub += ".pub";
                std::error_code ec;
                const std::string pubPath = fs::exists(pub, ec) ? pub.u8string() : std::string();
                const std::string keyPath = key.u8string();

                std::string passphrase;
                if (IsEncryptedKey(key))
                {
                    std::string unusedUser;
                    if (!_pCtx->m_pProvider || !*_pCtx->m_pProvider ||
                        !(*_pCtx->m_pProvider)(
                            "ssh-key:" + keyPath, _User, false, unusedUser, passphrase))
                    {
                        continue; // no passphrase for it (yet): try the next key
                    }
                }
                _pCtx->m_SshKeyTried = keyPath;
                return git_credential_ssh_key_new(_ppOut, _User.c_str(),
                    pubPath.empty() ? nullptr : pubPath.c_str(), keyPath.c_str(),
                    passphrase.c_str());
            }

            git_error_set_str(GIT_ERROR_SSH,
                "No SSH key was accepted. Add your public key (~/.ssh/*.pub) to the server, "
                "start your SSH agent, or generate a key in Options");
            return GIT_EAUTH;
        }

        int CredentialCb(git_credential** _ppOut, const char* _szUrl,
            const char* _szUsernameFromUrl, unsigned int _uiAllowedTypes, void* _pPayload)
        {
            auto* pctx = static_cast<RemoteContext*>(_pPayload);
            const std::string url = _szUrl ? _szUrl : "";
            const std::string userFromUrl =
                (_szUsernameFromUrl && *_szUsernameFromUrl) ? _szUsernameFromUrl : "";
            const std::string sshUser = userFromUrl.empty() ? "git" : userFromUrl;

            // SSH asks for the user name on its own when the URL has none.
            if (_uiAllowedTypes & GIT_CREDENTIAL_USERNAME)
            {
                return git_credential_username_new(_ppOut, sshUser.c_str());
            }
            if (_uiAllowedTypes & GIT_CREDENTIAL_SSH_KEY)
            {
                return OfferSshKey(_ppOut, sshUser, pctx);
            }

            if (!pctx || !pctx->m_pProvider || !*pctx->m_pProvider)
            {
                return GIT_PASSTHROUGH; // let libgit2 try default mechanisms
            }
            if ((_uiAllowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT) == 0)
            {
                return GIT_PASSTHROUGH;
            }
            // libgit2 re-asks after every rejection; returning the same stored
            // password forever would loop, so three strikes and we give up.
            // Every call after the first means the last answer was refused.
            const bool brejected = pctx->m_iAttempts > 0;
            if (++pctx->m_iAttempts > 3)
            {
                git_error_set_str(GIT_ERROR_NET, "Authentication failed (3 attempts)");
                return GIT_EAUTH;
            }

            std::string user;
            std::string pass;
            if (!(*pctx->m_pProvider)(url, userFromUrl, brejected, user, pass))
            {
                git_error_set_str(GIT_ERROR_NET, brejected ? "The server rejected the saved sign-in"
                                                           : "No credentials available");
                return GIT_EAUTH;
            }
            return git_credential_userpass_plaintext_new(_ppOut, user.c_str(), pass.c_str());
        }

        const char* SshKeyTypeName(git_cert_ssh_raw_type_t _Type)
        {
            switch (_Type)
            {
            case GIT_CERT_SSH_RAW_TYPE_RSA:
                return "ssh-rsa";
            case GIT_CERT_SSH_RAW_TYPE_DSS:
                return "ssh-dss";
            case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_256:
                return "ecdsa-sha2-nistp256";
            case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_384:
                return "ecdsa-sha2-nistp384";
            case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_521:
                return "ecdsa-sha2-nistp521";
            case GIT_CERT_SSH_RAW_TYPE_KEY_ED25519:
                return "ssh-ed25519";
            default:
                return "";
            }
        }

        // Is `_Host` already in known_hosts with a DIFFERENT key of the same
        // type? That's the man-in-the-middle warning, never a "trust it?" prompt.
        bool KnownHostMismatch(
            const std::string& _Host, const std::string& _Type, const std::string& _Key)
        {
            const std::string home = HomeDir();
            if (home.empty() || _Type.empty())
            {
                return false;
            }
            std::istringstream in(ReadAll(fs::u8path(home) / ".ssh" / "known_hosts"));
            std::string line;
            while (std::getline(in, line))
            {
                std::istringstream fields(line);
                std::string hosts;
                std::string type;
                std::string key;
                if (!(fields >> hosts >> type >> key) || hosts.empty() || hosts[0] == '|' ||
                    hosts[0] == '#')
                {
                    continue;
                }
                std::istringstream names(hosts);
                std::string name;
                while (std::getline(names, name, ','))
                {
                    if (name == _Host && type == _Type && key != _Key)
                    {
                        return true;
                    }
                }
            }
            return false;
        }

        int CertificateCheckCb(git_cert* _pCert, int _iValid, const char* _szHost, void* _pPayload)
        {
            if (_iValid)
            {
                return 0;
            }
            if (!_pCert || _pCert->cert_type != GIT_CERT_HOSTKEY_LIBSSH2)
            {
                return GIT_PASSTHROUGH; // HTTPS: the TLS stack's verdict stands
            }

            const auto* phostkey = reinterpret_cast<const git_cert_hostkey*>(_pCert);
            const std::string host = _szHost ? _szHost : "";
            std::string fingerprint;
            if (phostkey->type & GIT_CERT_SSH_SHA256)
            {
                fingerprint = "SHA256:" + Base64(phostkey->hash_sha256, 32);
                while (!fingerprint.empty() && fingerprint.back() == '=')
                {
                    fingerprint.pop_back();
                }
            }
            std::string type;
            std::string key;
            if (phostkey->type & GIT_CERT_SSH_RAW)
            {
                type = SshKeyTypeName(phostkey->raw_type);
                key = Base64(reinterpret_cast<const unsigned char*>(phostkey->hostkey),
                    phostkey->hostkey_len);
            }

            if (KnownHostMismatch(host, type, key))
            {
                const std::string message =
                    "WARNING: the SSH host key of " + host +
                    " has CHANGED since you last connected. Someone could be intercepting the "
                    "connection. If the server really changed its key, remove its old line "
                    "from ~/.ssh/known_hosts.";
                git_error_set_str(GIT_ERROR_SSH, message.c_str());
                return GIT_ECERTIFICATE;
            }

            auto* pctx = static_cast<RemoteContext*>(_pPayload);
            const std::string line = type.empty() ? std::string() : host + " " + type + " " + key;
            if (pctx && pctx->m_pHostKeys && *pctx->m_pHostKeys && !line.empty() &&
                (*pctx->m_pHostKeys)(host, fingerprint, line))
            {
                return 0;
            }
            const std::string message = "The authenticity of host '" + host +
                                        "' can't be established (key fingerprint " + fingerprint +
                                        ")";
            git_error_set_str(GIT_ERROR_SSH, message.c_str());
            return GIT_ECERTIFICATE;
        }

    } // namespace

    namespace internal
    {

        void SetupRemoteCallbacks(git_remote_callbacks& _Callbacks, RemoteContext& _Context)
        {
            _Callbacks.credentials = CredentialCb;
            _Callbacks.certificate_check = CertificateCheckCb;
            _Callbacks.payload = &_Context;
        }

    } // namespace internal

    void Repository::SetCredentialProvider(CredentialProvider _Provider)
    {
        if (m_pP4)
        {
            m_pP4->SetPasswordProvider(P4Passwords(_Provider));
        }

        m_CredProvider = std::move(_Provider);
    }

    void Repository::SetHostKeyProvider(HostKeyProvider _Provider)
    {
        m_HostKeyProvider = std::move(_Provider);
    }

    void Repository::Fetch(const std::string& _RemoteName)
    {
        if (m_pP4)
        {
            m_pP4->Fetch(_RemoteName);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("fetch() on an unopened repository");
        }

        RemotePtr remote;
        if (git_remote_lookup(&remote.m_pP, m_pRepo, _RemoteName.c_str()) < 0)
        {
            RaiseLastError("No such remote '" + _RemoteName + "'");
        }

        RemoteContext ctx;
        ctx.m_pProvider = &m_CredProvider;
        ctx.m_pHostKeys = &m_HostKeyProvider;
        git_fetch_options opts = GIT_FETCH_OPTIONS_INIT;
        SetupRemoteCallbacks(opts.callbacks, ctx);

        if (git_remote_fetch(remote.m_pP, /*refspecs=*/nullptr, &opts, "fetch (gitgud)") < 0)
        {
            RaiseLastError("Fetch from '" + _RemoteName + "' failed");
        }
    }

    std::vector<std::string> Repository::FetchAll()
    {
        if (m_pP4)
        {
            return m_pP4->FetchAll();
        }

        if (!m_pRepo)
        {
            throw GitError("fetchAll() on an unopened repository");
        }

        // One unreachable remote shouldn't keep the others stale: fetch every
        // one, then report what failed.
        std::vector<std::string> fetched;
        std::string failures;
        for (const RemoteInfo& remote : Remotes())
        {
            try
            {
                Fetch(remote.m_Name);
                fetched.push_back(remote.m_Name);
            }
            catch (const GitError& e)
            {
                failures += (failures.empty() ? "" : "; ") + std::string(e.what());
            }
        }
        if (!failures.empty())
        {
            throw GitError(failures);
        }
        return fetched;
    }

    namespace
    {

        // Push explicit refspecs to a remote with the credential callback wired.
        void PushRefspecs(git_repository* _pRepo, const std::string& _RemoteName,
            const std::vector<std::string>& _Refspecs, const CredentialProvider& _Provider,
            const HostKeyProvider& _HostKeys)
        {
            RemotePtr remote;
            if (git_remote_lookup(&remote.m_pP, _pRepo, _RemoteName.c_str()) < 0)
            {
                RaiseLastError("No such remote '" + _RemoteName + "'");
            }

            RemoteContext ctx;
            ctx.m_pProvider = &_Provider;
            ctx.m_pHostKeys = &_HostKeys;
            git_push_options opts = GIT_PUSH_OPTIONS_INIT;
            SetupRemoteCallbacks(opts.callbacks, ctx);

            PathSpec specs(_Refspecs);
            if (git_remote_push(remote.m_pP, &specs.m_A, &opts) < 0)
            {
                RaiseLastError("Push to '" + _RemoteName + "' failed");
            }
        }

    } // namespace

    void Repository::Push(const std::string& _RemoteName, bool _bForce, bool _bSetUpstream)
    {
        if (m_pP4)
        {
            m_pP4->Push(_RemoteName, _bForce, _bSetUpstream);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("push() on an unopened repository");
        }

        const std::string branch = CurrentBranch();
        if (branch.empty())
        {
            throw GitError("Cannot push: no branch is checked out");
        }
        const std::string localRef = "refs/heads/" + branch;

        // Push to the upstream's branch when the upstream lives on this
        // remote (it may be named differently), else to the same name.
        std::string target = branch;
        const std::string upstreamRemote = UpstreamRemoteOf(m_pRepo, localRef.c_str());
        if (upstreamRemote == _RemoteName)
        {
            const std::string upstreamBranch = UpstreamBranchOf(m_pRepo, localRef.c_str());
            if (!upstreamBranch.empty())
            {
                target = upstreamBranch;
            }
        }

        // A leading '+' lets the remote branch move non-fast-forward.
        const std::string refspec =
            std::string(_bForce ? "+" : "") + localRef + ":refs/heads/" + target;
        PushRefspecs(m_pRepo, _RemoteName, {refspec}, m_CredProvider, m_HostKeyProvider);

        // Adopt <remote>/<target> as upstream on the first push (or when
        // asked) so ahead/behind and Pull work from here on. Best effort.
        if (upstreamRemote.empty() || (_bSetUpstream && upstreamRemote != _RemoteName))
        {
            ReferencePtr local;
            if (git_reference_lookup(&local.m_pP, m_pRepo, localRef.c_str()) == 0)
            {
                const std::string up = _RemoteName + "/" + target;
                git_branch_set_upstream(local.m_pP, up.c_str());
            }
        }
    }

    void Repository::PushTags(const std::string& _RemoteName)
    {
        if (m_pP4)
        {
            m_pP4->PushTags(_RemoteName);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("pushTags() on an unopened repository");
        }

        // libgit2 push doesn't expand globs, so spell out every tag.
        StrArray names;
        if (git_tag_list(&names.m_A, m_pRepo) < 0)
        {
            RaiseLastError("git_tag_list failed");
        }
        std::vector<std::string> refspecs;
        for (std::size_t i = 0; i < names.m_A.count; ++i)
        {
            const std::string ref = std::string("refs/tags/") + names.m_A.strings[i];
            refspecs.push_back(ref + ":" + ref);
        }
        if (refspecs.empty())
        {
            return;
        }
        PushRefspecs(m_pRepo, _RemoteName, refspecs, m_CredProvider, m_HostKeyProvider);
    }

    void Repository::PushBranch(const std::string& _RemoteName, const std::string& _Branch,
        const std::string& _RemoteBranch, bool _bForce)
    {
        if (m_pP4)
        {
            m_pP4->PushBranch(_RemoteName, _Branch, _RemoteBranch, _bForce);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("pushBranch() on an unopened repository");
        }
        const std::string target = _RemoteBranch.empty() ? _Branch : _RemoteBranch;
        const std::string refspec =
            std::string(_bForce ? "+" : "") + "refs/heads/" + _Branch + ":refs/heads/" + target;
        PushRefspecs(m_pRepo, _RemoteName, {refspec}, m_CredProvider, m_HostKeyProvider);
    }

    void Repository::DeleteRemoteBranch(const std::string& _RemoteName, const std::string& _Branch)
    {
        if (m_pP4)
        {
            m_pP4->DeleteRemoteBranch(_RemoteName, _Branch);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("deleteRemoteBranch() on an unopened repository");
        }

        // An empty source deletes the destination ref.
        PushRefspecs(
            m_pRepo, _RemoteName, {":refs/heads/" + _Branch}, m_CredProvider, m_HostKeyProvider);

        // Drop our stale remote-tracking ref too (best effort).
        ReferencePtr tracking;
        const std::string trackingName = "refs/remotes/" + _RemoteName + "/" + _Branch;
        if (git_reference_lookup(&tracking.m_pP, m_pRepo, trackingName.c_str()) == 0)
        {
            git_reference_delete(tracking.m_pP);
        }
    }

    MergeResult Repository::Pull(const std::string& _RemoteName)
    {
        if (m_pP4)
        {
            return m_pP4->Pull(_RemoteName);
        }

        if (!m_pRepo)
        {
            throw GitError("pull() on an unopened repository");
        }

        Fetch(_RemoteName);

        const std::string branch = CurrentBranch();
        if (branch.empty())
        {
            throw GitError("Cannot pull: no branch is checked out");
        }

        // Merge the branch's upstream when it lives on this remote (it may be
        // named differently), else assume <remote>/<branch>.
        const std::string localRef = "refs/heads/" + branch;
        std::string remoteBranch = branch;
        if (UpstreamRemoteOf(m_pRepo, localRef.c_str()) == _RemoteName)
        {
            const std::string upstreamBranch = UpstreamBranchOf(m_pRepo, localRef.c_str());
            if (!upstreamBranch.empty())
            {
                remoteBranch = upstreamBranch;
            }
        }
        const std::string upstreamShorthand = _RemoteName + "/" + remoteBranch;
        return MergeRef("refs/remotes/" + upstreamShorthand, upstreamShorthand);
    }

    Repository Repository::Clone(const std::string& _Url, const std::string& _Path,
        CredentialProvider _Provider, HostKeyProvider _HostKeys)
    {
        RemoteContext ctx;
        ctx.m_pProvider = &_Provider;
        ctx.m_pHostKeys = &_HostKeys;
        git_clone_options opts = GIT_CLONE_OPTIONS_INIT;
        SetupRemoteCallbacks(opts.fetch_opts.callbacks, ctx);

        Repository r;
        if (git_clone(&r.m_pRepo, _Url.c_str(), _Path.c_str(), &opts) < 0)
        {
            RaiseLastError("Clone of '" + _Url + "' failed");
        }
        r.m_Path = _Path;
        r.m_CredProvider = std::move(_Provider);
        r.m_HostKeyProvider = std::move(_HostKeys);
        return r;
    }

} // namespace gitgud::git
