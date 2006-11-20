use Test::More tests => 9;
BEGIN { use_ok('POE::Component::CPAN::YACSmoke') };
use POE;

my $perl = '/COMPLETELY/MADE/UP/PATH/TO/PERL';

my $smoker = POE::Component::CPAN::YACSmoke->spawn( alias => 'smoker',debug => 0, options => { trace => 0 } );

isa_ok( $smoker, 'POE::Component::CPAN::YACSmoke' );

POE::Session->create(
	package_states => [
	   'main' => [ qw(_start _stop _results _timeout) ],
	],
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $kernel->post( 'smoker', 'recent', 
	{ event => '_results', perl => $perl, '_ArBiTrArY' => 12345 } 
  );
  $kernel->delay( '_time_out', 60 );
  undef;
}

sub _stop {
  pass("Hey the poco let go of our refcount");
  $poe_kernel->call( 'smoker', 'shutdown' );
  undef;
}

sub _timeout {
  die "F**k it all went pear-shaped";
  undef;
}

sub _results {
  my $job = $_[ARG0];
  ok( $job->{$_}, "There was a $_" ) for qw(recent start_time end_time PID status);
  ok( $job->{_ArBiTrArY} eq '12345', "The Arbitary value can through unchanged" );
  $poe_kernel->delay( '_time_out' );
  undef;
}
