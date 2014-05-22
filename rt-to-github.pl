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
use Encode 'encode';

$|++;

my %opts;

GetOptions(
    \%opts,
    'help|h',
    'dry-run|d',
    'rt-dist|r=s@',
    'id|i=i@',
    'comment|c',
    'no-prompt',
) || pod2usage( 1 );

pod2usage( 0 ) if $opts{'help'};

my ( $gh,@gh_issues )  = get_gh_issues( $opts{'no-prompt'} );
say scalar( @gh_issues ) . " existing issues on github";

my ( $rt,@rt_tickets ) = get_rt_tickets( $opts{'no-prompt'},$opts{'rt-dist'},$opts{'id'} );
say scalar( @rt_tickets ) . " issues on RT";

copy_tickets_to_github(
	$opts{'dry-run'},$opts{'comment'},$rt,$gh,\@rt_tickets,\@gh_issues
);

sub get_gh_issues {

    my ( $no_prompt ) = @_;

    my $github_user = $no_prompt
        ? _git_config("github.user")
        : prompt( "github user: ",  _git_config("github.user") );

    my $github_token = $no_prompt
        ? _git_config("github.token")
        : prompt( "github token: ", _git_config("github.token") );

    my $github_repo_owner = $no_prompt
        ? $github_user
        : prompt( "repo owner: ",   $github_user );

    my $github_repo = $no_prompt
        ? path(".")->absolute->basename
        : prompt( "repo name: ",    path(".")->absolute->basename );

    my $gh = Net::GitHub->new( access_token => $github_token );
    $gh->set_default_user_repo( $github_repo_owner, $github_repo );
    my $gh_issue = $gh->issue;

    # see which tickets we already have on the github side
    my @gh_issues =
        map { /\[rt\.cpan\.org #(\d+)\]/ }
        map { $_->{title} }
        $gh_issue->repos_issues(
            $github_repo_owner, $github_repo, { state => 'open' }
        );

    # repos_issues will only return 30 issues, need to check if
    # there are more and keep going until we have them all
    while ( $gh_issue->has_next_page ) {

        my @next_page =
            map { /\[rt\.cpan\.org #(\d+)\]/ }
            map { $_->{title} }
            $gh_issue->next_page;

        push( @gh_issues,@next_page );
    }

    return ( $gh,@gh_issues );
}

sub get_rt_tickets {

    my ( $no_prompt,$rt_dist,$ids ) = @_;

    my $rt_user = $no_prompt
        ? _pause_rc("user")
        : prompt( "PAUSE ID: ", _pause_rc("user") );

    my $rt_password = _pause_rc("password")
        ? _pause_rc("password")
        : prompt("PAUSE password: ");

    @{ $rt_dist } = ( prompt( "RT dist name: ", _dist_name() ) )
        if ! @{ $rt_dist // [] };

    my $rt = RT::Client::REST->new( server => 'https://rt.cpan.org/' );
    $rt->login(
        username => $rt_user,
        password => $rt_password
    ) || croak( "Couldn't log into RT: $_" );

    return ( $rt,@{ $ids } ) if @{ $ids // [] };

    my @rt_tickets;

    foreach my $rt_dist ( @{ $rt_dist } ) {

        my @rt_dist_tickets = $rt->search(
            type  => 'ticket',
            query => qq{
                Queue = '$rt_dist'
                and
                ( Status = 'new' or Status = 'open' or Status = 'stalled' )
            },
        );

        push( @rt_tickets,@rt_dist_tickets );
    }

    return ( $rt,@rt_tickets );
}

sub copy_tickets_to_github {

    my ( $dry_run,$comment_rt,$rt,$gh,$rt_tickets,$gh_issues ) = @_;

    my $gh_issue = $gh->issue;

    for my $id (sort { $a <=> $b } @{$rt_tickets}) {

        if ( any(@{$gh_issues}) eq $id ) {
            say "ticket #$id already on github";
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
            say "Problem getting RT #$id: " . $_;
        };

        next if ! $ticket;

        # we just want the first transaction, which
        # has the original ticket description

        my $iterator          = $ticket->transactions->get_iterator;
        my $first_transaction = $iterator->();
        my $desc              = $first_transaction->content;

        $desc =~ s/^/    /gms;
        $desc = encode( 'utf-8',$desc );

        my $subject = $ticket->subject;

        my $labels = [ 'Migrated From RT' ];

        foreach my $cf ( $ticket->cf ) {
            if ( $cf =~ /severity/i ) {
                push( @{ $labels },$ticket->cf( $cf ) )
                    if $ticket->cf( $cf );
            }
        }

        my %issue = (
            "title" => "$subject [rt.cpan.org #$id]",
            "body"  => "https://rt.cpan.org/Ticket/Display.html?id=$id\n\n$desc",
            "labels" => $labels,
        );

        my $isu;

        if ( $dry_run ) {
            say "$subject [rt.cpan.org #$id]";
        } else {
            try {
                $isu = $gh_issue->create_issue(\%issue);
                # sleep a little to make sure issue is replicated to read db
                # servers (making an assumption here, if there is no sleep
                # sometimes we can't add comments to issues we have just created
                sleep(5);
            } catch {
                say "Problem with create_issue (RT #$id): $_:";
                say "--->$desc<---";
            };
            $isu // next;
        }

        while (my $tx = $iterator->()) {
            my $content = $tx->content;
            if ($content ne 'This transaction appears to have no content') {
                $content = $tx->creator . ' - ' . $tx->created . "\n\n$content";
                $content = encode( 'utf-8',$content );
                if ( $dry_run ) {
                    say "	- comment length " . length( $content );
                } else {
                    try {
                        my $comment = $gh_issue->create_comment(
                            $isu->{number},
                            { body => $content }
                        );
                    } catch {
                        say "Problem creating comment: $_:";
                        say "--->$content<---";
                    };
                }
            }
        }

        if ( ! $dry_run ) {
            if ( $comment_rt ) {
                try {
                    $ticket->correspond(
                        message => "This issue has been copied to: "
                            . $isu->{html_url}
                            . " please take all future correspondence there.\n"
                            . " This ticket will remain open but please do not reply here.\n"
                            . " This ticket will be closed when the github issue is dealt with."
                    );
                } catch {
                    say $_;
                };
            }
            say "ticket #$id ($subject) copied to github";
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

    --dry-run | -d        dry run mode, will just print subject and comment lengths
    --rt-dist | -r <dist> RT dist to migrate tickets from, can be supplied multiple times
    --id      | -i <id>   specific RT ticket id, can be supplied multiple times
    --comment             add comment to RT ticket showing github location
    --no-prompt           use values in .git/config and ~/.pause
    --help    | -h        this help

=head1 DESCRIPTION

This script will allow you to mass copy rt.cpan.org issues to issues in a github repo.
It was used to successfully copy 89 of issues from two different RT distributions
for the CGI.pm perl module to github, so it should work for you.

The script does its best to copy all content from tickets, but there are some caveats:

    - No attachements will be copied
    - Original author data and timestamps will not be reflected in the new issue
    - That is to say, they will be included as part of the comments on the issue
      but the issue author/timestamp will be your github user details and the time
      this script copied the issue

You can run the script with --dry-run as a first sanity check. If no information is
supplied on the command line you will be prompted for it. You will need to add the
following to the .git/config file in the git[hub] repo you are copying tickets to:

    [github]
        user = <your github user name>
        token = <your github API token>

You can create a ~/.pause file to get the PAUSE login details, it should look like:

    user <your PAUSE user name>
    password <your PAUSE password>

You will still be prompted for the information on the command line, so to make the
script use the values defined in the above files supply --no-prompt

To add a comment to the existing RT ticket(s) supply the --comment options - this
will add a comment explaining that the ticket has been copied to github, with the
url, and asking to send future correspondence there. The existing ticket will B<not>
be closed, but the comment will state that the RT ticket will be closed when the
github issue is.

=head1 CREDITS

initial script sourced from:
	https://gist.github.com/markstos/5096483

raison d'être:
	https://github.com/leejo/CGI.pm/issues/1

=head1 BUGS

Please raise a github issue:
    https://github.com/leejo/rt-to-github/issues

=cut
