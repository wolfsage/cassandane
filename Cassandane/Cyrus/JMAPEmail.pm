#!/usr/bin/env perl
#
#  Copyright (c) 2017 FastMail Pty Ltd  All rights reserved.
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
#  FASTMAIL PTY LTD DISCLAIMS ALL WARRANTIES WITH REGARD TO
#  THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
#  AND FITNESS, IN NO EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE
#  FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
#  AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
#  OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

package Cassandane::Cyrus::JMAPEmail;
use strict;
use warnings;
use DateTime;
use JSON::XS;
use Net::CalDAVTalk 0.09;
use Net::CardDAVTalk 0.03;
use Mail::JMAPTalk 0.12;
use Data::Dumper;
use Storable 'dclone';
use MIME::Base64 qw(encode_base64);
use Cwd qw(abs_path getcwd);

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;

use charnames ':full';

sub new
{
    my ($class, @args) = @_;

    my $config = Cassandane::Config->default()->clone();
    $config->set(caldav_realm => 'Cassandane',
                 conversations => 'yes',
                 conversations_counted_flags => "\\Draft \\Flagged \$IsMailingList \$IsNotification \$HasAttachment",
                 httpmodules => 'carddav caldav jmap',
                 httpallowcompress => 'no');

    return $class->SUPER::new({
        config => $config,
        jmap => 1,
        adminstore => 1,
        services => [ 'imap', 'http' ]
    }, @args);
}

sub getinbox
{
    my ($self, $args) = @_;

    $args = {} unless $args;

    my $jmap = $self->{jmap};

    xlog "get existing mailboxes";
    my $res = $jmap->CallMethods([['Mailbox/get', $args, "R1"]]);
    $self->assert_not_null($res);

    my %m = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    return $m{"Inbox"};
}

sub get_settings
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};

    my $Request;
    my $Response;

    xlog "get settings";
    $Request = {
        headers => {
            'Authorization' => $jmap->auth_header(),
        },
        content => '',
    };
    $Response = $jmap->ua->get($jmap->uri(), $Request);
    if ($ENV{DEBUGJMAP}) {
        warn "JMAP " . Dumper($Request, $Response);
    }
    $self->assert_str_equals('200', $Response->{status});

    my $settings;
    $settings = eval { decode_json($Response->{content}) } if $Response->{success};
    return $settings;
}


sub defaultprops_for_email_get
{
    return ( "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt", "messageId", "inReplyTo", "references", "sender", "from", "to", "cc", "bcc", "replyTo", "subject", "sentAt", "hasAttachment", "preview", "bodyValues", "textBody", "htmlBody", "attachments" );
}

sub test_email_get
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    my $body = "";
    $body .= "Lorem ipsum dolor sit amet, consectetur adipiscing\r\n";
    $body .= "elit. Nunc in fermentum nibh. Vivamus enim metus.";

    my $maildate = DateTime->now();
    $maildate->add(DateTime::Duration->new(seconds => -10));

    xlog "Generate a email in INBOX via IMAP";
    my %exp_inbox;
    my %params = (
        date => $maildate,
        from => Cassandane::Address->new(
            name => "Sally Sender",
            localpart => "sally",
            domain => "local"
        ),
        to => Cassandane::Address->new(
            name => "Tom To",
            localpart => 'tom',
            domain => 'local'
        ),
        cc => Cassandane::Address->new(
            name => "Cindy CeeCee",
            localpart => 'cindy',
            domain => 'local'
        ),
        bcc => Cassandane::Address->new(
            name => "Benny CarbonCopy",
            localpart => 'benny',
            domain => 'local'
        ),
        messageid => 'fake.123456789@local',
        extra_headers => [
            ['x-tra', "foo bar\r\n baz"],
            ['sender', "Bla <blu\@local>"],
        ],
        body => $body
    );
    $self->make_message("Email A", %params) || die;

    xlog "get email list";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    $self->assert_num_equals(scalar @{$res->[0][1]->{ids}}, 1);

    my @props = $self->defaultprops_for_email_get();

    push @props, "header:x-tra";

    xlog "get emails";
    my $ids = $res->[0][1]->{ids};
    $res = $jmap->CallMethods([['Email/get', { ids => $ids, properties => \@props }, "R1"]]);
    my $msg = $res->[0][1]->{list}[0];

    $self->assert_not_null($msg->{mailboxIds}{$inboxid});
    $self->assert_num_equals(1, scalar keys %{$msg->{mailboxIds}});
    $self->assert_num_equals(0, scalar keys %{$msg->{keywords}});

    $self->assert_str_equals('fake.123456789@local', $msg->{messageId}[0]);
    $self->assert_str_equals(" foo bar\r\n baz", $msg->{'header:x-tra'});
    $self->assert_deep_equals($msg->{from}[0], {
            name => "Sally Sender",
            email => "sally\@local"
    });
    $self->assert_deep_equals($msg->{to}[0], {
            name => "Tom To",
            email => "tom\@local"
    });
    $self->assert_num_equals(scalar @{$msg->{to}}, 1);
    $self->assert_deep_equals($msg->{cc}[0], {
            name => "Cindy CeeCee",
            email => "cindy\@local"
    });
    $self->assert_num_equals(scalar @{$msg->{cc}}, 1);
    $self->assert_deep_equals($msg->{bcc}[0], {
            name => "Benny CarbonCopy",
            email => "benny\@local"
    });
    $self->assert_num_equals(scalar @{$msg->{bcc}}, 1);
    $self->assert_null($msg->{replyTo});
    $self->assert_deep_equals($msg->{sender}, [{
            name => "Bla",
            email => "blu\@local"
    }]);
    $self->assert_str_equals($msg->{subject}, "Email A");

    my $datestr = $maildate->strftime('%Y-%m-%dT%TZ');
    $self->assert_str_equals($datestr, $msg->{receivedAt});
    $self->assert_not_null($msg->{size});
}

sub test_email_get_mimeencode
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    my $body = "a body";

    my $maildate = DateTime->now();
    $maildate->add(DateTime::Duration->new(seconds => -10));

     # Thanks to http://dogmamix.com/MimeHeadersDecoder/ for examples

    xlog "Generate a email in INBOX via IMAP";
    my %exp_inbox;
    my %params = (
        date => $maildate,
        from => Cassandane::Address->new(
            name => "=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?=",
            localpart => "keld",
            domain => "local"
        ),
        to => Cassandane::Address->new(
            name => "=?US-ASCII?Q?Tom To?=",
            localpart => 'tom',
            domain => 'local'
        ),
        messageid => 'fake.123456789@local',
        extra_headers => [
            ['x-tra', "foo bar\r\n baz"],
            ['sender', "Bla <blu\@local>"],
            ['x-mood', '=?UTF-8?Q?I feel =E2=98=BA?='],
        ],
        body => $body
    );

    $self->make_message(
          "=?ISO-8859-1?B?SWYgeW91IGNhbiByZWFkIHRoaXMgeW8=?= " .
          "=?ISO-8859-2?B?dSB1bmRlcnN0YW5kIHRoZSBleGFtcGxlLg==?=",
    %params ) || die;

    xlog "get email list";
    $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => [ 'subject', 'header:x-mood:asText', 'from', 'to' ],
        }, 'R2'],
    ]);
    $self->assert_num_equals(scalar @{$res->[0][1]->{ids}}, 1);
    my $msg = $res->[1][1]->{list}[0];

    $self->assert_str_equals("If you can read this you understand the example.", $msg->{subject});
    $self->assert_str_equals("I feel \N{WHITE SMILING FACE}", $msg->{'header:x-mood:asText'});
    $self->assert_str_equals("Keld J\N{LATIN SMALL LETTER O WITH STROKE}rn Simonsen", $msg->{from}[0]{name});
    $self->assert_str_equals("Tom To", $msg->{to}[0]{name});
}

sub test_email_get_multimailboxes
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $now = DateTime->now();

    xlog "Generate a email in INBOX via IMAP";
    my $res = $self->make_message("foo") || die;
    my $uid = $res->{attrs}->{uid};
    my $msg;

    xlog "get email";
    $res = $jmap->CallMethods([
        ['Email/query', {}, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' } }, 'R2'],
    ]);
    $msg = $res->[1][1]{list}[0];
    $self->assert_num_equals(1, scalar @{$res->[0][1]{ids}});
    $self->assert_num_equals(1, scalar keys %{$msg->{mailboxIds}});

    xlog "Create target mailbox";
    $talk->create("INBOX.target");

    xlog "Copy email into INBOX.target";
    $talk->copy($uid, "INBOX.target");

    xlog "get email";
    $res = $jmap->CallMethods([
        ['Email/query', {}, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' } }, 'R2'],
    ]);
    $msg = $res->[1][1]{list}[0];
    $self->assert_num_equals(1, scalar @{$res->[0][1]{ids}});
    $self->assert_num_equals(2, scalar keys %{$msg->{mailboxIds}});
}

sub test_email_get_body_both
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $htmlBody = "<html><body><p>This is the html part.</p></body></html>";
    my $textBody = "This is the plain text part.";

    my $body = "--047d7b33dd729737fe04d3bde348\r\n";
    $body .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $body .= "\r\n";
    $body .= $textBody;
    $body .= "\r\n";
    $body .= "--047d7b33dd729737fe04d3bde348\r\n";
    $body .= "Content-Type: text/html;charset=\"UTF-8\"\r\n";
    $body .= "\r\n";
    $body .= $htmlBody;
    $body .= "\r\n";
    $body .= "--047d7b33dd729737fe04d3bde348--\r\n";
    $exp_sub{A} = $self->make_message("foo",
        mime_type => "multipart/alternative",
        mime_boundary => "047d7b33dd729737fe04d3bde348",
        body => $body
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids, fetchAllBodyValues => JSON::true }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    my $partId = $msg->{textBody}[0]{partId};
    $self->assert_str_equals($textBody, $msg->{bodyValues}{$partId}{value});
    $partId = $msg->{htmlBody}[0]{partId};
    $self->assert_str_equals($htmlBody, $msg->{bodyValues}{$partId}{value});
}

sub test_email_get_body_plain
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $body = "A plain text email.";
    $exp_sub{A} = $self->make_message("foo",
        body => $body
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get emails";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids, fetchAllBodyValues => JSON::true,  }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    my $partId = $msg->{textBody}[0]{partId};
    $self->assert_str_equals($body, $msg->{bodyValues}{$partId}{value});
    $self->assert_str_equals($msg->{textBody}[0]{partId}, $msg->{htmlBody}[0]{partId});
}

sub test_email_get_body_html
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $body = "<html><body> <p>A HTML email.</p> </body></html>";
    $exp_sub{A} = $self->make_message("foo",
        mime_type => "text/html",
        body => $body
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids, fetchAllBodyValues => JSON::true }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    my $partId = $msg->{htmlBody}[0]{partId};
    $self->assert_str_equals($body, $msg->{bodyValues}{$partId}{value});
}

sub test_email_get_attachment_name
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $body = "".
    "--sub\r\n".
    "Content-Type: image/jpeg\r\n".
    "Content-Disposition: attachment; filename\r\n\t=\"image1.jpg\"\r\n".
    "Content-Transfer-Encoding: base64\r\n".
    "\r\n" .
    "beefc0de".
    "\r\n--sub\r\n".
    "Content-Type: image/tiff\r\n".
    "Content-Transfer-Encoding: base64\r\n".
    "\r\n" .
    "abc=".
    "\r\n--sub\r\n".
    "Content-Type: application/x-excel\r\n".
    "Content-Transfer-Encoding: base64\r\n".
    "Content-Disposition: attachment; filename\r\n\t=\"f.xls\"\r\n".
    "\r\n" .
    "012312312313".
    "\r\n--sub\r\n".
    "Content-Type: application/foo;name=y.dat\r\n".
    "Content-Disposition: attachment; filename=z.dat\r\n".
    "\r\n" .
    "foo".
    "\r\n--sub\r\n".
    "Content-Type: application/bar;name*0=looo;name*1=ooong;name*2=.name\r\n".
    "\r\n" .
    "bar".
    "\r\n--sub\r\n".
    "Content-Type: application/baz\r\n".
    "Content-Disposition: attachment; filename*0=cont;\r\n filename*1=inue\r\n".
    "\r\n" .
    "baz".
    "\r\n--sub\r\n".
    "Content-Type: application/bam; name=\"=?utf-8?Q?=F0=9F=98=80=2Etxt?=\"\r\n".
    "\r\n" .
    "bam".
    "\r\n--sub\r\n".
    "Content-Type: application/tux\r\n".
    "Content-Disposition: attachment; filename*0*=utf-8''%F0%9F%98%80;\r\n filename*1=\".txt\"\r\n".
    "\r\n" .
    "baz".
    "\r\n--sub\r\n".
    "Content-Disposition: attachment;\r\n".
    " filename*0*=\"Unencoded ' char\";\r\n" .
    " filename*1*=\".txt\"\r\n" .
    "Content-Type: application/bla\r\n" .
    "\r\n" .
    "bla".
    "\r\n--sub--\r\n";

    $exp_sub{A} = $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => $body
    );
    $talk->store('1', '+flags', '($HasAttachment)');

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    $self->assert_equals(JSON::true, $msg->{hasAttachment});

    # Assert embedded email support
    my %m = map { $_->{type} => $_ } @{$msg->{attachments}};
    my $att;

    $att = $m{"image/tiff"};
    $self->assert_null($att->{name});

    $att = $m{"application/x-excel"};
    $self->assert_str_equals("f.xls", $att->{name});

    $att = $m{"image/jpeg"};
    $self->assert_str_equals("image1.jpg", $att->{name});

    $att = $m{"application/foo"};
    $self->assert_str_equals("z.dat", $att->{name});

    $att = $m{"application/bar"};
    $self->assert_str_equals("loooooong.name", $att->{name});

    $att = $m{"application/baz"};
    $self->assert_str_equals("continue", $att->{name});

    $att = $m{"application/bam"};
    $self->assert_str_equals("\N{GRINNING FACE}.txt", $att->{name});

    $att = $m{"application/tux"};
    $self->assert_str_equals("\N{GRINNING FACE}.txt", $att->{name});

    $att = $m{"application/bla"};
    $self->assert_str_equals("Unencoded ' char.txt", $att->{name});
}

sub test_email_get_body_notext
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    # Generate a email to have some blob ids
    xlog "Generate a email in $inbox via IMAP";
    $self->make_message("foo",
        mime_type => "application/zip",
        body => "boguszip",
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' } }, 'R2'],
    ]);
    my $msg = $res->[1][1]->{list}[0];

    $self->assert_deep_equals([], $msg->{textBody});
    $self->assert_deep_equals([], $msg->{htmlBody});
}


sub test_email_get_preview
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $body = "A   plain\r\ntext email.";
    $exp_sub{A} = $self->make_message("foo",
        body => $body
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);

    xlog "get emails";
    $res = $jmap->CallMethods([['Email/get', { ids => $res->[0][1]->{ids} }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    $self->assert_str_equals('A plain text email.', $msg->{preview});
}

sub test_email_get_imagesize
    :min_version_3_1 :needs_component_jmap
{
    # This is a FastMail-extension

    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    $store->set_folder('INBOX');

    # Part 1 has no imagesize defined, part 2 defines no EXIF
    # orientation, part 3 defines all image size properties.
    my $imageSize = {
        '2' => [1,2],
        '3' => [1,2,3],
    };

    # Generate an email with image MIME parts.
    xlog "Generate an email via IMAP";
    my $msg = $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: image/png\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          . "\r\n"
          . "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVQYV2NgYAAAAAMAAWgmWQ0AAAAASUVORK5CYII="
          . "\r\n--sub\r\n"
          . "Content-Type: image/png\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          . "\r\n"
          . "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVQYV2NgYAAAAAMAAWgmWQ0AAAAASUVORK5CYII="
          . "\r\n--sub\r\n"
          . "Content-Type: image/png\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          . "\r\n"
          . "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVQYV2NgYAAAAAMAAWgmWQ0AAAAASUVORK5CYII="
          . "\r\n--sub--\r\n",
    );
    xlog "set imagesize annotation";
    my $annot = '/vendor/messagingengine.com/imagesize';
    my $ret = $talk->store('1', 'annotation', [
        $annot, ['value.shared', { Quote => encode_json($imageSize) }]
    ]);
    if (not $ret) {
        xlog "Could not set $annot annotation. Aborting.";
        return;
    }

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', {
        ids => $ids,
        properties => ['bodyStructure'],
        bodyProperties => ['partId', 'imageSize' ],
    }, "R1"]]);
    my $email = $res->[0][1]{list}[0];

    my $part = $email->{bodyStructure}{subParts}[0];
    $self->assert_str_equals('1', $part->{partId});
    $self->assert_null($part->{imageSize});

    $part = $email->{bodyStructure}{subParts}[1];
    $self->assert_str_equals('2', $part->{partId});
    $self->assert_deep_equals($imageSize->{2}, $part->{imageSize});

    $part = $email->{bodyStructure}{subParts}[2];
    $self->assert_str_equals('3', $part->{partId});
    $self->assert_deep_equals($imageSize->{3}, $part->{imageSize});
}

sub test_email_get_isdeleted
    :min_version_3_1 :needs_component_jmap
{
    # This is a FastMail-extension

    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    $store->set_folder('INBOX');

    my $msg = $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: text/x-me-removed-file\r\n"
          . "\r\n"
          . "deleted"
          . "\r\n--sub--\r\n",
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', {
        ids => $ids,
        properties => ['bodyStructure'],
        bodyProperties => ['partId', 'isDeleted' ],
    }, "R1"]]);
    my $email = $res->[0][1]{list}[0];

    my $part = $email->{bodyStructure}{subParts}[0];
    $self->assert_str_equals('1', $part->{partId});
    $self->assert_equals(JSON::false, $part->{isDeleted});

    $part = $email->{bodyStructure}{subParts}[1];
    $self->assert_str_equals('2', $part->{partId});
    $self->assert_equals(JSON::true, $part->{isDeleted});
}

sub test_email_get_trustedsender
    :min_version_3_1 :needs_component_jmap
{
    # This is a FastMail-extension

    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    $store->set_folder('INBOX');

    my $msg = $self->make_message("foo");

    xlog "Assert trustedSender isn't set";
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => [ 'id', 'trustedSender', 'keywords' ],
        }, 'R2'],
    ]);
    my $emailId = $res->[0][1]{ids}[0];
    my $email = $res->[1][1]{list}[0];
    $self->assert_null($email->{trustedSender});

    xlog "Set IsTrusted flag";
    $talk->store('1', '+flags', '($IsTrusted)');

    xlog "Assert trustedSender isn't set";
    $res = $jmap->CallMethods([['Email/get', {
        ids => [$emailId], properties => [ 'id', 'trustedSender', 'keywords' ],
    }, 'R1']]);
    $email = $res->[0][1]{list}[0];
    $self->assert_null($email->{trustedSender});

    xlog "Set zero-length trusted annotation";
    my $annot = '/vendor/messagingengine.com/trusted';
    my $ret = $talk->store('1', 'annotation', [
        $annot, ['value.shared', { Quote => '' }]
    ]);
    if (not $ret) {
        xlog "Could not set $annot annotation. Aborting.";
        return;
    }

    xlog "Assert trustedSender isn't set";
    $res = $jmap->CallMethods([['Email/get', {
        ids => [$emailId], properties => [ 'id', 'trustedSender', 'keywords' ],
    }, 'R1']]);
    $email = $res->[0][1]{list}[0];
    $self->assert_null($email->{trustedSender});

    xlog "Set trusted annotation";
    $ret = $talk->store('1', 'annotation', [
        $annot, ['value.shared', { Quote => 'bar' }]
    ]);
    if (not $ret) {
        xlog "Could not set $annot annotation. Aborting.";
        return;
    }

    xlog "Assert trustedSender is set";
    $res = $jmap->CallMethods([['Email/get', {
        ids => [$emailId], properties => [ 'id', 'trustedSender', 'keywords' ],
    }, 'R1']]);
    $email = $res->[0][1]{list}[0];
    $self->assert_str_equals('bar', $email->{trustedSender});

    xlog "Remove IsTrusted flag";
    $talk->store('1', '-flags', '($IsTrusted)');

    xlog "Assert trustedSender isn't set";
    $res = $jmap->CallMethods([['Email/get', {
        ids => [$emailId], properties => [ 'id', 'trustedSender', 'keywords' ],
    }, 'R1']]);
    $email = $res->[0][1]{list}[0];
    $self->assert_null($email->{trustedSender});
}

sub test_email_get_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $admintalk = $self->{adminstore}->get_client();

    # Share account
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lr") or die;

    # Create mailbox A
    $admintalk->create("user.other.A") or die;
    $admintalk->setacl("user.other.A", "cassandane", "lr") or die;

    # Create message in mailbox A
    $self->{adminstore}->set_folder('user.other.A');
    $self->make_message("Email", store => $self->{adminstore}) or die;

    # Copy message to unshared mailbox B
    $admintalk->create("user.other.B") or die;
    $admintalk->setacl("user.other.B", "cassandane", "") or die;
    $admintalk->copy(1, "user.other.B");

    my @fetchEmailMethods = [
        ['Email/query', {
            accountId => 'other',
            collapseThreads => JSON::true,
        }, "R1"],
        ['Email/get', {
            accountId => 'other',
            properties => ['mailboxIds'],
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
    ];

    # Fetch Email
    my $res = $jmap->CallMethods(@fetchEmailMethods);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    $self->assert_num_equals(1, scalar keys %{$res->[1][1]{list}[0]{mailboxIds}});
        my $emailId = $res->[1][1]{list}[0]{id};

        # Share mailbox B
    $admintalk->setacl("user.other.B", "cassandane", "lr") or die;
    $res = $jmap->CallMethods(@fetchEmailMethods);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    $self->assert_num_equals(2, scalar keys %{$res->[1][1]{list}[0]{mailboxIds}});

        # Unshare mailboxes A and B
    $admintalk->setacl("user.other.A", "cassandane", "") or die;
    $admintalk->setacl("user.other.B", "cassandane", "") or die;
    $res = $jmap->CallMethods([['Email/get', {
        accountId => 'other',
        ids => [$emailId],
    }, 'R1']]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]{list}});
    $self->assert_str_equals($emailId, $res->[0][1]{notFound}[0]);
}

sub test_email_set_draft
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    my $draft =  {
        mailboxIds => { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        sender => [{ name => "Marvin the Martian", email => "marvin\@acme.local" }],
        to => [
            { name => "Bugs Bunny", email => "bugs\@acme.local" },
            { name => "Rainer M\N{LATIN SMALL LETTER U WITH DIAERESIS}ller", email => "rainer\@de.local" },
        ],
        cc => [
            { name => "Elmer Fudd", email => "elmer\@acme.local" },
            { name => "Porky Pig", email => "porky\@acme.local" },
        ],
        bcc => [
            { name => "Wile E. Coyote", email => "coyote\@acme.local" },
        ],
        replyTo => [ { name => undef, email => "the.other.sam\@acme.local" } ],
        subject => "Memo",
        textBody => [{ partId => '1' }],
        htmlBody => [{ partId => '2' }],
        bodyValues => {
            '1' => { value => "I'm givin' ya one last chance ta surrenda!" },
            '2' => { value => "Oh!!! I <em>hate</em> that Rabbit." },
        },
        keywords => { '$Draft' => JSON::true },
    };

    xlog "Create a draft";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $draft }}, "R1"]]);
    my $id = $res->[0][1]{created}{"1"}{id};

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    my $msg = $res->[0][1]->{list}[0];

    $self->assert_deep_equals($msg->{mailboxIds}, $draft->{mailboxIds});
    $self->assert_deep_equals($msg->{from}, $draft->{from});
    $self->assert_deep_equals($msg->{sender}, $draft->{sender});
    $self->assert_deep_equals($msg->{to}, $draft->{to});
    $self->assert_deep_equals($msg->{cc}, $draft->{cc});
    $self->assert_deep_equals($msg->{bcc}, $draft->{bcc});
    $self->assert_deep_equals($msg->{replyTo}, $draft->{replyTo});
    $self->assert_str_equals($msg->{subject}, $draft->{subject});
    $self->assert_equals(JSON::true, $msg->{keywords}->{'$draft'});
    $self->assert_num_equals(1, scalar keys %{$msg->{keywords}});

    # Now change the draft keyword, which is allowed since approx ~Q1/2018.
    xlog "Update a draft";
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => { $id => { 'keywords/$draft' => undef } },
        }, "R1"]
    ]);
    $self->assert(exists $res->[0][1]{updated}{$id});
}

sub test_email_set_issue2293
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $inboxid = $self->getinbox()->{id};

    my $email =  {
        mailboxIds => { $inboxid => JSON::true },
        from => [ { email => q{test1@robmtest.vm}, name => q{} } ],
        to => [ {
            email => q{foo@bar.com},
            name => "asd \x{529b}\x{9928}\x{5fc5}  asd \x{30ec}\x{30f1}\x{30b9}"
        } ],
    };

    xlog "create and get email";
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', { ids => [ "#1" ] }, "R2" ],
    ]);
    my $ret = $res->[1][1]->{list}[0];
    $self->assert_str_equals($email->{to}[0]{email}, $ret->{to}[0]{email});
    $self->assert_str_equals($email->{to}[0]{name}, $ret->{to}[0]{name});


    xlog "create and get email";
    $email->{to}[0]{name} = "asd \x{529b}\x{9928}\x{5fc5}  asd \x{30ec}\x{30f1}\x{30b9} asd  \x{3b1}\x{3bc}\x{3b5}\x{3c4}";

    $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', { ids => [ "#1" ] }, "R2" ],
    ]);
    $ret = $res->[1][1]->{list}[0];
    $self->assert_str_equals($email->{to}[0]{email}, $ret->{to}[0]{email});
    $self->assert_str_equals($email->{to}[0]{name}, $ret->{to}[0]{name});

    xlog "create and get email";
    my $to = [{
        name => "abcdefghijklmnopqrstuvwxyz1",
        email => q{abcdefghijklmnopqrstuvwxyz1@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz2",
        email => q{abcdefghijklmnopqrstuvwxyz2@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz3",
        email => q{abcdefghijklmnopqrstuvwxyz3@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz4",
        email => q{abcdefghijklmnopqrstuvwxyz4@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz5",
        email => q{abcdefghijklmnopqrstuvwxyz5@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz6",
        email => q{abcdefghijklmnopqrstuvwxyz6@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz7",
        email => q{abcdefghijklmnopqrstuvwxyz7@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz8",
        email => q{abcdefghijklmnopqrstuvwxyz8@local},
    }, {
        name => "abcdefghijklmnopqrstuvwxyz9",
        email => q{abcdefghijklmnopqrstuvwxyz9@local},
    }];
    $email->{to} = $to;

    $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', { ids => [ "#1" ] }, "R2" ],
    ]);
    $ret = $res->[1][1]->{list}[0];
    $self->assert_deep_equals($email->{to}, $ret->{to});
}

sub test_email_set_bodystructure
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "Content-Disposition: inline\r\n" . "\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "\r\n"
          . "Return-Path: <Ava.Nguyen\@local>\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Transfer-Encoding: 7bit\r\n"
          . "Subject: bar\r\n"
          . "From: Ava T. Nguyen <Ava.Nguyen\@local>\r\n"
          . "Message-ID: <fake.1475639947.6507\@local>\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: Test User <test\@local>\r\n"
          . "\r\n"
          . "An embedded email"
          . "\r\n--sub--\r\n",
    ) || die;
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['attachments', 'blobId'],
        }, 'R2' ],
    ]);
    my $emailBlobId = $res->[1][1]->{list}[0]->{blobId};
    my $embeddedEmailBlobId = $res->[1][1]->{list}[0]->{attachments}[0]{blobId};

    xlog "Upload a data blob";
    my $binary = pack "H*", "beefcode";
    my $data = $jmap->Upload($binary, "image/gif");
    my $dataBlobId = $data->{blobId};

    $self->assert_not_null($emailBlobId);
    $self->assert_not_null($embeddedEmailBlobId);
    $self->assert_not_null($dataBlobId);

    my $bodyStructure = {
        type => "multipart/alternative",
        subParts => [{
                type => 'text/plain',
                partId => '1',
            }, {
                type => 'message/rfc822',
                blobId => $embeddedEmailBlobId,
            }, {
                type => 'image/gif',
                blobId => $dataBlobId,
            }, {
                # No type set
                blobId => $dataBlobId,
            }, {
                type => 'message/rfc822',
                blobId => $emailBlobId,
        }],
    };

    xlog "Create email with body structure";
    my $inboxid = $self->getinbox()->{id};
    my $email = {
        mailboxIds => { $inboxid => JSON::true },
        from => [{ name => "Test", email => q{foo@bar} }],
        subject => "test",
        bodyStructure => $bodyStructure,
        bodyValues => {
            "1" => {
                value => "A text body",
            },
        },
    };
    $res = $jmap->CallMethods([
        ['Email/set', { create => { '1' => $email } }, 'R1'],
        ['Email/get', {
            ids => [ '#1' ],
            properties => [ 'bodyStructure' ],
            bodyProperties => [ 'partId', 'blobId', 'type' ],
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
    ]);

    # Normalize server-set properties
    my $gotBodyStructure = $res->[1][1]{list}[0]{bodyStructure};
    $self->assert_str_equals('multipart/alternative', $gotBodyStructure->{type});
    $self->assert_null($gotBodyStructure->{blobId});
    $self->assert_str_equals('text/plain', $gotBodyStructure->{subParts}[0]{type});
    $self->assert_not_null($gotBodyStructure->{subParts}[0]{blobId});
    $self->assert_str_equals('message/rfc822', $gotBodyStructure->{subParts}[1]{type});
    $self->assert_str_equals($embeddedEmailBlobId, $gotBodyStructure->{subParts}[1]{blobId});
    $self->assert_str_equals('image/gif', $gotBodyStructure->{subParts}[2]{type});
    $self->assert_str_equals($dataBlobId, $gotBodyStructure->{subParts}[2]{blobId});
    # Default type is text/plain if no Content-Type header is set
    $self->assert_str_equals('text/plain', $gotBodyStructure->{subParts}[3]{type});
    $self->assert_str_equals($dataBlobId, $gotBodyStructure->{subParts}[3]{blobId});
    $self->assert_str_equals('message/rfc822', $gotBodyStructure->{subParts}[4]{type});
    $self->assert_str_equals($emailBlobId, $gotBodyStructure->{subParts}[4]{blobId});
}

sub test_email_set_issue2500
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inboxid = $self->getinbox()->{id};

    my $email = {
        mailboxIds => { $inboxid => JSON::true },
        from => [{ name => "Test", email => q{foo@bar} }],
        subject => "test",
        bodyStructure => {
            partId => '1',
            charset => 'us/ascii',
        },
        bodyValues => {
            "1" => {
                value => "A text body",
            },
        },
    };
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { '1' => $email } }, 'R1'],
    ]);
    $self->assert_str_equals('invalidProperties', $res->[0][1]{notCreated}{1}{type});
    $self->assert_str_equals('bodyStructure/charset', $res->[0][1]{notCreated}{1}{properties}[0]);

    delete $email->{bodyStructure}{charset};
    $email->{bodyStructure}{'header:Content-Type'} = 'text/plain;charset=us-ascii';
    $res = $jmap->CallMethods([
        ['Email/set', { create => { '1' => $email } }, 'R1'],
    ]);
    $self->assert_str_equals('invalidProperties', $res->[0][1]{notCreated}{1}{type});
    $self->assert_str_equals('bodyStructure/header:Content-Type', $res->[0][1]{notCreated}{1}{properties}[0]);

}

sub test_email_set_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    xlog "Create user and share mailbox";
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lrswntex") or die;

    xlog "Create email in shared account via IMAP";
    $self->{adminstore}->set_folder('user.foo');
    $self->make_message("Email foo", store => $self->{adminstore}) or die;

    xlog "get email";
    my $res = $jmap->CallMethods([
        ['Email/query', { accountId => 'foo' }, "R1"],
    ]);
    my $id = $res->[0][1]->{ids}[0];

    xlog "toggle Seen flag on email";
    $res = $jmap->CallMethods([['Email/set', {
        accountId => 'foo',
        update => { $id => { keywords => { '$Seen' => JSON::true } } },
    }, "R1"]]);
    $self->assert(exists $res->[0][1]{updated}{$id});

    xlog "Remove right to write annotations";
    $admintalk->setacl("user.foo", "cassandane", "lrtex") or die;

    xlog 'Toggle \\Seen flag on email (should fail)';
    $res = $jmap->CallMethods([['Email/set', {
        accountId => 'foo',
        update => { $id => { keywords => { } } },
    }, "R1"]]);
    $self->assert(exists $res->[0][1]{notUpdated}{$id});

    xlog "Remove right to delete email";
    $admintalk->setacl("user.foo", "cassandane", "lr") or die;

    xlog 'Delete email (should fail)';
    $res = $jmap->CallMethods([['Email/set', {
        accountId => 'foo',
        destroy => [ $id ],
    }, "R1"]]);
    $self->assert(exists $res->[0][1]{notDestroyed}{$id});

    xlog "Add right to delete email";
    $admintalk->setacl("user.foo", "cassandane", "lrtex") or die;

    xlog 'Delete email';
    $res = $jmap->CallMethods([['Email/set', {
            accountId => 'foo',
            destroy => [ $id ],
    }, "R1"]]);
    $self->assert_str_equals($id, $res->[0][1]{destroyed}[0]);
}

sub test_email_set_userkeywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    my $draft =  {
        mailboxIds =>  { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [
            { name => "Bugs Bunny", email => "bugs\@acme.local" },
        ],
        subject => "Memo",
        textBody => [{ partId => '1' }],
        bodyValues => {
            '1' => {
                value => "I'm givin' ya one last chance ta surrenda!"
            }
        },
        keywords => {
            '$Draft' => JSON::true,
            'foo' => JSON::true
        },
    };

    xlog "Create a draft";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $draft }}, "R1"]]);
    my $id = $res->[0][1]{created}{"1"}{id};

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    my $msg = $res->[0][1]->{list}[0];

    $self->assert_equals(JSON::true, $msg->{keywords}->{'$draft'});
    $self->assert_equals(JSON::true, $msg->{keywords}->{'foo'});
    $self->assert_num_equals(2, scalar keys %{$msg->{keywords}});

    xlog "Update draft";
    $res = $jmap->CallMethods([['Email/set', {
        update => {
            $id => {
                "keywords" => {
                    '$Draft' => JSON::true,
                    'foo' => JSON::true,
                    'bar' => JSON::true
                }
            }
        }
    }, "R1"]]);

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    $msg = $res->[0][1]->{list}[0];
    $self->assert_equals(JSON::true, JSON::true, $msg->{keywords}->{'$draft'}); # case-insensitive!
    $self->assert_equals(JSON::true, $msg->{keywords}->{'foo'});
    $self->assert_equals(JSON::true, $msg->{keywords}->{'bar'});
    $self->assert_num_equals(3, scalar keys %{$msg->{keywords}});
}

sub test_email_set_keywords_bogus_values
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # See https://github.com/cyrusimap/cyrus-imapd/issues/2439

    $self->make_message("foo") || die;
    my $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    my $emailId = $res->[0][1]{ids}[0];
    $self->assert_not_null($res);

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            keywords => {
                'foo' => JSON::false,
            },
        }},
    }, 'R1' ]]);
    $self->assert_not_null($res->[0][1]{notUpdated}{$emailId});

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            'keywords/foo' => JSON::false,
            },
        },
    }, 'R1' ]]);
    $self->assert_not_null($res->[0][1]{notUpdated}{$emailId});

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            keywords => {
                'foo' => 1,
            },
        }},
    }, 'R1' ]]);
    $self->assert_not_null($res->[0][1]{notUpdated}{$emailId});

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            'keywords/foo' => 1,
            },
        },
    }, 'R1' ]]);
    $self->assert_not_null($res->[0][1]{notUpdated}{$emailId});

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            keywords => {
                'foo' => 'true',
            },
        }},
    }, 'R1' ]]);
    $self->assert_not_null($res->[0][1]{notUpdated}{$emailId});

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            'keywords/foo' => 'true',
            },
        },
    }, 'R1' ]]);
    $self->assert_not_null($res->[0][1]{notUpdated}{$emailId});

    $res = $jmap->CallMethods([['Email/set', {
        'update' => { $emailId => {
            keywords => {
                'foo' => JSON::true,
            },
        }},
    }, 'R1' ]]);
    $self->assert(exists $res->[0][1]{updated}{$emailId});
}

