package Clutch::Client;
use strict;
use warnings;
use Clutch::Util;
use Data::WeightedRoundRobin;
use IO::Select;
use Carp ();

sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{$_[0]} : @_;


    Carp::croak "Mandatory parameter 'servers'" unless $args{servers};

    %args = (
        servers => undef,
        timeout => 10,
        %args,
    );

    my $self = bless \%args, $class;

    my @servers;
    for my $row (@{$self->{servers}}) {
        if (ref($row) eq 'HASH') {
            push @servers, +{ value => $row->{address}, weight => $row->{weight} };
        }
        else {
            push @servers, $row;
        }
    }
    $self->{dwr} = Data::WeightedRoundRobin->new(\@servers);
    $self;
}

sub request_background {
    my ($self, $function, $args) = @_;
    $self->_request('request_background', $function, $args);
}

sub request {
    my ($self, $function, $args) = @_;
    $self->_request('request', $function, $args);
}

sub _request {
    my ($self, $cmd_name, $function, $args) = @_;

    my $server = $self->{dwr}->next;
    my $sock = Clutch::Util::new_client($server);

    my $json_args = Clutch::Util::json->encode($args);
    my $msg = join($DELIMITER, $cmd_name, $function, $json_args) . $CRLF;
    Clutch::Util::write_all($sock, $msg, $self->{timeout}, $self);

    my $buf='';
    while (1) {
        my $rlen = Clutch::Util::read_timeout(
            $sock, \$buf, $MAX_REQUEST_SIZE - length($buf), length($buf), $self->{timeout}, $self
        ) or return;

        Clutch::Util::verify_buffer($buf) and do {
            Clutch::Util::trim_buffer(\$buf);
            last;
        }
    }
    $sock->close();
    return $buf eq $NULL ? undef : Clutch::Util::json->decode($buf);
}

sub request_multi {
    my ($self, $args) = @_;
    $self->_verify_multi_args($args);
    $self->_request_multi('request', $args);
}

sub request_background_multi {
    my ($self, $args) = @_;
    $self->_verify_multi_args($args);
    $self->_request_multi('request_background', $args);
}

sub _verify_multi_args {
    my ($self, $args) = @_;

    for my $arg (@$args) {
        if ($arg->{function} eq '') {
            Carp::croak "there is no function to the argument of multi_request";
        }
    }
}

sub _request_multi {
    my ($self, $cmd_name, $args) = @_;

    my $request_count = scalar(@$args);
    my $is = IO::Select->new;

    my %sockets_map;
    for my $i (0 .. ($request_count - 1)) {
        my $server = $self->{dwr}->next;
        my $sock = Clutch::Util::new_client($server);
        $is->add($sock);
        $sockets_map{$sock}=$i;

        my $json_args = Clutch::Util::json->encode(($args->[$i]->{args}||''));
        my $msg = join($DELIMITER, $cmd_name, $args->[$i]->{function}, $json_args) . $CRLF;
        Clutch::Util::write_all($sock, $msg, $self->{timeout}, $self);
    }

    my @res;
    while ($request_count) {
        if (my @ready = $is->can_read($self->{timeout})) {
            for my $sock (@ready) {
                my $buf='';
                while (1) {
                    my $rlen = Clutch::Util::read_timeout(
                        $sock, \$buf, $MAX_REQUEST_SIZE - length($buf), length($buf), $self->{timeout}, $self
                    ) or return;

                    Clutch::Util::verify_buffer($buf) and do {
                        Clutch::Util::trim_buffer(\$buf);
                        last;
                    }
                }
                my $idx = $sockets_map{$sock};

                $request_count--;
                $is->remove($sock);
                $sock->close();

                $res[$idx] = $buf eq $NULL ? undef : Clutch::Util::json->decode($buf);
            }
        }
    }
    wantarray ? @res : \@res;
}

1;

__END__

=head1 NAME

Clutch::Client - distributed job system's client class

=head1 SYNOPSIS

    # client script
    use strict;
    use warnings;
    use Clutch::Client;
    my $args = shift || die 'missing args';
    my $client = Clutch::Client->new(
        servers => [
            +{ address => "$worker_ip:$worker_port" },
        ],
    );
    my $res = $client->request('echo', $args);
    print $res, "\n";

=head1 METHOD

=head2 my $client = Clutch::Client->new(%opts);

=over

=item $opts{servers}

The value is a reference to an array of worker addresses.

If hash reference, the keys are address (scalar), weight (positive rational number)

The server address is in the form host:port for network TCP connections

Client will distribute Data::WeightedRoundRobin.

=item $opts{timeout}

seconds until timeout (default: 10)

=back

=head2 my $res = $client->request($function_name, $args);

=over

=item $function_name

worker process function name.

=item $args

get over client argument for worker process.

$args must be single line data.

=back

=head2 my $res = $client->request_background($function_name, $args);

=over

=item $function_name

worker process function name.

=item $args

get over client argument for worker process.

$args must be single line data.

=item $res

When the worker accepts the background request and returns the "OK"

=back

=head2 my $res = $client->request_multi(\@args);

=over

=item $args->[$i]->{function}

worker process function name.

=item $args->[$i]->{args}

get over client argument for worker process.

$args must be single line data.

=item $res

worker response here.
The result is order request.

=back

=head2 my $res = $client->request_background_multi(\@args);

=over

=item $args->[$i]->{function}

worker process function name.

=item $args->[$i]->{args}

get over client argument for worker process.

$args must be single line data.

=item $res

worker response here.
The result is order request.

=back

=head1 SEE ALSO

L<Data::WeightedRoundRobin>

=cut

