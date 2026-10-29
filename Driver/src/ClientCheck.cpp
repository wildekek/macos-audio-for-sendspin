// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0

#include "ClientCheck.hpp"

#include <os/log.h>

#include <algorithm>
#include <cstring>
#include <iterator>
#include <optional>

// Asks the kernel about a process's code signature. Not in the SDK headers (it's in xnu's
// sys/codesign.h), but exported by libSystem. The Security framework's own checks can't
// run in the driver's sandbox; this needs no file access, and it's the signature the
// kernel enforces for that process.
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace sendspin {

namespace {

constexpr unsigned int CsOpsStatus = 0;
constexpr unsigned int CsOpsCDHash = 5;
constexpr unsigned int CsOpsIdentity = 11;
constexpr unsigned int CsOpsTeamID = 14;
constexpr uint32_t CsValid = 0x00000001;
constexpr uint32_t CsAdhoc = 0x00000002;
constexpr uint32_t CsLinkerSigned = 0x00020000;

constexpr const char* AllowedIdentifiers[] = {
    "com.sendspin-audio.mac",
    "com.sendspin-audio.mac.dev",
    "sendspin-bridge",
};

os_log_t Log()
{
    static os_log_t log = os_log_create("com.sendspin-audio.mac.driver", "ClientCheck");
    return log;
}

// Most verdicts kept; a client's checked again once they're cleared.
constexpr size_t MaxVerdicts = 64;

// How this driver is signed. Only its own signature can say ad hoc: anything that can't be
// read leaves both unset, and nobody gets the audio.
ClientCheck::Signature DriverSignature(CFBundleRef driverBundle)
{
    CFURLRef url = driverBundle ? CFBundleCopyBundleURL(driverBundle) : nullptr;
    if (!url) {
        return {};
    }
    SecStaticCodeRef code = nullptr;
    OSStatus status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    CFRelease(url);
    if (status != errSecSuccess) {
        os_log_error(Log(), "can't read the driver's signature (%d)", int(status));
        return {};
    }
    CFDictionaryRef info = nullptr;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    CFRelease(code);
    if (status != errSecSuccess || !info) {
        os_log_error(Log(), "can't read the driver's signing information (%d)", int(status));
        return {};
    }
    ClientCheck::Signature signature;
    char buffer[64] = {};
    auto team = static_cast<CFStringRef>(CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier));
    if (team && CFStringGetCString(team, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        signature.team = buffer;
    }
    uint32_t flags = 0;
    auto flagsNumber = static_cast<CFNumberRef>(CFDictionaryGetValue(info, kSecCodeInfoFlags));
    if (signature.team.empty() && flagsNumber && CFNumberGetValue(flagsNumber, kCFNumberSInt32Type, &flags)) {
        signature.adHoc = flags & kSecCodeSignatureAdhoc;
    }
    CFRelease(info);
    return signature;
}

// A string the kernel returns for csops: an 8-byte blob header, then the text.
std::string KernelString(pid_t pid, unsigned int op)
{
    struct {
        uint32_t magic;
        uint32_t length;
        char text[256];
    } blob = {};
    if (csops(pid, op, &blob, sizeof(blob)) != 0) {
        return "";
    }
    blob.text[sizeof(blob.text) - 1] = '\0';
    return blob.text;
}

// The hash of the process's code directory, or nothing if the kernel doesn't say.
std::optional<ClientCheck::CodeHash> CodeHashOf(pid_t pid)
{
    ClientCheck::CodeHash hash = {};
    if (csops(pid, CsOpsCDHash, hash.data(), hash.size()) != 0) {
        return std::nullopt;
    }
    return hash;
}

} // namespace

ClientCheck::ClientCheck(CFBundleRef driverBundle)
    : driver_(DriverSignature(driverBundle))
{
    if (!driver_.team.empty()) {
        os_log(Log(), "audio goes to clients signed by team %{public}s", driver_.team.c_str());
    } else if (driver_.adHoc) {
        os_log(Log(), "ad-hoc driver: audio goes to clients by identifier only");
    } else {
        os_log_error(Log(), "unknown driver signature: audio goes to nobody");
    }
}

bool ClientCheck::Allows(pid_t pid)
{
    // Without its code hash a reused PID can't be told apart, so such a verdict isn't kept.
    const auto codeHash = CodeHashOf(pid);
    std::lock_guard<std::mutex> lock(mutex_);
    if (auto it = verdicts_.find(pid); codeHash && it != verdicts_.end() && it->second.codeHash == *codeHash) {
        return it->second.allowed;
    }

    uint32_t flags = 0;
    const bool valid = csops(pid, CsOpsStatus, &flags, sizeof(flags)) == 0 && (flags & CsValid);
    const std::string identifier = KernelString(pid, CsOpsIdentity);
    const std::string team = KernelString(pid, CsOpsTeamID);
    bool allowed = valid
        && std::any_of(std::begin(AllowedIdentifiers), std::end(AllowedIdentifiers),
            [&](const char* allowedIdentifier) { return identifier == allowedIdentifier; });
    if (!driver_.team.empty()) {
        // An ad-hoc signature can claim any identifier; a team's certificate can't be faked.
        allowed = allowed && team == driver_.team && !(flags & (CsAdhoc | CsLinkerSigned));
    } else if (!driver_.adHoc) {
        allowed = false;
    }

    if (allowed) {
        os_log(Log(), "audio allowed to %{public}s (pid %d)", identifier.c_str(), int(pid));
    } else {
        os_log_error(Log(), "audio refused to %{public}s (pid %d, team %{public}s, flags 0x%x)",
            identifier.c_str(), int(pid), team.c_str(), flags);
    }
    if (codeHash) {
        if (verdicts_.size() >= MaxVerdicts) {
            verdicts_.clear();
        }
        verdicts_[pid] = Verdict{*codeHash, allowed};
    }
    return allowed;
}

} // namespace sendspin