sub test_misc_upload_zero
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    my $data = $jmap->Upload("", "text/plain");
    $self->assert_matches(qr/^Gda39a3ee5e6b4b0d3255bfef95601890/, $data->{blobId});
    $self->assert_num_equals(0, $data->{size});
    $self->assert_str_equals("text/plain", $data->{type});

    my $msgresp = $jmap->CallMethods([
      ['Email/set', { create => { "2" => {
        mailboxIds =>  { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [
            { name => "Bugs Bunny", email => "bugs\@acme.local" },
        ],
        subject => "Memo",
        textBody => [{ partId => '1' }],
        bodyValues => {
            '1' => {
                value => "I'm givin' ya one last chance ta surrenda!"
            }
        },
        attachments => [{
            blobId => $data->{blobId},
            name => "emptyfile.txt",
        }],
        keywords => { '$Draft' => JSON::true },
      } } }, 'R2'],
    ]);

    $self->assert_not_null($msgresp->[0][1]{created});
}

sub test_misc_upload
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    my $data = $jmap->Upload("a message with some text", "text/rubbish");
    $self->assert_matches(qr/^G44911b55c3b83ca05db9659d7a8e8b7b/, $data->{blobId});
    $self->assert_num_equals(24, $data->{size});
    $self->assert_str_equals("text/rubbish", $data->{type});

    my $msgresp = $jmap->CallMethods([
      ['Email/set', { create => { "2" => {
        mailboxIds =>  { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [
            { name => "Bugs Bunny", email => "bugs\@acme.local" },
        ],
        subject => "Memo",
        textBody => [{partId => '1'}],
        htmlBody => [{partId => '2'}],
        bodyValues => {
            1 => {
                value => "I'm givin' ya one last chance ta surrenda!"
            },
            2 => {
                value => "<html>I'm givin' ya one last chance ta surrenda!</html>"
            },
        },
        attachments => [{
            blobId => $data->{blobId},
            name => "test.txt",
        }],
        keywords => { '$Draft' => JSON::true },
      } } }, 'R2'],
    ]);

    $self->assert_not_null($msgresp->[0][1]{created});
}

sub test_misc_upload_multiaccount
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # Create user and share mailbox
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lrwkxd") or die;

    # Create user but don't share mailbox
    $self->{instance}->create_user("bar");

    my @res = $jmap->Upload("a email with some text", "text/rubbish", "foo");
    $self->assert_str_equals($res[0]->{status}, '201');

    @res = $jmap->Upload("a email with some text", "text/rubbish", "bar");
    $self->assert_str_equals($res[0]->{status}, '404');
}

sub test_misc_upload_bin
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    my $logofile = abs_path('data/logo.gif');
    open(FH, "<$logofile");
    local $/ = undef;
    my $binary = <FH>;
    close(FH);
    my $data = $jmap->Upload($binary, "image/gif");

    my $msgresp = $jmap->CallMethods([
      ['Email/set', { create => { "2" => {
        mailboxIds =>  { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [
            { name => "Bugs Bunny", email => "bugs\@acme.local" },
        ],
        subject => "Memo",
        textBody => [{ partId => '1' }],
        bodyValues => { 1 => { value => "I'm givin' ya one last chance ta surrenda!" }},
        attachments => [{
            blobId => $data->{blobId},
            name => "logo.gif",
        }],
        keywords => { '$Draft' => JSON::true },
      } } }, 'R2'],
    ]);

    $self->assert_not_null($msgresp->[0][1]{created});

    # XXX - fetch back the parts
}

sub test_misc_download
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    # Generate a email to have some blob ids
    xlog "Generate a email in $inbox via IMAP";
    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: image/jpeg\r\n"
          . "Content-Transfer-Encoding: base64\r\n" . "\r\n"
          . "beefc0de"
          . "\r\n--sub\r\n"
          . "Content-Type: image/png\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          . "\r\n"
          . "f00bae=="
          . "\r\n--sub--\r\n",
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', {
        ids => $ids,
        properties => ['bodyStructure'],
    }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    my $blobid1 = $msg->{bodyStructure}{subParts}[1]{blobId};
    my $blobid2 = $msg->{bodyStructure}{subParts}[2]{blobId};
    $self->assert_not_null($blobid1);
    $self->assert_not_null($blobid2);

    $res = $jmap->Download('cassandane', $blobid1);
    $self->assert_str_equals(encode_base64($res->{content}, ''), "beefc0de");
}

sub test_misc_download_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    my $admintalk = $self->{adminstore}->get_client();

    xlog "Create shared mailboxes";
    $self->{instance}->create_user("foo");
    $admintalk->create("user.foo.A") or die;
    $admintalk->setacl("user.foo.A", "cassandane", "lr") or die;
    $admintalk->create("user.foo.B") or die;
    $admintalk->setacl("user.foo.B", "cassandane", "lr") or die;

    xlog "Create email in shared mailbox";
    $self->{adminstore}->set_folder('user.foo.B');
    $self->make_message("foo", store => $self->{adminstore}) or die;

    xlog "get email blobId";
    my $res = $jmap->CallMethods([
        ['Email/query', { accountId => 'foo'}, 'R1'],
        ['Email/get', {
            accountId => 'foo',
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => ['blobId'],
        }, 'R2'],
    ]);
    my $blobId = $res->[1][1]->{list}[0]{blobId};

    xlog "download email as blob";
    $res = $jmap->Download('foo', $blobId);

    xlog "Unshare mailbox";
    $admintalk->setacl("user.foo.B", "cassandane", "") or die;

    my %Headers;
    $Headers{'Authorization'} = $jmap->auth_header();
    my %getopts = (headers => \%Headers);
    my $httpRes = $jmap->ua->get($jmap->downloaduri('foo', $blobId));
    $self->assert_str_equals('404', $httpRes->{status});
}

sub test_base64_forward
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    # Generate a email to have some blob ids
    xlog "Generate a email in $inbox via IMAP";
    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: image/jpeg\r\n"
          . "Content-Transfer-Encoding: base64\r\n" . "\r\n"
          . "beefc0de"
          . "\r\n--sub--\r\n",
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', {
        ids => $ids,
        properties => ['bodyStructure', 'mailboxIds'],
    }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    my $blobid = $msg->{bodyStructure}{subParts}[1]{blobId};
    $self->assert_not_null($blobid);
    my $size = $msg->{bodyStructure}{subParts}[1]{size};
    $self->assert_num_equals(6, $size);

    $res = $jmap->Download('cassandane', $blobid);
    $self->assert_str_equals("beefc0de", encode_base64($res->{content}, ''));

    # now create a new message referencing this blobId:

    $res = $jmap->CallMethods([['Email/set', {
        create => {
            k1 => {
                bcc => undef,
                bodyStructure => {
                    subParts => [{
                        partId => 'text',
                        type => 'text/plain',
                    },{
                        blobId => $blobid,
                        cid => undef,
                        disposition => 'attachment',
                        height => undef,
                        name => 'foobar.jpg',
                        size => $size,
                        type => 'image/jpeg',
                        width => undef,
                    }],
                    type => 'multipart/mixed',
                },
                bodyValues => {
                    text => {
                        isTruncated => $JSON::false,
                        value => "Hello world",
                    },
                },
                cc => undef,
                inReplyTo => undef,
                mailboxIds => $msg->{mailboxIds},
                from => [ {email => 'foo@example.com', name => 'foo' } ],
                keywords => { '$draft' => $JSON::true, '$seen' => $JSON::true },
                receivedAt => '2018-06-26T03:10:07Z',
                references => undef,
                replyTo => undef,
                sentAt => '2018-06-26T03:10:07Z',
                subject => 'test email',
                to => [ {email => 'foo@example.com', name => 'foo' } ],
            },
        },
    }, "R1"]]);

    my $id = $res->[0][1]{created}{k1}{id};
    $self->assert_not_null($id);

    $res = $jmap->CallMethods([['Email/get', {
        ids => [$id],
        properties => ['bodyStructure'],
    }, "R1"]]);
    $msg = $res->[0][1]{list}[0];

    my $newpart = $msg->{bodyStructure}{subParts}[1];
    $self->assert_str_equals("foobar.jpg", $newpart->{name});
    $self->assert_str_equals("image/jpeg", $newpart->{type});
    $self->assert_num_equals(6, $newpart->{size});

    # XXX - in theory, this IS allowed to change
    if ($newpart->{blobId} ne $blobid) {
        $res = $jmap->Download('cassandane', $blobid);
        # but this isn't!
        $self->assert_str_equals("beefc0de", encode_base64($res->{content}, ''));
    }
}

sub download
{
    my ($self, $accountid, $blobid) = @_;
    my $jmap = $self->{jmap};

    my $uri = $jmap->downloaduri($accountid, $blobid);
    my %Headers;
    $Headers{'Authorization'} = $jmap->auth_header();
    my %getopts = (headers => \%Headers);
    my $res = $jmap->ua->get($uri, \%getopts);
    xlog "JMAP DOWNLOAD @_ " . Dumper($res);
    return $res;
}

sub test_blob_copy
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # FIXME how to share just #jmap folder?
    xlog "create user foo and share inbox";
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lrkintex") or die;

    xlog "upload blob in main account";
    my $data = $jmap->Upload('somedata', "text/plain");
    $self->assert_not_null($data);

    xlog "attempt to download from shared account (should fail)";
    my $res = $self->download('foo', $data->{blobId});
    $self->assert_str_equals('404', $res->{status});

    xlog "copy blob to shared account";
    $res = $jmap->CallMethods([['Blob/copy', {
        fromAccountId => 'cassandane',
        accountId => 'foo',
        blobIds => [ $data->{blobId} ],
    }, 'R1']]);

    xlog "download from shared account";
    $res = $self->download('foo', $data->{blobId});
    $self->assert_str_equals('200', $res->{status});

    xlog "generate an email in INBOX via IMAP";
    $self->make_message("Email A") || die;

    xlog "get email blob id";
    $res = $jmap->CallMethods([
        ['Email/query', {}, "R1"],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => [ 'blobId' ],
        }, 'R2']
    ]);
    my $msgblobId = $res->[1][1]->{list}[0]{blobId};

    xlog "copy Email blob to shared account";
    $res = $jmap->CallMethods([['Blob/copy', {
        fromAccountId => 'cassandane',
        accountId => 'foo',
        blobIds => [ $msgblobId ],
    }, 'R1']]);

    xlog "download Email blob from shared account";
    $res = $self->download('foo', $msgblobId);
    $self->assert_str_equals('200', $res->{status});
}

sub test_email_set_attachments
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    # Generate a email to have some blob ids
    xlog "Generate a email in $inbox via IMAP";
    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "Content-Disposition: inline\r\n" . "\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: image/jpeg;foo=bar\r\n"
          . "Content-Disposition: attachment\r\n"
          . "Content-Transfer-Encoding: base64\r\n" . "\r\n"
          . "beefc0de"
          . "\r\n--sub\r\n"
          . "Content-Type: image/png\r\n"
          . "Content-Disposition: attachment\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          . "\r\n"
          . "f00bae=="
          . "\r\n--sub--\r\n",
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    my %m = map { $_->{type} => $_ } @{$res->[0][1]{list}[0]->{attachments}};
    my $blobJpeg = $m{"image/jpeg"}->{blobId};
    my $blobPng = $m{"image/png"}->{blobId};
    $self->assert_not_null($blobJpeg);
    $self->assert_not_null($blobPng);

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};
    my $shortfname = "test\N{GRINNING FACE}.jpg";
    my $longfname = "a_very_long_filename_thats_looking_quite_bogus_but_in_fact_is_absolutely_valid\N{GRINNING FACE}!.bin";

    my $draft =  {
        mailboxIds =>  { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [ { name => "Bugs Bunny", email => "bugs\@acme.local" }, ],
        subject => "Memo",
        htmlBody => [{ partId => '1' }],
        bodyValues => {
            '1' => {
                value => "<html>I'm givin' ya one last chance ta surrenda! ".
                         "<img src=\"cid:foo\@local\"></html>",
            },
        },
        attachments => [{
            blobId => $blobJpeg,
            name => $shortfname,
            type => 'image/jpeg',
        }, {
            blobId => $blobPng,
            cid => "foo\@local",
            type => 'image/png',
            disposition => 'inline',
        }, {
            blobId => $blobJpeg,
            type => "application/test",
            name => $longfname,
        }, {
            blobId => $blobPng,
            type => "application/test2",
            name => "simple",
        }],
        keywords => { '$Draft' => JSON::true },
    };

    my $wantBodyStructure = {
        type => 'multipart/mixed',
        name => undef,
        cid => undef,
        disposition => undef,
        subParts => [{
            type => 'multipart/related',
            name => undef,
            cid => undef,
            disposition => undef,
            subParts => [{
                type => 'text/html',
                name => undef,
                cid => undef,
                disposition => undef,
                subParts => [],
            },{
                type => 'image/png',
                cid => "foo\@local",
                disposition => 'inline',
                name => undef,
                subParts => [],
            }],
        },{
            type => 'image/jpeg',
            name => $shortfname,
            cid => undef,
            disposition => 'attachment',
            subParts => [],
        },{
            type => 'application/test',
            name => $longfname,
            cid => undef,
            disposition => 'attachment',
            subParts => [],
        },{
            type => 'application/test2',
            name => 'simple',
            cid => undef,
            disposition => 'attachment',
            subParts => [],
        }]
    };

    xlog "Create a draft";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $draft }}, "R1"]]);
    my $id = $res->[0][1]{created}{"1"}{id};

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', {
            ids => [$id],
            properties => ['bodyStructure'],
            bodyProperties => ['type', 'name', 'cid','disposition', 'subParts'],
    }, "R1"]]);
    $msg = $res->[0][1]->{list}[0];

    $self->assert_deep_equals($wantBodyStructure, $msg->{bodyStructure});
}

sub test_email_set_flagged
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $drafts = $res->[0][1]{created}{"1"}{id};

    my $draft =  {
        mailboxIds =>  { $drafts => JSON::true },
        keywords => { '$Draft' => JSON::true, '$Flagged' => JSON::true },
        textBody => [{ partId => '1' }],
        bodyValues => { '1' => { value => "a flagged draft" }},
    };

    xlog "Create a draft";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $draft }}, "R1"]]);
    my $id = $res->[0][1]{created}{"1"}{id};

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    my $msg = $res->[0][1]->{list}[0];

    $self->assert_deep_equals($msg->{mailboxIds}, $draft->{mailboxIds});
    $self->assert_equals(JSON::true, $msg->{keywords}->{'$flagged'});
}

sub test_email_set_mailboxids
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $inboxid = $self->getinbox()->{id};
    $self->assert_not_null($inboxid);

    my $res = $jmap->CallMethods([
        ['Mailbox/set', { create => {
            "1" => { name => "drafts", parentId => undef, role => "drafts" },
        }}, "R1"]
    ]);
    my $draftsid = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsid);

    my $msg =  {
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ],
        to => [ { name => "Bugs Bunny", email => "bugs\@acme.local" }, ],
        subject => "Memo",
        textBody => [{ partId => '1' }],
        bodyValues => { '1' => { value => "I'm givin' ya one last chance ta surrenda!" }},
        keywords => { '$Draft' => JSON::true },
    };

    # Not OK: at least one mailbox must be specified
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $msg }}, "R1"]]);
    $self->assert_str_equals('invalidProperties', $res->[0][1]{notCreated}{"1"}{type});
    $self->assert_str_equals('mailboxIds', $res->[0][1]{notCreated}{"1"}{properties}[0]);
    $msg->{mailboxIds} = {};
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $msg }}, "R1"]]);
    $self->assert_str_equals('invalidProperties', $res->[0][1]{notCreated}{"1"}{type});
    $self->assert_str_equals('mailboxIds', $res->[0][1]{notCreated}{"1"}{properties}[0]);

    # OK: drafts mailbox isn't required (anymore)
    $msg->{mailboxIds} = { $inboxid => JSON::true },
    $msg->{subject} = "Email 1";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $msg }}, "R1"]]);
    $self->assert(exists $res->[0][1]{created}{"1"});

    # OK: drafts mailbox is OK to create in
    $msg->{mailboxIds} = { $draftsid => JSON::true },
    $msg->{subject} = "Email 2";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $msg }}, "R1"]]);
    $self->assert(exists $res->[0][1]{created}{"1"});

    # OK: drafts mailbox is OK to create in, as is for multiple mailboxes
    $msg->{mailboxIds} = { $draftsid => JSON::true, $inboxid => JSON::true },
    $msg->{subject} = "Email 3";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $msg }}, "R1"]]);
    $self->assert(exists $res->[0][1]{created}{"1"});
}

sub test_email_get_keywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Create IMAP mailbox and message A";
    $talk->create('INBOX.A') || die;
    $store->set_folder('INBOX.A');
    $self->make_message('A') || die;

    xlog "Create IMAP mailbox B and copy message A to B";
    $talk->create('INBOX.B') || die;
    $talk->copy('1:*', 'INBOX.B');
    $self->assert_str_equals('ok', $talk->get_last_completion_response());

    my $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids'}
        }, 'R2' ]
    ]);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    my $jmapmsg = $res->[1][1]{list}[0];
    $self->assert_not_null($jmapmsg);

    # Keywords are empty by default
    my $keywords = {};
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});

    xlog "Set \\Seen on message A";
    $store->set_folder('INBOX.A');
    $talk->store('1', '+flags', '(\\Seen)');

    # Seen must only be set if ALL messages are seen.
    $res = $jmap->CallMethods([
        ['Email/get', { 'ids' => [ $jmapmsg->{id} ] }, 'R2' ]
    ]);
    $jmapmsg = $res->[0][1]{list}[0];
    $keywords = {};
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});

    xlog "Set \\Seen on message B";
    $store->set_folder('INBOX.B');
    $store->_select();
    $talk->store('1', '+flags', '(\\Seen)');

    # Seen must only be set if ALL messages are seen.
    $res = $jmap->CallMethods([
        ['Email/get', { 'ids' => [ $jmapmsg->{id} ] }, 'R2' ]
    ]);
    $jmapmsg = $res->[0][1]{list}[0];
    $keywords = {
        '$seen' => JSON::true,
    };
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});

    xlog "Set \\Flagged on message B";
    $store->set_folder('INBOX.B');
    $store->_select();
    $talk->store('1', '+flags', '(\\Flagged)');

    # Any other keyword is set if set on any IMAP message of this email.
    $res = $jmap->CallMethods([
        ['Email/get', { 'ids' => [ $jmapmsg->{id} ] }, 'R2' ]
    ]);
    $jmapmsg = $res->[0][1]{list}[0];
    $keywords = {
        '$seen' => JSON::true,
        '$flagged' => JSON::true,
    };
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});
}

sub test_email_get_keywords_case_insensitive
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Create IMAP mailbox and message A";
    $talk->create('INBOX.A') || die;
    $store->set_folder('INBOX.A');
    $self->make_message('A') || die;

    xlog "Set flag Foo and Flagged on message A";
    $store->set_folder('INBOX.A');
    $talk->store('1', '+flags', '(Foo \\Flagged)');

    my $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids'},
            properties => ['keywords'],
        }, 'R2' ]
    ]);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    my $jmapmsg = $res->[1][1]{list}[0];
    my $keywords = {
        'foo' => JSON::true,
        '$flagged' => JSON::true,
    };
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});
}

sub test_email_set_keywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    $self->{store}->set_fetch_attributes(qw(uid flags));

    xlog "Create IMAP mailboxes";
    $talk->create('INBOX.A') || die;
    $talk->create('INBOX.B') || die;
    $talk->create('INBOX.C') || die;

    xlog "Get JMAP mailboxes";
    my $res = $jmap->CallMethods([['Mailbox/get', { properties => [ 'name' ]}, "R1"]]);
    my %jmailboxes = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    $self->assert_num_equals(scalar keys %jmailboxes, 4);
    my $jmailboxA = $jmailboxes{A};
    my $jmailboxB = $jmailboxes{B};
    my $jmailboxC = $jmailboxes{C};

    my %mailboxA;
    my %mailboxB;
    my %mailboxC;

    xlog "Create message in mailbox A";
    $store->set_folder('INBOX.A');
    $mailboxA{1} = $self->make_message('Message');
    $mailboxA{1}->set_attributes(id => 1, uid => 1, flags => []);

    xlog "Copy message from A to B";
    $talk->copy('1:*', 'INBOX.B');
    $self->assert_str_equals('ok', $talk->get_last_completion_response());

    xlog "Set IMAP flag foo on message A";
    $store->set_folder('INBOX.A');
    $store->_select();
    $talk->store('1', '+flags', '(foo)');

    xlog "Get JMAP keywords";
    $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => [ 'keywords']
        }, 'R2' ]
    ]);
    my $jmapmsg = $res->[1][1]{list}[0];
    my $keywords = {
        foo => JSON::true
    };
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});

    xlog "Update JMAP email keywords";
    $keywords = {
        bar => JSON::true,
        baz => JSON::true,
    };
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $jmapmsg->{id} => {
                    keywords => $keywords
                }
            }
        }, 'R1'],
        ['Email/get', {
            ids => [ $jmapmsg->{id} ],
            properties => ['keywords']
        }, 'R2' ]
    ]);
    $jmapmsg = $res->[1][1]{list}[0];
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});

    xlog "Set \\Seen on message in mailbox B";
    $store->set_folder('INBOX.B');
    $store->_select();
    $talk->store('1', '+flags', '(\\Seen)');

    xlog "Patch JMAP email keywords and update mailboxIds";
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $jmapmsg->{id} => {
                    'keywords/bar' => undef,
                    'keywords/qux' => JSON::true,
                    mailboxIds => {
                        $jmailboxB->{id} => JSON::true,
                        $jmailboxC->{id} => JSON::true,
                    }
                }
            }
        }, 'R1'],
        ['Email/get', {
            ids => [ $jmapmsg->{id} ],
            properties => ['keywords', 'mailboxIds']
        }, 'R2' ]
    ]);
    $jmapmsg = $res->[1][1]{list}[0];
    $keywords = {
        baz => JSON::true,
        qux => JSON::true,
    };
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});

    $self->assert_str_not_equals($res->[0][1]{oldState}, $res->[0][1]{newState});

    xlog 'Patch $seen on email';
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $jmapmsg->{id} => {
                    'keywords/$seen' => JSON::true
                }
            }
        }, 'R1'],
        ['Email/get', {
            ids => [ $jmapmsg->{id} ],
            properties => ['keywords', 'mailboxIds']
        }, 'R2' ]
    ]);
    $jmapmsg = $res->[1][1]{list}[0];
    $keywords = {
        baz => JSON::true,
        qux => JSON::true,
        '$seen' => JSON::true,
    };
    $self->assert_deep_equals($keywords, $jmapmsg->{keywords});
}

sub test_emailsubmission_capability
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $settings = $self->get_settings();
    $self->assert(exists $settings->{capabilities}->{"urn:ietf:params:jmap:submission"});
}

sub test_emailsubmission_set
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityid);

    xlog "Generate a email via IMAP";
    $self->make_message("foo", body => "a email") or die;

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $emailid = $res->[0][1]->{ids}[0];

    xlog "create email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $emailid,
            }
       }
    }, "R1" ] ] );
    my $msgsubid = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($msgsubid);

    xlog "get email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/get', {
        ids => [ $msgsubid ],
    }, "R1" ] ] );
    $self->assert_str_equals($msgsubid, $res->[0][1]->{notFound}[0]);

    xlog "update email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        update => {
            $msgsubid => {
                undoStatus => 'canceled',
            }
       }
    }, "R1" ] ] );
    $self->assert_str_equals('notFound', $res->[0][1]->{notUpdated}{$msgsubid}{type});

    xlog "destroy email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        destroy => [ $msgsubid ],
    }, "R1" ] ] );
    $self->assert_str_equals("notFound", $res->[0][1]->{notDestroyed}{$msgsubid}{type});
}

sub test_emailsubmission_set_with_envelope
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityid);

    xlog "Generate a email via IMAP";
    $self->make_message("foo", body => "a email\r\nwithCRLF\r\n") or die;

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $emailid = $res->[0][1]->{ids}[0];

    xlog "create email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $emailid,
                envelope => {
                    mailFrom => {
                        email => 'from@localhost',
                    },
                    rcptTo => [{
                        email => 'rcpt1@localhost',
                    }, {
                        email => 'rcpt2@localhost',
                    }],
                },
            }
       }
    }, "R1" ] ] );
    my $msgsubid = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($msgsubid);
}

sub test_emailsubmission_set_creationid
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityId = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityId);

    xlog "create mailboxes";
    $imap->create("INBOX.A") or die;
    $imap->create("INBOX.B") or die;
    $res = $jmap->CallMethods([
        ['Mailbox/get', { properties => ['name'], }, "R1"]
    ]);
    my %mboxByName = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $mboxIdA = $mboxByName{A}->{id};
    my $mboxIdB = $mboxByName{B}->{id};

    xlog "create, send and update email";
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                'm1' => {
                    mailboxIds => {
                        $mboxIdA => JSON::true,
                    },
                    from => [{
                        name => '', email => 'foo@local'
                    }],
                    to => [{
                        name => '', email => 'bar@local'
                    }],
                    subject => 'hello',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'world',
                        }
                    },
                },
            },
        }, 'R1'],
        [ 'EmailSubmission/set', {
            create => {
                's1' => {
                    identityId => $identityId,
                    emailId  => '#m1',
                }
           },
           onSuccessUpdateEmail => {
               '#s1' => {
                    mailboxIds => {
                        $mboxIdB => JSON::true,
                    },
               },
           },
        }, 'R2' ],
        [ 'Email/get', {
            ids => ['#m1'],
            properties => ['mailboxIds'],
        }, 'R3'],
    ]);
    my $emailId = $res->[0][1]->{created}{m1}{id};
    $self->assert_not_null($emailId);
    my $msgSubId = $res->[1][1]->{created}{s1}{id};
    $self->assert_not_null($msgSubId);
    $self->assert(exists $res->[2][1]{updated}{$emailId});
    $self->assert_num_equals(1, scalar keys %{$res->[3][1]{list}[0]{mailboxIds}});
    $self->assert(exists $res->[3][1]{list}[0]{mailboxIds}{$mboxIdB});
}

sub test_email_seen_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # Share account
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lr") or die;

    # Create mailbox A
    $admintalk->create("user.other.A") or die;
    $admintalk->setacl("user.other.A", "cassandane", "lrs") or die;

    # Create message in mailbox A
    $self->{adminstore}->set_folder('user.other.A');
    $self->make_message("Email", store => $self->{adminstore}) or die;

    # Set \Seen on message A as user cassandane
    $self->{store}->set_folder('user.other.A');
    $talk->select('user.other.A');
    $talk->store('1', '+flags', '(\\Seen)');

    # Get email and assert $seen
    my $res = $jmap->CallMethods([
        ['Email/query', {
            accountId => 'other',
        }, 'R1'],
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            '#ids' => {
                resultOf => 'R1', name => 'Email/query', path => '/ids'
            }
        }, 'R2' ]
    ]);
    my $emailId = $res->[1][1]{list}[0]{id};
    my $wantKeywords = { '$seen' => JSON::true };
    $self->assert_deep_equals($wantKeywords, $res->[1][1]{list}[0]{keywords});

    # Set $seen via JMAP on the shared mailbox
    $res = $jmap->CallMethods([
        ['Email/set', {
            accountId => 'other',
            update => {
                $emailId => {
                    keywords => { },
                },
            },
        }, 'R1']
    ]);
    $self->assert_not_null($res->[0][1]{updated}{$emailId});

    # Assert $seen got updated
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            ids => [$emailId],
        }, 'R1' ]
    ]);
    $wantKeywords = { };
    $self->assert_deep_equals($wantKeywords, $res->[0][1]{list}[0]{keywords});
}

sub test_email_seen_shared_twofolder
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # Share account
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lr") or die;

    # Create mailbox A
    $admintalk->create("user.other.A") or die;
    $admintalk->setacl("user.other.A", "cassandane", "lrs") or die;
    $admintalk->create("user.other.A.sub") or die;
    $admintalk->setacl("user.other.A.sub", "cassandane", "lrs") or die;

    # Create message in mailbox A
    $self->{adminstore}->set_folder('user.other.A');
    $self->make_message("Email", store => $self->{adminstore}) or die;

    # Set \Seen on message A as user cassandane
    $self->{store}->set_folder('user.other.A');
    $admintalk->select('user.other.A');
    $admintalk->copy('1', 'user.other.A.sub');
    $talk->select('user.other.A');
    $talk->store('1', '+flags', '(\\Seen)');
    $talk->select('user.other.A.sub');
    $talk->store('1', '+flags', '(\\Seen)');

    # Get email and assert $seen
    my $res = $jmap->CallMethods([
        ['Email/query', {
            accountId => 'other',
        }, 'R1'],
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            '#ids' => {
                resultOf => 'R1', name => 'Email/query', path => '/ids'
            }
        }, 'R2' ]
    ]);
    my $emailId = $res->[1][1]{list}[0]{id};
    my $wantKeywords = { '$seen' => JSON::true };
    $self->assert_deep_equals($wantKeywords, $res->[1][1]{list}[0]{keywords});

    # Set $seen via JMAP on the shared mailbox
    $res = $jmap->CallMethods([
        ['Email/set', {
            accountId => 'other',
            update => {
                $emailId => {
                    keywords => { },
                },
            },
        }, 'R1']
    ]);
    $self->assert_not_null($res->[0][1]{updated}{$emailId});

    # Assert $seen got updated
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            ids => [$emailId],
        }, 'R1' ]
    ]);
    $wantKeywords = { };
    $self->assert_deep_equals($wantKeywords, $res->[0][1]{list}[0]{keywords});
}

sub test_email_seen_shared_twofolder_hidden
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # Share account
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lr") or die;

    # Create mailbox A
    $admintalk->create("user.other.A") or die;
    $admintalk->setacl("user.other.A", "cassandane", "lrs") or die;
    # NOTE: user cassandane does NOT get permission to see this one
    $admintalk->create("user.other.A.sub") or die;
    $admintalk->setacl("user.other.A.sub", "cassandane", "") or die;

    # Create message in mailbox A
    $self->{adminstore}->set_folder('user.other.A');
    $self->make_message("Email", store => $self->{adminstore}) or die;

    # Set \Seen on message A as user cassandane
    $self->{store}->set_folder('user.other.A');
    $admintalk->select('user.other.A');
    $admintalk->copy('1', 'user.other.A.sub');
    $talk->select('user.other.A');
    $talk->store('1', '+flags', '(\\Seen)');

    # Get email and assert $seen
    my $res = $jmap->CallMethods([
        ['Email/query', {
            accountId => 'other',
        }, 'R1'],
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            '#ids' => {
                resultOf => 'R1', name => 'Email/query', path => '/ids'
            }
        }, 'R2' ]
    ]);
    my $emailId = $res->[1][1]{list}[0]{id};
    my $wantKeywords = { '$seen' => JSON::true };
    $self->assert_deep_equals($wantKeywords, $res->[1][1]{list}[0]{keywords});

    # Set $seen via JMAP on the shared mailbox
    $res = $jmap->CallMethods([
        ['Email/set', {
            accountId => 'other',
            update => {
                $emailId => {
                    keywords => { },
                },
            },
        }, 'R1']
    ]);
    $self->assert_not_null($res->[0][1]{updated}{$emailId});

    # Assert $seen got updated
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            ids => [$emailId],
        }, 'R1' ]
    ]);
    $wantKeywords = { };
    $self->assert_deep_equals($wantKeywords, $res->[0][1]{list}[0]{keywords});
}

sub test_email_flagged_shared_twofolder_hidden
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # Share account
    $self->{instance}->create_user("other");

    # Create mailbox A
    $admintalk->create("user.other.A") or die;
    $admintalk->setacl("user.other.A", "cassandane", "lrsiwn") or die;
    # NOTE: user cassandane does NOT get permission to see this one
    $admintalk->create("user.other.A.sub") or die;

    # Create message in mailbox A
    $self->{adminstore}->set_folder('user.other.A');
    $self->make_message("Email", store => $self->{adminstore}) or die;

    # Set \Flagged on message A as user cassandane
    $self->{store}->set_folder('user.other.A');
    $admintalk->select('user.other.A');
    $admintalk->copy('1', 'user.other.A.sub');
    $talk->select('user.other.A');
    $talk->store('1', '+flags', '(\\Flagged)');

    # Get email and assert $seen
    my $res = $jmap->CallMethods([
        ['Email/query', {
            accountId => 'other',
        }, 'R1'],
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            '#ids' => {
                resultOf => 'R1', name => 'Email/query', path => '/ids'
            }
        }, 'R2' ]
    ]);
    my $emailId = $res->[1][1]{list}[0]{id};
    my $wantKeywords = { '$flagged' => JSON::true };
    $self->assert_deep_equals($wantKeywords, $res->[1][1]{list}[0]{keywords});

    # Set $seen via JMAP on the shared mailbox
    $res = $jmap->CallMethods([
        ['Email/set', {
            accountId => 'other',
            update => {
                $emailId => {
                    keywords => { },
                },
            },
        }, 'R1']
    ]);
    $self->assert_not_null($res->[0][1]{updated}{$emailId});

    # Assert $seen got updated
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            properties => ['keywords'],
            ids => [$emailId],
        }, 'R1' ]
    ]);
    $wantKeywords = { };
    $self->assert_deep_equals($wantKeywords, $res->[0][1]{list}[0]{keywords});
}

sub test_emailsubmission_set_too_many_recipients
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityid);

    xlog "Generate a email via IMAP";
    $self->make_message("foo", body => "a email\r\nwith 11 recipients\r\n") or die;

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $emailid = $res->[0][1]->{ids}[0];

    xlog "create email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $emailid,
                envelope => {
                    mailFrom => {
                        email => 'from@localhost',
                    },
                    rcptTo => [{
                        email => 'rcpt1@localhost',
                    }, {
                        email => 'rcpt2@localhost',
                    }, {
                        email => 'rcpt3@localhost',
                    }, {
                        email => 'rcpt4@localhost',
                    }, {
                        email => 'rcpt5@localhost',
                    }, {
                        email => 'rcpt6@localhost',
                    }, {
                        email => 'rcpt7@localhost',
                    }, {
                        email => 'rcpt8@localhost',
                    }, {
                        email => 'rcpt9@localhost',
                    }, {
                        email => 'rcpt10@localhost',
                    }, {
                        email => 'rcpt11@localhost',
                    }],
                },
            }
       }
    }, "R1" ] ] );
    my $errType = $res->[0][1]->{notCreated}{1}{type};
    $self->assert_str_equals($errType, "tooManyRecipients");
}

sub test_emailsubmission_set_fail_some_recipients
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityid);

    xlog "Generate a email via IMAP";
    $self->make_message("foo", body => "a email\r\nwith 10 recipients\r\n") or die;

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $emailid = $res->[0][1]->{ids}[0];

    xlog "create email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $emailid,
                envelope => {
                    mailFrom => {
                        email => 'from@localhost',
                    },
                    rcptTo => [{
                        email => 'rcpt1@localhost',
                    }, {
                        email => 'rcpt2@localhost',
                    }, {
                        email => 'rcpt3@fail.to.deliver',
                    }, {
                        email => 'rcpt4@localhost',
                    }, {
                        email => 'rcpt5@fail.to.deliver',
                    }, {
                        email => 'rcpt6@fail.to.deliver',
                    }, {
                        email => 'rcpt7@localhost',
                    }, {
                        email => 'rcpt8@localhost',
                    }, {
                        email => 'rcpt9@fail.to.deliver',
                    }, {
                        email => 'rcpt10@localhost',
                    }],
                },
            }
       }
    }, "R1" ] ] );
    my $errType = $res->[0][1]->{notCreated}{1}{type};
    $self->assert_str_equals($errType, "invalidRecipients");
}

sub test_emailsubmission_set_message_too_large
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityid);

    xlog "Generate a email via IMAP";
    my $x = "x";
    $self->make_message("foo", body => "a email\r\nwith 10k+ octet body\r\n" . $x x 10000) or die;

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $emailid = $res->[0][1]->{ids}[0];

    xlog "create email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $emailid,
                envelope => {
                    mailFrom => {
                        email => 'from@localhost',
                    },
                    rcptTo => [{
                        email => 'rcpt1@localhost',
                    }],
                },
            }
       }
    }, "R1" ] ] );
    my $errType = $res->[0][1]->{notCreated}{1}{type};
    $self->assert_str_equals($errType, "tooLarge");
}

