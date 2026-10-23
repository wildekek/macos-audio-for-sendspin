// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0

#pragma once

#include <Security/Security.h>

#include <cstdint>
#include <map>
#include <mutex>
#include <string>

namespace sendspin {

// Decides which processes may read the audio played to the device: only the macOS Audio
// for Sendspin app (release or dev build) and the sendspin-bridge tool. Anyone else would
// otherwise record it without any permission prompt.
//
// The kernel's record of the client's signature decides. When this driver is signed with a
// team (Developer ID), a client must be signed by the same team; an ad-hoc signed driver
// can only go by the client's identifier.
class ClientCheck
{
public:
    explicit ClientCheck(CFBundleRef driverBundle);

    bool Allows(pid_t pid);

private:
    struct Verdict {
        uint64_t startTime; // tells a reused PID from the process that was checked
        bool allowed;
    };

    const std::string team_;
    std::mutex mutex_;
    std::map<pid_t, Verdict> verdicts_;
};

} // namespace sendspin
