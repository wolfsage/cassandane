#!/usr/bin/env perl
#
#  Copyright (c) 2011-2017 FastMail Pty Ltd. All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in
#     the documentation and/or other materials provided with the
#     distribution.
#
#  3. The name "Fastmail Pty Ltd" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
#      FastMail Pty Ltd
#      PO Box 234
#      Collins St West 8007
#      Victoria
#      Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Fastmail Pty. Ltd."
#
#  FASTMAIL PTY LTD DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
#  INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY  AND FITNESS, IN NO
#  EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE FOR ANY SPECIAL, INDIRECT
#  OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
#  USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
#  TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
#  OF THIS SOFTWARE.
#

package Cassandane::Util::Wait;
use strict;
use warnings;
use base qw(Exporter);
use Time::HiRes qw(sleep gettimeofday tv_interval);

use lib '.';
use Cassandane::Util::Log;

our @EXPORT = qw(&timed_wait);

sub timed_wait
{
    my ($condition, %p) = @_;
    $p{delay} = 0.010           # 10 millisec
        unless defined $p{delay};
    $p{maxwait} = 20.0
        unless defined $p{maxwait};
    $p{description} = 'unknown condition'
        unless defined $p{description};

    my $start = [gettimeofday()];
    my $delayed = 0;
    while ( ! $condition->() )
    {
        die "Timed out waiting for " . $p{description}
            if (tv_interval($start, [gettimeofday()]) > $p{maxwait});
        sleep($p{delay});
        $delayed = 1;
        $p{delay} *= 1.5;       # backoff
    }

    if ($delayed)
    {
        my $t = tv_interval($start, [gettimeofday()]);
        xlog "Waited $t sec for " . $p{description};
        return $t;
    }
    return 0.0;
}


1;