sub test_emailsubmission_set_issue2285
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    my $inboxid = $self->getinbox()->{id};

    xlog "Create email";
    $res = $jmap->CallMethods([
    [ 'Email/set', {
        create => {
            'k40' => {
                'bcc' => undef,
                'cc' => undef,
                'attachments' => undef,
                'subject' => 'zlskdjgh',
                'identityId' => 'test1@robmtest.vm',
                'keywords' => {
                    '$Seen' => JSON::true,
                    '$Draft' => JSON::true
                },
                textBody => [{partId => '1'}],
                bodyValues => { '1' => { value => 'lsdkgjh' }},
                'to' => [
                    {
                        'email' => 'foo@bar.com',
                        'name' => ''
                    }
                ],
                'from' => [
                    {
                        'email' => 'fooalias1@robmtest.vm',
                        'name' => 'some name'
                    }
                ],
                'receivedAt' => '2018-03-06T03:49:04Z',
                'mailboxIds' => {
                    $inboxid => JSON::true,
                },
            }
        }
    }, "R1" ],
    [ 'EmailSubmission/set', {
        create => {
            'k41' => {
                identityId => $identityid,
                emailId  => '#k40',
                envelope => undef,
            },
        },
        onSuccessDestroyEmail => [ '#k41' ],
    }, "R2" ] ] );
    $self->assert_str_equals('EmailSubmission/set', $res->[1][0]);
    $self->assert_not_null($res->[1][1]->{created}{'k41'}{id});
    $self->assert_str_equals('R2', $res->[1][2]);
    $self->assert_str_equals('Email/set', $res->[2][0]);
    $self->assert_not_null($res->[2][1]->{destroyed}[0]);
    $self->assert_str_equals('R2', $res->[2][2]);
}

sub test_emailsubmission_changes
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};
    $self->assert_not_null($identityid);

    xlog "get current email submission state";
    $res = $jmap->CallMethods([['EmailSubmission/get', { }, "R1"]]);
    my $state = $res->[0][1]->{state};
    $self->assert_not_null($state);

    xlog "get email submission updates";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/changes', {
        sinceState => $state,
    }, "R1" ] ] );
    $self->assert_deep_equals([], $res->[0][1]->{created});
    $self->assert_deep_equals([], $res->[0][1]->{updated});
    $self->assert_deep_equals([], $res->[0][1]->{destroyed});

    xlog "Generate a email via IMAP";
    $self->make_message("foo", body => "a email") or die;

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $emailid = $res->[0][1]->{ids}[0];

    xlog "create email submission but don't update state";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $emailid,
            }
       }
    }, "R1" ] ] );

    xlog "get email submission updates";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/changes', {
        sinceState => $state,
    }, "R1" ] ] );
    $self->assert_deep_equals([], $res->[0][1]->{created});
    $self->assert_deep_equals([], $res->[0][1]->{updated});
    $self->assert_deep_equals([], $res->[0][1]->{destroyed});
}

sub test_emailsubmission_query
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "get email submission list (no arguments)";
    my $res = $jmap->CallMethods([['EmailSubmission/query', { }, "R1"]]);
    $self->assert_null($res->[0][1]{filter});
    $self->assert_null($res->[0][1]{sort});
    $self->assert_not_null($res->[0][1]{queryState});
    $self->assert_equals(JSON::false, $res->[0][1]{canCalculateChanges});
    $self->assert_num_equals(0, $res->[0][1]{position});
    $self->assert_num_equals(0, $res->[0][1]{total});
    $self->assert_not_null($res->[0][1]{ids});

    xlog "get email submission list (error arguments)";
    $res = $jmap->CallMethods([['EmailSubmission/query', { filter => 1 }, "R1"]]);
    $self->assert_str_equals('invalidArguments', $res->[0][1]{type});
}

sub test_emailsubmission_querychanges
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "get current email submission state";
    my $res = $jmap->CallMethods([['EmailSubmission/query', { }, "R1"]]);
    my $state = $res->[0][1]->{queryState};
    $self->assert_not_null($state);

    xlog "get email submission list updates (empty filter)";
    $res = $jmap->CallMethods([['EmailSubmission/queryChanges', {
        filter => {},
        sinceQueryState => $state,
    }, "R1"]]);
    $self->assert_str_equals("error", $res->[0][0]);
    $self->assert_str_equals("cannotCalculateChanges", $res->[0][1]{type});
    $self->assert_str_equals("R1", $res->[0][2]);
}

sub test_email_set_move
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Create test mailboxes";
    my $res = $jmap->CallMethods([
        ['Mailbox/set', { create => {
            "a" => { name => "a", parentId => undef },
            "b" => { name => "b", parentId => undef },
            "c" => { name => "c", parentId => undef },
            "d" => { name => "d", parentId => undef },
        }}, "R1"]
    ]);
    $self->assert_num_equals( 4, scalar keys %{$res->[0][1]{created}} );
    my $a = $res->[0][1]{created}{"a"}{id};
    my $b = $res->[0][1]{created}{"b"}{id};
    my $c = $res->[0][1]{created}{"c"}{id};
    my $d = $res->[0][1]{created}{"d"}{id};

    xlog "Generate a email via IMAP";
    my %exp_sub;
    $exp_sub{A} = $self->make_message(
        "foo", body => "a email",
    );

    xlog "get email id";
    $res = $jmap->CallMethods( [ [ 'Email/query', {}, "R1" ] ] );
    my $id = $res->[0][1]->{ids}[0];

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    my $msg = $res->[0][1]->{list}[0];
    $self->assert_num_equals(1, scalar keys %{$msg->{mailboxIds}});

    local *assert_move = sub {
        my ($moveto) = (@_);

        xlog "move email to " . Dumper($moveto);
        $res = $jmap->CallMethods(
            [ [ 'Email/set', {
                    update => { $id => { 'mailboxIds' => $moveto } },
            }, "R1" ] ] );
        $self->assert(exists $res->[0][1]{updated}{$id});

        $res = $jmap->CallMethods( [ [ 'Email/get', { ids => [$id], properties => ['mailboxIds'] }, "R1" ] ] );
        $msg = $res->[0][1]->{list}[0];

        $self->assert_deep_equals($moveto, $msg->{mailboxIds});
    };

    assert_move({$a => JSON::true, $b => JSON::true});
    assert_move({$a => JSON::true, $b => JSON::true, $c => JSON::true});
    assert_move({$d => JSON::true});
}

sub test_email_set_move_keywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate an email via IMAP";
    my %exp_sub;
    $exp_sub{A} = $self->make_message(
        "foo", body => "a email",
    );
    xlog "Set flags on message";
    $store->set_folder('INBOX');
    $talk->store('1', '+flags', '($foo \\Flagged)');

    xlog "get email";
    my $res = $jmap->CallMethods([
        ['Email/query', {}, 'R1'],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids'},
            properties => [ 'keywords', 'mailboxIds' ],
        }, 'R2' ]
    ]);
    my $msg = $res->[1][1]->{list}[0];
    $self->assert_num_equals(1, scalar keys %{$msg->{mailboxIds}});
    my $msgId = $msg->{id};
    my $inboxId = (keys %{$msg->{mailboxIds}})[0];
    $self->assert_not_null($inboxId);
    my $keywords = $msg->{keywords};

    xlog "create Archive mailbox";
    $res = $jmap->CallMethods([ ['Mailbox/get', {}, 'R1'], ]);
    my $mboxState = $res->[0][1]{state};
    $talk->create("INBOX.Archive", "(USE (\\Archive))") || die;
    $res = $jmap->CallMethods([
        ['Mailbox/changes', {sinceState => $mboxState }, 'R1'],
    ]);
    my $archiveId = $res->[0][1]{created}[0];
    $self->assert_not_null($archiveId);
    $self->assert_deep_equals([], $res->[0][1]->{updated});
    $self->assert_deep_equals([], $res->[0][1]->{destroyed});

    xlog "move email to Archive";
    xlog "update email";
    $res = $jmap->CallMethods([
        ['Email/set', { update => {
            $msgId => {
                mailboxIds => { $archiveId => JSON::true }
            },
        }}, "R1"],
        ['Email/get', { ids => [ $msgId ], properties => ['keywords'] }, 'R2'],
    ]);
    $self->assert(exists $res->[0][1]{updated}{$msgId});
    $self->assert_deep_equals($keywords, $res->[1][1]{list}[0]{keywords});
}

sub test_email_set_update
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $drafts = $res->[0][1]{created}{"1"}{id};

    my $draft =  {
        mailboxIds => {$drafts => JSON::true},
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ],
        to => [ { name => "Bugs Bunny", email => "bugs\@acme.local" } ],
        cc => [ { name => "Elmer Fudd", email => "elmer\@acme.local" } ],
        subject => "created",
        htmlBody => [ {partId => '1'} ],
        bodyValues => { 1 => { value => "Oh!!! I <em>hate</em> that Rabbit." }},
        keywords => {
            '$Draft' => JSON::true,
        }
    };

    xlog "Create a draft";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $draft }}, "R1"]]);
    my $id = $res->[0][1]{created}{"1"}{id};

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    my $msg = $res->[0][1]->{list}[0];

    xlog "Update draft $id";
    $draft->{keywords} = {
        '$draft' => JSON::true,
        '$flagged' => JSON::true,
        '$seen' => JSON::true,
        '$answered' => JSON::true,
    };
    $res = $jmap->CallMethods([['Email/set', { update => { $id => $draft }}, "R1"]]);

    xlog "Get draft $id";
    $res = $jmap->CallMethods([['Email/get', { ids => [$id] }, "R1"]]);
    $msg = $res->[0][1]->{list}[0];
    $self->assert_deep_equals($draft->{keywords}, $msg->{keywords});
}

sub test_email_set_seen
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # See https://github.com/cyrusimap/cyrus-imapd/issues/2270

    my $talk = $self->{store}->get_client();
    $self->{store}->_select();
    $self->{store}->set_fetch_attributes(qw(uid flags));

    xlog "Add message";
    $self->make_message('Message A');

    xlog "Query email";
    my $inbox = $self->getinbox();
    my $res = $jmap->CallMethods([
        ['Email/query', {
            filter => { inMailbox => $inbox->{id} }
        }, 'R1'],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids'}
        }, 'R2' ]
    ]);

    my $keywords = { };
    my $msg = $res->[1][1]->{list}[0];
    $self->assert_deep_equals($keywords, $msg->{keywords});

    $keywords->{'$seen'} = JSON::true;
    $res = $jmap->CallMethods([
        ['Email/set', { update => { $msg->{id} => { 'keywords/$seen' => JSON::true } } }, 'R1'],
        ['Email/get', { ids => [ $msg->{id} ] }, 'R2'],
    ]);
    $msg = $res->[1][1]->{list}[0];
    $self->assert_deep_equals($keywords, $msg->{keywords});
}

sub test_email_set_destroy
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create mailboxes";
    my $res = $jmap->CallMethods(
        [
            [
                'Mailbox/set',
                {
                    create => {
                        "1" => {
                            name     => "drafts",
                            parentId => undef,
                            role     => "drafts"
                        },
                        "2" => {
                            name     => "foo",
                            parentId => undef,
                        },
                        "3" => {
                            name     => "bar",
                            parentId => undef,
                        },
                    }
                },
                "R1"
            ]
        ]
    );
    $self->assert_str_equals( $res->[0][0], 'Mailbox/set' );
    $self->assert_str_equals( $res->[0][2], 'R1' );
    $self->assert_not_null( $res->[0][1]{created} );
    my $mailboxids = {
        $res->[0][1]{created}{"1"}{id} => JSON::true,
        $res->[0][1]{created}{"2"}{id} => JSON::true,
        $res->[0][1]{created}{"3"}{id} => JSON::true,
    };

    xlog "Create a draft";
    my $draft = {
        mailboxIds => $mailboxids,
        from       => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ],
        to         => [ { name => "Bugs Bunny", email => "bugs\@acme.local" } ],
        subject    => "created",
        textBody   => [{ partId => '1' }],
        bodyValues => { '1' => { value => "Oh!!! I *hate* that Rabbit." }},
        keywords => { '$Draft' => JSON::true },
    };
    $res = $jmap->CallMethods(
        [ [ 'Email/set', { create => { "1" => $draft } }, "R1" ] ],
    );
    my $id = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($id);

    xlog "Get draft $id";
    $res = $jmap->CallMethods( [ [ 'Email/get', { ids => [$id] }, "R1" ] ]);
    $self->assert_num_equals(3, scalar keys %{$res->[0][1]->{list}[0]{mailboxIds}});

    xlog "Destroy draft $id";
    $res = $jmap->CallMethods(
        [ [ 'Email/set', { destroy => [ $id ] }, "R1" ] ],
    );
    $self->assert_str_equals( $res->[0][1]{destroyed}[0], $id );

    xlog "Get draft $id";
    $res = $jmap->CallMethods( [ [ 'Email/get', { ids => [$id] }, "R1" ] ]);
    $self->assert_str_equals( $res->[0][1]->{notFound}[0], $id );

    xlog "Get emails";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});
}

sub test_email_query
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $account = undef;
    my $store = $self->{store};
    my $mboxprefix = "INBOX";
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { accountId => $account }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    xlog "create mailboxes";
    $talk->create("$mboxprefix.A") || die;
    $talk->create("$mboxprefix.B") || die;
    $talk->create("$mboxprefix.C") || die;

    $res = $jmap->CallMethods([['Mailbox/get', { accountId => $account }, "R1"]]);
    my %m = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $mboxa = $m{"A"}->{id};
    my $mboxb = $m{"B"}->{id};
    my $mboxc = $m{"C"}->{id};
    $self->assert_not_null($mboxa);
    $self->assert_not_null($mboxb);
    $self->assert_not_null($mboxc);

    xlog "create emails";
    my %params;
    $store->set_folder("$mboxprefix.A");
    my $dtfoo = DateTime->new(
        year       => 2016,
        month      => 11,
        day        => 1,
        hour       => 7,
        time_zone  => 'Etc/UTC',
    );
    my $bodyfoo = "A rather short email";
    %params = (
        date => $dtfoo,
        body => $bodyfoo,
        store => $store,
    );
    $res = $self->make_message("foo", %params) || die;
    $talk->copy(1, "$mboxprefix.C") || die;

    $store->set_folder("$mboxprefix.B");
    my $dtbar = DateTime->new(
        year       => 2016,
        month      => 3,
        day        => 1,
        hour       => 19,
        time_zone  => 'Etc/UTC',
    );
    my $bodybar = ""
    . "In the context of electronic mail, emails are viewed as having an\r\n"
    . "envelope and contents.  The envelope contains whatever information is\r\n"
    . "needed to accomplish transmission and delivery.  (See [RFC5321] for a\r\n"
    . "discussion of the envelope.)  The contents comprise the object to be\r\n"
    . "delivered to the recipient.  This specification applies only to the\r\n"
    . "format and some of the semantics of email contents.  It contains no\r\n"
    . "specification of the information in the envelope.i\r\n"
    . "\r\n"
    . "However, some email systems may use information from the contents\r\n"
    . "to create the envelope.  It is intended that this specification\r\n"
    . "facilitate the acquisition of such information by programs.\r\n"
    . "\r\n"
    . "This specification is intended as a definition of what email\r\n"
    . "content format is to be passed between systems.  Though some email\r\n"
    . "systems locally store emails in this format (which eliminates the\r\n"
    . "need for translation between formats) and others use formats that\r\n"
    . "differ from the one specified in this specification, local storage is\r\n"
    . "outside of the scope of this specification.\r\n";

    %params = (
        date => $dtbar,
        body => $bodybar,
        extra_headers => [
            ['x-tra', "baz"],
        ],
        store => $store,
    );
    $self->make_message("bar", %params) || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch emails without filter";
    $res = $jmap->CallMethods([
        ['Email/query', { accountId => $account }, 'R1'],
        ['Email/get', {
            accountId => $account,
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' }
        }, 'R2'],
    ]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_num_equals(2, scalar @{$res->[1][1]->{list}});

    %m = map { $_->{subject} => $_ } @{$res->[1][1]{list}};
    my $foo = $m{"foo"}->{id};
    my $bar = $m{"bar"}->{id};
    $self->assert_not_null($foo);
    $self->assert_not_null($bar);

    xlog "filter text";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        text => "foo",
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

    xlog "filter NOT text";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        operator => "NOT",
                        conditions => [ {text => "foo"} ],
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

    xlog "filter mailbox A";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        inMailbox => $mboxa,
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

    xlog "filter mailboxes";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        operator => 'OR',
                        conditions => [
                            {
                                inMailbox => $mboxa,
                            },
                            {
                                inMailbox => $mboxc,
                            },
                        ],
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

    xlog "filter mailboxes with not in";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        inMailboxOtherThan => [$mboxb],
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

    xlog "filter mailboxes";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        operator => 'AND',
                        conditions => [
                            {
                                inMailbox => $mboxa,
                            },
                            {
                                inMailbox => $mboxb,
                            },
                            {
                                inMailbox => $mboxc,
                            },
                        ],
                    },
                }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "filter not in mailbox A";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        operator => 'NOT',
                        conditions => [
                            {
                                inMailbox => $mboxa,
                            },
                        ],
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

    xlog "filter by before";
    my $dtbefore = $dtfoo->clone()->subtract(seconds => 1);
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        before => $dtbefore->strftime('%Y-%m-%dT%TZ'),
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

    xlog "filter by after",
    my $dtafter = $dtbar->clone()->add(seconds => 1);
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        after => $dtafter->strftime('%Y-%m-%dT%TZ'),
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

    xlog "filter by after and before",
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        after => $dtafter->strftime('%Y-%m-%dT%TZ'),
                        before => $dtbefore->strftime('%Y-%m-%dT%TZ'),
                    },
                }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "filter by minSize";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        minSize => length($bodybar),
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

    xlog "filter by maxSize";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        maxSize => length($bodybar),
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

    xlog "filter by header";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        header => [ "x-tra" ],
                    },
                }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

    xlog "filter by header and value";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    filter => {
                        header => [ "x-tra", "bam" ],
                    },
                }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "sort by ascending receivedAt";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    sort => [{ property => "receivedAt" }],
                }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[1]);

    xlog "sort by descending receivedAt";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    sort => [{ property => "receivedAt", isAscending => JSON::false }],
                }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[1]);

    xlog "sort by ascending size";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    sort => [{ property =>  "size" }],
                }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[1]);

    xlog "sort by descending size";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    sort => [{ property => "size", isAscending => JSON::false }],
                }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($foo, $res->[0][1]->{ids}[1]);

    xlog "sort by ascending id";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    sort => [{ property => "id" }],
                }, "R1"]]);
    my @ids = sort ($foo, $bar);
    $self->assert_deep_equals(\@ids, $res->[0][1]->{ids});

    xlog "sort by descending id";
    $res = $jmap->CallMethods([['Email/query', {
                    accountId => $account,
                    sort => [{ property => "id", isAscending => JSON::false }],
                }, "R1"]]);
    @ids = reverse sort ($foo, $bar);
    $self->assert_deep_equals(\@ids, $res->[0][1]->{ids});

    xlog "delete mailboxes";
    $talk->delete("$mboxprefix.A") or die;
    $talk->delete("$mboxprefix.B") or die;
    $talk->delete("$mboxprefix.C") or die;
}

sub test_email_query_bcc
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $account = undef;
    my $store = $self->{store};
    my $mboxprefix = "INBOX";
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { accountId => $account }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    xlog "create email1";
    my $bcc1  = Cassandane::Address->new(localpart => 'needle', domain => 'local');
    my $msg1 = $self->make_message('msg1', bcc => $bcc1);

    my $bcc2  = Cassandane::Address->new(localpart => 'beetle', domain => 'local');
    my $msg2 = $self->make_message('msg2', bcc => $bcc2);

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch emails without filter";
    $res = $jmap->CallMethods([
        ['Email/query', { accountId => $account }, 'R1'],
        ['Email/get', {
            accountId => $account,
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' }
        }, 'R2'],
    ]);

    my %m = map { $_->{subject} => $_ } @{$res->[1][1]{list}};
    my $emailId1 = $m{"msg1"}->{id};
    my $emailId2 = $m{"msg2"}->{id};
    $self->assert_not_null($emailId1);
    $self->assert_not_null($emailId2);

    xlog "filter text";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            text => "needle",
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId1, $res->[0][1]->{ids}[0]);

    xlog "filter NOT text";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            operator => "NOT",
            conditions => [ {text => "needle"} ],
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId2, $res->[0][1]->{ids}[0]);

    xlog "filter bcc";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            bcc => "needle",
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId1, $res->[0][1]->{ids}[0]);

    xlog "filter NOT bcc";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            operator => "NOT",
            conditions => [ {bcc => "needle"} ],
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId2, $res->[0][1]->{ids}[0]);
}


sub test_email_query_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $admintalk = $self->{adminstore}->get_client();
    $self->{instance}->create_user("test");
    $admintalk->setacl("user.test", "cassandane", "lrwkx") or die;

    # run tests for both the main and "test" account
    foreach (undef, "test") {
        my $account = $_;
        my $store = defined $account ? $self->{adminstore} : $self->{store};
        my $mboxprefix = defined $account ? "user.$account" : "INBOX";
        my $talk = $store->get_client();

        my $res = $jmap->CallMethods([['Mailbox/get', { accountId => $account }, "R1"]]);
        my $inboxid = $res->[0][1]{list}[0]{id};

        xlog "create mailboxes";
        $talk->create("$mboxprefix.A") || die;
        $talk->create("$mboxprefix.B") || die;
        $talk->create("$mboxprefix.C") || die;

        $res = $jmap->CallMethods([['Mailbox/get', { accountId => $account }, "R1"]]);
        my %m = map { $_->{name} => $_ } @{$res->[0][1]{list}};
        my $mboxa = $m{"A"}->{id};
        my $mboxb = $m{"B"}->{id};
        my $mboxc = $m{"C"}->{id};
        $self->assert_not_null($mboxa);
        $self->assert_not_null($mboxb);
        $self->assert_not_null($mboxc);

        xlog "create emails";
        my %params;
        $store->set_folder("$mboxprefix.A");
        my $dtfoo = DateTime->new(
            year       => 2016,
            month      => 11,
            day        => 1,
            hour       => 7,
            time_zone  => 'Etc/UTC',
        );
        my $bodyfoo = "A rather short email";
        %params = (
            date => $dtfoo,
            body => $bodyfoo,
            store => $store,
        );
        $res = $self->make_message("foo", %params) || die;
        $talk->copy(1, "$mboxprefix.C") || die;

        $store->set_folder("$mboxprefix.B");
        my $dtbar = DateTime->new(
            year       => 2016,
            month      => 3,
            day        => 1,
            hour       => 19,
            time_zone  => 'Etc/UTC',
        );
        my $bodybar = ""
        . "In the context of electronic mail, emails are viewed as having an\r\n"
        . "envelope and contents.  The envelope contains whatever information is\r\n"
        . "needed to accomplish transmission and delivery.  (See [RFC5321] for a\r\n"
        . "discussion of the envelope.)  The contents comprise the object to be\r\n"
        . "delivered to the recipient.  This specification applies only to the\r\n"
        . "format and some of the semantics of email contents.  It contains no\r\n"
        . "specification of the information in the envelope.i\r\n"
        . "\r\n"
        . "However, some email systems may use information from the contents\r\n"
        . "to create the envelope.  It is intended that this specification\r\n"
        . "facilitate the acquisition of such information by programs.\r\n"
        . "\r\n"
        . "This specification is intended as a definition of what email\r\n"
        . "content format is to be passed between systems.  Though some email\r\n"
        . "systems locally store emails in this format (which eliminates the\r\n"
        . "need for translation between formats) and others use formats that\r\n"
        . "differ from the one specified in this specification, local storage is\r\n"
        . "outside of the scope of this specification.\r\n";

        %params = (
            date => $dtbar,
            body => $bodybar,
            extra_headers => [
                ['x-tra', "baz"],
            ],
            store => $store,
        );
        $self->make_message("bar", %params) || die;

        xlog "run squatter";
        $self->{instance}->run_command({cyrus => 1}, 'squatter');

        xlog "fetch emails without filter";
        $res = $jmap->CallMethods([
                ['Email/query', { accountId => $account }, 'R1'],
                ['Email/get', {
                        accountId => $account,
                        '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' }
                    }, 'R2'],
            ]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert_num_equals(2, scalar @{$res->[1][1]->{list}});

        %m = map { $_->{subject} => $_ } @{$res->[1][1]{list}};
        my $foo = $m{"foo"}->{id};
        my $bar = $m{"bar"}->{id};
        $self->assert_not_null($foo);
        $self->assert_not_null($bar);

        xlog "filter text";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            text => "foo",
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

        xlog "filter NOT text";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            operator => "NOT",
                            conditions => [ {text => "foo"} ],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

        xlog "filter mailbox A";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            inMailbox => $mboxa,
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

        xlog "filter mailboxes";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            operator => 'OR',
                            conditions => [
                                {
                                    inMailbox => $mboxa,
                                },
                                {
                                    inMailbox => $mboxc,
                                },
                            ],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

        xlog "filter mailboxes with not in";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            inMailboxOtherThan => [$mboxb],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

        xlog "filter mailboxes with not in";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            inMailboxOtherThan => [$mboxa],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});

        xlog "filter mailboxes with not in";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            inMailboxOtherThan => [$mboxa, $mboxc],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

        xlog "filter mailboxes";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            operator => 'AND',
                            conditions => [
                                {
                                    inMailbox => $mboxa,
                                },
                                {
                                    inMailbox => $mboxb,
                                },
                                {
                                    inMailbox => $mboxc,
                                },
                            ],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

        xlog "filter not in mailbox A";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            operator => 'NOT',
                            conditions => [
                                {
                                    inMailbox => $mboxa,
                                },
                            ],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

        xlog "filter by before";
        my $dtbefore = $dtfoo->clone()->subtract(seconds => 1);
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            before => $dtbefore->strftime('%Y-%m-%dT%TZ'),
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

        xlog "filter by after",
        my $dtafter = $dtbar->clone()->add(seconds => 1);
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            after => $dtafter->strftime('%Y-%m-%dT%TZ'),
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

        xlog "filter by after and before",
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            after => $dtafter->strftime('%Y-%m-%dT%TZ'),
                            before => $dtbefore->strftime('%Y-%m-%dT%TZ'),
                        },
                    }, "R1"]]);
        $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

        xlog "filter by minSize";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            minSize => length($bodybar),
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

        xlog "filter by maxSize";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            maxSize => length($bodybar),
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);

        xlog "filter by header";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            header => [ "x-tra" ],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);

        xlog "filter by header and value";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        filter => {
                            header => [ "x-tra", "bam" ],
                        },
                    }, "R1"]]);
        $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

        xlog "sort by ascending receivedAt";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        sort => [{ property => "receivedAt" }],
                    }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[1]);

        xlog "sort by descending receivedAt";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        sort => [{ property => "receivedAt", isAscending => JSON::false, }],
                    }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[1]);

        xlog "sort by ascending size";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        sort => [{ property => "size" }],
                    }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[0]);
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[1]);

        xlog "sort by descending size";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        sort => [{ property => "size", isAscending => JSON::false }],
                    }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($bar, $res->[0][1]->{ids}[0]);
        $self->assert_str_equals($foo, $res->[0][1]->{ids}[1]);

        xlog "sort by ascending id";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        sort => [{ property => "id" }],
                    }, "R1"]]);
        my @ids = sort ($foo, $bar);
        $self->assert_deep_equals(\@ids, $res->[0][1]->{ids});

        xlog "sort by descending id";
        $res = $jmap->CallMethods([['Email/query', {
                        accountId => $account,
                        sort => [{ property => "id", isAscending => JSON::false }],
                    }, "R1"]]);
        @ids = reverse sort ($foo, $bar);
        $self->assert_deep_equals(\@ids, $res->[0][1]->{ids});

        xlog "delete mailboxes";
        $talk->delete("$mboxprefix.A") or die;
        $talk->delete("$mboxprefix.B") or die;
        $talk->delete("$mboxprefix.C") or die;
    }
}

sub test_email_query_keywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    xlog "create email";
    $res = $self->make_message("foo") || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch emails without filter";
    $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
    ]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $fooid = $res->[0][1]->{ids}[0];

    xlog "fetch emails with \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            hasKeyword => '$Seen',
        }
    }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "fetch emails without \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            notKeyword => '$Seen',
        }
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});

    xlog 'set $Seen flag on email';
    $res = $jmap->CallMethods([['Email/set', {
        update => {
            $fooid => {
                keywords => { '$Seen' => JSON::true },
            },
        }
    }, "R1"]]);
    $self->assert(exists $res->[0][1]->{updated}{$fooid});

    xlog "fetch emails with \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            hasKeyword => '$Seen',
        }
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});

    xlog "fetch emails without \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            notKeyword => '$Seen',
        }
    }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "create email";
    $res = $self->make_message("bar") || die;

    xlog "fetch emails without \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            notKeyword => '$Seen',
        }
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $barid = $res->[0][1]->{ids}[0];
    $self->assert_str_not_equals($barid, $fooid);

    xlog "fetch emails sorted ascending by \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ property => 'hasKeyword', keyword => '$Seen' }],
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($barid, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($fooid, $res->[0][1]->{ids}[1]);

    xlog "fetch emails sorted descending by \$Seen flag";
    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ property => 'hasKeyword', keyword => '$Seen', isAscending => JSON::false }],
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($fooid, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($barid, $res->[0][1]->{ids}[1]);
}

sub test_email_query_userkeywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "create email foo";
    my $res = $self->make_message("foo") || die;

    xlog "fetch foo's id";
    $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    my $fooid = $res->[0][1]->{ids}[0];
    $self->assert_not_null($fooid);

    xlog 'set foo flag on email foo';
    $res = $jmap->CallMethods([['Email/set', {
        update => {
            $fooid => {
                keywords => { 'foo' => JSON::true },
            },
        }
    }, "R1"]]);
    $self->assert(exists $res->[0][1]->{updated}{$fooid});

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch emails with foo flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            hasKeyword => 'foo',
        }
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($fooid, $res->[0][1]->{ids}[0]);

    xlog "create email bar";
    $res = $self->make_message("bar") || die;

    xlog "fetch emails without foo flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            notKeyword => 'foo',
        }
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $barid = $res->[0][1]->{ids}[0];
    $self->assert_str_not_equals($barid, $fooid);

    xlog "fetch emails sorted ascending by foo flag";
    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ property => 'hasKeyword', keyword => 'foo' }],
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($barid, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($fooid, $res->[0][1]->{ids}[1]);

    xlog "fetch emails sorted descending by foo flag";
    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ property => 'hasKeyword', keyword => 'foo', isAscending => JSON::false }],
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($fooid, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($barid, $res->[0][1]->{ids}[1]);
}

sub test_email_query_threadkeywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    my $convflags = $self->{instance}->{config}->get('conversations_counted_flags');
    if (not defined $convflags) {
        xlog "conversations_counted_flags not configured. Skipping test";
        return;
    }

    my $store = $self->{store};
    my $talk = $store->get_client();

    my %params = (store => $store);
    $store->set_folder("INBOX");

    xlog "generating email A";
    $exp{A} = $self->make_message("Email A", %params);
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", %params);
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    %params = (
        references => [ $exp{A} ],
        store => $store,
    );
    $exp{C} = $self->make_message("Re: Email A", %params);
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch email ids";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' } }, 'R2' ],
    ]);
    my %m = map { $_->{subject} => $_ } @{$res->[1][1]{list}};
    my $msga = $m{"Email A"};
    my $msgb = $m{"Email B"};
    my $msgc = $m{"Re: Email A"};
    $self->assert_not_null($msga);
    $self->assert_not_null($msgb);
    $self->assert_not_null($msgc);

    my @flags = split ' ', $convflags;
    foreach (@flags) {
        my $flag = $_;
        next if lc $flag eq '$hasattachment';  # special case

        xlog "Testing for counted conversation flag $flag";
        $flag =~ s+^\\+\$+ ;

        xlog "fetch collapsed threads with some $flag flag";
        $res = $jmap->CallMethods([['Email/query', {
            filter => {
                someInThreadHaveKeyword => $flag,
            },
            collapseThreads => JSON::true,
        }, "R1"]]);
        $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

        xlog "set $flag flag on email email A";
        $res = $jmap->CallMethods([['Email/set', {
            update => {
                $msga->{id} => {
                    keywords => { $flag => JSON::true },
                },
            }
        }, "R1"]]);

        xlog "fetch collapsed threads with some $flag flag";
        $res = $jmap->CallMethods([
            ['Email/query', {
                filter => {
                    someInThreadHaveKeyword => $flag,
                },
                collapseThreads => JSON::true,
            }, "R1"],
        ]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert(
            ($msga->{id} eq $res->[0][1]->{ids}[0]) or
            ($msgc->{id} eq $res->[0][1]->{ids}[0])
        );

        xlog "fetch collapsed threads with no $flag flag";
        $res = $jmap->CallMethods([['Email/query', {
            filter => {
                noneInThreadHaveKeyword => $flag,
            },
            collapseThreads => JSON::true,
        }, "R1"]]);
        $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($msgb->{id}, $res->[0][1]->{ids}[0]);

        xlog "fetch collapsed threads sorted ascending by $flag";
        $res = $jmap->CallMethods([['Email/query', {
            sort => [{ property => "someInThreadHaveKeyword", keyword => $flag }],
            collapseThreads => JSON::true,
        }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert_str_equals($msgb->{id}, $res->[0][1]->{ids}[0]);
        $self->assert(
            ($msga->{id} eq $res->[0][1]->{ids}[1]) or
            ($msgc->{id} eq $res->[0][1]->{ids}[1])
        );

        xlog "fetch collapsed threads sorted descending by $flag";
        $res = $jmap->CallMethods([['Email/query', {
            sort => [{ property => "someInThreadHaveKeyword", keyword => $flag, isAscending => JSON::false }],
            collapseThreads => JSON::true,
        }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
        $self->assert(
            ($msga->{id} eq $res->[0][1]->{ids}[0]) or
            ($msgc->{id} eq $res->[0][1]->{ids}[0])
        );
        $self->assert_str_equals($msgb->{id}, $res->[0][1]->{ids}[1]);

        xlog 'reset keywords on email email A';
        $res = $jmap->CallMethods([['Email/set', {
            update => {
                $msga->{id} => {
                    keywords => { },
                },
            }
        }, "R1"]]);
    }

    # test that 'someInThreadHaveKeyword' filter fail
    # with an 'cannotDoFilter' error for flags that are not defined
    # in the conversations_counted_flags config option
    xlog "fetch collapsed threads with unsupported flag";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            someInThreadHaveKeyword => 'notcountedflag',
        },
        collapseThreads => JSON::true,
    }, "R1"]]);
    $self->assert_str_equals('error', $res->[0][0]);
    $self->assert_str_equals('unsupportedFilter', $res->[0][1]->{type});
}

sub test_email_query_empty
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # See
    # https://github.com/cyrusimap/cyrus-imapd/issues/2266
    # and
    # https://github.com/cyrusimap/cyrus-imapd/issues/2287

    my $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    $self->assert(ref($res->[0][1]->{ids}) eq 'ARRAY');
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    $res = $jmap->CallMethods([['Email/query', { limit => 0 }, "R1"]]);
    $self->assert(ref($res->[0][1]->{ids}) eq 'ARRAY');
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});
}

sub test_email_query_collapse
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    my $admintalk = $self->{adminstore}->get_client();
    $self->{instance}->create_user("test");
    $admintalk->setacl("user.test", "cassandane", "lrwkx") or die;

    # run tests for both the main and "test" account
    foreach (undef, "test") {
        my $account = $_;
        my $store = defined $account ? $self->{adminstore} : $self->{store};
        my $mboxprefix = defined $account ? "user.$account" : "INBOX";
        my $talk = $store->get_client();

        my %params = (store => $store);
        $store->set_folder($mboxprefix);

        xlog "generating email A";
        $exp{A} = $self->make_message("Email A", %params);
        $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

        xlog "generating email B";
        $exp{B} = $self->make_message("Email B", %params);
        $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

        xlog "generating email C referencing A";
        %params = (
            references => [ $exp{A} ],
            store => $store,
        );
        $exp{C} = $self->make_message("Re: Email A", %params);
        $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

        xlog "list uncollapsed threads";
        $res = $jmap->CallMethods([['Email/query', { accountId => $account }, "R1"]]);
        $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});

        $res = $jmap->CallMethods([['Email/query', { accountId => $account, collapseThreads => JSON::true }, "R1"]]);
        $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    }
}

sub test_email_query_inmailbox_null
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    xlog "generating email A";
    $self->make_message("Email A") or die;

    xlog "call Email/query with null inMailbox";
    my $res = $jmap->CallMethods([['Email/query', { filter => { inMailbox => undef } }, "R1"]]);
    $self->assert_str_equals("invalidArguments", $res->[0][1]{type});
}

