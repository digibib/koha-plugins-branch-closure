package Koha::Plugin::Deichman::BranchClosure;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
use CGI '-utf8';
use Koha::DateUtils qw/dt_from_string output_pref/;
use Koha::Database;
use Koha::Libraries;
use Koha::Patrons;

## Here we set our plugin version
our $VERSION = 1.00;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Branch Closure',
    author          => 'Benjamin Rokseth',
    description     => 'This plugin takes care of the steps for closing a branch',
    date_authored   => '2017-05-11',
    date_updated    => '2017-06-08',
    minimum_version => '16.11.070000',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);
    return $self;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self ) = @_;

    return C4::Context->dbh->do(
        qq{
            CREATE TABLE IF NOT EXISTS `closed_branches` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `branchcode` varchar(10) COLLATE utf8_unicode_ci NOT NULL,
            `tempbranch` varchar(10) COLLATE utf8_unicode_ci NOT NULL,
            `from_date` DATE NOT NULL,
            `to_date` DATE NOT NULL,
            `movepatrons` int(1) DEFAULT 0,
            `items_moved` int(1) DEFAULT 0,
            `done` int(1) NOT NULL DEFAULT 0,
            PRIMARY KEY (id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
          }
    );
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self) = @_;

    return C4::Context->dbh->do("DROP TABLE `closed_branches`");
}

## Plugin configuration handler
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    $cgi->charset('utf-8');

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param( body      => $self->retrieve_data('body'), );
        $template->param( subject   => $self->retrieve_data('subject'), );

        print $cgi->header();
        print $template->output();
    } else {
        $self->store_data(
            {
                body               => $cgi->param('body'),
                subject            => $cgi->param('subject'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
    }

    $self->go_home();
}

# Main Tool handler
sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};
    my $op = $cgi->param('op') || "";

    if ( $op eq "reopen" ) {
        $self->reopen_branch_step;
    } elsif ( $op eq "moveitems" ) {
        $self->move_items_step;
    } elsif ( $op eq "close" ) {
        $self->close_branch_step;
    } else {
        $self->firstpage;
    }

}

# Show status of closed branches, reopen or make new closures
sub firstpage {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $body_template = $self->retrieve_data('body');
    my $subject       = $self->retrieve_data('subject');

    my @closed_branches = get_closed_branches();
    my @libraries = Koha::Libraries->search;

    my $template = $self->get_template({ file => 'firstpage.tt' });
    $template->param(
        closed_branches => \@closed_branches,
        libraries       => \@libraries,
        subject         => $subject,
        body            => $body_template,
    );
    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

sub get_closed_branches {
    my $query = "SELECT * FROM closed_branches";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";
    my @res;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push @res, $row;
    }
    return @res;
}

