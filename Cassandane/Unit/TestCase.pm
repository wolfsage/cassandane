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

package Cassandane::Unit::TestCase;
use strict;
use warnings;

use base qw(Test::Unit::TestCase);
use Data::Dumper;

use lib '.';
use Cassandane::Util::Log;

my $enabled;
my $buildinfo;

sub new
{
    my $class = shift;
    if (not $buildinfo) {
        $buildinfo = Cassandane::BuildInfo->new();
    }
    return $class->SUPER::new(@_);
}

sub enable_test
{
    my ($class, $test) = @_;
    $enabled = $test;
}

sub _skip_version
{
    my ($str) = @_;

    return if not $str =~ m/^(min|max)_version_([\d_]+)$/;
    my $minmax = $1;
    my ($lim_major, $lim_minor, $lim_revision, $lim_commits)
        = map { 0 + $_ } split /_/, $2;
    return if not defined $lim_major;

    my ($major, $minor, $revision, $commits) = Cassandane::Instance->get_version();

    if ($minmax eq 'min') {
        return 1 if $major < $lim_major; # too old, skip!
        return if $major > $lim_major;   # definitely new enough

        return if not defined $lim_minor; # don't check deeper if caller doesn't care
        return 1 if $minor < $lim_minor;
        return if $minor > $lim_minor;

        return if not defined $lim_revision;
        return 1 if $revision < $lim_revision;

        return if not defined $lim_commits;
        return 1 if $commits < $lim_commits;
    }
    else {
        return 1 if $major > $lim_major; # too new, skip!
        return if $major < $lim_major;   # definitely old enough

        return if not defined $lim_minor; # don't check deeper if caller doesn't care
        return 1 if $minor > $lim_minor;
        return if $minor < $lim_minor;

        return if not defined $lim_revision;
        return 1 if $revision > $lim_revision;

        return if not defined $lim_commits;
        return 1 if $commits > $lim_commits;
    }

    return;
}

sub filter
{
    my ($self) = @_;
    return
    {
        x => sub
        {
            my $method = shift;
            $method =~ s/^test_//;
            # Only the explicitly enabled test runs
            return ($enabled eq $method ? undef : 1);
        },
        skip_version => sub
        {
            return if not exists $self->{_name};
            my $sub = $self->can($self->{_name});
            return if not defined $sub;
            foreach my $attr (attributes::get($sub)) {
                next if $attr !~ m/^(?:min|max)_version_[\d_]+$/;
                return 1 if _skip_version($attr);
            }
            return;
        },
        skip_missing_features => sub
        {
            return if not exists $self->{_name};
            my $sub = $self->can($self->{_name});
            return if not defined $sub;
            foreach my $attr (attributes::get($sub)) {
                next if $attr !~ m/^needs_(\w+)_([\w_]+)$/;
                if (not $buildinfo->get($1, $2)) {
                    xlog "$1.$2 not enabled, $self->{_name} will be skipped";
                    return 1;
                }
            }
            return;
        }
    };
}

sub annotate_from_file
{
    my ($self, $filename) = @_;
    return if !defined $filename;

    open LOG, '<', $filename
        or die "Cannot open $filename for reading: $!";
    while (<LOG>)
    {
        $self->annotate($_);
    }
    close LOG;
}

my @params;

sub parameter
{
    my ($ref, @values) = @_;

    return if (!scalar(@values));

    my $param = {
        id => scalar(@params),
        package => caller,
        values => \@values,
        maxvidx => scalar(@values)-1,
        reference => $ref,
    };
    push(@params, $param);

#     xlog "XXX registering parameter id $param->{id} in package $param->{package}";
}

sub _describe_setting
{
    my ($setting) = @_;
    $setting ||= [];

    my @parts;
    my @ss = ( @$setting );
    while (scalar @ss)
    {
        my $id = shift @ss;
        my $value = $params[$id]->{values}->[shift @ss];
        push(@parts, "$id:\"$value\"");
    }
    return '[' . join(' ', @parts) . ']';
}

sub make_parameter_settings
{
    my ($class, $package) = @_;

#     xlog "XXX making parameter settings for package $package";

    my @settings;
    my @stack;
    foreach my $param (grep { $_->{package} eq $package } @params)
    {
        push(@stack, { param => $param, vidx => 0 });
    }
    return [] if !scalar(@stack);

    SETTING: while (1)
    {
        # save a setting
        my $setting = [ map { $_->{param}->{id}, $_->{vidx} } @stack ];
#       xlog "XXX making setting " . _describe_setting($setting);
        push(@settings, $setting);
        # increment indexes, wrapping and overflowing
        foreach my $s (@stack)
        {
            $s->{vidx}++;
            if ($s->{vidx} > $s->{param}->{maxvidx})
            {
                $s->{vidx} = 0;
            }
            else
            {
                next SETTING;
            }
        }
        last;
    }

    return @settings;
}

sub apply_parameter_setting
{
    my ($class, $setting) = @_;

#     xlog "XXX applying setting " . _describe_setting($setting);

    foreach my $param (@params)
    {
        ${$param->{reference}} = undef;
    }

    my @ss = ( @$setting );
    while (scalar @ss)
    {
        my $param = $params[shift @ss];
        my $value = $param->{values}->[shift @ss];
#       xlog "XXX setting parameter id $param->{id} to value \"$value\"";
        ${$param->{reference}} = $value;
    }
}

1;