sub test_email_query_cached
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $search_db = $self->{instance}->{config}->get('jmap_emailsearch_db_path');
    if (not defined $search_db) {
        return;
    }

    my $res = $jmap->CallMethods([['Mailbox/get', { }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    xlog "create emails";
    $res = $self->make_message("foo 1") || die;
    $res = $self->make_message("foo 2") || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $query1 = {
        filter => {
            subject => 'foo',
        },
        sort => [{ property => 'subject' }],
    };

    my $query2 = {
        filter => {
            subject => 'foo',
        },
        sort => [{ property => 'subject', isAscending => JSON::false }],
    };

    xlog "run query #1";
    $res = $jmap->CallMethods([['Email/query', $query1, 'R1']]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::false, $res->[0][1]->{isCached});

    xlog "re-run query #1";
    $res = $jmap->CallMethods([['Email/query', $query1, 'R1']]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::true, $res->[0][1]->{isCached});

    xlog "run query #2";
    $res = $jmap->CallMethods([['Email/query', $query2, 'R1']]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::false, $res->[0][1]->{isCached});

    xlog "re-run query #1 (still cached)";
    $res = $jmap->CallMethods([['Email/query', $query1, 'R1']]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::true, $res->[0][1]->{isCached});

    xlog "re-run query #2 (still cached)";
    $res = $jmap->CallMethods([['Email/query', $query2, 'R1']]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::true, $res->[0][1]->{isCached});

    xlog "change Email state";
    $res = $self->make_message("foo 3") || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "re-run query #1 (cache invalidated)";
    $res = $jmap->CallMethods([['Email/query', $query1, 'R1']]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::false, $res->[0][1]->{isCached});

    xlog "re-run query #2 (cache invalidated)";
    $res = $jmap->CallMethods([['Email/query', $query2, 'R1']]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});
    $self->assert_equals(JSON::false, $res->[0][1]->{isCached});
}

sub test_email_query_inmailboxid_conjunction
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    xlog "create mailboxes";
    $imap->create("INBOX.A") or die;
    $imap->create("INBOX.B") or die;
    my $res = $jmap->CallMethods([
        ['Mailbox/get', {
            properties => ['name', 'parentId'],
        }, "R1"]
    ]);
    my %mboxByName = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $mboxIdA = $mboxByName{'A'}->{id};
    my $mboxIdB = $mboxByName{'B'}->{id};

    xlog "create emails";
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                'mAB' => {
                    mailboxIds => {
                        $mboxIdA => JSON::true,
                        $mboxIdB => JSON::true,
                    },
                    from => [{
                        name => '', email => 'foo@local'
                    }],
                    to => [{
                        name => '', email => 'bar@local'
                    }],
                    subject => 'AB',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'test',
                        }
                    },
                },
                'mA' => {
                    mailboxIds => {
                        $mboxIdA => JSON::true,
                    },
                    from => [{
                        name => '', email => 'foo@local'
                    }],
                    to => [{
                        name => '', email => 'bar@local'
                    }],
                    subject => 'A',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'test',
                        }
                    },
                },
                'mB' => {
                    mailboxIds => {
                        $mboxIdB => JSON::true,
                    },
                    from => [{
                        name => '', email => 'foo@local'
                    }],
                    to => [{
                        name => '', email => 'bar@local'
                    }],
                    subject => 'B',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'test',
                        }
                    },
                },
            },
        }, 'R1'],
    ]);
    my $emailIdAB = $res->[0][1]->{created}{mAB}{id};
    $self->assert_not_null($emailIdAB);
    my $emailIdA = $res->[0][1]->{created}{mA}{id};
    $self->assert_not_null($emailIdA);
    my $emailIdB = $res->[0][1]->{created}{mB}{id};
    $self->assert_not_null($emailIdB);

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "query emails in mailboxes A AND B";
    $res = $jmap->CallMethods([
        ['Email/query', {
            filter => {
                operator => 'AND',
                conditions => [{
                    inMailbox => $mboxIdA,
                }, {
                    inMailbox => $mboxIdB,
                }],
            },
        }, 'R1'],
    ]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailIdAB, $res->[0][1]->{ids}[0]);

    xlog "query emails in mailboxes A AND B (forcing indexed search)";
    $res = $jmap->CallMethods([
        ['Email/query', {
            filter => {
                operator => 'AND',
                conditions => [{
                    inMailbox => $mboxIdA,
                }, {
                    inMailbox => $mboxIdB,
                }, {
                    text => "test",
                }],
            },
        }, 'R1'],
    ]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailIdAB, $res->[0][1]->{ids}[0]);
}

sub test_email_query_moved
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    xlog "create mailboxes";
    $imap->create("INBOX.A") or die;
    $imap->create("INBOX.B") or die;
    my $res = $jmap->CallMethods([
        ['Mailbox/get', {
            properties => ['name', 'parentId'],
        }, "R1"]
    ]);
    my %mboxByName = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $mboxIdA = $mboxByName{'A'}->{id};
    my $mboxIdB = $mboxByName{'B'}->{id};

    xlog "create emails in mailbox A";
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                'msg1' => {
                    mailboxIds => {
                        $mboxIdA => JSON::true,
                    },
                    from => [{
                        name => '', email => 'foo@local'
                    }],
                    to => [{
                        name => '', email => 'bar@local'
                    }],
                    subject => 'message 1',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'test',
                        }
                    },
                },
            },
        }, 'R1'],
        ['Email/set', {
            create => {
                'msg2' => {
                    mailboxIds => {
                        $mboxIdA => JSON::true,
                    },
                    from => [{
                        name => '', email => 'foo@local'
                    }],
                    to => [{
                        name => '', email => 'bar@local'
                    }],
                    subject => 'message 2',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'test',
                        }
                    },
                },
            },
        }, 'R2'],
    ]);
    my $emailId1 = $res->[0][1]->{created}{msg1}{id};
    $self->assert_not_null($emailId1);
    my $emailId2 = $res->[1][1]->{created}{msg2}{id};
    $self->assert_not_null($emailId2);

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "query emails";
    $res = $jmap->CallMethods([
        ['Email/query', {
            filter => {
                inMailbox => $mboxIdA,
                text => 'message',
            },
            sort => [{
                property => 'subject',
                isAscending => JSON::true,
            }],
        }, 'R1'],
    ]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId1, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($emailId2, $res->[0][1]->{ids}[1]);

    xlog "move msg2 to mailbox B";
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $emailId2 => {
                    mailboxIds => {
                        $mboxIdB => JSON::true,
                    },
                },
            },
        }, 'R1'],
    ]);
    $self->assert(exists $res->[0][1]{updated}{$emailId2});

    xlog "assert move";
    $res = $jmap->CallMethods([
        ['Email/get', {
            ids => [$emailId1, $emailId2],
            properties => ['mailboxIds'],
        }, 'R1'],
    ]);
    $self->assert_str_equals($emailId1, $res->[0][1]{list}[0]{id});
    my $wantMailboxIds1 = { $mboxIdA => JSON::true };
    $self->assert_deep_equals($wantMailboxIds1, $res->[0][1]{list}[0]{mailboxIds});

    $self->assert_str_equals($emailId2, $res->[0][1]{list}[1]{id});
    my $wantMailboxIds2 = { $mboxIdB => JSON::true };
    $self->assert_deep_equals($wantMailboxIds2, $res->[0][1]{list}[1]{mailboxIds});

    xlog "query emails";
    $res = $jmap->CallMethods([
        ['Email/query', {
            filter => {
                inMailbox => $mboxIdA,
                text => 'message',
            },
        }, 'R1'],
        ['Email/query', {
            filter => {
                inMailbox => $mboxIdB,
                text => 'message',
            },
        }, 'R2'],
    ]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId1, $res->[0][1]->{ids}[0]);
    $self->assert_num_equals(1, scalar @{$res->[1][1]->{ids}});
    $self->assert_str_equals($emailId2, $res->[1][1]->{ids}[0]);
}

sub test_email_query_from
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    # Create test messages.
    $self->make_message('uid1', from => Cassandane::Address->new(
        name => 'B',
        localpart => 'local',
        domain => 'hostA'
    ));
    $self->make_message('uid2', from => Cassandane::Address->new(
        name => 'A',
        localpart => 'local',
        domain => 'hostA'
    ));
    $self->make_message('uid3', from => Cassandane::Address->new(
        localpart => 'local',
        domain => 'hostY'
    ));
    $self->make_message('uid4', from => Cassandane::Address->new(
        localpart => 'local',
        domain => 'hostX'
    ));

    my $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [{ property => 'subject' }],
        }, 'R1'],
    ]);
    $self->assert_num_equals(4, scalar @{$res->[0][1]->{ids}});
    my $emailId1 = $res->[0][1]{ids}[0];
    my $emailId2 = $res->[0][1]{ids}[1];
    my $emailId3 = $res->[0][1]{ids}[2];
    my $emailId4 = $res->[0][1]{ids}[3];

    $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [
                { property => 'from' },
                { property => 'subject'}
            ],
        }, 'R1'],
    ]);
    $self->assert_num_equals(4, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId2, $res->[0][1]{ids}[0]);
    $self->assert_str_equals($emailId1, $res->[0][1]{ids}[1]);
    $self->assert_str_equals($emailId4, $res->[0][1]{ids}[2]);
    $self->assert_str_equals($emailId3, $res->[0][1]{ids}[3]);
}

sub test_email_query_addedDates
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    xlog "create messages";
    $self->make_message('uid1') || die;
    $self->make_message('uid2') || die;
    $self->make_message('uid3') || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [{
                property => 'subject',
                isAscending => JSON::true
            }],
        }, 'R1'],
    ]);
    my $emailId1 = $res->[0][1]{ids}[0];
    my $emailId2 = $res->[0][1]{ids}[1];
    my $emailId3 = $res->[0][1]{ids}[2];
    $self->assert_not_null($emailId1);
    $self->assert_not_null($emailId2);
    $self->assert_not_null($emailId3);

    xlog "query emails sorted by addedDates";
    $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [{
                property => 'addedDates',
                isAscending => JSON::true
            }],
        }, 'R1'],
    ]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId1, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($emailId2, $res->[0][1]->{ids}[1]);
    $self->assert_str_equals($emailId3, $res->[0][1]->{ids}[2]);

    $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [{
                property => 'addedDates',
                isAscending => JSON::false,
            }],
        }, 'R1'],
    ]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($emailId3, $res->[0][1]->{ids}[0]);
    $self->assert_str_equals($emailId2, $res->[0][1]->{ids}[1]);
    $self->assert_str_equals($emailId1, $res->[0][1]->{ids}[2]);
}


sub test_misc_collapsethreads_issue2024
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    # test that the collapseThreads property is echoed back verbatim
    # see https://github.com/cyrusimap/cyrus-imapd/issues/2024

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    xlog "generating email A";
    $exp{A} = $self->make_message("Email A");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ]);
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    $res = $jmap->CallMethods([['Email/query', { collapseThreads => JSON::true }, "R1"]]);
    $self->assert_equals(JSON::true, $res->[0][1]->{collapseThreads});

    $res = $jmap->CallMethods([['Email/query', { collapseThreads => JSON::false }, "R1"]]);
    $self->assert_equals(JSON::false, $res->[0][1]->{collapseThreads});

    $res = $jmap->CallMethods([['Email/query', { collapseThreads => undef }, "R1"]]);
    $self->assert_null($res->[0][1]->{collapseThreads});

    $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    $self->assert_equals(JSON::false, $res->[0][1]->{collapseThreads});
}

sub test_email_query_window
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    xlog "generating email A";
    $exp{A} = $self->make_message("Email A");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ]);
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "generating email D";
    $exp{D} = $self->make_message("Email D");
    $exp{D}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "list all emails";
    $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    $self->assert_num_equals(4, scalar @{$res->[0][1]->{ids}});
    $self->assert_num_equals(4, $res->[0][1]->{total});

    my $ids = $res->[0][1]->{ids};
    my @subids;

    xlog "list emails from position 1";
    $res = $jmap->CallMethods([['Email/query', { position => 1 }, "R1"]]);
    @subids = @{$ids}[1..3];
    $self->assert_deep_equals(\@subids, $res->[0][1]->{ids});
    $self->assert_num_equals(4, $res->[0][1]->{total});

    xlog "list emails from position 4";
    $res = $jmap->CallMethods([['Email/query', { position => 4 }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});
    $self->assert_num_equals(4, $res->[0][1]->{total});

    xlog "limit emails from position 1 to one email";
    $res = $jmap->CallMethods([['Email/query', { position => 1, limit => 1 }, "R1"]]);
    @subids = @{$ids}[1..1];
    $self->assert_deep_equals(\@subids, $res->[0][1]->{ids});
    $self->assert_num_equals(4, $res->[0][1]->{total});
    $self->assert_num_equals(1, $res->[0][1]->{position});

    xlog "anchor at 2nd email";
    $res = $jmap->CallMethods([['Email/query', { anchor => @{$ids}[1] }, "R1"]]);
    @subids = @{$ids}[1..3];
    $self->assert_deep_equals(\@subids, $res->[0][1]->{ids});
    $self->assert_num_equals(4, $res->[0][1]->{total});
    $self->assert_num_equals(1, $res->[0][1]->{position});

    xlog "anchor at 2nd email and offset -1";
    $res = $jmap->CallMethods([['Email/query', {
        anchor => @{$ids}[1], anchorOffset => -1,
    }, "R1"]]);
    @subids = @{$ids}[2..3];
    $self->assert_deep_equals(\@subids, $res->[0][1]->{ids});
    $self->assert_num_equals(4, $res->[0][1]->{total});
    $self->assert_num_equals(2, $res->[0][1]->{position});

    xlog "anchor at 3rd email and offset 1";
    $res = $jmap->CallMethods([['Email/query', {
        anchor => @{$ids}[2], anchorOffset => 1,
    }, "R1"]]);
    @subids = @{$ids}[1..3];
    $self->assert_deep_equals(\@subids, $res->[0][1]->{ids});
    $self->assert_num_equals(4, $res->[0][1]->{total});
    $self->assert_num_equals(1, $res->[0][1]->{position});

    xlog "anchor at 1st email offset -1 and limit 2";
    $res = $jmap->CallMethods([['Email/query', {
        anchor => @{$ids}[0], anchorOffset => -1, limit => 2
    }, "R1"]]);
    @subids = @{$ids}[1..2];
    $self->assert_deep_equals(\@subids, $res->[0][1]->{ids});
    $self->assert_num_equals(4, $res->[0][1]->{total});
    $self->assert_num_equals(1, $res->[0][1]->{position});
}

sub test_email_query_long
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    for (1..100) {
        $self->make_message("Email $_");
    }

    xlog "list first 60 emails";
    $res = $jmap->CallMethods([['Email/query', {
        limit => 60,
        position => 0,
        collapseThreads => JSON::true,
        sort => [{ property => "id" }],
    }, "R1"]]);
    $self->assert_num_equals(60, scalar @{$res->[0][1]->{ids}});
    $self->assert_num_equals(100, $res->[0][1]->{total});
    $self->assert_num_equals(0, $res->[0][1]->{position});

    xlog "list 5 emails from offset 55 by anchor";
    $res = $jmap->CallMethods([['Email/query', {
        limit => 5,
        anchorOffset => 1,
        anchor => $res->[0][1]->{ids}[55],
        collapseThreads => JSON::true,
        sort => [{ property => "id" }],
    }, "R1"]]);
    $self->assert_num_equals(5, scalar @{$res->[0][1]->{ids}});
    $self->assert_num_equals(100, $res->[0][1]->{total});
    $self->assert_num_equals(54, $res->[0][1]->{position});

    my $ids = $res->[0][1]->{ids};
    my @subids;
}

sub test_email_query_acl
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $admintalk = $self->{adminstore}->get_client();

    # Create user and share mailbox
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lr") or die;

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', { accountId => 'foo' }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "Create email in shared account";
    $self->{adminstore}->set_folder('user.foo');
    $self->make_message("Email foo", store => $self->{adminstore}) or die;

    xlog "get email list in main account";
    $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{ids}});

    xlog "get email list in shared account";
    $res = $jmap->CallMethods([['Email/query', { accountId => 'foo' }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $id = $res->[0][1]->{ids}[0];

    xlog "Create email in main account";
    $self->make_message("Email cassandane") or die;

    xlog "get email list in main account";
    $res = $jmap->CallMethods([['Email/query', { }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_not_equals($id, $res->[0][1]->{ids}[0]);

    xlog "get email list in shared account";
    $res = $jmap->CallMethods([['Email/query', { accountId => 'foo' }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($id, $res->[0][1]->{ids}[0]);

    xlog "create but do not share mailbox";
    $admintalk->create("user.foo.box1") or die;
    $admintalk->setacl("user.foo.box1", "cassandane", "") or die;

    xlog "create email in private mailbox";
    $self->{adminstore}->set_folder('user.foo.box1');
    $self->make_message("Email private foo", store => $self->{adminstore}) or die;

    xlog "get email list in shared account";
    $res = $jmap->CallMethods([['Email/query', { accountId => 'foo' }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($id, $res->[0][1]->{ids}[0]);
}

sub test_email_query_unknown_mailbox
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    xlog "filter inMailbox with unknown mailbox";
    $res = $jmap->CallMethods([['Email/query', { filter => { inMailbox => "foo" } }, "R1"]]);
    $self->assert_str_equals('error', $res->[0][0]);
    $self->assert_str_equals('invalidArguments', $res->[0][1]{type});
    $self->assert_str_equals('filter/inMailbox', $res->[0][1]{arguments}[0]);

    xlog "filter inMailboxOtherThan with unknown mailbox";
    $res = $jmap->CallMethods([['Email/query', { filter => { inMailboxOtherThan => ["foo"] } }, "R1"]]);
    $self->assert_str_equals('error', $res->[0][0]);
    $self->assert_str_equals('invalidArguments', $res->[0][1]{type});
    $self->assert_str_equals('filter/inMailboxOtherThan[0:foo]', $res->[0][1]{arguments}[0]);
}


sub test_searchsnippet_get
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    xlog "create emails";
    my %params = (
        body => "A simple message",
    );
    $res = $self->make_message("Message foo", %params) || die;

    %params = (
        body => ""
        . "In the context of electronic mail, messages are viewed as having an\r\n"
        . "envelope and contents.  The envelope contains whatever information is\r\n"
        . "needed to accomplish transmission and delivery.  (See [RFC5321] for a\r\n"
        . "discussion of the envelope.)  The contents comprise the object to be\r\n"
        . "delivered to the recipient.  This specification applies only to the\r\n"
        . "format and some of the semantics of message contents.  It contains no\r\n"
        . "specification of the information in the envelope.i\r\n"
        . "\r\n"
        . "However, some message systems may use information from the contents\r\n"
        . "to create the envelope.  It is intended that this specification\r\n"
        . "facilitate the acquisition of such information by programs.\r\n"
        . "\r\n"
        . "This specification is intended as a definition of what message\r\n"
        . "content format is to be passed between systems.  Though some message\r\n"
        . "systems locally store messages in this format (which eliminates the\r\n"
        . "need for translation between formats) and others use formats that\r\n"
        . "differ from the one specified in this specification, local storage is\r\n"
        . "outside of the scope of this specification.\r\n"
        . "\r\n"
        . "This paragraph is not part of the specification, it has been added to\r\n"
        . "contain the most mentions of the word message. Messages are processed\r\n"
        . "by messaging systems, which is the message of this paragraph.\r\n"
        . "Don't interpret too much into this message.\r\n",
    );
    $self->make_message("Message bar", %params) || die;
    %params = (
        body => "This body doesn't contain any of the search terms.\r\n",
    );
    $self->make_message("A subject without any matching search term", %params) || die;

    $self->make_message("Message baz", %params) || die;
    %params = (
        body => "This body doesn't contain any of the search terms.\r\n",
    );
    $self->make_message("A subject with message", %params) || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch email ids";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' } }, 'R2' ],
    ]);

    my %m = map { $_->{subject} => $_ } @{$res->[1][1]{list}};
    my $foo = $m{"Message foo"}->{id};
    my $bar = $m{"Message bar"}->{id};
    my $baz = $m{"Message baz"}->{id};
    $self->assert_not_null($foo);
    $self->assert_not_null($bar);
    $self->assert_not_null($baz);

    xlog "fetch snippets";
    $res = $jmap->CallMethods([['SearchSnippet/get', {
            emailIds => [ $foo, $bar ],
            filter => { text => "message" },
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{list}});
    $self->assert_null($res->[0][1]->{notFound});
    %m = map { $_->{emailId} => $_ } @{$res->[0][1]{list}};
    $self->assert_not_null($m{$foo});
    $self->assert_not_null($m{$bar});

    %m = map { $_->{emailId} => $_ } @{$res->[0][1]{list}};
    $self->assert_num_not_equals(-1, index($m{$foo}->{subject}, "<mark>Message</mark> foo"));
    $self->assert_num_not_equals(-1, index($m{$foo}->{preview}, "A simple <mark>message</mark>"));
    $self->assert_num_not_equals(-1, index($m{$bar}->{subject}, "<mark>Message</mark> bar"));
    $self->assert_num_not_equals(-1, index($m{$bar}->{preview}, ""
        . "<mark>Messages</mark> are processed by <mark>messaging</mark> systems,"
    ));

    xlog "fetch snippets with one unknown id";
    $res = $jmap->CallMethods([['SearchSnippet/get', {
            emailIds => [ $foo, "bam" ],
            filter => { text => "message" },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{list}});
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{notFound}});

    xlog "fetch snippets with only a matching subject";
    $res = $jmap->CallMethods([['SearchSnippet/get', {
            emailIds => [ $baz ],
            filter => { text => "message" },
    }, "R1"]]);
    $self->assert_not_null($res->[0][1]->{list}[0]->{subject});
    $self->assert(exists $res->[0][1]->{list}[0]->{preview});
}

sub test_searchsnippet_get_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $admintalk = $self->{adminstore}->get_client();

    xlog "create user and share mailboxes";
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lr") or die;
    $admintalk->create("user.foo.box1") or die;
    $admintalk->setacl("user.foo.box1", "cassandane", "lr") or die;

    my $res = $jmap->CallMethods([['Mailbox/get', { accountId => 'foo' }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    xlog "create emails in shared account";
    $self->{adminstore}->set_folder('user.foo');
    my %params = (
        body => "A simple email",
    );
    $res = $self->make_message("Email foo", %params, store => $self->{adminstore}) || die;
    $self->{adminstore}->set_folder('user.foo.box1');
    %params = (
        body => "Another simple email",
    );
    $res = $self->make_message("Email bar", %params, store => $self->{adminstore}) || die;

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch email ids";
    $res = $jmap->CallMethods([
        ['Email/query', { accountId => 'foo' }, "R1"],
        ['Email/get', {
            accountId => 'foo',
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' }
        }, 'R2' ],
    ]);

    my %m = map { $_->{subject} => $_ } @{$res->[1][1]{list}};
    my $foo = $m{"Email foo"}->{id};
    my $bar = $m{"Email bar"}->{id};
    $self->assert_not_null($foo);
    $self->assert_not_null($bar);

    xlog "remove read rights for mailbox containing email $bar";
    $admintalk->setacl("user.foo.box1", "cassandane", "") or die;

    xlog "fetch snippets";
    $res = $jmap->CallMethods([['SearchSnippet/get', {
            accountId => 'foo',
            emailIds => [ $foo, $bar ],
            filter => { text => "simple" },
    }, "R1"]]);
    $self->assert_str_equals($foo, $res->[0][1]->{list}[0]{emailId});
    $self->assert_str_equals($bar, $res->[0][1]->{notFound}[0]);
}

sub test_email_query_snippets
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;

    my $imaptalk = $self->{store}->get_client();

    # check IMAP server has the XCONVERSATIONS capability
    $self->assert($self->{store}->get_client()->capability()->{xconversations});

    xlog "generating email A";
    $exp{A} = $self->make_message("Email A");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "fetch email and snippet";
    $res = $jmap->CallMethods([
        ['Email/query', { filter => { text => "email" }}, "R1"],
        ['SearchSnippet/get', {
            '#emailIds' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids',
            },
            '#filter' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/filter',
            },
        }, 'R2'],
    ]);

    my $snippet = $res->[1][1]{list}[0];
    $self->assert_not_null($snippet);
    $self->assert_num_not_equals(-1, index($snippet->{subject}, "<mark>Email</mark> A"));

    xlog "fetch email and snippet with no filter";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['SearchSnippet/get', {
            '#emailIds' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids',
            },
        }, 'R2'],
    ]);
    $snippet = $res->[1][1]{list}[0];
    $self->assert_not_null($snippet);
    $self->assert_null($snippet->{subject});
    $self->assert_null($snippet->{preview});

    xlog "fetch email and snippet with no text filter";
    $res = $jmap->CallMethods([
        ['Email/query', {
            filter => {
                operator => "OR",
                conditions => [{minSize => 1}, {maxSize => 1}]
            },
        }, "R1"],
        ['SearchSnippet/get', {
            '#emailIds' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids',
            },
            '#filter' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/filter',
            },
        }, 'R2'],
    ]);

    $snippet = $res->[1][1]{list}[0];
    $self->assert_not_null($snippet);
    $self->assert_null($snippet->{subject});
    $self->assert_null($snippet->{preview});
}

sub test_email_query_attachments
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    # create a email with an attachment
    my $logofile = abs_path('data/logo.gif');
    open(FH, "<$logofile");
    local $/ = undef;
    my $binary = <FH>;
    close(FH);
    my $data = $jmap->Upload($binary, "image/gif");

    $res = $jmap->CallMethods([
      ['Email/set', { create => {
                  "1" => {
                      mailboxIds => {$draftsmbox =>  JSON::true},
                      from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
                      to => [
                          { name => "Bugs Bunny", email => "bugs\@acme.local" },
                      ],
                      subject => "Memo",
                      textBody => [{ partId => '1' }],
                      bodyValues => {'1' => { value => "I'm givin' ya one last chance ta surrenda!" }},
                      attachments => [{
                              blobId => $data->{blobId},
                              name => "logo.gif",
                      }],
                      keywords => { '$Draft' => JSON::true },
                  },
                  "2" => {
                      mailboxIds => {$draftsmbox =>  JSON::true},
                      from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
                      to => [
                          { name => "Bugs Bunny", email => "bugs\@acme.local" },
                      ],
                      subject => "Memo 2",
                      textBody => [{ partId => '1' }],
                      bodyValues => {'1' => { value => "I'm givin' ya *one* last chance ta surrenda!" }},
                      attachments => [{
                              blobId => $data->{blobId},
                              name => "somethingelse.gif",
                      }],
                      keywords => { '$Draft' => JSON::true },
                  },
  } }, 'R2'],
    ]);
    my $id1 = $res->[0][1]{created}{"1"}{id};
    my $id2 = $res->[0][1]{created}{"2"}{id};

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "filter attachmentName";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            attachmentName => "logo",
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($id1, $res->[0][1]->{ids}[0]);

    xlog "filter attachmentName";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            attachmentName => "somethingelse.gif",
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($id2, $res->[0][1]->{ids}[0]);

    xlog "filter attachmentName";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            attachmentName => "gif",
        },
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});

    xlog "filter text";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            text => "logo",
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($id1, $res->[0][1]->{ids}[0]);
}

sub test_email_query_attachmentname
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $self->assert_str_equals($res->[0][0], 'Mailbox/set');
    $self->assert_str_equals($res->[0][2], 'R1');
    $self->assert_not_null($res->[0][1]{created});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    # create a email with an attachment
    my $logofile = abs_path('data/logo.gif');
    open(FH, "<$logofile");
    local $/ = undef;
    my $binary = <FH>;
    close(FH);
    my $data = $jmap->Upload($binary, "image/gif");

    $res = $jmap->CallMethods([
      ['Email/set', { create => {
                  "1" => {
                      mailboxIds => {$draftsmbox =>  JSON::true},
                      from => [ { name => "", email => "sam\@acme.local" } ] ,
                      to => [ { name => "", email => "bugs\@acme.local" } ],
                      subject => "msg1",
                      textBody => [{ partId => '1' }],
                      bodyValues => { '1' => { value => "foo" } },
                      attachments => [{
                              blobId => $data->{blobId},
                              name => "R\N{LATIN SMALL LETTER U WITH DIAERESIS}bezahl.txt",
                      }],
                      keywords => { '$Draft' => JSON::true },
                  },
              }}, 'R2'],
    ]);
    my $id1 = $res->[0][1]{created}{"1"}{id};

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "filter attachmentName";
    $res = $jmap->CallMethods([['Email/query', {
        filter => {
            attachmentName => "r\N{LATIN SMALL LETTER U WITH DIAERESIS}bezahl",
        },
    }, "R1"]]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    $self->assert_str_equals($id1, $res->[0][1]->{ids}[0]);
}

sub test_email_query_attachmenttype
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $blobId = $jmap->Upload('some_data', "application/octet")->{blobId};

    my $inboxid = $self->getinbox()->{id};

    my $res = $jmap->CallMethods([
      ['Email/set', { create => {
        "1" => {
          mailboxIds => {$inboxid => JSON::true},
          from => [ { name => "", email => "sam\@acme.local" } ] ,
          to => [ { name => "", email => "bugs\@acme.local" } ],
          subject => "foo",
          textBody => [{ partId => '1' }],
          bodyValues => { '1' => { value => "foo" } },
          attachments => [{
            blobId => $blobId,
            type => 'image/gif',
          }],
      },
      "2" => {
          mailboxIds => {$inboxid => JSON::true},
          from => [ { name => "", email => "tweety\@acme.local" } ] ,
          to => [ { name => "", email => "duffy\@acme.local" } ],
          subject => "bar",
          textBody => [{ partId => '1' }],
          bodyValues => { '1' => { value => "bar" } },
      },
      "3" => {
          mailboxIds => {$inboxid => JSON::true},
          from => [ { name => "", email => "elmer\@acme.local" } ] ,
          to => [ { name => "", email => "porky\@acme.local" } ],
          subject => "baz",
          textBody => [{ partId => '1' }],
          bodyValues => { '1' => { value => "baz" } },
          attachments => [{
            blobId => $blobId,
            type => 'application/msword',
          }],
      }
      }}, 'R1']
    ]);
    my $idGif = $res->[0][1]{created}{"1"}{id};
    my $idTxt = $res->[0][1]{created}{"2"}{id};
    my $idDoc = $res->[0][1]{created}{"3"}{id};
    $self->assert_not_null($idGif);
    $self->assert_not_null($idTxt);
    $self->assert_not_null($idDoc);

    xlog "run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my @testCases = ({
        filter => {
            attachmentType => 'image/gif',
        },
        wantIds => [$idGif],
    }, {
        filter => {
            attachmentType => 'image',
        },
        wantIds => [$idGif],
    }, {
        filter => {
            attachmentType => 'application/msword',
        },
        wantIds => [$idDoc],
    }, {
        filter => {
            attachmentType => 'document',
        },
        wantIds => [$idDoc],
    }, {
        filter => {
            operator => 'NOT',
            conditions => [{
                attachmentType => 'image',
            }, {
                attachmentType => 'document',
            }],
        },
        wantIds => [$idTxt],
    });

    foreach (@testCases) {
        my $filter = $_->{filter};
        my $wantIds = $_->{wantIds};
        $res = $jmap->CallMethods([['Email/query', {
            filter => $filter,
        }, "R1"]]);
        my @wantIds = sort @{$wantIds};
        my @gotIds = sort @{$res->[0][1]->{ids}};
        $self->assert_deep_equals(\@wantIds, \@gotIds);
    }
}

sub test_thread_get
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;
    my %params;
    my $dt;

    my $imaptalk = $self->{store}->get_client();

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $drafts = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($drafts);

    xlog "generating email A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{A} = $self->make_message("Email A", date => $dt, body => "a");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", body => "b");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "c");
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "generating email D referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -1));
    $exp{D} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "d");
    $exp{D}->set_attributes(uid => 4, cid => $exp{A}->get_attribute('cid'));

    xlog "fetch emails";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
    ]);

    # Map messages by body contents
    my %m = map { $_->{bodyValues}{$_->{textBody}[0]{partId}}{value} => $_ } @{$res->[1][1]{list}};
    my $msgA = $m{"a"};
    my $msgB = $m{"b"};
    my $msgC = $m{"c"};
    my $msgD = $m{"d"};
    $self->assert_not_null($msgA);
    $self->assert_not_null($msgB);
    $self->assert_not_null($msgC);
    $self->assert_not_null($msgD);

    %m = map { $_->{threadId} => 1 } @{$res->[1][1]{list}};
    my @threadids = keys %m;

    xlog "create draft replying to email A";
    $res = $jmap->CallMethods(
        [[ 'Email/set', { create => { "1" => {
            mailboxIds           => {$drafts =>  JSON::true},
            inReplyTo            => $msgA->{messageId},
            from                 => [ { name => "", email => "sam\@acme.local" } ],
            to                   => [ { name => "", email => "bugs\@acme.local" } ],
            subject              => "Re: Email A",
            textBody             => [{ partId => '1' }],
            bodyValues           => { 1 => { value => "I'm givin' ya one last chance ta surrenda!" }},
            keywords             => { '$Draft' => JSON::true },
        }}}, "R1" ]]);
    my $draftid = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftid);

    xlog "get threads";
    $res = $jmap->CallMethods([['Thread/get', { ids => \@threadids }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{list}});
    $self->assert_deep_equals([], $res->[0][1]->{notFound});

    %m = map { $_->{id} => $_ } @{$res->[0][1]{list}};
    my $threadA = $m{$msgA->{threadId}};
    my $threadB = $m{$msgB->{threadId}};

    # Assert all emails are listed
    $self->assert_num_equals(4, scalar @{$threadA->{emailIds}});
    $self->assert_num_equals(1, scalar @{$threadB->{emailIds}});

    # Assert sort order by date
    $self->assert_str_equals($msgA->{id}, $threadA->{emailIds}[0]);
    $self->assert_str_equals($msgC->{id}, $threadA->{emailIds}[1]);
    $self->assert_str_equals($msgD->{id}, $threadA->{emailIds}[2]);
    $self->assert_str_equals($draftid, $threadA->{emailIds}[3]);
}

sub test_thread_get_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $admintalk = $self->{adminstore}->get_client();

    # Create user and share mailbox A but not B
    xlog "Create shared mailbox";
    $self->{instance}->create_user("other");
    $admintalk->create("user.other.A") or die;
    $admintalk->setacl("user.other.A", "cassandane", "lr") or die;
    $admintalk->create("user.other.B") or die;

    # Create message in mailbox A
    $self->{adminstore}->set_folder('user.other.A');
    my $msgA = $self->make_message("EmailA", store => $self->{adminstore}) or die;

    # Reply-to message in mailbox B
    $self->{adminstore}->set_folder('user.other.B');
    my $msgB = $self->make_message("Re: EmailA", (
        references => [ $msgA ],
        store => $self->{adminstore},
    )) or die;

    my @fetchThreadMethods = [
        ['Email/query', {
            accountId => 'other',
            collapseThreads => JSON::true,
        }, "R1"],
        ['Email/get', {
            accountId => 'other',
            properties => ['threadId'],
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
        ['Thread/get', {
            accountId => 'other',
            '#ids' => {
                resultOf => 'R2',
                name => 'Email/get',
                path => '/list/*/threadId'
            },
        }, 'R3' ],
    ];

    # Fetch Thread
    my $res = $jmap->CallMethods(@fetchThreadMethods);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    $self->assert_num_equals(1, scalar @{$res->[2][1]{list}[0]{emailIds}});

    # Now share mailbox B
    $admintalk->setacl("user.other.B", "cassandane", "lr") or die;
    $res = $jmap->CallMethods(@fetchThreadMethods);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    $self->assert_num_equals(2, scalar @{$res->[2][1]{list}[0]{emailIds}});
}

sub test_identity_get
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $id;
    my $res;

    xlog "get identities";
    $res = $jmap->CallMethods([['Identity/get', { }, "R1"]]);

    $self->assert_num_equals(1, scalar @{$res->[0][1]->{list}});
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{notFound}});

    $id = $res->[0][1]->{list}[0];
    $self->assert_not_null($id->{id});
    $self->assert_not_null($id->{email});

    xlog "get unknown identities";
    $res = $jmap->CallMethods([['Identity/get', { ids => ["foo"] }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]->{list}});
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{notFound}});
}

sub test_misc_emptyids
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();
    my $res;

    $imaptalk->create("INBOX.foo") || die;

    $res = $jmap->CallMethods([['Mailbox/get', { ids => [] }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]{list}});

    $res = $jmap->CallMethods([['Thread/get', { ids => [] }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]{list}});

    $res = $jmap->CallMethods([['Email/get', { ids => [] }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]{list}});

    $res = $jmap->CallMethods([['Identity/get', { ids => [] }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]{list}});

    $res = $jmap->CallMethods([['SearchSnippet/get', { emailIds => [], filter => { text => "foo" } }, "R1"]]);
    $self->assert_num_equals(0, scalar @{$res->[0][1]{list}});
}