sub move_items_step {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $id          = $cgi->param('id');
    my $frombranch  = $cgi->param('branchcode');
    my $tobranch    = $cgi->param('tempbranch');

    # do database updates
    make_items_unavailable($frombranch);
    mark_items_as_moved($id);

    # print success page
    my $template = $self->get_template( { file => 'items_moved.tt' } );
    $template->param(
        branchcode  => $frombranch,
        tempbranch  => $tobranch,
    );
    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

# Main method for closing branch
sub close_branch_step {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $frombranch     = $cgi->param('branchcode');
    my $tobranch       = $cgi->param('tempbranch');
    my $fromDate       = dt_from_string($cgi->param('fromdate'));
    my $toDate         = dt_from_string($cgi->param('todate'));
    my $email_subject  = $cgi->param('email_subject');
    my $email_template = $cgi->param('email_template');
    my $movepatrons    = $cgi->param('movepatrons') eq "on" ? 1 : undef;

    # do database updates
    disable_branch_in_api($frombranch);
    if ( $movepatrons ) {
        change_pickup_branch({ orig_branch => $frombranch, temp_branch => $tobranch });
        notify_patrons({
            frombranch     => $frombranch,
            tobranch       => $tobranch,
            fromdate       => $fromDate,
            todate         => $toDate,
            email_subject  => $email_subject,
            email_template => $email_template,
        });
        change_patrons_homebranch({ orig_branch => $frombranch, temp_branch => $tobranch });
    }
    update_calendar();
    update_closed_branches({
        frombranch  => $frombranch,
        tobranch    => $tobranch,
        fromdate    => $fromDate,
        todate      => $toDate,
        movepatrons => $movepatrons,
    });

    # print success page
    my $template = $self->get_template( { file => 'closed_branch.tt' } );
    $template->param(
        branchcode  => $frombranch,
        tempbranch  => $tobranch,
        movepatrons => $movepatrons,
    );
    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

sub reopen_branch_step {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $id          = $cgi->param('id');
    my $branchcode  = $cgi->param('branchcode');
    my $tempbranch  = $cgi->param('tempbranch');
    my $fromdate    = $cgi->param('fromdate');
    my $movepatrons = $cgi->param('movepatrons');

    # steps to reopen
    enable_branch_in_api($branchcode);
    make_items_available($branchcode);
    if ( $movepatrons ) {
        revert_pickup_branch({orig_branch => $branchcode, temp_branch => $tempbranch});
        revert_patrons_homebranch({orig_branch => $branchcode, temp_branch => $tempbranch});
    }
    finish_closed_branch($id);

    # print success page
    my $template = $self->get_template( { file => 'reopened_branch.tt' } );
    $template->param(
        branchcode  => $branchcode,
        tempbranch  => $tempbranch,
        movepatrons => $movepatrons,
    );

    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}



# unused yet
sub get_branch {
    my $id = shift;
    my $query = "SELECT * FROM closed_branches where id = '$id'";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";
    my @res;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push @res, $row;
    }
    return @res;
}

# params: branch
# set branchnotes to "BRANCH_CLOSED" so that API can ignore branch
sub disable_branch_in_api {
    my $branch = shift;
    my $query = "
        UPDATE branches
        SET branchnotes = 'BRANCH_CLOSED'
        WHERE branchcode = ?
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute($branch) or die "Error running query: $sth";

    return;
}

# re-enable branch
sub enable_branch_in_api {
    my $branch = shift;
    my $query = "
        UPDATE branches
        SET branchnotes = NULL
        WHERE branchcode = ?
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute($branch) or die "Error running query: $sth";

    return;
}

# params: branch
# make items notforloan, except if they are on loan or specific item is reserved
# dont touch homebranch, as they are to be left in boxes temporarily
sub make_items_unavailable {
    my $branch = shift;
    return unless $branch;
    my $query = "
        UPDATE items i
        SET notforloan = 1, new_status = 'BRANCH_CLOSED'
        WHERE i.homebranch = ?
        AND NOT EXISTS (SELECT * FROM issues WHERE itemnumber = i.itemnumber)
        AND NOT EXISTS (SELECT * FROM reserves WHERE itemnumber = i.itemnumber)
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute($branch) or die "Error running query: $sth";
    return;
}

# remove notforloan status on items from specified branch marked 'BRANCH_CLOSED'
sub make_items_available {
    my $branch = shift;
    return unless $branch;
    my $query = "
        UPDATE items i
        SET notforloan = 0, new_status = NULL
        WHERE i.homebranch = ?
        AND i.new_status = 'BRANCH_CLOSED'
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute($branch) or die "Error running query: $sth";
    return;
}

# params: orig_branch, temp_branch
# move all reserves to another pickup branch, except items waiting on hold shelf
# mark reserve as 'MOVED FROM x'
sub change_pickup_branch {
    my ( $args ) = @_;
    my $query = "
        UPDATE reserves
        SET branchcode = '$args->{temp_branch}', reservenotes = 'MOVED FROM $args->{orig_branch}'
        WHERE branchcode = '$args->{orig_branch}'
        AND (found != 'W' OR found IS NULL)
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";

    return;
}

# params: orig_branch, temp_branch
# move all reserves back to original pickup branch, except items waiting on hold shelf
# mark reserve as 'MOVED FROM x'
sub revert_pickup_branch {
    my ( $args ) = @_;
    my $query = "
        UPDATE reserves
        SET branchcode = IF(found = 'W', '$args->{temp_branch}', '$args->{orig_branch}'), reservenotes = NULL
        WHERE branchcode = '$args->{temp_branch}'
        AND reservenotes = 'MOVED FROM $args->{orig_branch}'
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";

    return;
}

# params: orig_branch, temp_branch
sub change_patrons_homebranch {
    my ( $args ) = @_;
    my $query = "
        UPDATE borrowers
        SET branchcode = '$args->{temp_branch}', borrowernotes = 'MOVED FROM $args->{orig_branch}'
        WHERE branchcode = '$args->{orig_branch}'
        AND categorycode IN ('V','B')
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";
    return;
}

# params: orig_branch, temp_branch
sub revert_patrons_homebranch {
    my ( $args ) = @_;
    my $query = "
        UPDATE borrowers b
        SET branchcode = '$args->{orig_branch}', borrowernotes = NULL
        WHERE branchcode = '$args->{temp_branch}'
        AND borrowernotes = 'MOVED FROM $args->{orig_branch}'
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";
    return;
}

# TODO: Update branch closing times in calendar so pickup lists are updated
# but the special_holidays table is a mess
# params: branch, fromdate, todate
sub update_calendar {
    my ( $args ) = @_;
    return;
}

# params: frombranch, tobranch, fromdate, todate, email_subject, email_template
sub notify_patrons {
    my ( $args ) = @_;
    my $schema           = Koha::Database->new()->schema();
    my $message_queue_rs = $schema->resultset('MessageQueue');

    my $patrons = Koha::Patrons->search({ branchcode => $args->{frombranch} });
    # compose email to patron and put in message queue
    while ( my $patron = $patrons->next ) {
        next unless $patron->email;
        my $email = Template->new();
        my $body;
        $email->process( \$args->{email_template}, {
            cardnumber => $patron->cardnumber,
            firstname  => $patron->firstname,
            surname    => $patron->surname,
            frombranch => Koha::Libraries->find($args->{frombranch})->branchname,
            tobranch   => Koha::Libraries->find($args->{tobranch})->branchname,
            fromdate   => output_pref({dt => $args->{fromdate}, dateonly => 1}),
            todate     => output_pref({dt => $args->{todate}, dateonly => 1}),
        }, \$body );
        #use Data::Dumper; warn Dumper($body);

        $message_queue_rs->create(
            {
                borrowernumber         => $patron->borrowernumber,
                subject                => $args->{email_subject},
                content                => $body,
                message_transport_type => 'email',
                status                 => 'pending',
                to_address             => $patron->email,
                from_address           => C4::Context->preference('KohaAdminEmailAddress'),
            }
        );
    }
    return;
}

# params: branch, fromdate, todate
sub update_closed_branches {
    my ( $args ) = @_;
    my $query = "
        INSERT INTO closed_branches (branchcode,tempbranch,from_date,to_date,movepatrons,done)
        VALUES (?, ?, ?, ?, ?, 0);
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute($args->{frombranch}, $args->{tobranch}, $args->{fromdate}, $args->{todate}, $args->{movepatrons}) or die "Error running query: $sth";
    return;
}

# params: id
sub mark_items_as_moved {
    my $id = shift;
    my $query = "
        UPDATE closed_branches
        SET items_moved = 1
        WHERE id = '$id'
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";
    return;
}

# params: id
sub finish_closed_branch {
    my $id = shift;
    my $query = "
        UPDATE closed_branches
        SET done = 1
        WHERE id = '$id'
        ";
    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute() or die "Error running query: $sth";
    return;
}

1;
