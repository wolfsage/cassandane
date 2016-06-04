#!/usr/bin/perl
#
#  Copyright (c) 2011 Opera Software Australia Pty. Ltd.  All rights
#  reserved.
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
#  3. The name "Opera Software Australia" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
# 	Opera Software Australia Pty. Ltd.
# 	Level 50, 120 Collins St
# 	Melbourne 3000
# 	Victoria
# 	Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Opera Software
#     Australia Pty. Ltd."
#
#  OPERA SOFTWARE AUSTRALIA DISCLAIMS ALL WARRANTIES WITH REGARD TO
#  THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
#  AND FITNESS, IN NO EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE
#  FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
#  AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
#  OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

use strict;
use warnings;
package Cassandane::Cyrus::Archive;
use base qw(Cassandane::Cyrus::TestCase);
use DateTime;
use Cassandane::Util::Log;
use Cassandane::Util::Words;
use Data::Dumper;

sub new
{
    my $class = shift;
    return $class->SUPER::new({}, @_);
}

sub set_up
{
    my ($self) = @_;
    $self->SUPER::set_up();
}

sub tear_down
{
    my ($self) = @_;
    $self->SUPER::tear_down();
}

Cassandane::Cyrus::TestCase::magic(ArchivePartition => sub {
    my $conf = shift;
    $conf->config_set('archivepartition-default' => '@basedir@/archive');
    $conf->config_set('archive_enabled' => 'yes');
    $conf->config_set('archive_days' => '7');
});

Cassandane::Cyrus::TestCase::magic(ArchiveNow => sub {
    my $conf = shift;
    $conf->config_set('archivepartition-default' => '@basedir@/archive');
    $conf->config_set('archive_enabled' => 'yes');
    $conf->config_set('archive_days' => '0');
});

#
# Test that
#  - cyr_expire archives messages
#  - once archived, messages are in the new path
#  - the message is gone from the old path
#  - XXX: hard to test - that there's no possible race in which the message
#    isn't available to clients during the archive operation
#
sub test_archive_messages
    :ArchivePartition
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();
    $self->{store}->_select();
    $self->assert_num_equals(1, $talk->uid());
    $self->{store}->set_fetch_attributes(qw(uid flags));

    xlog "Append 3 messages";
    my %msg;
    $msg{A} = $self->make_message('Message A');
    $msg{A}->set_attributes(id => 1,
			    uid => 1,
			    flags => []);
    $msg{B} = $self->make_message('Message B');
    $msg{B}->set_attributes(id => 2,
			    uid => 2,
			    flags => []);
    $msg{C} = $self->make_message('Message C');
    $msg{C}->set_attributes(id => 3,
			    uid => 3,
			    flags => []);
    $self->check_messages(\%msg);

    my $basedir = $self->{instance}->{basedir};

    -f "$basedir/data/user/cassandane/1." || die;
    -f "$basedir/data/user/cassandane/2." || die;
    -f "$basedir/data/user/cassandane/3." || die;

    -f "$basedir/archive/user/cassandane/1." && die;
    -f "$basedir/archive/user/cassandane/2." && die;
    -f "$basedir/archive/user/cassandane/3." && die;

    xlog "Run cyr_expire but no messages should move";
    $self->{instance}->run_command({ cyrus => 1 }, 'cyr_expire', '-A' => '7d' );

    -f "$basedir/data/user/cassandane/1." || die;
    -f "$basedir/data/user/cassandane/2." || die;
    -f "$basedir/data/user/cassandane/3." || die;

    -f "$basedir/archive/user/cassandane/1." && die;
    -f "$basedir/archive/user/cassandane/2." && die;
    -f "$basedir/archive/user/cassandane/3." && die;

    xlog "Run cyr_expire to archive now";
    $self->{instance}->run_command({ cyrus => 1 }, 'cyr_expire', '-A' => '0' );

    -f "$basedir/data/user/cassandane/1." && die;
    -f "$basedir/data/user/cassandane/2." && die;
    -f "$basedir/data/user/cassandane/3." && die;

    -f "$basedir/archive/user/cassandane/1." || die;
    -f "$basedir/archive/user/cassandane/2." || die;
    -f "$basedir/archive/user/cassandane/3." || die;
}

sub test_archivenow_messages
    :ArchiveNow
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();
    $self->{store}->_select();
    $self->assert_num_equals(1, $talk->uid());
    $self->{store}->set_fetch_attributes(qw(uid flags));

    xlog "Append 3 messages";
    my %msg;
    $msg{A} = $self->make_message('Message A');
    $msg{A}->set_attributes(id => 1,
			    uid => 1,
			    flags => []);
    $msg{B} = $self->make_message('Message B');
    $msg{B}->set_attributes(id => 2,
			    uid => 2,
			    flags => []);
    $msg{C} = $self->make_message('Message C');
    $msg{C}->set_attributes(id => 3,
			    uid => 3,
			    flags => []);
    $self->check_messages(\%msg);

    my $basedir = $self->{instance}->{basedir};

    # already archived
    -f "$basedir/data/user/cassandane/1." && die;
    -f "$basedir/data/user/cassandane/2." && die;
    -f "$basedir/data/user/cassandane/3." && die;

    -f "$basedir/archive/user/cassandane/1." || die;
    -f "$basedir/archive/user/cassandane/2." || die;
    -f "$basedir/archive/user/cassandane/3." || die;

    xlog "Run cyr_expire with old and messages stay archived";
    $self->{instance}->run_command({ cyrus => 1 }, 'cyr_expire', '-A' => '7d' );

    -f "$basedir/data/user/cassandane/1." && die;
    -f "$basedir/data/user/cassandane/2." && die;
    -f "$basedir/data/user/cassandane/3." && die;

    -f "$basedir/archive/user/cassandane/1." || die;
    -f "$basedir/archive/user/cassandane/2." || die;
    -f "$basedir/archive/user/cassandane/3." || die;

    xlog "Run cyr_expire to archive now and messages stay archived";
    $self->{instance}->run_command({ cyrus => 1 }, 'cyr_expire', '-A' => '0' );

    -f "$basedir/data/user/cassandane/1." && die;
    -f "$basedir/data/user/cassandane/2." && die;
    -f "$basedir/data/user/cassandane/3." && die;

    -f "$basedir/archive/user/cassandane/1." || die;
    -f "$basedir/archive/user/cassandane/2." || die;
    -f "$basedir/archive/user/cassandane/3." || die;
}

1;