sub test_email_querychanges_basic
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $draftsmbox;

    xlog "Generate some email in INBOX via IMAP";
    $self->make_message("Email A") || die;
    $self->make_message("Email B") || die;
    $self->make_message("Email C") || die;
    $self->make_message("Email D") || die;

    $res = $jmap->CallMethods([['Email/query', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
    }, 'R1']]);

    $talk->select("INBOX");
    $talk->store("3", "+flags", "(\\Flagged)");

    my $old = $res->[0][1];

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        sinceQueryState => $old->{queryState},
    }, 'R2']]);

    my $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);
}

sub test_email_querychanges_basic_collapse
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $draftsmbox;

    xlog "Generate some email in INBOX via IMAP";
    $self->make_message("Email A") || die;
    $self->make_message("Email B") || die;
    $self->make_message("Email C") || die;
    $self->make_message("Email D") || die;

    $res = $jmap->CallMethods([['Email/query', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        collapseThreads => $JSON::true,
    }, 'R1']]);

    $talk->select("INBOX");
    $talk->store("3", "+flags", "(\\Flagged)");

    my $old = $res->[0][1];

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
    }, 'R2']]);

    my $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);
}

sub test_email_querychanges_basic_mb
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inboxid = $self->getinbox()->{id};

    xlog "Generate some email in INBOX via IMAP";
    $self->make_message("Email A") || die;
    $self->make_message("Email B") || die;
    $self->make_message("Email C") || die;
    $self->make_message("Email D") || die;

    $res = $jmap->CallMethods([['Email/query', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
    }, 'R1']]);

    $talk->select("INBOX");
    $talk->store("3", "+flags", "(\\Flagged)");

    my $old = $res->[0][1];

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        sinceQueryState => $old->{queryState},
    }, 'R2']]);

    my $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);
}

sub test_email_querychanges_basic_mb_collapse
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inboxid = $self->getinbox()->{id};

    xlog "Generate some email in INBOX via IMAP";
    $self->make_message("Email A") || die;
    $self->make_message("Email B") || die;
    $self->make_message("Email C") || die;
    $self->make_message("Email D") || die;

    $res = $jmap->CallMethods([['Email/query', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
    }, 'R1']]);

    $talk->select("INBOX");
    $talk->store("3", "+flags", "(\\Flagged)");

    my $old = $res->[0][1];

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
        ##upToId => $old->{ids}[3],
    }, 'R2']]);

    my $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    # with collased threads we have to check
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);

    xlog "now with upto past";
    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
        upToId => $old->{ids}[3],
    }, 'R2']]);

    $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);

    xlog "now with upto equal";
    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
        upToId => $old->{ids}[2],
    }, 'R2']]);

    $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);

    xlog "now with upto early";
    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
        upToId => $old->{ids}[1],
    }, 'R2']]);

    $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    $self->assert_num_equals(0, scalar @{$new->{added}});
    $self->assert_num_equals(0, scalar @{$new->{removed}});
}

sub test_email_querychanges_skipdeleted
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inboxid = $self->getinbox()->{id};

    xlog "Generate some email in INBOX via IMAP";
    $self->make_message("Email A") || die;
    $self->make_message("Email B") || die;
    $self->make_message("Email C") || die;
    $self->make_message("Email D") || die;

    $talk->create("INBOX.foo");
    $talk->select("INBOX");
    $talk->move("1:2", "INBOX.foo");
    $talk->select("INBOX.foo");
    $talk->move("1:2", "INBOX");

    $res = $jmap->CallMethods([['Email/query', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
    }, 'R1']]);

    my $old = $res->[0][1];

    $talk->select("INBOX");
    $talk->store("1", "+flags", "(\\Flagged)");

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
    }, 'R2']]);

    my $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    # with collased threads we have to check
    $self->assert_num_equals(1, scalar @{$new->{added}});
    $self->assert_num_equals(1, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{removed}[0], $new->{added}[0]{id});
    $self->assert_str_equals($new->{removed}[0], $old->{ids}[$new->{added}[0]{index}]);
}

sub test_email_querychanges_deletedcopy
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inboxid = $self->getinbox()->{id};

    xlog "Generate some email in INBOX via IMAP";
    $self->make_message("Email A") || die;
    $self->make_message("Email B") || die;
    $self->make_message("Email C") || die;
    $self->make_message("Email D") || die;

    $res = $jmap->CallMethods([['Email/query', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
    }, 'R1']]);

    $talk->create("INBOX.foo");
    $talk->select("INBOX");
    $talk->move("2", "INBOX.foo");
    $talk->select("INBOX.foo");
    $talk->move("1", "INBOX");
    $talk->select("INBOX");
    $talk->store("2", "+flags", "(\\Flagged)");

    # order is now A (B) C D B, and (B), C and B are "changed"

    my $old = $res->[0][1];

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sort => [
         {
           property =>  "subject",
           isAscending => $JSON::true,
         }
        ],
        filter => { inMailbox => $inboxid },
        collapseThreads => $JSON::true,
        sinceQueryState => $old->{queryState},
    }, 'R2']]);

    my $new = $res->[0][1];
    $self->assert_str_equals($old->{queryState}, $new->{oldQueryState});
    $self->assert_str_not_equals($old->{queryState}, $new->{newQueryState});
    # with collased threads we have to check
    $self->assert_num_equals(2, scalar @{$new->{added}});
    $self->assert_num_equals(2, scalar @{$new->{removed}});
    $self->assert_str_equals($new->{added}[0]{id}, $old->{ids}[$new->{added}[0]{index}]);
    $self->assert_str_equals($new->{added}[1]{id}, $old->{ids}[$new->{added}[1]{index}]);
}

sub test_email_changes
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $draftsmbox;

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $draftsmbox = $res->[0][1]{created}{"1"}{id};

    xlog "get email updates (expect error)";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => 0 }, "R1"]]);
    $self->assert_str_equals($res->[0][1]->{type}, "invalidArguments");
    $self->assert_str_equals($res->[0][1]->{arguments}[0], "sinceState");

    xlog "get email state";
    $res = $jmap->CallMethods([['Email/get', { ids => []}, "R1"]]);
    $state = $res->[0][1]->{state};
    $self->assert_not_null($state);

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("Email A") || die;

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_str_equals($ida, $res->[0][1]{created}[0]);
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "get email updates (expect no changes)";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "update email $ida";
    $res = $jmap->CallMethods([['Email/set', {
        update => { $ida => { keywords => { '$Seen' => JSON::true }}}
    }, "R1"]]);
    $self->assert(exists $res->[0][1]->{updated}{$ida});

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{updated}});
    $self->assert_str_equals($ida, $res->[0][1]{updated}[0]);
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "delete email $ida";
    $res = $jmap->CallMethods([['Email/set', {destroy => [ $ida ] }, "R1"]]);
    $self->assert_str_equals($ida, $res->[0][1]->{destroyed}[0]);

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{destroyed}});
    $self->assert_str_equals($ida, $res->[0][1]{destroyed}[0]);
    $state = $res->[0][1]->{newState};

    xlog "get email updates (expect no changes)";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "create email B";
    $res = $jmap->CallMethods(
        [[ 'Email/set', { create => { "1" => {
            mailboxIds           => {$draftsmbox =>  JSON::true},
            from                 => [ { name => "", email => "sam\@acme.local" } ],
            to                   => [ { name => "", email => "bugs\@acme.local" } ],
            subject              => "Email B",
            textBody             => [{ partId => '1' }],
            bodyValues           => { '1' => { value => "I'm givin' ya one last chance ta surrenda!" }},
            keywords             => { '$Draft' => JSON::true },
        }}}, "R1" ]]);
    my $idb = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($idb);

    xlog "create email C";
    $res = $jmap->CallMethods(
        [[ 'Email/set', { create => { "1" => {
            mailboxIds           => {$draftsmbox =>  JSON::true},
            from                 => [ { name => "", email => "sam\@acme.local" } ],
            to                   => [ { name => "", email => "bugs\@acme.local" } ],
            subject              => "Email C",
            textBody             => [{ partId => '1' }],
            bodyValues           => { '1' => { value => "I *hate* that rabbit!" } },
            keywords             => { '$Draft' => JSON::true },
        }}}, "R1" ]]);
    my $idc = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($idc);

    xlog "get max 1 email updates";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state, maxChanges => 1 }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::true, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_str_equals($idb, $res->[0][1]{created}[0]);
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "get max 1 email updates";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state, maxChanges => 1 }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_str_equals($idc, $res->[0][1]{created}[0]);
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "get email updates (expect no changes)";
    $res = $jmap->CallMethods([['Email/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
}

sub test_email_querychanges
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("Email A") || die;

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    $self->make_message("Email B") || die;

    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);

    my ($idb) = grep { $_ ne $ida } @{$res->[0][1]->{ids}};

    xlog "get email list updates";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state }, "R1"]]);

    $self->assert_equals($res->[0][1]{added}[0]{id}, $idb);

    xlog "get email list updates with threads collapsed";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, collapseThreads => JSON::true }, "R1"]]);

    $self->assert_equals($res->[0][1]{added}[0]{id}, $idb);
}

sub test_email_querychanges_toomany
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("Email A") || die;

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    $self->make_message("Email B") || die;

    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);

    my ($idb) = grep { $_ ne $ida } @{$res->[0][1]->{ids}};

    xlog "get email list updates";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, maxChanges => 1 }, "R1"]]);

    $self->assert_str_equals("error", $res->[0][0]);
    $self->assert_str_equals("tooManyChanges", $res->[0][1]{type});
    $self->assert_str_equals("R1", $res->[0][2]);

    xlog "get email list updates with threads collapsed";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, collapseThreads => JSON::true, maxChanges => 1 }, "R1"]]);

    $self->assert_str_equals("error", $res->[0][0]);
    $self->assert_str_equals("tooManyChanges", $res->[0][1]{type});
    $self->assert_str_equals("R1", $res->[0][2]);
}

sub test_email_querychanges_zerosince
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("Email A") || die;

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    $self->make_message("Email B") || die;

    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);

    my ($idb) = grep { $_ ne $ida } @{$res->[0][1]->{ids}};

    xlog "get email list updates";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state }, "R1"]]);

    $self->assert_equals($res->[0][1]{added}[0]{id}, $idb);

    xlog "get email list updates with threads collapsed";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => "0", collapseThreads => JSON::true }, "R1"]]);
    $self->assert_equals('error', $res->[0][0]);
}


sub test_email_querychanges_thread
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;
    my %exp;
    my $dt;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "generating email A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{A} = $self->make_message("Email A", date => $dt, body => "a");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", body => "b");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "c");
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "generating email D referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -1));
    $exp{D} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "d");
    $exp{D}->set_attributes(uid => 4, cid => $exp{A}->get_attribute('cid'));

    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, collapseThreads => JSON::true }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    # assert that IDA got destroyed
    $self->assert_not_null(grep { $_ eq $ida } map { $_ } @{$res->[0][1]->{removed}});
    # and not recreated
    $self->assert_null(grep { $_ eq $ida } map { $_->{id} } @{$res->[0][1]->{added}});

    $talk->select("INBOX");
    $talk->store('3', "+flags", '\\Deleted');
    $talk->expunge();

    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, collapseThreads => JSON::true }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    $self->assert(ref($res->[0][1]{added}) eq 'ARRAY');
    $self->assert_num_equals(0, scalar @{$res->[0][1]{added}});
    $self->assert(ref($res->[0][1]{removed}) eq 'ARRAY');
    $self->assert_num_equals(0, scalar @{$res->[0][1]{removed}});

    $talk->store('3', "+flags", '\\Deleted');
    $talk->expunge();

    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, collapseThreads => JSON::true }, "R1"]]);

    $self->assert_num_equals(2, $res->[0][1]{total});
    $self->assert_num_equals(1, scalar(@{$res->[0][1]{added}}));
    $self->assert_num_equals(2, scalar(@{$res->[0][1]{removed}}));

    # same thread, back to ida
    $self->assert_str_equals($ida, $res->[0][1]{added}[0]{id});
    #$self->assert_str_equals($res->[0][1]{added}[0]{threadId}, $res->[0][1]{destroyed}[0]{threadId});
}

sub test_email_querychanges_sortflagged
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;
    my %exp;
    my $dt;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "generating email A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{A} = $self->make_message("Email A", date => $dt, body => "a");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
        ],
    }, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", body => "b");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "c");
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "generating email D referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -1));
    $exp{D} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "d");
    $exp{D}->set_attributes(uid => 4, cid => $exp{A}->get_attribute('cid'));

    # EXPECTED ORDER OF MESSAGES NOW BY DATE IS:
    # A C D B
    # fetch them all by ID now to get an ID map
    $res = $jmap->CallMethods([['Email/query', {
        sort => [
            { property => "receivedAt",
              "isAscending" => $JSON::true },
        ],
    }, "R1"]]);
    my @ids = @{$res->[0][1]->{ids}};
    $self->assert_num_equals(4, scalar @ids);
    $self->assert_str_equals($ida, $ids[0]);
    my $idc = $ids[1];
    my $idd = $ids[2];
    my $idb = $ids[3];

    # raw fetch - check order now
    $res = $jmap->CallMethods([['Email/query', {
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $self->assert_deep_equals([$idb, $idd], $res->[0][1]->{ids});

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sinceQueryState => $state, collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    $self->assert_num_equals(4, scalar @{$res->[0][1]->{removed}});
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{added}});
    # check that the order is B D
    $self->assert_deep_equals([{id => $idb, index => 0}, {id => $idd, index => 1}], $res->[0][1]{added});

    $talk->select("INBOX");
    $talk->store('1', "+flags", '\\Flagged');

    # this will sort D to the top because of the flag on A

    # raw fetch - check order now
    $res = $jmap->CallMethods([['Email/query', {
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $self->assert_deep_equals([$idd, $idb], $res->[0][1]->{ids});

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sinceQueryState => $state, collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    # will have removed 'D' (old exemplar) and 'A' (touched)
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $idd } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $ida } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $idc } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_deep_equals([{id => $idd, index => 0}], $res->[0][1]{added});
}

sub test_email_querychanges_sortflagged_topmessage
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;
    my %exp;
    my $dt;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "generating email A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{A} = $self->make_message("Email A", date => $dt, body => "a");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
        ],
    }, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", body => "b");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "c");
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "generating email D referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -1));
    $exp{D} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "d");
    $exp{D}->set_attributes(uid => 4, cid => $exp{A}->get_attribute('cid'));

    # EXPECTED ORDER OF MESSAGES NOW BY DATE IS:
    # A C D B
    # fetch them all by ID now to get an ID map
    $res = $jmap->CallMethods([['Email/query', {
        sort => [
            { property => "receivedAt",
              "isAscending" => $JSON::true },
        ],
    }, "R1"]]);
    my @ids = @{$res->[0][1]->{ids}};
    $self->assert_num_equals(4, scalar @ids);
    $self->assert_str_equals($ida, $ids[0]);
    my $idc = $ids[1];
    my $idd = $ids[2];
    my $idb = $ids[3];

    # raw fetch - check order now
    $res = $jmap->CallMethods([['Email/query', {
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $self->assert_deep_equals([$idb, $idd], $res->[0][1]->{ids});

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sinceQueryState => $state, collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    $self->assert_num_equals(4, scalar @{$res->[0][1]->{removed}});
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{added}});
    # check that the order is B D
    $self->assert_deep_equals([{id => $idb, index => 0}, {id => $idd, index => 1}], $res->[0][1]{added});

    $talk->select("INBOX");
    $talk->store('4', "+flags", '\\Flagged');

    # this will sort D to the top because of the flag on D

    # raw fetch - check order now
    $res = $jmap->CallMethods([['Email/query', {
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $self->assert_deep_equals([$idd, $idb], $res->[0][1]->{ids});

    $res = $jmap->CallMethods([['Email/queryChanges', {
        sinceQueryState => $state, collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    # will have removed 'D' (touched) as well as
    # XXX: C and A because it can't know what the old order was, oh well
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $idd } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $ida } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $idc } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_deep_equals([{id => $idd, index => 0}], $res->[0][1]{added});
}

sub test_email_querychanges_sortflagged_otherfolder
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;
    my %exp;
    my $dt;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "generating email A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{A} = $self->make_message("Email A", date => $dt, body => "a");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "Get mailbox id";
    $res = $jmap->CallMethods([['Mailbox/query', {}, "R1"]]);
    my $mbid = $res->[0][1]->{ids}[0];
    $self->assert_not_null($mbid);

    xlog "Get email id";
    $res = $jmap->CallMethods([['Email/query', {
        filter => { inMailbox => $mbid },
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
        ],
    }, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);

    $state = $res->[0][1]->{queryState};

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", body => "b");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email C referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "c");
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "Create new mailbox";
    $res = $jmap->CallMethods([['Mailbox/set', { create => { 1 => { name => "foo" } } }, "R1"]]);

    $self->{store}->set_folder("INBOX.foo");
    xlog "generating email D referencing A (in foo)";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -1));
    $exp{D} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "d");
    $exp{D}->set_attributes(uid => 1, cid => $exp{A}->get_attribute('cid'));

    # EXPECTED ORDER OF MESSAGES NOW BY DATE IS:
    # A C B (with D in the other mailbox)
    # fetch them all by ID now to get an ID map
    $res = $jmap->CallMethods([['Email/query', {
        filter => { inMailbox => $mbid },
        sort => [
            { property => "receivedAt",
              "isAscending" => $JSON::true },
        ],
    }, "R1"]]);
    my @ids = @{$res->[0][1]->{ids}};
    $self->assert_num_equals(3, scalar @ids);
    $self->assert_str_equals($ida, $ids[0]);
    my $idc = $ids[1];
    my $idb = $ids[2];

    # raw fetch - check order now
    $res = $jmap->CallMethods([['Email/query', {
        filter => { inMailbox => $mbid },
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $self->assert_deep_equals([$idb, $idc], $res->[0][1]->{ids});

    $res = $jmap->CallMethods([['Email/queryChanges', {
        filter => { inMailbox => $mbid },
        sinceQueryState => $state, collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{removed}});
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{added}});
    # check that the order is B C
    $self->assert_deep_equals([{id => $idb, index => 0}, {id => $idc, index => 1}], $res->[0][1]{added});

    $talk->select("INBOX.foo");
    $talk->store('1', "+flags", '\\Flagged');

    # this has put the flag on D, which should sort C to the top!

    # raw fetch - check order now
    $res = $jmap->CallMethods([['Email/query', {
        filter => { inMailbox => $mbid },
        collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $self->assert_deep_equals([$idc, $idb], $res->[0][1]->{ids});

    $res = $jmap->CallMethods([['Email/queryChanges', {
        filter => { inMailbox => $mbid },
        sinceQueryState => $state, collapseThreads => $JSON::true,
        sort => [
            { property => "someInThreadHaveKeyword",
              keyword => "\$flagged",
              isAscending => $JSON::false },
            { property => "receivedAt",
              isAscending => $JSON::false },
         ],
    }, "R1"]]);
    $state = $res->[0][1]{newQueryState};

    $self->assert_num_equals(2, $res->[0][1]{total});
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $ida } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_not_null(grep { $_ eq $idc } map { $_ } @{$res->[0][1]->{removed}});
    $self->assert_deep_equals([{id => $idc, index => 0}], $res->[0][1]{added});
}

sub test_email_querychanges_order
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;
    my $state;

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("A") || die;

    # First order descending by subject. We expect Email/queryChanges
    # to return any items added after 'state' to show up at the start of
    # the result list.
    my $sort = [{ property => "subject", isAscending => JSON::false }];

    xlog "Get email id and state";
    $res = $jmap->CallMethods([['Email/query', { sort => $sort }, "R1"]]);
    my $ida = $res->[0][1]->{ids}[0];
    $self->assert_not_null($ida);
    $state = $res->[0][1]->{queryState};

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("B") || die;

    xlog "Fetch updated list";
    $res = $jmap->CallMethods([['Email/query', { sort => $sort }, "R1"]]);
    my $idb = $res->[0][1]->{ids}[0];
    $self->assert_str_not_equals($ida, $idb);

    xlog "get email list updates";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, sort => $sort }, "R1"]]);
    $self->assert_equals($idb, $res->[0][1]{added}[0]{id});
    $self->assert_num_equals(0, $res->[0][1]{added}[0]{index});

    # Now restart with sorting by ascending subject. We refetch the state
    # just to be sure. Then we expect an additional item to show up at the
    # end of the result list.
    xlog "Fetch reverse sorted list and state";
    $sort = [{ property => "subject" }];
    $res = $jmap->CallMethods([['Email/query', { sort => $sort }, "R1"]]);
    $ida = $res->[0][1]->{ids}[0];
    $self->assert_str_not_equals($ida, $idb);
    $idb = $res->[0][1]->{ids}[1];
    $state = $res->[0][1]->{queryState};

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("C") || die;

    xlog "get email list updates";
    $res = $jmap->CallMethods([['Email/queryChanges', { sinceQueryState => $state, sort => $sort }, "R1"]]);
    $self->assert_str_not_equals($ida, $res->[0][1]{added}[0]{id});
    $self->assert_str_not_equals($idb, $res->[0][1]{added}[0]{id});
    $self->assert_num_equals(2, $res->[0][1]{added}[0]{index});
}

sub test_email_querychanges_implementation
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # Also see https://github.com/cyrusimap/cyrus-imapd/issues/2294

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate two emails via IMAP";
    $self->make_message("EmailA") || die;
    $self->make_message("EmailB") || die;

    # The JMAP implementation in Cyrus uses two strategies
    # for processing an Email/queryChanges request, depending
    # on the query arguments:
    #
    # (1) 'trivial': if collapseThreads is false
    #
    # (2) 'collapse': if collapseThreads is true
    #
    #  The results should be the same for (1) and (2), where
    #  updated message are reported as both 'added' and 'removed'.

    my $inboxid = $self->getinbox()->{id};

    xlog "Get email ids and state";
    my $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [
                { isAscending => JSON::true, property => 'subject' }
            ],
            collapseThreads => JSON::false,
        }, "R1"],
        ['Email/query', {
            sort => [
                { isAscending => JSON::true, property => 'subject' }
            ],
            collapseThreads => JSON::true,
        }, "R2"],
    ]);
    my $msgidA = $res->[0][1]->{ids}[0];
    $self->assert_not_null($msgidA);
    my $msgidB = $res->[0][1]->{ids}[1];
    $self->assert_not_null($msgidB);

    my $state_trivial = $res->[0][1]->{queryState};
    $self->assert_not_null($state_trivial);
    my $state_collapsed = $res->[1][1]->{queryState};
    $self->assert_not_null($state_collapsed);

        xlog "update email B";
        $res = $jmap->CallMethods([['Email/set', {
                update => { $msgidB => {
                        'keywords/$Seen' => JSON::true }
                },
        }, "R1"]]);
    $self->assert(exists $res->[0][1]->{updated}{$msgidB});

    xlog "Create two new emails via IMAP";
    $self->make_message("EmailC") || die;
    $self->make_message("EmailD") || die;

    xlog "Get email ids";
    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ isAscending => JSON::true, property => 'subject' }],
    }, "R1"]]);
    my $msgidC = $res->[0][1]->{ids}[2];
    $self->assert_not_null($msgidC);
    my $msgidD = $res->[0][1]->{ids}[3];
    $self->assert_not_null($msgidD);

    xlog "Query changes up to first newly created message";
    $res = $jmap->CallMethods([
        ['Email/queryChanges', {
            sort => [
                { isAscending => JSON::true, property => 'subject' }
            ],
            sinceQueryState => $state_trivial,
            collapseThreads => JSON::false,
            upToId => $msgidC,
        }, "R1"],
        ['Email/queryChanges', {
            sort => [
                { isAscending => JSON::true, property => 'subject' }
            ],
            sinceQueryState => $state_collapsed,
            collapseThreads => JSON::true,
            upToId => $msgidC,
        }, "R2"],
    ]);

    # 'trivial' case
    $self->assert_num_equals(2, scalar @{$res->[0][1]{added}});
    $self->assert_str_equals($msgidB, $res->[0][1]{added}[0]{id});
    $self->assert_num_equals(1, $res->[0][1]{added}[0]{index});
    $self->assert_str_equals($msgidC, $res->[0][1]{added}[1]{id});
    $self->assert_num_equals(2, $res->[0][1]{added}[1]{index});
    $self->assert_deep_equals([$msgidB, $msgidC], $res->[0][1]{removed});
    $self->assert_num_equals(4, $res->[0][1]{total});
    $state_trivial = $res->[0][1]{newQueryState};

    # 'collapsed' case
    $self->assert_num_equals(2, scalar @{$res->[1][1]{added}});
    $self->assert_str_equals($msgidB, $res->[1][1]{added}[0]{id});
    $self->assert_num_equals(1, $res->[1][1]{added}[0]{index});
    $self->assert_str_equals($msgidC, $res->[1][1]{added}[1]{id});
    $self->assert_num_equals(2, $res->[1][1]{added}[1]{index});
    $self->assert_deep_equals([$msgidB, $msgidC], $res->[1][1]{removed});
    $self->assert_num_equals(4, $res->[0][1]{total});
    $state_collapsed = $res->[1][1]{newQueryState};

    xlog "delete email C ($msgidC)";
    $res = $jmap->CallMethods([['Email/set', { destroy => [ $msgidC ] }, "R1"]]);
    $self->assert_str_equals($msgidC, $res->[0][1]->{destroyed}[0]);

    xlog "Query changes";
    $res = $jmap->CallMethods([
        ['Email/queryChanges', {
            sort => [
                { isAscending => JSON::true, property => 'subject' }
            ],
            sinceQueryState => $state_trivial,
            collapseThreads => JSON::false,
        }, "R1"],
        ['Email/queryChanges', {
            sort => [
                { isAscending => JSON::true, property => 'subject' }
            ],
            sinceQueryState => $state_collapsed,
            collapseThreads => JSON::true,
        }, "R2"],
    ]);

    # 'trivial' case
    $self->assert_num_equals(0, scalar @{$res->[0][1]{added}});
    $self->assert_deep_equals([$msgidC], $res->[0][1]{removed});
    $self->assert_num_equals(3, $res->[0][1]{total});

    # 'collapsed' case
    $self->assert_num_equals(0, scalar @{$res->[1][1]{added}});
    $self->assert_deep_equals([$msgidC], $res->[1][1]{removed});
    $self->assert_num_equals(3, $res->[0][1]{total});
}

sub test_email_changes_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $res;

    my $store = $self->{store};
    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    xlog "create user and share inbox";
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lrwkxd") or die;

    xlog "create non-shared mailbox box1";
    $admintalk->create("user.foo.box1") or die;
    $admintalk->setacl("user.foo.box1", "cassandane", "") or die;

    xlog "get email state";
    $res = $jmap->CallMethods([['Email/get', { accountId => 'foo', ids => []}, "R1"]]);
    my $state = $res->[0][1]->{state};
    $self->assert_not_null($state);

    xlog "get email updates (expect empty changes)";
    $res = $jmap->CallMethods([['Email/changes', { accountId => 'foo', sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    # This could be the same as oldState, or not, as we might leak
    # unshared modseqs (but not the according mail!).
    $self->assert_not_null($res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "Generate a email in shared account INBOX via IMAP";
    $self->{adminstore}->set_folder('user.foo');
    $self->make_message("Email A", store => $self->{adminstore}) || die;

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { accountId => 'foo', sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};
    my $ida = $res->[0][1]{created}[0];

    xlog "create email in non-shared mailbox";
    $self->{adminstore}->set_folder('user.foo.box1');
    $self->make_message("Email B", store => $self->{adminstore}) || die;

    xlog "get email updates (expect empty changes)";
    $res = $jmap->CallMethods([['Email/changes', { accountId => 'foo', sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    # This could be the same as oldState, or not, as we might leak
    # unshared modseqs (but not the according mail!).
    $self->assert_not_null($res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "share private mailbox box1";
    $admintalk->setacl("user.foo.box1", "cassandane", "lr") or die;

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { accountId => 'foo', sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "delete email $ida";
    $res = $jmap->CallMethods([['Email/set', { accountId => 'foo', destroy => [ $ida ] }, "R1"]]);
    $self->assert_str_equals($ida, $res->[0][1]->{destroyed}[0]);

    xlog "get email updates";
    $res = $jmap->CallMethods([['Email/changes', { accountId => 'foo', sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{destroyed}});
    $self->assert_str_equals($ida, $res->[0][1]{destroyed}[0]);
    $state = $res->[0][1]->{newState};
}

sub test_misc_upload_download822
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};

    my $download = $jmap->Download('cassandane', $blobid);

    $self->assert_str_equals($download->{content}, $email);
}

sub test_email_get_bogus_encoding
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: foobar

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};
    my $inboxid = $self->getinbox()->{id};

    xlog "import and get email from blob $blobid";
    my $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$inboxid =>  JSON::true},
            },
        },
    }, "R1"], ["Email/get", {
        ids => ["#1"],
        properties => ['bodyStructure', 'bodyValues'],
        fetchAllBodyValues => JSON::true,
    }, "R2" ]]);

    $self->assert_str_equals("Email/import", $res->[0][0]);
    $self->assert_str_equals("Email/get", $res->[1][0]);

    my $msg = $res->[1][1]{list}[0];
    my $partId = $msg->{bodyStructure}{partId};
    my $bodyValue = $msg->{bodyValues}{$partId};
    $self->assert_str_equals("", $bodyValue->{value});
    $self->assert_equals(JSON::true, $bodyValue->{isEncodingProblem});
}

sub test_misc_upload_sametype
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $lazy = "the quick brown fox jumped over the lazy dog";

    my $data = $jmap->Upload($lazy, "text/plain; charset=us-ascii");
    my $blobid = $data->{blobId};

    $data = $jmap->Upload($lazy, "TEXT/PLAIN; charset=US-Ascii");
    my $blobid2 = $data->{blobId};

    $self->assert_str_equals($blobid, $blobid2);
}

sub test_misc_brokenrfc822_badendline
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $email =~ s/\r//gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsmbox);

    xlog "import email from blob $blobid";
    $res = $jmap->CallMethods([['Email/import', {
            emails => {
                "1" => {
                    blobId => $blobid,
                    mailboxIds => {$draftsmbox =>  JSON::true},
                    keywords => {
                        '$Draft' => JSON::true,
                    },
                },
            },
        }, "R1"]]);
    my $error = $@;
    $self->assert_str_equals("invalidEmail", $res->[0][1]{notCreated}{1}{type});
}

sub test_email_import_zerobyte
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # A bogus email with an unencoded zero byte
    my $email = <<"EOF";
From: \"Some Example Sender\" <example\@local>\r\n
To: baseball\@local\r\n
Subject: test email\r\n
Date: Wed, 7 Dec 2016 22:11:11 +1100\r\n
MIME-Version: 1.0\r\n
Content-Type: text/plain; charset="UTF-8"\r\n
\r\n
This is a test email with a \x{0}-byte.\r\n
EOF

    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsmbox);

    xlog "import email from blob $blobid";
    $res = $jmap->CallMethods([['Email/import', {
            emails => {
                "1" => {
                    blobId => $blobid,
                    mailboxIds => {$draftsmbox =>  JSON::true},
                    keywords => {
                        '$Draft' => JSON::true,
                    },
                },
            },
        }, "R1"]]);
    $self->assert_str_equals("invalidEmail", $res->[0][1]{notCreated}{1}{type});
}


sub test_email_import_setdate
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 22:11:11 +1100
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsmbox);

    my $receivedAt = '2016-12-10T01:02:03Z';
    xlog "import email from blob $blobid";
    $res = eval {
        $jmap->CallMethods([['Email/import', {
            emails => {
                "1" => {
                    blobId => $blobid,
                    mailboxIds => {$draftsmbox =>  JSON::true},
                    keywords => {
                        '$Draft' => JSON::true,
                    },
                    receivedAt => $receivedAt,
                },
            },
        }, "R1"], ['Email/get', {ids => ["#1"]}, "R2"]]);
    };

    $self->assert_str_equals("Email/import", $res->[0][0]);
    my $msg = $res->[0][1]->{created}{"1"};
    $self->assert_not_null($msg);

    my $sentAt = '2016-12-07T11:11:11Z';
    $self->assert_str_equals("Email/get", $res->[1][0]);
    $self->assert_str_equals($msg->{id}, $res->[1][1]{list}[0]->{id});
    $self->assert_str_equals($receivedAt, $res->[1][1]{list}[0]->{receivedAt});
    $self->assert_str_equals($sentAt, $res->[1][1]{list}[0]->{sentAt});
}

sub test_email_import_mailboxid_by_role
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 22:11:11 +1100
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};

    xlog "create drafts mailbox";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $draftsMboxId = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsMboxId);

    xlog "import email from blob $blobid";
    $res = eval {
        $jmap->CallMethods([['Email/import', {
            emails => {
                "1" => {
                    blobId => $blobid,
                    mailboxIds => {
                        '$drafts'=>  JSON::true
                    },
                    keywords => {
                        '$Draft' => JSON::true,
                    },
                },
            },
        }, "R1"], ['Email/get', {ids => ["#1"]}, "R2"]]);
    };

    $self->assert_str_equals("Email/import", $res->[0][0]);
    $self->assert_not_null($res->[1][1]{list}[0]->{mailboxIds}{$draftsMboxId});
}

sub test_thread_get_onemsg
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;
    my $draftsmbox;
    my $state;
    my $threadA;
    my $threadB;

    my $imaptalk = $self->{store}->get_client();

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $draftsmbox = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsmbox);

    xlog "get thread state";
    $res = $jmap->CallMethods([['Thread/get', { ids => [ 'no' ] }, "R1"]]);
    $state = $res->[0][1]->{state};
    $self->assert_not_null($state);

    my $email = <<'EOF';
Return-Path: <Hannah.Smith@gmail.com>
Received: from gateway (gateway.vmtom.com [10.0.0.1])
    by ahost (ahost.vmtom.com[10.0.0.2]); Wed, 07 Dec 2016 11:43:25 +1100
Received: from mail.gmail.com (mail.gmail.com [192.168.0.1])
    by gateway.vmtom.com (gateway.vmtom.com [10.0.0.1]); Wed, 07 Dec 2016 11:43:25 +1100
Mime-Version: 1.0
Content-Type: text/plain; charset="us-ascii"
Content-Transfer-Encoding: 7bit
Subject: Email A
From: Hannah V. Smith <Hannah.Smith@gmail.com>
Message-ID: <fake.1481071405.58492@gmail.com>
Date: Wed, 07 Dec 2016 11:43:25 +1100
To: Test User <test@vmtom.com>
X-Cassandane-Unique: 294f71c341218d36d4bda75aad56599b7be3d15b

a
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};
    xlog "import email from blob $blobid";
    $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$draftsmbox =>  JSON::true},
                keywords => {
                    '$Draft' => JSON::true,
                },
            },
        },
    }, "R1"]]);

    xlog "get thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
}

