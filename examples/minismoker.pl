use strict;
use POE qw(Component::CPAN::YACSmoke);
use Getopt::Long;

$|=1;

my ($perl, $jobs);

GetOptions( 'perl=s' => \$perl, 'jobs=s' => \$jobs );

my @pending;
if ( $jobs ) {
  open my $fh, "<$jobs" or die "$jobs: $!\n";
  while (<$fh>) {
        chomp;
        push @pending, $_;
  }
  close($fh);
}

my $smoker = POE::Component::CPAN::YACSmoke->spawn( alias => 'smoker',debug => 0, options => { trace => 0 } );

POE::Session->create(
	package_states => [
	   'main' => [ qw(_start _start_smoking _stop _results _recent _check) ],
	],
	heap => { perl => $perl, pending => \@pending },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $kernel->post( 'smoker', 'check', { event => '_check', perl => $heap->{perl} } );
  undef;
}

sub _check {
  my ($kernel,$heap,$job) = @_[KERNEL,HEAP,ARG0];
  unless ( $job->{status} == 0 ) {
     my $perl = $heap->{perl} || $^X;
     warn "$perl doesn't have CPAN::YACSmoke installed. Aborting\n";
     return;
  }
  $kernel->yield('_start_smoking');
  undef;
}

sub _start_smoking {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  if ( @{ $heap->{pending} } ) {
    $kernel->post( 'smoker', 'submit', { event => '_results', perl => $heap->{perl}, module => $_ } ) 
	for @{ $heap->{pending} };
  } 
  else {
    $kernel->post( 'smoker', 'recent', { event => '_recent', perl => $heap->{perl} } );
  }
  undef;
}

sub _stop {
  $poe_kernel->call( 'smoker', 'shutdown' );
  undef;
}

sub _results {
  my $job = $_[ARG0];
  print STDOUT "Module: ", $job->{module}, "\n";
  print STDOUT "$_\n" for @{ $job->{log} };
  undef;
}

sub _recent {
  my ($kernel,$heap,$job) = @_[KERNEL,HEAP,ARG0];
  $kernel->post( 'smoker', 'submit', { event => '_results', perl => $heap->{perl}, module => $_ } )
	for @{ $job->{recent} };
  undef;
}

__END__

=head1 NAME

minismoker.pl - Example script for POE::Component::CPAN::YACSmoke

=head1 SYNOPSIS

  perl minismoker.pl --perl /path/to/smoke/perl --jobs /path/to/file/with/jobs

=head1 DESCRIPTION

minismoker.pl is an example script for L<POE::Component::CPAN::YACSmoke>, a L<POE> based component
that provides L<CPAN::YACSmoke> services to other components and sessions.

It spits out the results of each smoke to STDOUT.

=head1 SWITCHES

=over

=item --perl

Specify the path to a perl executable to run the smoke testing with. This perl should have L<CPANPLUS>
and L<CPAN::YACSmoke> installed and configured accordingly.

=item --jobs

Specify a file with modules to be smoked, eg.

  C/CH/CHROMATIC/Acme-Incorporated-1.00.tar.gz
  B/BI/BINGOS/POE-Component-IRC-5.12.tar.gz

If a job file is not provided the script obtains a list of recently uploaded modules and processes
them.

=back

=head1 AUTHOR

Chris 'BinGOs' Williams <chris@bingosnet.co.uk>

=head1 SEE ALSO

L<POE::Component::CPAN::YACSmoke>

L<POE>

L<CPANPLUS>

L<CPAN::YACSmoke>
