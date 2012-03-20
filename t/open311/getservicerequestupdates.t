#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../perllib";
use lib "$FindBin::Bin/../commonlib/perllib";

use_ok( 'Open311' );

use_ok( 'Open311::GetServiceRequestUpdates' );
use DateTime;
use FixMyStreet::App;

my $user = FixMyStreet::App->model('DB::User')->find_or_create(
    {
        email => 'system_user@example.com'
    }
);

my $requests_xml = qq{<?xml version="1.0" encoding="utf-8"?>
<service_requests_updates>
<request_update>
<update_id>638344</update_id>
<service_request_id>1</service_request_id>
<service_request_id_ext>1</service_request_id_ext>
<status>open</status>
<description>This is a note</description>
UPDATED_DATETIME
</request_update>
</service_requests_updates>
};


my $dt = DateTime->now;

# basic xml -> perl object tests
for my $test (
    {
        desc => 'basic parsing - element missing',
        updated_datetime => '',
        res => { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note' },
    },
    {
        desc => 'basic parsing - empty element',
        updated_datetime => '<updated_datetime />',
        res =>  { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note', updated_datetime => {} } ,
    },
    {
        desc => 'basic parsing - element with no content',
        updated_datetime => '<updated_datetime></updated_datetime>',
        res =>  { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note', updated_datetime => {} } ,
    },
    {
        desc => 'basic parsing - element with content',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        res =>  { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note', updated_datetime => $dt } ,
    },
) {
    subtest $test->{desc} => sub {
        my $local_requests_xml = $requests_xml;
        $local_requests_xml =~ s/UPDATED_DATETIME/$test->{updated_datetime}/;

        my $o = Open311->new( jurisdiction => 'mysociety', endpoint => 'http://example.com', test_mode => 1, test_get_returns => { 'update.xml' => $local_requests_xml } );

        my $res = $o->get_service_request_updates;
        is_deeply $res->{ request_update }, $test->{ res }, 'result looks correct';

    };
}

my $problem_rs = FixMyStreet::App->model('DB::Problem');
my $problem = $problem_rs->new(
    {
        postcode     => 'EH99 1SP',
        latitude     => 1,
        longitude    => 1,
        areas        => 1,
        title        => '',
        detail       => '',
        used_map     => 1,
        user_id      => 1,
        name         => '',
        state        => 'confirmed',
        service      => '',
        cobrand      => 'default',
        cobrand_data => '',
        user         => $user,
        created      => DateTime->now()->subtract( days => 1 ),
        lastupdate   => DateTime->now()->subtract( days => 1 ),
        anonymous    => 1,
        external_id  => time(),
    }
);

$problem->insert;

for my $test (
    {
        desc => 'element with content',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'confirmed',
        close_comment => 0,
        mark_fixed=> 0,
        mark_open => 0,
        end_state => 'confirmed',
    },
    {
        desc => 'comment closes report',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'confirmed',
        close_comment => 1,
        mark_fixed=> 1,
        mark_open => 0,
        end_state => 'fixed - council',
    },
    {
        desc => 'comment re-opens fixed report',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'fixed - user',
        close_comment => 0,
        mark_fixed => 0,
        mark_open => 1,
        end_state => 'confirmed',
    },
    {
        desc => 'comment re-opens closed report',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'closed',
        close_comment => 0,
        mark_fixed => 0,
        mark_open => 1,
        end_state => 'confirmed',
    },
    {
        desc => 'comment leaves report closed',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'closed',
        close_comment => 1,
        mark_fixed => 0,
        mark_open => 0,
        end_state => 'closed',
    },
) {
    subtest $test->{desc} => sub {
        my $local_requests_xml = $requests_xml;
        $local_requests_xml =~ s/UPDATED_DATETIME/$test->{updated_datetime}/;
        $local_requests_xml =~ s#<service_request_id>\d+</service_request_id>#<service_request_id>@{[$problem->external_id]}</service_request_id>#;
        $local_requests_xml =~ s#<service_request_id_ext>\d+</service_request_id_ext>#<service_request_id_ext>@{[$problem->id]}</service_request_id_ext>#;
        $local_requests_xml =~ s#<status>\w+</status>#<status>closed</status># if $test->{close_comment};

        my $o = Open311->new( jurisdiction => 'mysociety', endpoint => 'http://example.com', test_mode => 1, test_get_returns => { 'update.xml' => $local_requests_xml } );

        $problem->comments->delete;
        $problem->state( $test->{start_state} );
        $problem->update;

        my $update = Open311::GetServiceRequestUpdates->new( system_user => $user );
        $update->update_comments( $o );

        is $problem->comments->count, 1, 'comment count';
        $problem->discard_changes;

        my $c = FixMyStreet::App->model('DB::Comment')->search( { external_id => $test->{external_id} } )->first;
        ok $c, 'comment exists';
        is $c->text, $test->{description}, 'text correct';
        is $c->mark_fixed, $test->{mark_fixed}, 'mark_closed correct';
        is $c->mark_open, $test->{mark_open}, 'mark_open correct';
        is $problem->state, $test->{end_state}, 'correct problem state';
    };
}

$problem->comments->delete();
$problem->delete;
$user->comments->delete;
$user->problems->delete;
$user->delete;

done_testing();