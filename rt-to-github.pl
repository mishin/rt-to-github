#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;
use Carp;
use IO::Prompt::Tiny 'prompt';
use Net::GitHub;
use Path::Tiny;
use RT::Client::REST::Ticket;
use RT::Client::REST;
use Syntax::Keyword::Junction 'any';
use Data::Dump 'dump';

# In the .git/config of the active repo, create a [github] section and add 'user' and 'token' keys'
sub _git_config {
    my $key = shift;
    chomp( my $value = `git config --get $key` );
    croak "Unknown $key" unless $value;
    return $value;
}

my $pause_rc = path( $ENV{HOME}, ".pause" );
my %pause;

sub _pause_rc {
    my $key = shift;
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

my $github_user       = prompt( "github user: ",  _git_config("github.user") );
my $github_token      = prompt( "github token: ", _git_config("github.token") );
my $github_repo_owner = prompt( "repo owner: ",   $github_user );
my $github_repo       = prompt( "repo name: ",    path(".")->absolute->basename );

my $rt_user = prompt( "PAUSE ID: ", _pause_rc("user") );
my $rt_password =
  _pause_rc("password") ? _pause_rc("password") : prompt("PAUSE password: ");
my $rt_dist = prompt( "RT dist name: ", _dist_name() );

my $gh = Net::GitHub->new( access_token => $github_token );
$gh->set_default_user_repo( $github_repo_owner, $github_repo );
my $gh_issue = $gh->issue;

my $rt = RT::Client::REST->new( server => 'https://rt.cpan.org/' );
$rt->login(
    username => $rt_user,
    password => $rt_password
);

# see which tickets we already have on the github side
my @gh_issues =
  map { /\[rt\.cpan\.org #(\d+)\]/ }
  map { $_->{title} }
  $gh_issue->repos_issues( $github_repo_owner, $github_repo, { state => 'open' } );

my @rt_tickets = $rt->search(
    type  => 'ticket',
    query => qq{
        Queue = '$rt_dist'
        and
        ( Status = 'new' or Status = 'open' )
    },
);

for my $id (@rt_tickets) {

    if ( any(@gh_issues) eq $id ) {
        say "ticket #$id already on github";
        next;
    }

    # get the information from RT
    my $ticket = RT::Client::REST::Ticket->new(
        rt => $rt,
        id => $id,
    );
    $ticket->retrieve;

    # we just want the first transaction, which
    # has the original ticket description

    my $iterator = $ticket->transactions->get_iterator;
    my $first_transaction = $iterator->();
    my $desc = $first_transaction->content;

    $desc =~ s/^/    /gms;

    my $subject = $ticket->subject;

    my %issue = (
            "title" => "$subject [rt.cpan.org #$id]",
            "body"  => "https://rt.cpan.org/Ticket/Display.html?id=$id\n\n$desc",
            "labels" => [ 'rt' ],
    );

    # say dump (\%issue);
    my $isu = $gh_issue->create_issue(\%issue);

    while (my $tx = $iterator->()) {
        my $content = $tx->content;
        #say "tx: ".dump($content) unless $content eq 'This transaction appears to have no content';
        unless ($content eq 'This transaction appears to have no content') {
            my $comment  = $gh_issue->create_comment($isu->{number}, { body => $content });
        }
    }

    say "ticket #$id ($subject) copied to github";
}
