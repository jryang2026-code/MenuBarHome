#!/usr/bin/env bash
# Print a usable go binary, or a one-line skip reason on stderr and exit 2.
# A directory, a non-file, or a stub whose `version` fails is not usable.
set -euo pipefail

if command -v go >/dev/null 2>&1; then
    candidate="$(command -v go)"
else
    candidate="${GO2RTC_PTZ_GO_CACHE:-$HOME/.cache/menubarmijia/go1.26.10}/go/bin/go"
fi

if [ ! -e "$candidate" ]; then
    echo "未找到 go" >&2
    exit 2
fi
if [ -d "$candidate" ] || [ ! -f "$candidate" ]; then
    echo "go 不是普通可执行文件" >&2
    exit 2
fi
if [ ! -x "$candidate" ]; then
    echo "go 不可执行" >&2
    exit 2
fi
# macOS has no GNU timeout. The alarm lives in perl, and the child is its own
# process group so a hang (and any process it starts) is killed at the deadline.
version_status=0
perl -e '
use strict;
my $sec = shift @ARGV;
my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    setpgrp(0, 0);
    exec @ARGV;
    exit 127;
}
local $SIG{ALRM} = sub {
    kill "KILL", -$pid;
    waitpid($pid, 0);
    exit 124;
};
local $SIG{INT} = local $SIG{TERM} = sub {
    kill "KILL", -$pid;
    waitpid($pid, 0);
    exit 130;
};
alarm $sec;
waitpid($pid, 0);
alarm 0;
my $status = $?;
exit 0 if $status == 0;
exit($status >> 8) if ($status & 127) == 0;
exit(128 + ($status & 127));
' "${GO2RTC_VERSION_TIMEOUT:-5}" "$candidate" version >/dev/null 2>&1 || version_status=$?
if [ "$version_status" -ne 0 ]; then
    if [ "$version_status" -eq 124 ]; then
        echo "go version 超时" >&2
    else
        echo "go version 失败" >&2
    fi
    exit 2
fi
printf '%s\n' "$candidate"