sub test_thread_changes
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $jmap = $self->{jmap};
    my $res;
    my %params;
    my $dt;
    my $draftsmbox;
    my $state;
    my $threadA;
    my $threadB;

    my $imaptalk = $self->{store}->get_client();

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    $draftsmbox = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsmbox);

    xlog "Generate an email in drafts via IMAP";
    $self->{store}->set_folder("INBOX.drafts");
    $self->make_message("Email A") || die;

    xlog "get thread state";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' } }, 'R2' ],
    ]);
    $res = $jmap->CallMethods([
        ['Thread/get', { 'ids' => [ $res->[1][1]{list}[0]{threadId} ] }, 'R1'],
    ]);
    $state = $res->[0][1]->{state};
    $self->assert_not_null($state);

    xlog "get thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "generating email A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{A} = $self->make_message("Email A", date => $dt, body => "a");
    $exp{A}->set_attributes(uid => 1, cid => $exp{A}->make_cid());

    xlog "get thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};
    $threadA = $res->[0][1]{created}[0];

    xlog "generating email C referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "c");
    $exp{C}->set_attributes(uid => 3, cid => $exp{A}->get_attribute('cid'));

    xlog "get thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{updated}});
    $self->assert_str_equals($threadA, $res->[0][1]{updated}[0]);
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "get thread updates (expect no changes)";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});

    xlog "generating email B";
    $exp{B} = $self->make_message("Email B", body => "b");
    $exp{B}->set_attributes(uid => 2, cid => $exp{B}->make_cid());

    xlog "generating email D referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -1));
    $exp{D} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "d");
    $exp{D}->set_attributes(uid => 4, cid => $exp{A}->get_attribute('cid'));

    xlog "generating email E referencing A";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(minutes => -30));
    $exp{E} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "e");
    $exp{E}->set_attributes(uid => 5, cid => $exp{A}->get_attribute('cid'));

    xlog "get max 1 thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state, maxChanges => 1 }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::true, $res->[0][1]->{hasMoreChanges});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{created}});
    $self->assert_str_not_equals($threadA, $res->[0][1]{created}[0]);
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};
    $threadB = $res->[0][1]{created}[0];

    xlog "get max 2 thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state, maxChanges => 2 }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{updated}});
    $self->assert_str_equals($threadA, $res->[0][1]{updated}[0]);
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    xlog "fetch emails";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
    ]);

    # Map messages by body contents
    my %m = map { $_->{bodyValues}{$_->{textBody}[0]{partId}}{value} => $_ } @{$res->[1][1]{list}};
    my $msgA = $m{"a"};
    my $msgB = $m{"b"};
    my $msgC = $m{"c"};
    my $msgD = $m{"d"};
    my $msgE = $m{"e"};
    $self->assert_not_null($msgA);
    $self->assert_not_null($msgB);
    $self->assert_not_null($msgC);
    $self->assert_not_null($msgD);
    $self->assert_not_null($msgE);

    xlog "destroy email b, update email d";
    $res = $jmap->CallMethods([['Email/set', {
        destroy => [ $msgB->{id} ],
        update =>  { $msgD->{id} => { 'keywords/$foo' => JSON::true }},
    }, "R1"]]);
    $self->assert_str_equals($res->[0][1]{destroyed}[0], $msgB->{id});
    $self->assert(exists $res->[0][1]->{updated}{$msgD->{id}});

    xlog "get thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{updated}});
    $self->assert_str_equals($threadA, $res->[0][1]{updated}[0]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]{destroyed}});
    $self->assert_str_equals($threadB, $res->[0][1]{destroyed}[0]);
    $state = $res->[0][1]->{newState};

    xlog "destroy emails c and e";
    $res = $jmap->CallMethods([['Email/set', {
        destroy => [ $msgC->{id}, $msgE->{id} ],
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]{destroyed}});

    xlog "get thread updates, fetch threads";
    $res = $jmap->CallMethods([
        ['Thread/changes', { sinceState => $state }, "R1"],
        ['Thread/get', { '#ids' => { resultOf => 'R1', name => 'Thread/changes', path => '/updated' }}, 'R2'],
    ]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{updated}});
    $self->assert_str_equals($threadA, $res->[0][1]{updated}[0]);
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
    $state = $res->[0][1]->{newState};

    $self->assert_str_equals('Thread/get', $res->[1][0]);
    $self->assert_num_equals(1, scalar @{$res->[1][1]{list}});
    $self->assert_str_equals($threadA, $res->[1][1]{list}[0]->{id});

    xlog "destroy emails a and d";
    $res = $jmap->CallMethods([['Email/set', {
        destroy => [ $msgA->{id}, $msgD->{id} ],
    }, "R1"]]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]{destroyed}});

    xlog "get thread updates";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_not_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_num_equals(1, scalar @{$res->[0][1]{destroyed}});
    $self->assert_str_equals($threadA, $res->[0][1]{destroyed}[0]);
    $state = $res->[0][1]->{newState};

    xlog "get thread updates (expect no changes)";
    $res = $jmap->CallMethods([['Thread/changes', { sinceState => $state }, "R1"]]);
    $self->assert_str_equals($state, $res->[0][1]->{oldState});
    $self->assert_str_equals($state, $res->[0][1]->{newState});
    $self->assert_equals(JSON::false, $res->[0][1]->{hasMoreChanges});
    $self->assert_deep_equals([], $res->[0][1]{created});
    $self->assert_deep_equals([], $res->[0][1]{updated});
    $self->assert_deep_equals([], $res->[0][1]{destroyed});
}

sub test_thread_latearrival_drafts
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my %exp;
    my $dt;
    my $res;
    my $state;

    my $jmap = $self->{jmap};

    my $imaptalk = $self->{store}->get_client();

    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -8));
    $exp{A} = $self->make_message("Email A", date => $dt, body => 'a') || die;

    xlog "get thread state";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', { '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' }, properties => ['threadId'] }, 'R2' ],
        ['Thread/get', { '#ids' => { resultOf => 'R2', name => 'Email/get', path => '/list/*/threadId' } }, 'R3'],
    ]);
    $state = $res->[2][1]{state};
    $self->assert_not_null($state);
    my $threadid = $res->[2][1]{list}[0]{id};
    $self->assert_not_null($threadid);

    my $inreplyheader = [['In-Reply-To' => $exp{A}->messageid()]];

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($draftsmbox);

    xlog "generating email B";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -5));
    $exp{B} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "b");

    xlog "generating email C";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -2));
    $exp{C} = $self->make_message("Re: Email A", references => [ $exp{A}, $exp{B} ], date => $dt, body => "c");

    xlog "generating email D (before C)";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -3));
    $exp{D} = $self->make_message("Re: Email A", extra_headers => $inreplyheader, date => $dt, body => "d");

    xlog "Generate draft email E replying to A";
    $self->{store}->set_folder("INBOX.drafts");
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -4));
    $exp{E} = $self->{gen}->generate(subject => "Re: Email A", extra_headers => $inreplyheader, date => $dt, body => "e");
    $self->{store}->write_begin();
    $self->{store}->write_message($exp{E}, flags => ["\\Draft"]);
    $self->{store}->write_end();

    xlog "fetch emails";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
    ]);

    # Map messages by body contents
    my %m = map { $_->{bodyValues}{$_->{textBody}[0]{partId}}{value} => $_ } @{$res->[1][1]{list}};
    my $msgA = $m{"a"};
    my $msgB = $m{"b"};
    my $msgC = $m{"c"};
    my $msgD = $m{"d"};
    my $msgE = $m{"e"};
    $self->assert_not_null($msgA);
    $self->assert_not_null($msgB);
    $self->assert_not_null($msgC);
    $self->assert_not_null($msgD);
    $self->assert_not_null($msgE);

    my %map = (
        A => $msgA->{id},
        B => $msgB->{id},
        C => $msgC->{id},
        D => $msgD->{id},
        E => $msgE->{id},
    );

    # check thread ordering
    $res = $jmap->CallMethods([
        ['Thread/get', { 'ids' => [$threadid] }, 'R3'],
    ]);
    $self->assert_deep_equals([$map{A},$map{B},$map{E},$map{D},$map{C}],
                              $res->[0][1]{list}[0]{emailIds});

    # now deliver something late that's earlier than the draft

    xlog "generating email F (late arrival)";
    $dt = DateTime->now();
    $dt->add(DateTime::Duration->new(hours => -6));
    $exp{F} = $self->make_message("Re: Email A", references => [ $exp{A} ], date => $dt, body => "f");

    xlog "fetch emails";
    $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            fetchAllBodyValues => JSON::true,
        }, 'R2' ],
    ]);

    # Map messages by body contents
    %m = map { $_->{bodyValues}{$_->{textBody}[0]{partId}}{value} => $_ } @{$res->[1][1]{list}};
    my $msgF = $m{"f"};
    $self->assert_not_null($msgF);

    $map{F} = $msgF->{id};

    # check thread ordering - this message should appear after F and before B
    $res = $jmap->CallMethods([
        ['Thread/get', { 'ids' => [$threadid] }, 'R3'],
    ]);
    $self->assert_deep_equals([$map{A},$map{F},$map{B},$map{E},$map{D},$map{C}],
                              $res->[0][1]{list}[0]{emailIds});
}

sub test_email_import
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $inbox = $self->getinbox()->{id};
    $self->assert_not_null($inbox);

    # Generate an embedded email to get a blob id
    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "Content-Disposition: inline\r\n" . "\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "\r\n"
          . "Return-Path: <Ava.Nguyen\@local>\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Transfer-Encoding: 7bit\r\n"
          . "Subject: bar\r\n"
          . "From: Ava T. Nguyen <Ava.Nguyen\@local>\r\n"
          . "Message-ID: <fake.1475639947.6507\@local>\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: Test User <test\@local>\r\n"
          . "\r\n"
          . "An embedded email"
          . "\r\n--sub--\r\n",
    ) || die;

    xlog "get blobId";
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['attachments'],
        }, 'R2' ],
    ]);
    my $blobid = $res->[1][1]->{list}[0]->{attachments}[0]{blobId};
    $self->assert_not_null($blobid);

    xlog "create drafts mailbox";
    $res = $jmap->CallMethods([
            ['Mailbox/set', { create => { "1" => {
                            name => "drafts",
                            parentId => undef,
                            role => "drafts"
             }}}, "R1"]
    ]);
    my $drafts = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($drafts);

    xlog "import and get email from blob $blobid";
    $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$drafts =>  JSON::true},
                keywords => { '$Draft' => JSON::true },
            },
        },
    }, "R1"], ["Email/get", { ids => ["#1"] }, "R2" ]]);

    $self->assert_str_equals("Email/import", $res->[0][0]);
    my $msg = $res->[0][1]->{created}{"1"};
    $self->assert_not_null($msg);

    $self->assert_str_equals("Email/get", $res->[1][0]);
    $self->assert_str_equals($msg->{id}, $res->[1][1]{list}[0]->{id});

    xlog "load email";
    $res = $jmap->CallMethods([['Email/get', { ids => [$msg->{id}] }, "R1"]]);
    $self->assert_num_equals(1, scalar keys %{$res->[0][1]{list}[0]->{mailboxIds}});
    $self->assert_not_null($res->[0][1]{list}[0]->{mailboxIds}{$drafts});

    xlog "import existing email (expect email exists error)";
    $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$drafts =>  JSON::true, $inbox => JSON::true},
                keywords => { '$Draft' => JSON::true },
            },
        },
    }, "R1"]]);
    $self->assert_str_equals("Email/import", $res->[0][0]);
    $self->assert_str_equals("alreadyExists", $res->[0][1]->{notCreated}{"1"}{type});
    $self->assert_not_null($res->[0][1]->{notCreated}{"1"}{existingId});
}

sub test_email_import_error
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $inboxid = $self->getinbox()->{id};

    my $res = $jmap->CallMethods([['Email/import', { emails => "nope" }, 'R1' ]]);
    $self->assert_str_equals('error', $res->[0][0]);
    $self->assert_str_equals('invalidArguments', $res->[0][1]{type});
    $self->assert_str_equals('emails', $res->[0][1]{arguments}[0]);

    $res = $jmap->CallMethods([['Email/import', { emails => { 1 => "nope" }}, 'R1' ]]);
    $self->assert_str_equals('error', $res->[0][0]);
    $self->assert_str_equals('invalidArguments', $res->[0][1]{type});
    $self->assert_str_equals('emails/1', $res->[0][1]{arguments}[0]);

    $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => "nope",
                mailboxIds => {$inboxid =>  JSON::true},
            },
        },
    }, "R1"]]);

    $self->assert_str_equals('Email/import', $res->[0][0]);
    $self->assert_str_equals('invalidProperties', $res->[0][1]{notCreated}{1}{type});
    $self->assert_str_equals('blobId', $res->[0][1]{notCreated}{1}{properties}[0]);
}


sub test_email_import_shared
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $admintalk = $self->{adminstore}->get_client();

    # Create user and share mailbox
    xlog "create shared mailbox";
    $self->{instance}->create_user("foo");
    $admintalk->setacl("user.foo", "cassandane", "lkrwpsintex") or die;

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 22:11:11 +1100
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822", "foo");
    my $blobid = $data->{blobId};

    my $mboxid = $self->getinbox({accountId => 'foo'})->{id};

    my $req = ['Email/import', {
                accountId => 'foo',
                emails => {
                    "1" => {
                        blobId => $blobid,
                        mailboxIds => {$mboxid =>  JSON::true},
                        keywords => {  },
                    },
                },
            }, "R1"
    ];

    xlog "import email from blob $blobid";
    my $res = eval { $jmap->CallMethods([$req]) };
    $self->assert(exists $res->[0][1]->{created}{"1"});
}

sub test_email_import_has_attachment
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $emailSimple = <<'EOF';
From: example@example.com
To: example@example.biz
Subject: This is a test
Message-Id: <15288246899.CBDb71cE.3455@cyrus-dev>
Date: Tue, 12 Jun 2018 13:31:29 -0400
MIME-Version: 1.0

This is a very simple message.
EOF
    $emailSimple =~ s/\r?\n/\r\n/gs;
    my $blobIdSimple = $jmap->Upload($emailSimple, "message/rfc822")->{blobId};

    my $emailMixed = <<'EOF';
From: example@example.com
To: example@example.biz
Subject: This is a test
Message-Id: <15288246899.CBDb71cE.3455@cyrus-dev>
Date: Tue, 12 Jun 2018 13:31:29 -0400
MIME-Version: 1.0
Content-Type: multipart/mixed;boundary=123456789

--123456789
Content-Type: text/plain

This is a mixed message.

--123456789
Content-Type: application/data

data

--123456789--
EOF
    $emailMixed =~ s/\r?\n/\r\n/gs;
    my $blobIdMixed = $jmap->Upload($emailMixed, "message/rfc822")->{blobId};

    my $inboxId = $self->getinbox()->{id};

    my $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobIdSimple,
                mailboxIds => {$inboxId =>  JSON::true},
            },
            "2" => {
                blobId => $blobIdMixed,
                mailboxIds => {$inboxId =>  JSON::true},
            },
        },
    }, "R1"], ["Email/get", { ids => ["#1", "#2"] }, "R2" ]]);

    my $msgSimple = $res->[1][1]{list}[0];
    $self->assert_equals(JSON::false, $msgSimple->{hasAttachment});
    my $msgMixed = $res->[1][1]{list}[1];
    $self->assert_equals(JSON::true, $msgMixed->{hasAttachment});
}

sub test_misc_refobjects_simple
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "get email state";
    my $res = $jmap->CallMethods([['Email/get', { ids => [] }, "R1"]]);
    my $state = $res->[0][1]->{state};
    $self->assert_not_null($state);

    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("Email A") || die;

    xlog "get email updates and email using reference";
    $res = $jmap->CallMethods([
        ['Email/changes', {
            sinceState => $state,
        }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/changes',
                path => '/created',
            },
        }, 'R2'],
    ]);

    # assert that the changed id equals the id of the returned email
    $self->assert_str_equals($res->[0][1]{created}[0], $res->[1][1]{list}[0]{id});
}

sub test_email_import_no_keywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 22:11:11 +1100
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};

    my $mboxid = $self->getinbox()->{id};

    my $req = ['Email/import', {
                emails => {
                    "1" => {
                        blobId => $blobid,
                        mailboxIds => {$mboxid =>  JSON::true},
                    },
                },
            }, "R1"
    ];
    xlog "import email from blob $blobid";
    my $res = eval { $jmap->CallMethods([$req]) };
    $self->assert(exists $res->[0][1]->{created}{"1"});
}

sub test_misc_refobjects_extended
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    foreach my $i (1..10) {
        $self->make_message("Email$i") || die;
    }

    xlog "get email properties using reference";
    my $res = $jmap->CallMethods([
        ['Email/query', {
            sort => [{ property => 'receivedAt', isAscending => JSON::false }],
            collapseThreads => JSON::true,
            position => 0,
            limit => 10,
        }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids',
            },
            properties => [ 'threadId' ],
        }, 'R2'],
        ['Thread/get', {
            '#ids' => {
                resultOf => 'R2',
                name => 'Email/get',
                path => '/list/*/threadId',
            },
        }, 'R3'],
    ]);
    $self->assert_num_equals(10, scalar @{$res->[2][1]{list}});
}

sub test_email_set_patch
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $res = $jmap->CallMethods([['Mailbox/get', { }, "R1"]]);
    my $inboxid = $res->[0][1]{list}[0]{id};

    my $draft =  {
        mailboxIds => { $inboxid => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [ { name => "Bugs Bunny", email => "bugs\@acme.local" }, ],
        subject => "Memo",
        textBody => [{ partId => '1' }],
        bodyValues => { '1' => { value => "Whoa!" }},
        keywords => { '$Draft' => JSON::true, foo => JSON::true },
    };

    xlog "Create draft email";
    $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $draft }}, "R1"],
    ]);
    my $id = $res->[0][1]{created}{"1"}{id};

    $res = $jmap->CallMethods([
        ['Email/get', { 'ids' => [$id] }, 'R2' ]
    ]);
    my $msg = $res->[0][1]->{list}[0];
    $self->assert_equals(JSON::true, $msg->{keywords}->{'$draft'});
    $self->assert_equals(JSON::true, $msg->{keywords}->{'foo'});
    $self->assert_num_equals(2, scalar keys %{$msg->{keywords}});
    $self->assert_equals(JSON::true, $msg->{mailboxIds}->{$inboxid});
    $self->assert_num_equals(1, scalar keys %{$msg->{mailboxIds}});

    xlog "Patch email keywords";
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $id => {
                    "keywords/foo" => undef,
                    "keywords/bar" => JSON::true,
                }
            },
        }, "R1"],
        ['Email/get', { ids => [$id], properties => ['keywords'] }, 'R2'],
    ]);

    $msg = $res->[1][1]->{list}[0];
    $self->assert_equals(JSON::true, $msg->{keywords}->{'$draft'});
    $self->assert_equals(JSON::true, $msg->{keywords}->{'bar'});
    $self->assert_num_equals(2, scalar keys %{$msg->{keywords}});

    xlog "create mailbox";
    $res = $jmap->CallMethods([['Mailbox/set', {create => { "1" => { name => "baz", }}}, "R1"]]);
    my $mboxid = $res->[0][1]{created}{"1"}{id};
    $self->assert_not_null($mboxid);

    xlog "Patch email mailboxes";
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $id => {
                    "mailboxIds/$inboxid" => undef,
                    "mailboxIds/$mboxid" => JSON::true,
                }
            },
        }, "R1"],
        ['Email/get', { ids => [$id], properties => ['mailboxIds'] }, 'R2'],
    ]);
    $msg = $res->[1][1]->{list}[0];
    $self->assert_equals(JSON::true, $msg->{mailboxIds}->{$mboxid});
    $self->assert_num_equals(1, scalar keys %{$msg->{mailboxIds}});
}

sub test_capability
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};

    my $Request;
    my $Response;

    xlog "get settings";
    $Request = {
        headers => {
            'Authorization' => $jmap->auth_header(),
        },
        content => '',
    };
    $Response = $jmap->ua->get($jmap->uri(), $Request);
    if ($ENV{DEBUGJMAP}) {
        warn "JMAP " . Dumper($Request, $Response);
    }
    $self->assert_str_equals('200', $Response->{status});

    my $settings;
    $settings = eval { decode_json($Response->{content}) } if $Response->{success};

    my $cap = $settings->{capabilities}->{"urn:ietf:params:jmap:mail"};
    $self->assert($cap->{maxSizeAttachmentsPerEmail} > 0);
}

sub test_misc_set_oldstate
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # Assert that /set returns oldState (null, or a string)
    # See https://github.com/cyrusimap/cyrus-imapd/issues/2260

    xlog "create drafts mailbox and email";
    my $res = $jmap->CallMethods([
            ['Mailbox/set', {
                create => { "1" => {
                    name => "drafts",
                    parentId => undef,
                    role => "drafts"
                }}
            }, "R1"],
    ]);
    $self->assert(exists $res->[0][1]{oldState});
    my $draftsmbox = $res->[0][1]{created}{"1"}{id};

    my $draft =  {
        mailboxIds => { $draftsmbox => JSON::true },
        from => [ { name => "Yosemite Sam", email => "sam\@acme.local" } ] ,
        to => [
            { name => "Bugs Bunny", email => "bugs\@acme.local" },
        ],
        subject => "foo",
        textBody => [{partId => '1' }],
        bodyValues => { 1 => { value => "bar" }},
        keywords => { '$Draft' => JSON::true },
    };

    xlog "create a draft";
    $res = $jmap->CallMethods([['Email/set', { create => { "1" => $draft }}, "R1"]]);
    $self->assert(exists $res->[0][1]{oldState});
    my $msgid = $res->[0][1]{created}{"1"}{id};

    $res = $jmap->CallMethods( [ [ 'Identity/get', {}, "R1" ] ] );
    my $identityid = $res->[0][1]->{list}[0]->{id};

    xlog "create email submission";
    $res = $jmap->CallMethods( [ [ 'EmailSubmission/set', {
        create => {
            '1' => {
                identityId => $identityid,
                emailId  => $msgid,
            }
       }
    }, "R1" ] ] );
    $self->assert(exists $res->[0][1]{oldState});
}

sub test_email_set_text_crlf
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $inboxid = $self->getinbox()->{id};

    my $text = "ab\r\ncde\rfgh\nij";
    my $want = "ab\ncdefgh\nij";

    my $email =  {
        mailboxIds => { $inboxid => JSON::true },
        from => [ { email => q{test1@robmtest.vm}, name => q{} } ],
        to => [ {
            email => q{foo@bar.com},
            name => "foo",
        } ],
        textBody => [{partId => '1'}],
        bodyValues => {1 => { value => $text }},
    };

    xlog "create and get email";
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', { ids => [ "#1" ], fetchAllBodyValues => JSON::true }, "R2" ],
    ]);
    my $ret = $res->[1][1]->{list}[0];
    my $got = $ret->{bodyValues}{$ret->{textBody}[0]{partId}}{value};
    $self->assert_str_equals($want, $got);
}

sub test_email_set_text_split
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $inboxid = $self->getinbox()->{id};

    my $text = "x" x 2000;

    my $email =  {
        mailboxIds => { $inboxid => JSON::true },
        from => [ { email => q{test1@robmtest.vm}, name => q{} } ],
        to => [ {
            email => q{foo@bar.com},
            name => "foo",
        } ],
        textBody => [{partId => '1'}],
        bodyValues => {1 => { value => $text }},
    };

    xlog "create and get email";
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', { ids => [ "#1" ], fetchAllBodyValues => JSON::true }, "R2" ],
    ]);
    my $ret = $res->[1][1]->{list}[0];
    my $got = $ret->{bodyValues}{$ret->{textBody}[0]{partId}}{value};
}

sub test_email_get_attachedemails
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $body = "".
    "--sub\r\n".
    "Content-Type: text/plain; charset=UTF-8\r\n".
    "Content-Disposition: inline\r\n".
    "\r\n".
    "Short text". # Exactly 10 byte long body
    "\r\n--sub\r\n".
    "Content-Type: message/rfc822\r\n".
    "\r\n" .
    "Return-Path: <Ava.Nguyen\@local>\r\n".
    "Mime-Version: 1.0\r\n".
    "Content-Type: text/plain\r\n".
    "Content-Transfer-Encoding: 7bit\r\n".
    "Subject: bar\r\n".
    "From: Ava T. Nguyen <Ava.Nguyen\@local>\r\n".
    "Message-ID: <fake.1475639947.6507\@local>\r\n".
    "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n".
    "To: Test User <test\@local>\r\n".
    "\r\n".
    "Jeez....an embedded email".
    "\r\n--sub--\r\n";

    $exp_sub{A} = $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => $body
    );
    $talk->store('1', '+flags', '($HasAttachment)');

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    $self->assert_num_equals(1, scalar @{$msg->{attachments}});
    $self->assert_str_equals("message/rfc822", $msg->{attachments}[0]{type});
}

sub test_email_get_maxbodyvaluebytes_utf8
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    # A body containing a three-byte, two-byte and one-byte UTF-8 char
    my $body = "\N{EURO SIGN}\N{CENT SIGN}\N{DOLLAR SIGN}";
    my @wantbodies = (
        [1, ""],
        [2, ""],
        [3, "\N{EURO SIGN}"],
        [4, "\N{EURO SIGN}"],
        [5, "\N{EURO SIGN}\N{CENT SIGN}"],
        [6, "\N{EURO SIGN}\N{CENT SIGN}\N{DOLLAR SIGN}"],
    );

    utf8::encode($body);
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;

    xlog "get email id";
    my $res = $jmap->CallMethods([['Email/query', {}, 'R1']]);
    my $id = $res->[0][1]->{ids}[0];

    for my $tc ( @wantbodies ) {
        my $nbytes = $tc->[0];
        my $wantbody = $tc->[1];

        xlog "get email";
        my $res = $jmap->CallMethods([
            ['Email/get', {
                ids => [ $id ],
                properties => [ 'bodyValues' ],
                fetchAllBodyValues => JSON::true,
                maxBodyValueBytes => $nbytes + 0,
            }, "R1"],
        ]);
        my $msg = $res->[0][1]->{list}[0];
        $self->assert_str_equals($wantbody, $msg->{bodyValues}{'1'}{value});
    }
}

sub test_email_get_header_all
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    my %exp_inbox;
    my %params = (
        extra_headers => [
            ['x-tra', "foo"],
            ['x-tra', "bar"],
        ],
        body => "hello",
    );
    $self->make_message("Email A", %params) || die;

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', { ids => $ids, properties => ['header:x-tra:all', 'header:x-tra:asRaw:all'] }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    $self->assert_deep_equals([' foo', ' bar'], $msg->{'header:x-tra:all'});
    $self->assert_deep_equals([' foo', ' bar'], $msg->{'header:x-tra:asRaw:all'});
}

sub test_email_set_nullheader
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $inboxid = $self->getinbox()->{id};

    my $text = "x";

    # Prepare test email
    my $email =  {
        mailboxIds => { $inboxid => JSON::true },
        from => [ { email => q{test1@robmtest.vm}, name => q{} } ],
        'header:foo' => undef,
        'header:foo:asMessageIds' => undef,
    };

    # Create and get mail
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', {
            ids => [ "#1" ],
            properties => [ 'headers', 'header:foo' ],
        }, "R2" ],
    ]);
    my $msg = $res->[1][1]{list}[0];

    foreach (@{$msg->{headers}}) {
        xlog "Checking header $_->{name}";
        $self->assert_str_not_equals('foo', $_->{name});
    }
    $self->assert_null($msg->{'header:foo'});
}

sub test_email_set_headers
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $inboxid = $self->getinbox()->{id};

    my $text = "x";

    # Prepare test headers
    my $headers = {
        'header:X-TextHeader8bit' => {
            format  => 'asText',
            value   => "I feel \N{WHITE SMILING FACE}",
            wantRaw => " =?UTF-8?Q?I_feel_=E2=98=BA?="
        },
        'header:X-TextHeaderLong' => {
            format  => 'asText',
            value   => "x" x 80,
            wantRaw => " =?UTF-8?Q?xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx?=\r\n =?UTF-8?Q?xxxxxxxxxxxxxxxxxx?="
        },
        'header:X-TextHeaderShort' => {
            format  => 'asText',
            value   => "x",
            wantRaw => " x"
        },
       'header:X-MsgIdsShort' => {
           format => 'asMessageIds',
           value  => [ 'foobar@ba' ],
           wantRaw => " <foobar\@ba>",
       },
       'header:X-MsgIdsLong' => {
           format => 'asMessageIds',
           value  => [
               'foobar@ba',
               'foobar@ba',
               'foobar@ba',
               'foobar@ba',
               'foobar@ba',
               'foobar@ba',
               'foobar@ba',
               'foobar@ba',
           ],
           wantRaw => (" <foobar\@ba>" x 5)."\r\n".(" <foobar\@ba>" x 3),
       },
       'header:X-AddrsShort' => {
           format => 'asAddresses',
           value => [{ 'name' => 'foo', email => 'bar@local' }],
           wantRaw => ' foo <bar@local>',
       },
       'header:X-AddrsQuoted' => {
           format => 'asAddresses',
           value => [{ 'name' => 'Foo Bar', email => 'quotbar@local' }],
           wantRaw => ' "Foo Bar" <quotbar@local>',
       },
       'header:X-Addrs8bit' => {
           format => 'asAddresses',
           value => [{ 'name' => "Rudi R\N{LATIN SMALL LETTER U WITH DIAERESIS}be", email => 'bar@local' }],
           wantRaw => ' =?UTF-8?Q?Rudi_R=C3=BCbe?= <bar@local>',
       },
       'header:X-AddrsLong' => {
           format => 'asAddresses',
           value => [{
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }, {
               'name' => 'foo', email => 'bar@local'
           }],
           wantRaw => (' foo <bar@local>,' x 3)."\r\n".(' foo <bar@local>,' x 4)."\r\n".' foo <bar@local>',
       },
       'header:X-URLsShort' => {
           format => 'asURLs',
           value => [ 'foourl' ],
           wantRaw => ' <foourl>',
       },
       'header:X-URLsLong' => {
           format => 'asURLs',
           value => [
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
               'foourl',
           ],
           wantRaw => (' <foourl>,' x 6)."\r\n".(' <foourl>,' x 4).' <foourl>',
       },
    };

    # Prepare test email
    my $email =  {
        mailboxIds => { $inboxid => JSON::true },
        from => [ { email => q{test1@robmtest.vm}, name => q{} } ],
    };
    while( my ($k, $v) = each %$headers ) {
        $email->{$k.':'.$v->{format}} = $v->{value},
    }

    my @properties = keys %$headers;
    while( my ($k, $v) = each %$headers ) {
        push @properties, $k.':'.$v->{format};
    }


    # Create and get mail
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', {
            ids => [ "#1" ],
            properties => \@properties,
        }, "R2" ],
    ]);
    my $msg = $res->[1][1]{list}[0];

    # Validate header values
    while( my ($k, $v) = each %$headers ) {
        xlog "Validating $k";
        my $raw = $msg->{$k};
        my $val = $msg->{$k.':'.$v->{format}};
        # Check raw header
        $self->assert_str_equals($v->{wantRaw}, $raw);
        # Check formatted header
        if (ref $v->{value} eq 'ARRAY') {
            $self->assert_deep_equals($v->{value}, $val);
        } else {
            $self->assert_str_equals($v->{value}, $val);
        }
    }
}

sub test_email_download
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Generate a email in INBOX via IMAP";
    my $body = "--047d7b33dd729737fe04d3bde348\r\n";
    $body .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $body .= "\r\n";
    $body .= "some text";
    $body .= "\r\n";
    $body .= "--047d7b33dd729737fe04d3bde348\r\n";
    $body .= "Content-Type: text/html;charset=\"UTF-8\"\r\n";
    $body .= "\r\n";
    $body .= "<p>some HTML text</p>";
    $body .= "\r\n";
    $body .= "--047d7b33dd729737fe04d3bde348--\r\n";
    $self->make_message("foo",
        mime_type => "multipart/alternative",
        mime_boundary => "047d7b33dd729737fe04d3bde348",
        body => $body
    );

    xlog "get email";
    my $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => [ 'blobId' ],
        }, 'R2'],
    ]);
    my $msg = $res->[1][1]->{list}[0];

    my $blob = $jmap->Download({ accept => 'message/rfc822' }, 'cassandane', $msg->{blobId});
    $self->assert_str_equals('message/rfc822', $blob->{headers}->{'content-type'});
    $self->assert_num_not_equals(0, $blob->{headers}->{'content-length'});
}

sub test_email_embedded_download
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    # Generate an embedded email
    xlog "Generate a email in INBOX via IMAP";
    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: text/plain; charset=UTF-8\r\n"
          . "Content-Disposition: inline\r\n" . "\r\n"
          . "some text"
          . "\r\n--sub\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "\r\n"
          . "Return-Path: <Ava.Nguyen\@local>\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Transfer-Encoding: 7bit\r\n"
          . "Subject: bar\r\n"
          . "From: Ava T. Nguyen <Ava.Nguyen\@local>\r\n"
          . "Message-ID: <fake.1475639947.6507\@local>\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: Test User <test\@local>\r\n"
          . "\r\n"
          . "An embedded email"
          . "\r\n--sub--\r\n",
    ) || die;

    xlog "get blobId";
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['attachments'],
        }, 'R2' ],
    ]);
    my $blobId = $res->[1][1]->{list}[0]->{attachments}[0]{blobId};

    my $blob = $jmap->Download({ accept => 'message/rfc822' }, 'cassandane', $blobId);
    $self->assert_str_equals('message/rfc822', $blob->{headers}->{'content-type'});
    $self->assert_num_not_equals(0, $blob->{headers}->{'content-length'});
}

sub test_blob_download
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $logofile = abs_path('data/logo.gif');
    open(FH, "<$logofile");
    local $/ = undef;
    my $binary = <FH>;
    close(FH);
    my $data = $jmap->Upload($binary, "image/gif");

    my $blob = $jmap->Download({ accept => 'image/gif' }, 'cassandane', $data->{blobId});
    $self->assert_str_equals('image/gif', $blob->{headers}->{'content-type'});
    $self->assert_num_not_equals(0, $blob->{headers}->{'content-length'});
    $self->assert_equals($binary, $blob->{content});
}

sub test_email_set_filename
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Upload a data blob";
    my $binary = pack "H*", "beefcode";
    my $data = $jmap->Upload($binary, "image/gif");
    my $dataBlobId = $data->{blobId};

    my @testcases = ({
        name   => 'foo',
        wantCt => ' image/gif; name="foo"',
        wantCd => ' attachment;filename="foo"',
    }, {
        name   => "I feel \N{WHITE SMILING FACE}",
        wantCt => ' image/gif; name="=?UTF-8?Q?I_feel_=E2=98=BA?="',
        wantCd => " attachment;filename*=utf-8''%49%20%66%65%65%6c%20%e2%98%ba",
    }, {
        name   => "foo" . ("_foo" x 20),
        wantCt => " image/gif;\r\n name=\"=?UTF-8?Q?foo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffo?=\r\n =?UTF-8?Q?o=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo=5Ffoo?=\"",
        wantCd => " attachment;\r\n filename*0*=\"foo_foo_foo_foo_foo_foo_foo_foo_foo_foo_foo_foo_foo_foo_foo_\";\r\n filename*1*=\"foo_foo_foo_foo_foo_foo\"",
    }, {
        name   => 'Incoming Email Flow.xml',
        wantCt => ' image/gif; name="Incoming Email Flow.xml"',
        wantCd => ' attachment;filename="Incoming Email Flow.xml"',
    });

    foreach my $tc (@testcases) {
        xlog "Checking name $tc->{name}";
        my $bodyStructure = {
            type => "multipart/alternative",
            subParts => [{
                    type => 'text/plain',
                    partId => '1',
                }, {
                    type => 'image/gif',
                    disposition => 'attachment',
                    name => $tc->{name},
                    blobId => $dataBlobId,
                }],
        };

        xlog "Create email with body structure";
        my $inboxid = $self->getinbox()->{id};
        my $email = {
            mailboxIds => { $inboxid => JSON::true },
            from => [{ name => "Test", email => q{foo@bar} }],
            subject => "test",
            bodyStructure => $bodyStructure,
            bodyValues => {
                "1" => {
                    value => "A text body",
                },
            },
        };
        my $res = $jmap->CallMethods([
                ['Email/set', { create => { '1' => $email } }, 'R1'],
                ['Email/get', {
                        ids => [ '#1' ],
                        properties => [ 'bodyStructure' ],
                        bodyProperties => [ 'partId', 'blobId', 'type', 'name', 'disposition', 'header:Content-Type', 'header:Content-Disposition' ],
                        fetchAllBodyValues => JSON::true,
                    }, 'R2' ],
            ]);

        my $gotBodyStructure = $res->[1][1]{list}[0]{bodyStructure};
        my $gotName = $gotBodyStructure->{subParts}[1]{name};
        $self->assert_str_equals($tc->{name}, $gotName);
        my $gotCt = $gotBodyStructure->{subParts}[1]{'header:Content-Type'};
        $self->assert_str_equals($tc->{wantCt}, $gotCt);
        my $gotCd = $gotBodyStructure->{subParts}[1]{'header:Content-Disposition'};
        $self->assert_str_equals($tc->{wantCd}, $gotCd);
    }
}

sub test_email_get_size
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    $self->make_message("foo",
        mime_type => 'text/plain; charset="UTF-8"',
        mime_encoding => 'quoted-printable',
        body => '=C2=A1Hola, se=C3=B1or!',
    ) || die;
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['bodyStructure', 'size'],
        }, 'R2' ],
    ]);

    my $msg = $res->[1][1]{list}[0];
    $self->assert_num_equals(15, $msg->{bodyStructure}{size});
}

sub test_email_get_references
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $rawReferences = '<bar>, <baz>';
    my $parsedReferences = [ 'bar', 'baz' ];

    $self->make_message("foo",
        mime_type => 'text/plain',
        extra_headers => [
            ['References', $rawReferences],
        ],
        body => 'foo',
    ) || die;
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['references', 'header:references', 'header:references:asMessageIds'],
        }, 'R2' ],
    ]);
    my $msg = $res->[1][1]{list}[0];
    $self->assert_str_equals(' ' . $rawReferences, $msg->{'header:references'});
    $self->assert_deep_equals($parsedReferences, $msg->{'header:references:asMessageIds'});
    $self->assert_deep_equals($parsedReferences, $msg->{references});
}

