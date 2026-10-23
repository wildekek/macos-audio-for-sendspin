// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0

#include "ClientCheck.hpp"

#include <libproc.h>
#include <os/log.h>

#include <algorithm>
#include <cstring>
#include <iterator>

// Asks the kernel about a process's code signature. Not in the SDK headers (it's in xnu's
// sys/codesign.h), but exported by libSystem. The Security framework's own checks can't
// run in the driver's sandbox; this needs no file access, and it's the signature the
// kernel enforces for that process.
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace sendspin {

namespace {

constexpr unsigned int CsOpsStatus = 0;
constexpr unsigned int CsOpsIdentity = 11;
constexpr unsigned int CsOpsTeamID = 14;
constexpr uint32_t CsValid = 0x00000001;
constexpr uint32_t CsAdhoc = 0x00000002;
constexpr uint32_t CsLinkerSigned = 0x00020000;

constexpr const char* AllowedIdentifiers[] = {
    "eu.vooijs.MacOSAudioForSendspin",
    "eu.vooijs.MacOSAudioForSendspin.dev",
    "sendspin-bridge",
};

os_log_t Log()
{
    static os_log_t log = os_log_create("eu.vooijs.MacOSAudioForSendspin.Driver", "ClientCheck");
    return log;
}

// The team that signed this driver; empty when it's signed ad hoc.
std::string TeamID(CFBundleRef driverBundle)
{
    CFURLRef url = driverBundle ? CFBundleCopyBundleURL(driverBundle) : nullptr;
    if (!url) {
        return "";
    }
    SecStaticCodeRef code = nullptr;
    OSStatus status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    CFRelease(url);
    if (status != errSecSuccess) {
        os_log_error(Log(), "can't read the driver's signature (%d)", int(status));
        return "";
    }
    CFDictionaryRef info = nullptr;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    CFRelease(code);
    if (status != errSecSuccess || !info) {
        return "";
    }
    char buffer[64] = {};
    auto team = static_cast<CFStringRef>(CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier));
    const bool ok = team && CFStringGetCString(team, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(info);
    return ok ? buffer : "";
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

// When the process started, or 0 if that can't be read.
uint64_t StartTime(pid_t pid)
{
    proc_bsdinfo info = {};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
        return 0;
    }
    return info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
}

} // namespace

ClientCheck::ClientCheck(CFBundleRef driverBundle)
    : team_(TeamID(driverBundle))
{
    if (team_.empty()) {
        os_log(Log(), "ad-hoc driver: audio goes to clients by identifier only");
    } else {
        os_log(Log(), "audio goes to clients signed by team %{public}s", team_.c_str());
    }
}

bool ClientCheck::Allows(pid_t pid)
{
    const uint64_t startTime = StartTime(pid);
    std::lock_guard<std::mutex> lock(mutex_);
    if (auto it = verdicts_.find(pid); it != verdicts_.end() && it->second.startTime == startTime) {
        return it->second.allowed;
    }

    uint32_t flags = 0;
    const bool valid = csops(pid, CsOpsStatus, &flags, sizeof(flags)) == 0 && (flags & CsValid);
    const std::string identifier = KernelString(pid, CsOpsIdentity);
    const std::string team = KernelString(pid, CsOpsTeamID);
    bool allowed = valid
        && std::any_of(std::begin(AllowedIdentifiers), std::end(AllowedIdentifiers),
            [&](const char* allowedIdentifier) { return identifier == allowedIdentifier; });
    if (!team_.empty()) {
        // An ad-hoc signature can claim any identifier; a team's certificate can't be faked.
        allowed = allowed && team == team_ && !(flags & (CsAdhoc | CsLinkerSigned));
    }

    if (allowed) {
        os_log(Log(), "audio allowed to %{public}s (pid %d)", identifier.c_str(), int(pid));
    } else {
        os_log_error(Log(), "audio refused to %{public}s (pid %d, team %{public}s, flags 0x%x)",
            identifier.c_str(), int(pid), team.c_str(), flags);
    }
    verdicts_[pid] = Verdict{startTime, allowed};
    return allowed;
}

} // namespace sendspin
