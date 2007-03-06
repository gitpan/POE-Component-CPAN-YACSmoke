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