sub test_email_get_groupaddr
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    # Straight from Appendix A.1.3 of RFC 5322
    my $rawTo = 'A Group:Ed Jones <c@a.test>,joe@where.test,John <jdoe@one.test>';
    my $wantTo = [{
        name => 'A Group',
        email => undef,
    }, {
        name => 'Ed Jones',
        email => 'c@a.test',
    }, {
        name => undef,
        email => 'joe@where.test'
    }, {
        name => 'John',
        email => 'jdoe@one.test',
    }, {
        name => undef,
        email => undef
    }];

    my $msg = $self->{gen}->generate();
    $msg->set_headers('To', ($rawTo));
    $self->_save_message($msg);

    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['to'],
        }, 'R2' ],
    ]);
    $self->assert_deep_equals($wantTo, $res->[1][1]{list}[0]->{to});
}

sub test_email_parse
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "\r\n"
          . "Return-Path: <Ava.Nguyen\@local>\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Transfer-Encoding: 7bit\r\n"
          . "Subject: bar\r\n"
          . "From: Ava T. Nguyen <Ava.Nguyen\@local>\r\n"
          . "Message-ID: <fake.1475639947.6507\@local>\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: Test User <test\@local>\r\n"
          . "\r\n"
          . "An embedded email"
          . "\r\n--sub--\r\n",
    ) || die;
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['attachments'],
        }, 'R2' ],
    ]);
    my $blobId = $res->[1][1]{list}[0]{attachments}[0]{blobId};

    my @props = $self->defaultprops_for_email_get();
    push @props, "bodyStructure";
    push @props, "bodyValues";

    $res = $jmap->CallMethods([['Email/parse', {
        blobIds => [ $blobId ], properties => \@props, fetchAllBodyValues => JSON::true,
    }, 'R1']]);
    my $email = $res->[0][1]{parsed}{$blobId};
    $self->assert_not_null($email);

    $self->assert_null($email->{id});
    $self->assert_null($email->{threadId});
    $self->assert_null($email->{mailboxIds});
    $self->assert_null($email->{keywords});
    $self->assert_deep_equals(['fake.1475639947.6507@local'], $email->{messageId});
    $self->assert_deep_equals([{name=>'Ava T. Nguyen', email=>'Ava.Nguyen@local'}], $email->{from});
    $self->assert_deep_equals([{name=>'Test User', email=>'test@local'}], $email->{to});
    $self->assert_null($email->{cc});
    $self->assert_null($email->{bcc});
    $self->assert_null($email->{references});
    $self->assert_null($email->{sender});
    $self->assert_null($email->{replyTo});
    $self->assert_str_equals('bar', $email->{subject});
    $self->assert_str_equals('2016-10-05T03:59:07Z', $email->{sentAt});
    $self->assert_not_null($email->{blobId});
    $self->assert_str_equals('text/plain', $email->{bodyStructure}{type});
    $self->assert_null($email->{bodyStructure}{subParts});
    $self->assert_num_equals(1, scalar @{$email->{textBody}});
    $self->assert_num_equals(1, scalar @{$email->{htmlBody}});
    $self->assert_num_equals(0, scalar @{$email->{attachments}});

    my $bodyValue = $email->{bodyValues}{$email->{bodyStructure}{partId}};
    $self->assert_str_equals('An embedded email', $bodyValue->{value});
}

sub test_email_parse_digest
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    $self->make_message("foo",
        mime_type => "multipart/digest",
        mime_boundary => "sub",
        body => ""
          . "\r\n--sub\r\n"
          . "\r\n"
          . "Return-Path: <Ava.Nguyen\@local>\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Transfer-Encoding: 7bit\r\n"
          . "Subject: bar\r\n"
          . "From: Ava T. Nguyen <Ava.Nguyen\@local>\r\n"
          . "Message-ID: <fake.1475639947.6507\@local>\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: Test User <test\@local>\r\n"
          . "\r\n"
          . "An embedded email"
          . "\r\n--sub--\r\n",
    ) || die;
    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['bodyStructure']
        }, 'R2' ],
    ]);
    my $blobId = $res->[1][1]{list}[0]{bodyStructure}{subParts}[0]{blobId};
    $self->assert_not_null($blobId);

    $res = $jmap->CallMethods([['Email/parse', { blobIds => [ $blobId ] }, 'R1']]);
    $self->assert_not_null($res->[0][1]{parsed}{$blobId});
}

sub test_email_parse_blob822
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $rawEmail = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $rawEmail =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($rawEmail, "application/data");
    my $blobId = $data->{blobId};

    my @props = $self->defaultprops_for_email_get();
    push @props, "bodyStructure";
    push @props, "bodyValues";

    my $res = $jmap->CallMethods([['Email/parse', {
        blobIds => [ $blobId ],
        properties => \@props,
        fetchAllBodyValues => JSON::true,
    }, 'R1']]);
    my $email = $res->[0][1]{parsed}{$blobId};

    $self->assert_not_null($email);
    $self->assert_deep_equals([{name=>'Some Example Sender', email=>'example@example.com'}], $email->{from});

    my $bodyValue = $email->{bodyValues}{$email->{bodyStructure}{partId}};
    $self->assert_str_equals("This is a test email.\n", $bodyValue->{value});
}

sub test_email_parse_base64
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $rawEmail = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $rawEmail =~ s/\r?\n/\r\n/gs;

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "sub",
        body => ""
          . "--sub\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          . "\r\n"
          . MIME::Base64::encode_base64($rawEmail, "\r\n")
          . "\r\n--sub--\r\n",
    ) || die;

    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['attachments'],
        }, 'R2' ],
    ]);
    my $blobId = $res->[1][1]{list}[0]{attachments}[0]{blobId};

    my @props = $self->defaultprops_for_email_get();
    push @props, "bodyStructure";
    push @props, "bodyValues";

    $res = $jmap->CallMethods([['Email/parse', {
        blobIds => [ $blobId ],
        properties => \@props,
        fetchAllBodyValues => JSON::true,
    }, 'R1']]);

    my $email = $res->[0][1]{parsed}{$blobId};
    $self->assert_not_null($email);
    $self->assert_deep_equals(
        [{
            name => 'Some Example Sender',
            email => 'example@example.com'
        }],
        $email->{from}
    );
    my $bodyValue = $email->{bodyValues}{$email->{bodyStructure}{partId}};
    $self->assert_str_equals("This is a test email.\n", $bodyValue->{value});
}

sub test_email_parse_blob822_lenient
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    # This isn't a valid RFC822 message, as it neither contains
    # a Date nor a From header. But there's wild stuff out there,
    # so let's be lenient.
    my $rawEmail = <<'EOF';
To: foo@bar.local
MIME-Version: 1.0

Some illegit mail.
EOF
    $rawEmail =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($rawEmail, "application/data");
    my $blobId = $data->{blobId};

    my $res = $jmap->CallMethods([['Email/parse', {
        blobIds => [ $blobId ],
        fetchAllBodyValues => JSON::true,
    }, 'R1']]);
    my $email = $res->[0][1]{parsed}{$blobId};

    $self->assert_not_null($email);
    $self->assert_null($email->{from});
    $self->assert_null($email->{sentAt});
    $self->assert_deep_equals([{name=>undef, email=>'foo@bar.local'}], $email->{to});
}

sub test_email_parse_contenttype_default
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $emailWithoutContentType = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0

This is a test email.
EOF

    my $emailWithoutCharset = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
Content-Type: text/plain
MIME-Version: 1.0

This is a test email.
EOF

    my $emailWithNonTextContentType = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
Content-Type: application/data
MIME-Version: 1.0

This is a test email.
EOF


    my @testCases = ({
        desc => "Email without Content-Type header",
        rawEmail => $emailWithoutContentType,
        wantContentType => 'text/plain',
        wantCharset => 'us-ascii',
    }, {
        desc => "Email without charset parameter",
        rawEmail => $emailWithoutCharset,
        wantContentType => 'text/plain',
        wantCharset => 'us-ascii',
    }, {
        desc => "Email with non-text Content-Type",
        rawEmail => $emailWithNonTextContentType,
        wantContentType => 'application/data',
        wantCharset => undef,
    });

    foreach (@testCases) {
        xlog "Running test: $_->{desc}";
        my $rawEmail = $_->{rawEmail};
        $rawEmail =~ s/\r?\n/\r\n/gs;
        my $data = $jmap->Upload($rawEmail, "application/data");
        my $blobId = $data->{blobId};

        my $res = $jmap->CallMethods([['Email/parse', {
            blobIds => [ $blobId ],
            properties => ['bodyStructure'],
        }, 'R1']]);
        my $email = $res->[0][1]{parsed}{$blobId};
        $self->assert_str_equals($_->{wantContentType}, $email->{bodyStructure}{type});
        if (defined $_->{wantCharset}) {
            $self->assert_str_equals($_->{wantCharset}, $email->{bodyStructure}{charset});
        } else {
            $self->assert_null($email->{bodyStructure}{charset});
        }
    }
}

sub test_email_parse_encoding
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $decodedBody = "\N{LATIN SMALL LETTER A WITH GRAVE} la carte";
    my $encodedBody = '=C3=A0 la carte';
    $encodedBody =~ s/\r?\n/\r\n/gs;

    my $Header = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable
EOF
    $Header =~ s/\r?\n/\r\n/gs;
    my $emailBlob = $Header . "\r\n" . $encodedBody;

    my $email;
    my $res;
    my $partId;

    $self->make_message("foo",
        mime_type => "multipart/mixed;boundary=1234567",
        body => ""
        . "--1234567\r\n"
        . "Content-Type: text/plain; charset=utf-8\r\n"
        . "Content-Transfer-Encoding: quoted-printable\r\n"
        . "\r\n"
        . $encodedBody
        . "\r\n--1234567\r\n"
        . "Content-Type: message/rfc822\r\n"
        . "\r\n"
        . "X-Header: ignore\r\n" # make this blob id unique
        . $emailBlob
        . "\r\n--1234567--\r\n"
    );

    # Assert content decoding for top-level message.
    xlog "get email";
    $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => ['bodyValues', 'bodyStructure', 'textBody'],
            bodyProperties => ['partId', 'blobId'],
            fetchAllBodyValues => JSON::true,
        }, 'R2'],
    ]);
    $self->assert_num_equals(scalar @{$res->[0][1]->{ids}}, 1);
    $email = $res->[1][1]->{list}[0];
    $partId = $email->{textBody}[0]{partId};
    $self->assert_str_equals($decodedBody, $email->{bodyValues}{$partId}{value});

    # Assert content decoding for embedded message.
    xlog "parse embedded email";
    my $embeddedBlobId = $email->{bodyStructure}{subParts}[1]{blobId};
    $res = $jmap->CallMethods([['Email/parse', {
        blobIds => [ $email->{bodyStructure}{subParts}[1]{blobId} ],
        properties => ['bodyValues', 'textBody'],
        fetchAllBodyValues => JSON::true,
    }, 'R1']]);
    $email = $res->[0][1]{parsed}{$embeddedBlobId};
    $partId = $email->{textBody}[0]{partId};
    $self->assert_str_equals($decodedBody, $email->{bodyValues}{$partId}{value});

    # Assert content decoding for message blob.
    my $data = $jmap->Upload($emailBlob, "application/data");
    my $blobId = $data->{blobId};

    $res = $jmap->CallMethods([['Email/parse', {
        blobIds => [ $blobId ],
        properties => ['bodyValues', 'textBody'],
        fetchAllBodyValues => JSON::true,
    }, 'R1']]);
    $email = $res->[0][1]{parsed}{$blobId};
    $partId = $email->{textBody}[0]{partId};
    $self->assert_str_equals($decodedBody, $email->{bodyValues}{$partId}{value});
}

sub test_email_parse_notparsable
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $rawEmail = ""
    ."To:foo\@bar.local\r\n"
    ."Date: Date: Wed, 7 Dec 2016 00:21:50 -0500\r\n"
    ."\r\n"
    ."Some\nbogus\nbody";

    my $data = $jmap->Upload($rawEmail, "application/data");
    my $blobId = $data->{blobId};

    my $res = $jmap->CallMethods([['Email/parse', { blobIds => [ $blobId ] }, 'R1']]);
    $self->assert_str_equals($blobId, $res->[0][1]{notParsable}[0]);
}

sub test_email_get_bodystructure
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary_1",
        body => ""
        # body A
          . "\r\n--boundary_1\r\n"
          . "X-Body-Id:A\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Disposition: inline\r\n"
          . "\r\n"
          . "A"
        # multipart/mixed
          . "\r\n--boundary_1\r\n"
          . "Content-Type: multipart/mixed; boundary=\"boundary_1_1\"\r\n"
        # multipart/alternative
          . "\r\n--boundary_1_1\r\n"
          . "Content-Type: multipart/alternative; boundary=\"boundary_1_1_1\"\r\n"
        # multipart/mixed
          . "\r\n--boundary_1_1_1\r\n"
          . "Content-Type: multipart/mixed; boundary=\"boundary_1_1_1_1\"\r\n"
        # body B
          . "\r\n--boundary_1_1_1_1\r\n"
          . "X-Body-Id:B\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Disposition: inline\r\n"
          . "\r\n"
          . "B"
        # body C
          . "\r\n--boundary_1_1_1_1\r\n"
          . "X-Body-Id:C\r\n"
          . "Content-Type: image/jpeg\r\n"
          . "Content-Disposition: inline\r\n"
          . "\r\n"
          . "C"
        # body D
          . "\r\n--boundary_1_1_1_1\r\n"
          . "X-Body-Id:D\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Disposition: inline\r\n"
          . "\r\n"
          . "D"
        # end multipart/mixed
          . "\r\n--boundary_1_1_1_1--\r\n"
        # multipart/mixed
          . "\r\n--boundary_1_1_1\r\n"
          . "Content-Type: multipart/related; boundary=\"boundary_1_1_1_2\"\r\n"
        # body E
          . "\r\n--boundary_1_1_1_2\r\n"
          . "X-Body-Id:E\r\n"
          . "Content-Type: text/html\r\n"
          . "\r\n"
          . "E"
        # body F
          . "\r\n--boundary_1_1_1_2\r\n"
          . "X-Body-Id:F\r\n"
          . "Content-Type: image/jpeg\r\n"
          . "\r\n"
          . "F"
        # end multipart/mixed
          . "\r\n--boundary_1_1_1_2--\r\n"
        # end multipart/alternative
          . "\r\n--boundary_1_1_1--\r\n"
        # body G
          . "\r\n--boundary_1_1\r\n"
          . "X-Body-Id:G\r\n"
          . "Content-Type: image/jpeg\r\n"
          . "Content-Disposition: attachment\r\n"
          . "\r\n"
          . "G"
        # body H
          . "\r\n--boundary_1_1\r\n"
          . "X-Body-Id:H\r\n"
          . "Content-Type: application/x-excel\r\n"
          . "\r\n"
          . "H"
        # body J
          . "\r\n--boundary_1_1\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "X-Body-Id:J\r\n"
          . "\r\n"
          . "From: foo\@local\r\n"
          . "Date: Thu, 10 May 2018 15:15:38 +0200\r\n"
          . "\r\n"
          . "J"
          . "\r\n--boundary_1_1--\r\n"
        # body K
          . "\r\n--boundary_1\r\n"
          . "X-Body-Id:K\r\n"
          . "Content-Type: text/plain\r\n"
          . "Content-Disposition: inline\r\n"
          . "\r\n"
          . "K"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    my $bodyA = {
        'header:x-body-id' => 'A',
        type => 'text/plain',
        disposition => 'inline',
    };
    my $bodyB = {
        'header:x-body-id' => 'B',
        type => 'text/plain',
        disposition => 'inline',
    };
    my $bodyC = {
        'header:x-body-id' => 'C',
        type => 'image/jpeg',
        disposition => 'inline',
    };
    my $bodyD = {
        'header:x-body-id' => 'D',
        type => 'text/plain',
        disposition => 'inline',
    };
    my $bodyE = {
        'header:x-body-id' => 'E',
        type => 'text/html',
        disposition => undef,
    };
    my $bodyF = {
        'header:x-body-id' => 'F',
        type => 'image/jpeg',
        disposition => undef,
    };
    my $bodyG = {
        'header:x-body-id' => 'G',
        type => 'image/jpeg',
        disposition => 'attachment',
    };
    my $bodyH = {
        'header:x-body-id' => 'H',
        type => 'application/x-excel',
        disposition => undef,
    };
    my $bodyJ = {
        'header:x-body-id' => 'J',
        type => 'message/rfc822',
        disposition => undef,
    };
    my $bodyK = {
        'header:x-body-id' => 'K',
        type => 'text/plain',
        disposition => 'inline',
    };

    my $wantBodyStructure = {
        'header:x-body-id' => undef,
        type => 'multipart/mixed',
        disposition => undef,
        subParts => [
            $bodyA,
            {
                'header:x-body-id' => undef,
                type => 'multipart/mixed',
                disposition => undef,
                subParts => [
                    {
                        'header:x-body-id' => undef,
                        type => 'multipart/alternative',
                        disposition => undef,
                        subParts => [
                            {
                                'header:x-body-id' => undef,
                                type => 'multipart/mixed',
                                disposition => undef,
                                subParts => [
                                    $bodyB,
                                    $bodyC,
                                    $bodyD,
                                ],
                            },
                            {
                                'header:x-body-id' => undef,
                                type => 'multipart/related',
                                disposition => undef,
                                subParts => [
                                    $bodyE,
                                    $bodyF,
                                ],
                            },
                        ],
                    },
                    $bodyG,
                    $bodyH,
                    $bodyJ,
                ],
            },
            $bodyK,
        ],
    };

    my $wantTextBody = [ $bodyA, $bodyB, $bodyC, $bodyD, $bodyK ];
    my $wantHtmlBody = [ $bodyA, $bodyE, $bodyK ];
    my $wantAttachments = [ $bodyC, $bodyF, $bodyG, $bodyH, $bodyJ ];

    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['bodyStructure', 'textBody', 'htmlBody', 'attachments' ],
            bodyProperties => ['type', 'disposition', 'header:x-body-id'],
        }, 'R2' ],
    ]);
    my $msg = $res->[1][1]{list}[0];
    $self->assert_deep_equals($wantBodyStructure, $msg->{bodyStructure});
    $self->assert_deep_equals($wantTextBody, $msg->{textBody});
    $self->assert_deep_equals($wantHtmlBody, $msg->{htmlBody});
    $self->assert_deep_equals($wantAttachments, $msg->{attachments});
}

sub test_email_get_calendarevents
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $uid1 = "d9e7f7d6-ce1a-4a71-94c0-b4edd41e5959";
    my $uid2 = "caf7f7d6-ce1a-4a71-94c0-b4edd41e5959";

    $self->make_message("foo",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt body"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/calendar;charset=utf-8\r\n"
          . "Content-Transfer-Encoding: quoted-printable\r\n"
          . "\r\n"
          . "BEGIN:VCALENDAR\r\n"
          . "VERSION:2.0\r\n"
          . "PRODID:-//CyrusIMAP.org/Cyrus 3.1.3-606//EN\r\n"
          . "CALSCALE:GREGORIAN\r\n"
          . "BEGIN:VTIMEZONE\r\n"
          . "TZID:Europe/Vienna\r\n"
          . "BEGIN:STANDARD\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n"
          . "TZOFFSETFROM:+0200\r\n"
          . "TZOFFSETTO:+0100\r\n"
          . "END:STANDARD\r\n"
          . "BEGIN:DAYLIGHT\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n"
          . "TZOFFSETFROM:+0100\r\n"
          . "TZOFFSETTO:+0200\r\n"
          . "END:DAYLIGHT\r\n"
          . "END:VTIMEZONE\r\n"
          . "BEGIN:VEVENT\r\n"
          . "CREATED:20180518T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180518T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180518T090000\r\n"
          . "LAST-MODIFIED:20180518T090306Z\r\n"
          . "SEQUENCE:1\r\n"
          . "SUMMARY:K=C3=A4se\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:$uid1\r\n"
          . "END:VEVENT\r\n"
          . "BEGIN:VEVENT\r\n"
          . "CREATED:20180718T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180718T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180718T190000\r\n"
          . "LAST-MODIFIED:20180718T090306Z\r\n"
          . "SEQUENCE:1\r\n"
          . "SUMMARY:Foo\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:$uid2\r\n"
          . "END:VEVENT\r\n"
          . "END:VCALENDAR\r\n"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['textBody', 'attachments', 'calendarEvents'],
        }, 'R2' ],
    ]);
    my $msg = $res->[1][1]{list}[0];

    $self->assert_num_equals(1, scalar @{$msg->{attachments}});
    $self->assert_str_equals('text/calendar', $msg->{attachments}[0]{type});

    $self->assert_num_equals(1, scalar keys %{$msg->{calendarEvents}});
    my $partId = $msg->{attachments}[0]{partId};

    my %jsevents_by_uid = map { $_->{uid} => $_ } @{$msg->{calendarEvents}{$partId}};
    $self->assert_num_equals(2, scalar keys %jsevents_by_uid);
    my $jsevent1 = $jsevents_by_uid{$uid1};
    my $jsevent2 = $jsevents_by_uid{$uid2};

    $self->assert_not_null($jsevent1);
    $self->assert_str_equals("K\N{LATIN SMALL LETTER A WITH DIAERESIS}se", $jsevent1->{title});
    $self->assert_str_equals('2018-05-18T09:00:00', $jsevent1->{start});
    $self->assert_str_equals('Europe/Vienna', $jsevent1->{timeZone});
    $self->assert_str_equals('PT1H', $jsevent1->{duration});

    $self->assert_not_null($jsevent2);
    $self->assert_str_equals("Foo", $jsevent2->{title});
}

sub test_email_get_calendarevents_icsfile
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $rawEvent = ""
          . "BEGIN:VCALENDAR\r\n"
          . "VERSION:2.0\r\n"
          . "PRODID:-//CyrusIMAP.org/Cyrus 3.1.3-606//EN\r\n"
          . "CALSCALE:GREGORIAN\r\n"
          . "BEGIN:VTIMEZONE\r\n"
          . "TZID:Europe/Vienna\r\n"
          . "BEGIN:STANDARD\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n"
          . "TZOFFSETFROM:+0200\r\n"
          . "TZOFFSETTO:+0100\r\n"
          . "END:STANDARD\r\n"
          . "BEGIN:DAYLIGHT\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n"
          . "TZOFFSETFROM:+0100\r\n"
          . "TZOFFSETTO:+0200\r\n"
          . "END:DAYLIGHT\r\n"
          . "END:VTIMEZONE\r\n"
          . "BEGIN:VEVENT\r\n"
          . "CREATED:20180518T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180518T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180518T090000\r\n"
          . "LAST-MODIFIED:20180518T090306Z\r\n"
          . "SEQUENCE:1\r\n"
          . "SUMMARY:Hello\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:d9e7f7d6-ce1a-4a71-94c0-b4edd41e5959\r\n"
          . "END:VEVENT\r\n"
          . "END:VCALENDAR\r\n";

    $self->make_message("foo",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt body"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: application/unknown\r\n"
          . "Content-Transfer-Encoding: base64\r\n"
          ."Content-Disposition: attachment; filename*0=Add_Appointment_;\r\n filename*1=To_Calendar.ics\r\n"
          . "\r\n"
          . encode_base64($rawEvent, "\r\n")
          . "\r\n--boundary_1--\r\n"
    ) || die;

    my $res = $jmap->CallMethods([
        ['Email/query', { }, "R1"],
        ['Email/get', {
            '#ids' => { resultOf => 'R1', name => 'Email/query', path => '/ids' },
            properties => ['textBody', 'attachments', 'calendarEvents'],
        }, 'R2' ],
    ]);
    my $msg = $res->[1][1]{list}[0];

    my $partId = $msg->{attachments}[0]{partId};
    my $jsevent = $msg->{calendarEvents}{$partId}[0];
    $self->assert_str_equals("Hello", $jsevent->{title});
}

sub test_email_set_blobencoding
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    xlog "Upload a data blob";
    my $logofile = abs_path('data/logo.gif');
    open(FH, "<$logofile");
    local $/ = undef;
    my $binary = <FH>;
    close(FH);
    my $data = $jmap->Upload($binary, "image/gif");
    my $dataBlobId = $data->{blobId};

    my $emailBlob = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: test email
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

This is a test email.
EOF
    $emailBlob =~ s/\r?\n/\r\n/gs;
    $data = $jmap->Upload($emailBlob, "application/octet");
    my $rfc822Blobid = $data->{blobId};

    xlog "Create email with body structure";
    my $inboxid = $self->getinbox()->{id};
    my $email = {
        mailboxIds => { $inboxid => JSON::true },
        from => [{ name => "Test", email => q{foo@bar} }],
        subject => "test",
        textBody => [{
            type => 'text/plain',
            partId => '1',
        }],
        bodyValues => {
            '1' => {
                value => "A text body",
            },
        },
        attachments => [{
            type => 'image/gif',
            blobId => $dataBlobId,
        }, {
            type => 'message/rfc822',
            blobId => $rfc822Blobid,
        }],
    };
    my $res = $jmap->CallMethods([
        ['Email/set', { create => { '1' => $email } }, 'R1'],
        ['Email/get', {
            ids => [ '#1' ],
            properties => [ 'bodyStructure' ],
            bodyProperties => [ 'type', 'header:Content-Transfer-Encoding' ],
        }, 'R2' ],
    ]);

    my $gotPart;
    $gotPart = $res->[1][1]{list}[0]{bodyStructure}{subParts}[1];
    $self->assert_str_equals('message/rfc822', $gotPart->{type});
    $self->assert_str_equals(' 7BIT', $gotPart->{'header:Content-Transfer-Encoding'});
    $gotPart = $res->[1][1]{list}[0]{bodyStructure}{subParts}[2];
    $self->assert_str_equals('image/gif', $gotPart->{type});
    $self->assert_str_equals(' BASE64', uc($gotPart->{'header:Content-Transfer-Encoding'}));
}

sub test_email_get_fixbrokenmessageids
    :min_version_3_1 :needs_component_jmap
{

    # See issue https://github.com/cyrusimap/cyrus-imapd/issues/2601

    my ($self) = @_;
    my $jmap = $self->{jmap};

    # An email with a folded reference id.
    my %params = (
        extra_headers => [
            ['references', "<123\r\n\t456\@lo cal>" ],
        ],
    );
    $self->make_message("Email A", %params) || die;

    xlog "get email";
    my $res = $jmap->CallMethods([
        ['Email/query', { }, 'R1'],
        ['Email/get', {
            '#ids' => {
                resultOf => 'R1',
                name => 'Email/query',
                path => '/ids'
            },
            properties => [
                'references'
            ],
        }, 'R2'],
    ]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $email = $res->[1][1]->{list}[0];

    $self->assert_str_equals('123456@local', $email->{references}[0]);
}


sub test_email_body_alternative_without_html
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my %exp_sub;
    $store->set_folder("INBOX");
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $body = "".
    "--sub\r\n".
    "Content-Type: text/plain\r\n".
    "\r\n" .
    "plain text".
    "\r\n--sub\r\n".
    "Content-Type: some/part\r\n".
    "Content-Transfer-Encoding: base64\r\n".
    "\r\n" .
    "abc=".
    "\r\n--sub--\r\n";

    $exp_sub{A} = $self->make_message("foo",
        mime_type => "multipart/alternative",
        mime_boundary => "sub",
        body => $body
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', {
        ids => $ids,
        properties => ['textBody', 'htmlBody', 'bodyStructure'],
        fetchAllBodyValues => JSON::true
    }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];
    $self->assert_num_equals(1, scalar @{$msg->{textBody}});
    $self->assert_num_equals(1, scalar @{$msg->{htmlBody}});
    $self->assert_str_equals($msg->{textBody}[0]->{partId}, $msg->{htmlBody}[0]->{partId});
}

sub test_email_copy
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    xlog "Create user and share mailbox";
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lrsiwntex") or die;

    my $srcInboxId = $self->getinbox()->{id};
    $self->assert_not_null($srcInboxId);

    my $dstInboxId = $self->getinbox({accountId => 'other'})->{id};
    $self->assert_not_null($dstInboxId);

    xlog "create email";
    my $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                1 => {
                    mailboxIds => {
                        $srcInboxId => JSON::true,
                    },
                    keywords => {
                        'foo' => JSON::true,
                    },
                    subject => 'hello',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'world',
                        }
                    },
                },
            },
        }, 'R1'],
    ]);
    my $emailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($emailId);

    my $email = $res = $jmap->CallMethods([
        ['Email/get', {
            ids => [$emailId],
            properties => ['receivedAt'],
        }, 'R1']
    ]);
    my $receivedAt = $res->[0][1]{list}[0]{receivedAt};
    $self->assert_not_null($receivedAt);

    # Safeguard receivedAt asserts.
    sleep 1;

    xlog "move email";
    $res = $jmap->CallMethods([
        ['Email/copy', {
            fromAccountId => 'cassandane',
            accountId => 'other',
            create => {
                1 => {
                    id => $emailId,
                    mailboxIds => {
                        $dstInboxId => JSON::true,
                    },
                    keywords => {
                        'bar' => JSON::true,
                    },
                },
            },
            onSuccessDestroyOriginal => JSON::true,
        }, 'R1'],
    ]);

    my $copiedEmailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($copiedEmailId);
    $self->assert_str_equals('Email/set', $res->[1][0]);
    $self->assert_str_equals($emailId, $res->[1][1]{destroyed}[0]);

    xlog "get copied email";
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            ids => [$copiedEmailId],
            properties => ['keywords', 'receivedAt'],
        }, 'R1']
    ]);
    my $wantKeywords = { 'bar' => JSON::true };
    $self->assert_deep_equals($wantKeywords, $res->[0][1]{list}[0]{keywords});
    $self->assert_str_equals($receivedAt, $res->[0][1]{list}[0]{receivedAt});

    xlog "copy email back";
    $res = $jmap->CallMethods([
        ['Email/copy', {
            accountId => 'cassandane',
            fromAccountId => 'other',
            create => {
                1 => {
                    id => $copiedEmailId,
                    mailboxIds => {
                        $srcInboxId => JSON::true,
                    },
                    keywords => {
                        'bar' => JSON::true,
                    },
                },
            },
        }, 'R1'],
    ]);

    $self->assert_str_equals($copiedEmailId, $res->[0][1]->{created}{1}{id});

    xlog "copy email back (again)";
    $res = $jmap->CallMethods([
        ['Email/copy', {
            accountId => 'cassandane',
            fromAccountId => 'other',
            create => {
                1 => {
                    id => $copiedEmailId,
                    mailboxIds => {
                        $srcInboxId => JSON::true,
                    },
                    keywords => {
                        'bar' => JSON::true,
                    },
                },
            },
        }, 'R1'],
    ]);

   $self->assert_str_equals('alreadyExists', $res->[0][1]->{notCreated}{1}{type});
   $self->assert_not_null($res->[0][1]->{notCreated}{1}{existingId});
}

sub test_email_copy_hasattachment
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    xlog "Create user and share mailbox";
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lrsiwntex") or die;

    my $srcInboxId = $self->getinbox()->{id};
    $self->assert_not_null($srcInboxId);

    my $dstInboxId = $self->getinbox({accountId => 'other'})->{id};
    $self->assert_not_null($dstInboxId);

    xlog "create email";
    my $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                1 => {
                    mailboxIds => {
                        $srcInboxId => JSON::true,
                    },
                    keywords => {
                        'foo' => JSON::true,
                        '$seen' => JSON::true,
                    },
                    subject => 'hello',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'world',
                        }
                    },
                },
            },
        }, 'R1'],
    ]);
    my $emailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($emailId);

    xlog "set hasAttachment";
    my $store = $self->{store};
    $store->set_folder('INBOX');
    $store->_select();
    my $talk = $store->get_client();
    $talk->store('1', '+flags', '($HasAttachment)') or die;


    xlog "copy email";
    $res = $jmap->CallMethods([
        ['Email/copy', {
            fromAccountId => 'cassandane',
            accountId => 'other',
            create => {
                1 => {
                    id => $emailId,
                    mailboxIds => {
                        $dstInboxId => JSON::true,
                    },
                },
            },
        }, 'R1'],
    ]);

    my $copiedEmailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($copiedEmailId);

    xlog "get copied email";
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            ids => [$copiedEmailId],
            properties => ['keywords'],
        }, 'R1']
    ]);
    my $wantKeywords = {
        '$hasattachment' => JSON::true,
        foo => JSON::true,
        '$seen' => JSON::true,
    };
    $self->assert_deep_equals($wantKeywords, $res->[0][1]{list}[0]{keywords});
}

sub test_email_copy_mailboxid_by_role
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    xlog "Create user and share mailbox";
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lrsiwntex") or die;

    my $srcInboxId = $self->getinbox()->{id};
    $self->assert_not_null($srcInboxId);

    my $dstInboxId = $self->getinbox({accountId => 'other'})->{id};
    $self->assert_not_null($dstInboxId);

    xlog "create email";
    my $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                1 => {
                    mailboxIds => {
                        $srcInboxId => JSON::true,
                    },
                    keywords => {
                        'foo' => JSON::true,
                    },
                    subject => 'hello',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'world',
                        }
                    },
                },
            },
        }, 'R1'],
    ]);
    my $emailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($emailId);

    # Copy to other account, with mailbox identified by role
    $res = $jmap->CallMethods([
        ['Email/copy', {
            fromAccountId => 'cassandane',
            accountId => 'other',
            create => {
                1 => {
                    id => $emailId,
                    mailboxIds => {
                        '$inbox' => JSON::true,
                    },
                },
            },
        }, 'R1'],
        ['Email/get', {
            accountId => 'other',
            ids => ['#1'],
            properties => ['mailboxIds'],
        }, 'R2']
    ]);
    $self->assert_not_null($res->[1][1]{list}[0]{mailboxIds}{$dstInboxId});
}

sub test_email_set_destroy_bulk
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $store = $self->{store};

    my $talk = $self->{store}->get_client();

    $talk->create('INBOX.A') or die;
    $talk->create('INBOX.B') or die;

    # Email 1 is in both A and B mailboxes.
    $store->set_folder('INBOX.A');
    $self->make_message('Email 1') || die;
    $talk->copy(1, 'INBOX.B');

    # Email 2 is in mailbox A.
    $store->set_folder('INBOX.A');
    $self->make_message('Email 2') || die;

    # Email 3 is in mailbox B.
    $store->set_folder('INBOX.B');
    $self->make_message('Email 3') || die;

    my $res = $jmap->CallMethods([['Email/query', { }, 'R1']]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});
    my $ids = $res->[0][1]->{ids};

    $res = $jmap->CallMethods([['Email/set', { destroy => $ids }, 'R1']]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{destroyed}});

}

sub test_email_set_update_bulk
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $store = $self->{store};

    my $talk = $self->{store}->get_client();

    $talk->create('INBOX.A') or die;
    $talk->create('INBOX.B') or die;
    $talk->create('INBOX.C') or die;
    $talk->create('INBOX.D') or die;

    # Get mailboxes
    my $res = $jmap->CallMethods([['Mailbox/get', {}, "R1"]]);
    $self->assert_not_null($res);
    my %mboxIdByName = map { $_->{name} => $_->{id} } @{$res->[0][1]{list}};

    # Create email in mailbox A and B
    $store->set_folder('INBOX.A');
    $self->make_message('Email1') || die;
    $talk->copy(1, 'INBOX.B');
    $talk->store(1, "+flags", "(\\Seen hello)");

    # check that the flags aren't on B
    $talk->select("INBOX.B");
    $res = $talk->fetch("1", "(flags)");
    my @flags = @{$res->{1}{flags}};
    $self->assert_null(grep { $_ eq 'hello' } @flags);
    $self->assert_null(grep { $_ eq '\\Seen' } @flags);

    # Create email in mailboox A
    $talk->select("INBOX.A");
    $self->make_message('Email2') || die;

    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ property => 'subject' }],
    }, 'R1']]);
    $self->assert_num_equals(2, scalar @{$res->[0][1]->{ids}});
    my $emailId1 = $res->[0][1]->{ids}[0];
    my $emailId2 = $res->[0][1]->{ids}[1];

    $res = $jmap->CallMethods([['Email/set', {
        update => {
            $emailId1 => {
                mailboxIds => {
                    $mboxIdByName{'C'} => JSON::true,
                },
            },
            $emailId2 => {
                mailboxIds => {
                    $mboxIdByName{'C'} => JSON::true,
                },
            }
        },
        'cyrusimap.org/debugBulkUpdate' => JSON::true,
    }, 'R1']]);
    $self->make_message('Email3') || die;

    # check that the flags made it
    $talk->select("INBOX.C");
    $res = $talk->fetch("1", "(flags)");
    @flags = @{$res->{1}{flags}};
    $self->assert_not_null(grep { $_ eq 'hello' } @flags);
    # but \Seen shouldn't
    $self->assert_null(grep { $_ eq '\\Seen' } @flags);

    $res = $jmap->CallMethods([['Email/query', {
        sort => [{ property => 'subject' }],
    }, 'R1']]);
    $self->assert_num_equals(3, scalar @{$res->[0][1]->{ids}});
    my @ids = @{$res->[0][1]->{ids}};
    my $emailId3 = $ids[2];

    # now move all the ids to folder 'D' but two are not in the
    # source folder any more
    $res = $jmap->CallMethods([['Email/set', {
        update => {
            map { $_ => {
                 "mailboxIds/$mboxIdByName{'A'}" => undef,
                 "mailboxIds/$mboxIdByName{'D'}" => JSON::true,
            } } @ids,
        },
        'cyrusimap.org/debugBulkUpdate' => JSON::true,
    }, 'R1']]);

    $self->assert_not_null($res);
    $self->assert_not_null($res->[0][1]{updated}{$emailId1});
    $self->assert_not_null($res->[0][1]{updated}{$emailId2});
    $self->assert_not_null($res->[0][1]{updated}{$emailId3});
    $self->assert_null($res->[0][1]{notUpdated});

    $res = $jmap->CallMethods([['Email/get', {
        ids => [$emailId1, $emailId2, $emailId3],
        properties => ['mailboxIds'],
    }, "R1"]]);
    my %emailById = map { $_->{id} => $_ } @{$res->[0][1]{list}};

    # now we need to test for actual location
    my $wantMailboxesEmail1 = {
        $mboxIdByName{'C'} => JSON::true,
        $mboxIdByName{'D'} => JSON::true,
    };
    my $wantMailboxesEmail2 = {
        $mboxIdByName{'C'} => JSON::true,
        $mboxIdByName{'D'} => JSON::true,
    };
    my $wantMailboxesEmail3 = {
        $mboxIdByName{'D'} => JSON::true,
    };
    $self->assert_deep_equals($wantMailboxesEmail1, $emailById{$emailId1}->{mailboxIds});
    $self->assert_deep_equals($wantMailboxesEmail2, $emailById{$emailId2}->{mailboxIds});
    $self->assert_deep_equals($wantMailboxesEmail3, $emailById{$emailId3}->{mailboxIds});

}

