// The macOS Keychain credential store, under a service name of its own
// ("GitGud tests", never the app's "GitGud") so the user's real saved
// passwords are never read or replaced. Every item it adds is deleted.

#include <catch2/catch_test_macros.hpp>

#include "platform/ICredentialStore.h"

using namespace gitgud::platform;

TEST_CASE("Keychain store saves, replaces and erases a credential", "[keychain]")
{
    const auto store = MakeKeychainStore("GitGud tests");
    REQUIRE(store);
    const std::string host = "keychain-test.gitgud.invalid";
    store->Erase(host); // a leftover from an interrupted run

    Credential found;
    CHECK_FALSE(store->Get(host, found));

    REQUIRE(store->Set(host, {"alice", "first secret"}));
    REQUIRE(store->Get(host, found));
    CHECK(found.m_Username == "alice");
    CHECK(found.m_Password == "first secret");

    // A second Set replaces the item; a password may hold a line break.
    REQUIRE(store->Set(host, {"bob", "second\nsecret"}));
    REQUIRE(store->Get(host, found));
    CHECK(found.m_Username == "bob");
    CHECK(found.m_Password == "second\nsecret");

    CHECK(store->Erase(host));
    CHECK_FALSE(store->Get(host, found));
    CHECK_FALSE(store->Erase(host));
}
