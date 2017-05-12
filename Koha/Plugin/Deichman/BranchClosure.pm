package Koha::Plugin::Deichman::BranchClosure;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
use CGI '-utf8';
use DateTime;
use Koha::Database;

## Here we set our plugin version
our $VERSION = 1.00;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Branch Closure',
    author          => 'Benjamin Rokseth',
    description     => 'This plugin takes care of the steps for closing a branch',
    date_authored   => '2017-05-11',
    date_updated    => '2017-05-11',
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
              CREATE TABLE IF NOT EXISTS 'branch_closures' (
              id int(11) NOT NULL AUTO_INCREMENT,
              branchcode varchar(10) COLLATE utf8_unicode_ci NOT NULL,
              from_date DATE NOT NULL,
              to_date DATE NOT NULL,
              done int(1) NOT NULL DEFAULT 0,
              PRIMARY KEY (id)
              ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
          }
    );
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self) = @_;

    return C4::Context->dbh->do("DROP TABLE 'branch_closures'");
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
    }
    else {
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

# Tool handler
# - in general any plugin that modifies the Koha database should be considered a tool
sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    if ( $cgi->param('validate') ) { # validate button in step 1 clicked
        $self->tool_step2();
    } else if ( $cgi->param('confirmed') ) { # confirm button in step 1 clicked
        $self->tool_step3();
    } else {
        $self->tool_step1();
    }

}

# Step 1 - Choose frombranch, tobranch and length of closure, compose email template
sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $body_template = $self->retrieve_data('body');
    my $subject       = $self->retrieve_data('subject');

    my $template = $self->get_template({ file => 'tool-step1.tt' });
    $template->param(
        subject => $subject,
        content_template => $body_template,
    );
    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

# Step 2 - Close branch and send emails
sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $frombranch     = $cgi->param('frombranch');
    my $tobranch       = $cgi->param('tobranch');
    my $fromDate       = $cgi->param('fromdate');
    my $toDate         = $cgi->param('todate');
    my $email_subject  = $cgi->param('email_subject');
    my $email_template = $cgi->param('email_template');

    # do database updates
    disable_branch_in_api($frombranch);
    make_items_unavailable($frombranch);
    change_pickup_branch({ frombranch => $frombranch, tobranch => $tobranch });
    change_patrons_homebranch({ frombranch => $frombranch, tobranch => $tobranch });
    notify_patrons({
        frombranch    => $frombranch,
        tobranch      => $tobranch,
        fromdate      => $fromDate,
        todate        => $toDate,
        subject       => $email_subject,
        body_template => $email_template,
    });
    update_calendar();
    update_branch_closures();

    # print success page
    my $template = $self->get_template( { file => 'tool-step2.tt' } );

    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

# params: branch
# set branchnotes to "DISABLED" so that API ignores branch
sub disable_branch_in_api {
    my $branch = shift;
    use Data::Dumper; warn Dumper($branch);
    my $query = "
        UPDATE branches
        SET branchnotes = 'BRANCH_CLOSED'
        WHERE branchcode = ?
        ";
    warn $query;
    #my $sth = C4::Context->dbh->prepare($query);
    #$sth->execute($args->{branch}) or die "Error running query: $sth";

    return;
}

# params: branch
# make items notforloan, except if they are on loan or item is reserved
# dont touch homebranch, as they are to be left in boxes temporarily
sub make_items_unavailable {
    my $branch = shift;
    my $query = "
        UPDATE items i
        JOIN issues iss USING (itemnumber)
        JOIN reserves ON (r.itemnumber=i.itemnumber)
        SET notforloan = 8, new_status = 'BRANCH_CLOSED'
        WHERE homebranch = ?
        ";
    warn $query;
    #my $sth = C4::Context->dbh->prepare($query);
    #$sth->execute($args->{branch}) or die "Error running query: $sth";
    return;
}

# params: frombranch, tobranch
# move all reserves to another pickup branch
# mark reserve as 'MOVED FROM x'
sub change_pickup_branch {
    my ( $args ) = @_;
    use Data::Dumper; warn Dumper($args);
    my $query = "
        UPDATE reserves
        SET branchcode = ?, reservenotes = 'MOVED FROM $args->{frombranch}'
        WHERE branchcode = ?
        ";
    my $sth = C4::Context->dbh->prepare($query);
    warn $sth->{Statement};
    warn $sth->{ParamValues};
    warn $query;
    #$sth->execute($args->{frombranch}, $args->{tobranch}) or die "Error running query: $sth";

    return;
}



# params: frombranch, tobranch
sub change_patrons_homebranch {
    my ( $args ) = @_;
    use Data::Dumper; warn Dumper($args);
    my $query = "
        UPDATE borrowers b
        SET branchcode = ?, borrowernotes = 'MOVED FROM $args->{frombranch}'
        WHERE homebranch = ?
        ";
    warn $query;
    #my $sth = C4::Context->dbh->prepare($query);
    #$sth->execute($args->{frombranch}, $args->{tobranch}) or die "Error running query: $sth";
    return;
}

# params: branch, fromdate, todate
sub update_calendar { }

# params: frombranch, tobranch, fromdate, todate, subject, body_template
sub notify_patrons {
    my ( $args ) = @_;
    my $schema           = Koha::Database->new()->schema();
    my $message_queue_rs = $schema->resultset('MessageQueue');

    my $patrons = Koha::Patrons->search({ branchcode => $args->{frombranch} });

    while (my ($patron) = $patrons->next()) {
        my $email = create_email_body($body_template, $patron, $frombranch, $tobranch, $fromdate, $todate);
        my $email = Template->new();
        my $body;
        $email->process( \$body_template, {
            cardnumber => $patron->cardnumber,
            name => $patron->name,
            frombranch => $args->{frombranch},
            tobranch => $args->{tobranch},
            fromdate => $args->{fromdate},
            todate => $args->{todate},
        }, \$body );
        use Data::Dumper; warn Dumper($email);
        # $message_queue_rs->create(
        #     {
        #         borrowernumber         => $patron->borrowernumber,
        #         subject                => $subject,
        #         content                => $email,
        #         message_transport_type => 'email',
        #         status                 => 'pending',
        #         to_address             => $patron->email,
        #         from_address           => C4::Context->preference('KohaAdminEmailAddress'),
        #     }
        # );
    }
}

# params: branch, fromdate, todate
sub update_branch_closures {}

1;