sub test_email_set_update_too_many_mailboxes
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $store = $self->{store};
    my $talk = $self->{store}->get_client();

    my $inboxId = $self->getinbox()->{id};

    # Create email in INBOX
    $self->make_message('Email') || die;

    my $res = $jmap->CallMethods([['Email/query', { }, 'R1']]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $emailId = $res->[0][1]->{ids}[0];

    my $settings = $self->get_settings();
    my $mailCapabilities = $settings->{capabilities}{'urn:ietf:params:jmap:mail'};
    my $maxMailboxesPerEmail = $mailCapabilities->{maxMailboxesPerEmail};
    $self->assert($maxMailboxesPerEmail > 0);

    # Create and get mailboxes
    for (my $i = 1; $i < $maxMailboxesPerEmail + 2; $i++) {
        $talk->create("INBOX.mbox$i") or die;
    }
    $res = $jmap->CallMethods([['Mailbox/get', {}, "R1"]]);
    $self->assert_not_null($res);
    my %mboxIds = map { $_->{id} => JSON::true } @{$res->[0][1]{list}};

    # remove from INBOX
    delete $mboxIds{$inboxId};

    # Move mailbox to too many mailboxes
    $res = $jmap->CallMethods([['Email/set', {
        update => {
            $emailId => {
                mailboxIds => \%mboxIds,
            },
        },
        'cyrusimap.org/debugBulkUpdate' => JSON::true,
   }, 'R1']]);
   $self->assert_str_equals('tooManyMailboxes', $res->[0][1]{notUpdated}{$emailId}{type});
}

sub test_email_set_update_too_many_keywords
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $store = $self->{store};
    my $talk = $self->{store}->get_client();

    my $inboxId = $self->getinbox()->{id};

    # Create email in INBOX
    $self->make_message('Email') || die;

    my $res = $jmap->CallMethods([['Email/query', { }, 'R1']]);
    $self->assert_num_equals(1, scalar @{$res->[0][1]->{ids}});
    my $emailId = $res->[0][1]->{ids}[0];

    my $settings = $self->get_settings();
    my $mailCapabilities = $settings->{capabilities}{'urn:ietf:params:jmap:mail'};
    my $maxKeywordsPerEmail = $mailCapabilities->{maxKeywordsPerEmail};
    $self->assert($maxKeywordsPerEmail > 0);

    # Set lots of keywords on this email
    my %keywords;
    for (my $i = 1; $i < $maxKeywordsPerEmail + 2; $i++) {
        $keywords{"keyword$i"} = JSON::true;
    }
    $res = $jmap->CallMethods([['Email/set', {
        update => {
            $emailId => {
                keywords => \%keywords,
            },
        },
        'cyrusimap.org/debugBulkUpdate' => JSON::true,
   }, 'R1']]);
   $self->assert_str_equals('tooManyKeywords', $res->[0][1]{notUpdated}{$emailId}{type});
}

sub test_email_get_headers_multipart
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();
    my $inbox = 'INBOX';

    xlog "Generate a email in $inbox via IMAP";
    my %exp_sub;
    $store->set_folder($inbox);
    $store->_select();
    $self->{gen}->set_next_uid(1);

    my $htmlBody = "<html><body><p>This is the html part.</p></body></html>";
    my $textBody = "This is the plain text part.";

    my $body = "--047d7b33dd729737fe04d3bde348\r\n";
    $body .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $body .= "\r\n";
    $body .= $textBody;
    $body .= "\r\n";
    $body .= "--047d7b33dd729737fe04d3bde348\r\n";
    $body .= "Content-Type: text/html;charset=\"UTF-8\"\r\n";
    $body .= "\r\n";
    $body .= $htmlBody;
    $body .= "\r\n";
    $body .= "--047d7b33dd729737fe04d3bde348--\r\n";
    $exp_sub{A} = $self->make_message("foo",
        mime_type => "multipart/alternative",
        mime_boundary => "047d7b33dd729737fe04d3bde348",
        body => $body,
        extra_headers => [['X-Spam-Hits', 'SPAMA, SPAMB, SPAMC']],
    );

    xlog "get email list";
    my $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    my $ids = $res->[0][1]->{ids};

    xlog "get email";
    $res = $jmap->CallMethods([['Email/get', {
        ids => $ids,
        properties => [ "header:x-spam-hits:asRaw", "header:x-spam-hits:asText" ],
    }, "R1"]]);
    my $msg = $res->[0][1]{list}[0];

    $self->assert_str_equals(' SPAMA, SPAMB, SPAMC', $msg->{"header:x-spam-hits:asRaw"});
    $self->assert_str_equals('SPAMA, SPAMB, SPAMC', $msg->{"header:x-spam-hits:asText"});
}

sub test_email_get_brokenheader_split_codepoint
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: =?UTF-8?Q?=F0=9F=98=80=F0=9F=98=83=F0=9F=98=84=F0=9F=98=81=F0=9F=98=86=F0?=
 =?UTF-8?Q?=9F=98=85=F0=9F=98=82=F0=9F=A4=A3=E2=98=BA=EF=B8=8F=F0=9F=98=8A?=
  =?UTF-8?Q?=F0=9F=98=87?=
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: foobar

This is a test email.
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};
    my $inboxid = $self->getinbox()->{id};

    my $wantSubject = '😀😃😄😁😆😅😂🤣☺️😊😇';
    utf8::decode($wantSubject);

    xlog "import and get email from blob $blobid";
    my $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$inboxid =>  JSON::true},
            },
        },
    }, "R1"], ["Email/get", {
        ids => ["#1"],
        properties => ['subject'],
    }, "R2" ]]);

    $self->assert_str_equals($wantSubject, $res->[1][1]{list}[0]{subject});
}

sub test_email_get_detect_utf32
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: Here are some base64-encoded UTF-32LE bytes without BOM.
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-32"
Content-Transfer-Encoding: base64

QjAAAIEwAACKMAAASzAAAGlyAACeigAADQAAAAoAAAANAAAACgAAAAAwAAAOZgAAu2wAAAlOAABB
UwAAbVEAAHReAABuMAAAy3kAAEFTAAAIZwAAbjAAAAOYAACIMAAAijAAAHN8AAALVwAAazAAAEqQ
AABzMAAAZjAAAMpOAAAygwAADmYAALtsAADbVgAAQVMAAHReAAANAAAACgAAAAAwAABuMAAAD1kA
AANOAAAIZwAA1TAAAOkwAADzMAAAuTAAAGswAAARVAAAcjAAAGYwAADLMAAA5TAAAPwwAADoMAAA
/DAAAK8wAACSMAAAu1MAAIswAABrMAAA6IEAAH8wAAABMAAA5WUAAAOYAAANAAAACgAAAAAwAADF
ZQAAl3oAAGswAAD4ZgAATTAAALR9AACKMAAAXzAAAIswAACCMAAAbjAAAJIwAAChYwAAijAAAMaW
AACBMAAAZjAAAAEwAABCMAAAgTAAAIowAABLMAAAgjAAAG4wAABMMAAAXzAAAIowAAANAAAACgAA
AAAwAABoMAAATJgAAFcwAAABMAAAY/oAAJMwAABnMAAAjzAAAEwwAABpYAAAK14AAGswAABXMAAA
ZjAAAGlgAADLUwAAajAAAIswAAAPXAAA4mwAAHFcAAC6TgAA1l0AADeMAABIUQAAH3UAAG4wAAAN
AAAACgAAAAAwAAA6ZwAAC04AAGswAABIVAAAWTAAAAIwAAAOZgAAu2wAANtWAABBUwAAdF4AAEFT
AAAATgAACGcAAMyRAAA7ZgAAazAAAGYwAAA4bAAAlU4AAHeDAAComAAAAjAAAA0AAAAKAAAADQAA
AAoAAAAAMAAAOYIAAD9iAAAcWQAAcYoAAA0AAAAKAAAADQAAAAoAAAAAMAAAVU8AAFWGAAAKMAAA
RDAAAGUwAABTMAAACzAAAGswAABXMAAAZjAAAIIwAAB4lgAAkjAAAIuJAACLMAAAi04AAG4wAAD6
UQAAhk8AAGowAABEMAAAKoIAAEX6AABvMAAAATAAAIZrAABpMAAAKlgAAHgwAABo+gAARDAAAAt6
AAAhcQAASoAAAAowAAB2MAAAjDAAAEYwAAALMAAAazAAAOaCAABXMAAAgTAAAIkwAACMMAAAizAA
AIIwAABuMAAAZzAAAEIwAACLMAAATDAAAAEwAABragAA8W8AAEswAACJMAAAnk4AAHN8AAApUgAA
oFIAAAowAABCMAAAgTAAAIowAABLMAAACzAAAG4wAACwZQAAi5UAADBXAAC3MAAAojAAAMgwAADr
MAAAbjAAAC9uAAB4MAAAGpAAAHUwAAAqggAARfoAAAEwAABkawAAjDAAAIIwAABdMAAAbjAAAABO
AADEMAAAZzAAAEIwAACJMAAARjAAAAIwAAANAAAACgAAAAAwAAD6UQAABl4AAFcwAABfMAAA5WUA
AAEwAABFZQAAC1cAAG4wAABxXAAAcV8AAGswAAAlUgAAjDAAAF8wAABqMAAAiTAAAAEwAAA5ggAA
olsAAG8wAAB8XwAAuFwAAG4wAAAnWQAAeJYAAGswAAA5kAAAWTAAAIswAAB2UQAAbjAAAOVlAAB+
MAAAZzAAAAEwAABKUwAACGcAAEIwAAB+MAAAijAAAG4wAACTlQAAATAAAABOAADEMAAAbjAAAPZc
AAABMAAAAE4AAMQwAABuMAAAcVwAAJIwAACCMAAAi4kAAIswAACLTgAAbzAAAPpRAACGTwAAajAA
AEQwAAACMAAAKGYAAOVlAACCMAAARfoAAAEwAADKTgAA5WUAAIIwAABF+gAAFSAAABUgAAAVIAAA
VU8AAEJmAACLiQAAZjAAAIIwAACKiwAAiTAAAGwwAAAqWQAAc14AAAttAABuMAAAOncAABtnAAAK
MAAAajAAAEwwAACBMAAACzAAAGgwAACRTgAAdTAAAG4wAABvMAAAL1UAAGAwAAArgwAAIG8AAGgw
AABXMAAAZjAAAAEwAAAnWQAATTAAAGowAADibAAAam0AAAowAABqMAAAfzAAAAswAABuMAAAd40A
AA9PAABZMAAAizAAAIqQAABrMAAA/H8AAG4wAAB3lQAARDAAADRWAAAKMAAATzAAAGEwAABwMAAA
VzAAAAswAABuMAAA8mYAAGQwAABfMAAAcHAAAHKCAABuMAAA4U8AAClZAADBfwAACjAAAEIwAABv
MAAARjAAAGkwAACKMAAACzAAAG4wAADbmAAAczAAAPteAABkMAAAZjAAAJAwAACLMAAAcDAAAEsw
AACKMAAAZzAAAEIwAACLMAAAAjAAAF0wAABuMAAACk4AAGswAACCMAAAKVkAACNsAABvMAAAIWsA
ACx7AABrMAAAF1MAAG4wAAC5ZQAAeDAAAGgwAAAykAAAgDAAAGswAAAjkAAAjDAAAGYwAADDXwAA
MFcAAIgwAABPMAAAEvoAAIwwAAAhbgAAizAAAItOAABvMAAAAHoAAGswAABqMAAAijAAAAEwAAB+
MAAAZTAAAM9rAADlZQAAbjAAAIQwAABGMAAAazAAAHp6AABvMAAAl2YAALlvAABfMAAAizAAACCf
AAByggAAbjAAAPKWAABrMAAAPYUAAHIwAADhdgAAVTAAAIswAACdMAAAbjAAAH8wAABLMAAA1VIA
AAowAACEMAAAnTAAAAswAACCMAAAWTAAAIwwAABwMAAA6JYAAEswAADIUwAAbzAAACeXAABrMAAA
ajAAAGQwAABmMAAAhk4AAHUwAAACMAAADQAAAAoAAAAAMAAAwXkAAG8wAAAWVwAAiTAAAFowAACC
MAAAZGsAAMttAABXMAAARDAAAEX6AABuMAAACk4AAG4wAADFZQAAuk4AAGswAABqMAAAZDAAAF8w
AAACMAAAXTAAAFcwAABmMAAA6WUAAE8wAACCMAAAQVMAAOVlAABwMAAASzAAAIowAABuMAAA5WUA
AHhlAACSMAAAAZAAAIowAACXXwAAXzAAAFWGAABnMAAAQjAAAIswAAACMAAAXWYAAJOVAABqMAAA
iTAAAHAwAAAydQAAf2cAAGcwAACwdAAAlWIAAAowAACPMAAAajAAAFIwAAALMAAAbjAAAEqQAABz
MAAAATAAAOWCAABXMAAATzAAAG8wAACrVQAAWXEAAKRbAABnMAAAqJoAAExyAAAKMAAASzAAAIsw
AABfMAAACzAAAJIwAADWUwAAijAAAGowAABeMAAAVzAAAGYwAAABMAAAaTAAAEYwAABLMAAAr2UA
AEYwAABLMAAAQmYAAJOVAACSMAAAiG0AALuMAABZMAAAizAAAItOAABMMAAA+lEAAIZPAACLMAAA
UTAAAIwwAABpMAAAATAAAFUwAABmMAAAWmYAABCZAABuMAAA35gAAFNTAAAKMAAAxjAAAPwwAADW
MAAA6zAAAAswAACSMAAA4pYAAIwwAABmMAAASzAAAIkwAABuMAAAHFkAAGswAABqMAAAizAAAGgw
AAABMAAAhmsAAGkwAAAycgAAWTAAAItOAABMMAAAIXEAAE8wAABqMAAAZDAAAGYwAACGTgAAdTAA
AAIwAAAUTgAAZDAAAMpOAADlZQAAQjAAAF8wAACKMAAAbzAAABiZAAALegAAI2wAABlQAACCMAAA
0lsAAE8wAABqMAAAZDAAAGYwAACGTwAAXzAAAIQwAABGMAAAYDAAAAIwAAAWWQAAV1kAAGowAABX
MAAAZzAAAG8wAABoMAAAZjAAAIIwAAAydQAAf2cAAJIwAABlawAARDAAAGYwAACrVQAAWXEAAKRb
AAB4MAAAgjAAAEyIAABLMAAAjDAAAH4wAABEMAAAaDAAAB1gAAB1MAAAQGIAAEswAACJMAAAATAA
AMF5AABvMAAAdlEAAG4wAAAYUQAAXP8AADmCAAA/YgAACjAAAK0wAADkMAAA0zAAAPMwAAALMAAA
azAAAImVAABYMAAAYHwAAGQwAABmMAAAATAAAOVlAAAsZwAASzAAAIkwAAABYwAAZDAAAGYwAACG
TwAAXzAAANyWAACMigAAZzAAAIIwAACLlQAASzAAAEYwAABLMAAAaDAAAB1gAABkMAAAZjAAAEVc
AACLMAAAaDAAAAEwAAB2UQAAbjAAAEJmAACkWwAAbjAAADZiAACSMAAAB2MAAEhRAABnMAAAszAA
AMgwAAAzMAAANTAAAGgwAAAVjwAATzAAAOlTAABPMAAAgjAAAG4wAABMMAAAQjAAAIswAAACMAAA
DQAAAAoA
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};
    my $inboxid = $self->getinbox()->{id};

    xlog "import and get email from blob $blobid";
    my $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$inboxid =>  JSON::true},
            },
        },
    }, "R1"], ["Email/get", {
        ids => ["#1"],
        properties => ['textBody', 'bodyValues', 'preview'],
        fetchTextBodyValues => JSON::true,
    }, "R2" ]]);

    $self->assert_num_equals(0,
        index($res->[1][1]{list}[0]{bodyValues}{1}{value},
            "\N{HIRAGANA LETTER A}" .
            "\N{HIRAGANA LETTER ME}" .
            "\N{HIRAGANA LETTER RI}")
    );
    $self->assert_equals(JSON::true, $res->[1][1]{list}[0]{bodyValues}{1}{isEncodingProblem});
}

sub test_email_get_detect_iso_8859_1
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    if (not $self->{instance}->{buildinfo}->get('dependency', 'libchardet')) {
        xlog "Cyrus instance doesn't support charset detection. Skipping test.";
        return 0;
    }

    my $jmap = $self->{jmap};

    my $email = <<'EOF';
From: "Some Example Sender" <example@example.com>
To: baseball@vitaead.com
Subject: Here is some ISO-8859-1 text that claims to be ascii
Date: Wed, 7 Dec 2016 00:21:50 -0500
MIME-Version: 1.0
Content-Type: text/plain
Content-Transfer-Encoding: base64

Ikvkc2Ugc2NobGllc3N0IGRlbiBNYWdlbiIsIGj2cnRlIGljaCBkZW4gU2NobG/faGVycm4gc2FnZW4uCg==

EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $data = $jmap->Upload($email, "message/rfc822");
    my $blobid = $data->{blobId};
    my $inboxid = $self->getinbox()->{id};

    xlog "import and get email from blob $blobid";
    my $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobid,
                mailboxIds => {$inboxid =>  JSON::true},
            },
        },
    }, "R1"], ["Email/get", {
        ids => ["#1"],
        properties => ['textBody', 'bodyValues'],
        fetchTextBodyValues => JSON::true,
    }, "R2" ]]);

    $self->assert_num_equals(0,
        index($res->[1][1]{list}[0]{bodyValues}{1}{value},
            "\"K\N{LATIN SMALL LETTER A WITH DIAERESIS}se")
    );
    $self->assert_equals(JSON::true, $res->[1][1]{list}[0]{bodyValues}{1}{isEncodingProblem});
}

sub test_email_set_intermediary_create
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    xlog "Create mailboxes";
    $imap->create("INBOX.i1.foo") or die;
    my $res = $jmap->CallMethods([
        ['Mailbox/get', {
            properties => ['name', 'parentId'],
        }, "R1"]
    ]);
    my %mboxByName = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $mboxId1 = $mboxByName{'i1'}->{id};

    xlog "Create email in intermediary mailbox";
    my $email =  {
        mailboxIds => {
            $mboxId1 => JSON::true
        },
        from => [{
            email => q{test1@local},
            name => q{}
        }],
        to => [{
            email => q{test2@local},
            name => '',
        }],
        subject => 'foo',
    };

    xlog "create and get email";
    $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
        ['Email/get', { ids => [ "#1" ] }, "R2" ],
    ]);
    $self->assert_not_null($res->[0][1]{created}{1});
    $self->assert_equals(JSON::true, $res->[1][1]{list}[0]{mailboxIds}{$mboxId1});
}

sub test_email_set_intermediary_move
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    xlog "Create mailboxes";
    $imap->create("INBOX.i1.foo") or die;
    my $res = $jmap->CallMethods([
        ['Mailbox/get', {
            properties => ['name', 'parentId'],
        }, "R1"]
    ]);
    my %mboxByName = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $mboxId1 = $mboxByName{'i1'}->{id};
    my $mboxIdFoo = $mboxByName{'foo'}->{id};

    xlog "Create email";
    my $email =  {
        mailboxIds => {
            $mboxIdFoo => JSON::true
        },
        from => [{
            email => q{test1@local},
            name => q{}
        }],
        to => [{
            email => q{test2@local},
            name => '',
        }],
        subject => 'foo',
    };
    xlog "create and get email";
    $res = $jmap->CallMethods([
        ['Email/set', { create => { "1" => $email }}, "R1"],
    ]);
    my $emailId = $res->[0][1]{created}{1}{id};
    $self->assert_not_null($emailId);

    xlog "Move email to intermediary mailbox";
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $emailId => {
                    mailboxIds => {
                        $mboxId1 => JSON::true,
                    },
                },
            },
        }, 'R1'],
        ['Email/get', { ids => [ $emailId ] }, "R2" ],
    ]);
    $self->assert(exists $res->[0][1]{updated}{$emailId});
    $self->assert_equals(JSON::true, $res->[1][1]{list}[0]{mailboxIds}{$mboxId1});
}

sub test_email_copy_intermediary
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    xlog "Create user and share mailbox";
    $self->{instance}->create_user("other");
    $admintalk->setacl("user.other", "cassandane", "lrsiwntex") or die;
    $admintalk->create("user.other.i1.box") or die;
    my $res = $jmap->CallMethods([
        ['Mailbox/get', {
            accountId => 'other',
            properties => ['name'],
        }, "R1"]
    ]);
    my %mboxByName = map { $_->{name} => $_ } @{$res->[0][1]{list}};
    my $dstMboxId = $mboxByName{'i1'}->{id};
    $self->assert_not_null($dstMboxId);

    my $srcInboxId = $self->getinbox()->{id};
    $self->assert_not_null($srcInboxId);

    xlog "create email";
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                1 => {
                    mailboxIds => {
                        $srcInboxId => JSON::true,
                    },
                    keywords => {
                        'foo' => JSON::true,
                    },
                    subject => 'hello',
                    bodyStructure => {
                        type => 'text/plain',
                        partId => 'part1',
                    },
                    bodyValues => {
                        part1 => {
                            value => 'world',
                        }
                    },
                },
            },
        }, 'R1'],
    ]);
    my $emailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($emailId);

    xlog "move email";
    $res = $jmap->CallMethods([
        ['Email/copy', {
            fromAccountId => 'cassandane',
            accountId => 'other',
            create => {
                1 => {
                    id => $emailId,
                    mailboxIds => {
                        $dstMboxId => JSON::true,
                    },
                },
            },
        }, 'R1'],
    ]);

    my $copiedEmailId = $res->[0][1]->{created}{1}{id};
    $self->assert_not_null($copiedEmailId);

    xlog "get copied email";
    $res = $jmap->CallMethods([
        ['Email/get', {
            accountId => 'other',
            ids => [$copiedEmailId],
            properties => ['mailboxIds'],
        }, 'R1']
    ]);
    $self->assert_equals(JSON::true, $res->[0][1]{list}[0]{mailboxIds}{$dstMboxId});
}

sub test_email_set_setflags_mboxevent
    :min_version_3_1 :needs_component_jmap
{

    my ($self) = @_;

    my $jmap = $self->{jmap};
    my $imap = $self->{store}->get_client();

    xlog "create mailboxes";
    my $res = $jmap->CallMethods([
        ['Mailbox/set', {
            create => {
                "A" => {
                    name => "A",
                },
                "B" => {
                    name => "B",
                },
            },
        }, "R1"]
    ]);
    my $mboxIdA = $res->[0][1]{created}{A}{id};
    $self->assert_not_null($mboxIdA);
    my $mboxIdB = $res->[0][1]{created}{B}{id};
    $self->assert_not_null($mboxIdB);

    xlog "Create emails";
    # Use separate requests for deterministic order of UIDs.
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                msgA1 => {
                    mailboxIds => {
                        $mboxIdA => JSON::true
                    },
                    from => [{
                            email => q{test1@local},
                            name => q{}
                        }],
                    to => [{
                            email => q{test2@local},
                            name => '',
                        }],
                    subject => 'msgA1',
                    keywords => {
                        '$seen' => JSON::true,
                    },
                },
            }
        }, "R1"],
        ['Email/set', {
            create => {
                msgA2 => {
                    mailboxIds => {
                        $mboxIdA => JSON::true
                    },
                    from => [{
                            email => q{test1@local},
                            name => q{}
                        }],
                    to => [{
                            email => q{test2@local},
                            name => '',
                        }],
                    subject => 'msgA2',
                },
            }
        }, "R2"],
        ['Email/set', {
            create => {
                msgB1 => {
                    mailboxIds => {
                        $mboxIdB => JSON::true
                    },
                    from => [{
                            email => q{test1@local},
                            name => q{}
                        }],
                    to => [{
                            email => q{test2@local},
                            name => '',
                        }],
                    keywords => {
                        baz => JSON::true,
                    },
                    subject => 'msgB1',
                },
            }
        }, "R3"],
    ]);
    my $emailIdA1 = $res->[0][1]{created}{msgA1}{id};
    $self->assert_not_null($emailIdA1);
    my $emailIdA2 = $res->[1][1]{created}{msgA2}{id};
    $self->assert_not_null($emailIdA2);
    my $emailIdB1 = $res->[2][1]{created}{msgB1}{id};
    $self->assert_not_null($emailIdB1);

    # Clear notification cache
    $self->{instance}->getnotify();

    # Update emails
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $emailIdA1 => {
                    'keywords/$seen' => undef,
                    'keywords/foo' => JSON::true,
                },
                $emailIdA2 => {
                    keywords => {
                        'bar' => JSON::true,
                    },
                },
                $emailIdB1 => {
                    'keywords/baz' => undef,
                },
            }
        }, "R1"],
    ]);
    $self->assert(exists $res->[0][1]{updated}{$emailIdA1});
    $self->assert(exists $res->[0][1]{updated}{$emailIdA2});
    $self->assert(exists $res->[0][1]{updated}{$emailIdB1});

    # Gather notifications
    my $data = $self->{instance}->getnotify();
    if ($self->{replica}) {
        my $more = $self->{replica}->getnotify();
        push @$data, @$more;
    }

    # Assert notifications
    my %flagsClearEvents;
    my %flagsSetEvents;
    foreach (@$data) {
        my $event = decode_json($_->{MESSAGE});
        if ($event->{event} eq "FlagsClear") {
            $flagsClearEvents{$event->{mailboxID}} = $event;
        }
        elsif ($event->{event} eq "FlagsSet") {
            $flagsSetEvents{$event->{mailboxID}} = $event;
        }
    }

    # Assert mailbox A events.
    $self->assert_str_equals('1:2', $flagsSetEvents{$mboxIdA}{uidset});
    $self->assert_num_not_equals(-1, index($flagsSetEvents{$mboxIdA}{flagNames}, 'foo'));
    $self->assert_num_not_equals(-1, index($flagsSetEvents{$mboxIdA}{flagNames}, 'bar'));
    $self->assert_str_equals('1', $flagsClearEvents{$mboxIdA}{uidset});
    $self->assert_str_equals('\Seen', $flagsClearEvents{$mboxIdA}{flagNames});

    # Assert mailbox B events.
    $self->assert(not exists $flagsSetEvents{$mboxIdB});
    $self->assert_str_equals('1', $flagsClearEvents{$mboxIdB}{uidset});
    $self->assert_str_equals('baz', $flagsClearEvents{$mboxIdB}{flagNames});
}

sub test_implementation_email_query
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $now = DateTime->now();

    xlog "Generate a email in INBOX via IMAP";
    my $res = $self->make_message("foo") || die;
    my $uid = $res->{attrs}->{uid};
    my $msg;

    my $inbox = $self->getinbox();

    xlog "non-filtered query can calculate changes";
    $res = $jmap->CallMethods([['Email/query', {}, "R1"]]);
    $self->assert($res->[0][1]{canCalculateChanges});

    xlog "inMailbox query can calculate changes";
    $res = $jmap->CallMethods([
        ['Email/query', {
          filter => { inMailbox => $inbox->{id} },
          sort => [ {
            isAscending => $JSON::false,
            property => 'receivedAt',
          } ],
        }, "R1"],
    ]);
    $self->assert($res->[0][1]{canCalculateChanges});

    xlog "inMailbox query can calculate changes with mutable sort";
    $res = $jmap->CallMethods([
        ['Email/query', {
          filter => { inMailbox => $inbox->{id} },
          sort => [ {
            property => "someInThreadHaveKeyword",
            keyword => "\$seen",
            isAscending => $JSON::false,
          }, {
            property => 'receivedAt',
            isAscending => $JSON::false,
          } ],
        }, "R1"],
    ]);
    $self->assert($res->[0][1]{canCalculateChanges});

    xlog "inMailbox query with keyword can not calculate changes";
    $res = $jmap->CallMethods([
        ['Email/query', {
          filter => {
            conditions => [
              { inMailbox => $inbox->{id} },
              { conditions => [ { allInThreadHaveKeyword => "\$seen" } ],
                operator => 'NOT',
              },
            ],
            operator => 'AND',
          },
            sort => [ {
                isAscending => $JSON::false,
                property => 'receivedAt',
            } ],
        }, "R1"],
    ]);
    $self->assert(not $res->[0][1]{canCalculateChanges});
}

sub _set_quotaroot
{
    my ($self, $quotaroot) = @_;
    $self->{quotaroot} = $quotaroot;
}

sub _set_quotalimits
{
    my ($self, %resources) = @_;
    my $admintalk = $self->{adminstore}->get_client();

    my $quotaroot = delete $resources{quotaroot} || $self->{quotaroot};
    my @quotalist;
    foreach my $resource (keys %resources)
    {
        my $limit = $resources{$resource}
            or die "No limit specified for $resource";
        push(@quotalist, uc($resource), $limit);
    }
    $self->{limits}->{$quotaroot} = { @quotalist };
    $admintalk->setquota($quotaroot, \@quotalist);
    $self->assert_str_equals('ok', $admintalk->get_last_completion_response());
}

sub test_email_set_getquota
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    $self->_set_quotaroot('user.cassandane');
    xlog "set ourselves a basic limit";
    $self->_set_quotalimits(storage => 1000); # that's 1000 * 1024 bytes

    my $jmap = $self->{jmap};
    my $service = $self->{instance}->get_service("http");
    my $inboxId = $self->getinbox()->{id};

    my $res;

    $res = $jmap->CallMethods([
        ['Quota/get', {
            accountId => 'cassandane',
            ids => undef,
        }, 'R1'],
    ]);

    my $mailQuota = $res->[0][1]{list}[0];
    $self->assert_str_equals('mail', $mailQuota->{id});
    $self->assert_num_equals(0, $mailQuota->{used});
    $self->assert_num_equals(1000 * 1024, $mailQuota->{total});
    my $quotaState = $res->[0][1]{state};
    $self->assert_not_null($quotaState);

    xlog "Create email";
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                msgA1 => {
                    mailboxIds => {
                        $inboxId => JSON::true,
                    },
                    from => [{
                            email => q{test1@local},
                            name => q{}
                        }],
                    to => [{
                            email => q{test2@local},
                            name => '',
                        }],
                    subject => 'foo',
                    keywords => {
                        '$seen' => JSON::true,
                    },
                },
            }
        }, "R1"],
        ['Quota/get', {}, 'R2'],
    ], ['http://cyrusimap.org/ns/quota']);

    $self->assert_str_equals('Quota/get', $res->[1][0]);
    $mailQuota = $res->[1][1]{list}[0];
    $self->assert_str_equals('mail', $mailQuota->{id});
    $self->assert_num_not_equals(0, $mailQuota->{used});
    $self->assert_num_equals(1000 * 1024, $mailQuota->{total});
    $self->assert_str_not_equals($quotaState, $res->[1][1]{state});
}

sub test_email_set_mailbox_alias
    :min_version_3_1 :needs_component_jmap
{
    my ($self) = @_;

    my $jmap = $self->{jmap};
    my $imaptalk = $self->{store}->get_client();

    # Create mailboxes
    my $res = $jmap->CallMethods([
        ['Mailbox/set', {
            create => {
                "drafts" => {
                    name => "Drafts",
                    parentId => undef,
                    role => "drafts"
                },
                "trash" => {
                    name => "Trash",
                    parentId => undef,
                    role => "trash"
                }
            }
        }, "R1"]
    ]);
    my $draftsMboxId = $res->[0][1]{created}{drafts}{id};
    $self->assert_not_null($draftsMboxId);
    my $trashMboxId = $res->[0][1]{created}{trash}{id};
    $self->assert_not_null($trashMboxId);

    # Create email in mailbox using role as id
    $res = $jmap->CallMethods([
        ['Email/set', {
            create => {
                "1" => {
                    mailboxIds => {
                        '$drafts' => JSON::true
                    },
                    from => [{ email => q{from@local}, name => q{} } ],
                    to => [{ email => q{to@local}, name => q{} } ],
                }
            },
        }, 'R1'],
        ['Email/get', {
            ids => [ "#1" ],
            properties => ['mailboxIds'],
        }, "R2" ],
    ]);
    $self->assert_num_equals(1, scalar keys %{$res->[1][1]{list}[0]{mailboxIds}});
    $self->assert_not_null($res->[1][1]{list}[0]{mailboxIds}{$draftsMboxId});
    my $emailId = $res->[0][1]{created}{1}{id};

    # Move email to mailbox using role as id
    $res = $jmap->CallMethods([
        ['Email/set', {
            update => {
                $emailId => {
                    'mailboxIds/$drafts' => undef,
                    'mailboxIds/$trash' => JSON::true
                }
            },
        }, 'R1'],
        ['Email/get', {
            ids => [ $emailId ],
            properties => ['mailboxIds'],
        }, "R2" ],
    ]);
    $self->assert_num_equals(1, scalar keys %{$res->[1][1]{list}[0]{mailboxIds}});
    $self->assert_not_null($res->[1][1]{list}[0]{mailboxIds}{$trashMboxId});
}

sub test_email_import_encoded_contenttype
    :min_version_3_1 :needs_component_jmap
{
    # Very old macOS Mail.app versions encode the complete
    # Content-Type header value, when they really should
    # just encode its file name parameter value.
    # See: https://github.com/cyrusimap/cyrus-imapd/issues/2622

    my ($self) = @_;
    my $jmap = $self->{jmap};

    my $store = $self->{store};
    my $talk = $store->get_client();

    my $email = <<'EOF';
From: example@example.com
To: example@example.biz
Subject: This is a test
Message-Id: <15288246899.CBDb71cE.3455@cyrus-dev>
Date: Tue, 12 Jun 2018 13:31:29 -0400
MIME-Version: 1.0
Content-Type: multipart/mixed;boundary=123456789

--123456789
Content-Type: text/html

This is a mixed message.

--123456789
Content-Type: =?utf-8?B?aW1hZ2UvcG5nOyBuYW1lPSJr?=
 =?utf-8?B?w6RmZXIucG5nIg==?=

data

--123456789--
EOF
    $email =~ s/\r?\n/\r\n/gs;
    my $blobId = $jmap->Upload($email, "message/rfc822")->{blobId};

    my $inboxId = $self->getinbox()->{id};

    my $res = $jmap->CallMethods([['Email/import', {
        emails => {
            "1" => {
                blobId => $blobId,
                mailboxIds => {$inboxId =>  JSON::true},
            },
        },
    }, "R1"], ["Email/get", { ids => ["#1", "#2"], properties => ['bodyStructure'] }, "R2" ]]);

    my $msg = $res->[1][1]{list}[0];
    $self->assert_equals('image/png', $msg->{bodyStructure}{subParts}[1]{type});
    $self->assert_equals("k\N{LATIN SMALL LETTER A WITH DIAERESIS}fer.png", $msg->{bodyStructure}{subParts}[1]{name});
}

1;
