#!/usr/bin/env perl

use v5.10;
use strict;
use warnings;

use Carp 'croak';
use IO::Prompt::Tiny 'prompt';
use Net::GitHub;
use Path::Tiny;
use RT::Client::REST::Ticket;
use RT::Client::REST;
use Syntax::Keyword::Junction 'any';
use Data::Dump 'dump';
use Getopt::Long;
use Try::Tiny;
use Pod::Usage;

my %opts;

GetOptions(
	\%opts,
    'help|h',
	'dry-run|d',
    'rt-dist|r=s',
    'id|i=i@',
) || pod2usage( 1 );

pod2usage( 0 ) if $opts{'help'};

my ( $gh,@gh_issues )  = get_gh_issues();
warn scalar( @gh_issues ) . " existing issues on github";

my ( $rt,@rt_tickets ) = get_rt_tickets( $opts{'rt-dist'},$opts{'id'} );
warn scalar( @rt_tickets ) . " issues on RT";

copy_tickets_to_github(
	$opts{'dry-run'},$rt,$gh,\@rt_tickets,\@gh_issues
);

sub get_gh_issues {

    my $github_user       = prompt( "github user: ",  _git_config("github.user") );
    my $github_token      = prompt( "github token: ", _git_config("github.token") );
    my $github_repo_owner = prompt( "repo owner: ",   $github_user );
    my $github_repo       = prompt( "repo name: ",    path(".")->absolute->basename );

    my $gh = Net::GitHub->new( access_token => $github_token );
    $gh->set_default_user_repo( $github_repo_owner, $github_repo );
    my $gh_issue = $gh->issue;

    # see which tickets we already have on the github side
    my @gh_issues =
        map { /\[rt\.cpan\.org #(\d+)\]/ }
        map { $_->{title} }
        $gh_issue->repos_issues( $github_repo_owner, $github_repo, { state => 'open' } );

    return ( $gh,@gh_issues );
}

sub get_rt_tickets {

    my ( $rt_dist,$ids ) = @_;

    my $rt_user = prompt( "PAUSE ID: ", _pause_rc("user") );
    my $rt_password =
      _pause_rc("password") ? _pause_rc("password") : prompt("PAUSE password: ");

    $rt_dist //= prompt( "RT dist name: ", _dist_name() );

    my $rt = RT::Client::REST->new( server => 'https://rt.cpan.org/' );
    $rt->login(
        username => $rt_user,
        password => $rt_password
    ) || croak( "Couldn't log into RT: $_" );

    my @rt_tickets = @{ $ids // [] } ? @{ $ids } : $rt->search(
        type  => 'ticket',
        query => qq{
            Queue = '$rt_dist'
            and
            ( Status = 'new' or Status = 'open' or Status = 'stalled' )
        },
    );

    return ( $rt,@rt_tickets );
}

sub copy_tickets_to_github {

    my ( $dry_run,$rt,$gh,$rt_tickets,$gh_issues ) = @_;

    my $gh_issue = $gh->issue;

    for my $id (@{$rt_tickets}) {

        if ( any(@{$gh_issues}) eq $id ) {
            warn "ticket #$id already on github";
            next;
        }

        # get the information from RT
        my $ticket;

        try {
            $ticket = RT::Client::REST::Ticket->new(
                rt => $rt,
                id => $id,
            );
            $ticket->retrieve;
        } catch {
            warn "Problem getting RT #$id: " . $_;
        };

        next if ! $ticket;

        # we just want the first transaction, which
        # has the original ticket description

        my $iterator          = $ticket->transactions->get_iterator;
        my $first_transaction = $iterator->();
        my $desc              = $first_transaction->content;

        $desc =~ s/^/    /gms;

        my $subject = $ticket->subject;

        my $labels = [ 'Migrated From RT' ];

        foreach my $cf ( $ticket->cf ) {
            if ( $cf =~ /severity/i ) {
                push( @{ $labels },$ticket->cf( $cf ) );
            }
        }

        my %issue = (
            "title" => "$subject [rt.cpan.org #$id]",
            "body"  => "https://rt.cpan.org/Ticket/Display.html?id=$id\n\n$desc",
            "labels" => $labels,
        );

        my $isu;

        if ( $dry_run ) {
            warn dump (\%issue);
        } else {
            $isu = $gh_issue->create_issue(\%issue);
        }

        while (my $tx = $iterator->()) {
            my $content = $tx->content;
            if ($content ne 'This transaction appears to have no content') {
                $content = $tx->creator . ' - ' . $tx->created . "\n\n$content";
                if ( $dry_run ) {
                    warn "tx: ".dump($content);
                    warn "tx: ".dump($gh_issue);
                } else {
                    my $comment = $gh_issue->create_comment(
                        $isu->{number},
                        { body => $content }
                    );
                }
            }
        }

        if ( ! $dry_run ) {
            $ticket->comment(
                message => "This issue has been copied to: "
                    . $isu->{html_url}
                    . " please take all future correspondence there.\n"
                    . " This ticket will remain open but please do not reply here.\n"
                    . " This ticket will be closed when the github issue is dealt with."
            );
            warn "ticket #$id ($subject) copied to github";
        }
    }
}

sub _pause_rc {
    my $key = shift;
    state %pause;
    state $pause_rc = path( $ENV{HOME}, ".pause" );
    if ( $pause_rc->exists && !%pause ) {
        %pause = split " ", $pause_rc->slurp;
    }
    return $pause{$key} // '';
}

sub _dist_name {
    # dzil only for now
    my $dist = path("dist.ini");
    if ( $dist->exists ) {
        my ($first) = $dist->lines( { count => 1 } );
        my ($name) = $first =~ m/name\s*=\s*(\S+)/;
        return $name if defined $name;
    }
    return '';
}

# In the .git/config of the active repo, create a [github] section and add 'user' and 'token' keys'
sub _git_config {
    my $key = shift;
    chomp( my $value = `git config --get $key` );
    croak "Unknown $key" unless $value;
    return $value;
}

=head1 rt-to-github.pl

A script to copy tickets form rt.cpan.org to github.com

=head1 SYNOPSIS

rt-to-github.pl [options]

    --help    | -h        this help
    --dry-run | -d        dry run mode, will dump out migration data
    --rt-dist | -r <dist> RT dist to migrate tickets from
    --id      | -i <id>   RT ticket id, can bu supplied multiple times

=cut
