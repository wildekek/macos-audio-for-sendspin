// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0

#pragma once

#include <Security/Security.h>

#include <array>
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
// can only go by the client's identifier. When the driver can't tell how it's signed itself,
// it refuses everyone: the check fails closed.
class ClientCheck
{
public:
    explicit ClientCheck(CFBundleRef driverBundle);

    bool Allows(pid_t pid);

    // How this driver is signed. Neither a team nor ad hoc: its signature couldn't be read.
    struct Signature {
        std::string team;
        bool adHoc = false;
    };

    // The hash of the client's code directory, as the kernel has it: a reused PID, or a
    // process that exec'd another program, has another one. (Its start time would do too, but
    // the driver's sandbox doesn't let it read that.)
    using CodeHash = std::array<uint8_t, 20>;

private:
    struct Verdict {
        CodeHash codeHash;
        bool allowed;
    };

    const Signature driver_;
    std::mutex mutex_;
    std::map<pid_t, Verdict> verdicts_;
};

} // namespace sendspin
