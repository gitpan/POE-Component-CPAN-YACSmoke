package POE::Component::CPAN::YACSmoke;

use strict;
use POE qw(Wheel::Run);
use vars qw($VERSION);

$VERSION = '0.23';

my $GOT_KILLFAM;

BEGIN {
	$GOT_KILLFAM = 0;
	eval {
		require Proc::ProcessTable;
		$GOT_KILLFAM = 1;
	};
}

sub spawn {
  my $package = shift;
  my %opts = @_;
  $opts{lc $_} = delete $opts{$_} for keys %opts;
  my $options = delete $opts{options};

  if ( $^O eq 'MSWin32' ) {
    eval    { require Win32; };
    if ($@) { die "Win32 but failed to load:\n$@" }
    eval    { require Win32::Job; };
    if ($@) { die "Win32::Job but failed to load:\n$@" }
    eval    { require Win32::Process; };
    if ($@) { die "Win32::Process but failed to load:\n$@" }
  }

  my $self = bless \%opts, $package;
  $self->{session_id} = POE::Session->create(
	object_states => [
	   $self => { shutdown  => '_shutdown', 
		      submit    => '_command',
		      push      => '_command',
		      unshift   => '_command',
		      recent    => '_command',
		      check     => '_command',
		      indices   => '_command',
		      author    => '_command',
		      flush	=> '_command',
		      'package' => '_command',
	   },
	   $self => [ qw(_start _spawn_wheel _wheel_error _wheel_closed _wheel_stdout _wheel_stderr _wheel_idle _sig_child) ],
	],
	heap => $self,
	( ref($options) eq 'HASH' ? ( options => $options ) : () ),
  )->ID();
  return $self;
}

sub session_id {
  return $_[0]->{session_id};
}

sub pending_jobs {
  return @{ $_[0]->{job_queue} };
}

sub shutdown {
  my $self = shift;
  $poe_kernel->post( $self->{session_id}, 'shutdown' );
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{session_id} = $_[SESSION]->ID();
  if ( $self->{alias} ) {
	$kernel->alias_set( $self->{alias} );
  } else {
	$kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
  }
  $self->{job_queue} = [ ];
  $self->{idle} = 600 unless $self->{idle};
  undef;
}

sub _shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->alias_remove( $_ ) for $kernel->alias_list();
  $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ ) unless $self->{alias};
  $kernel->refcount_decrement( $_->{session}, __PACKAGE__ ) for @{ $self->{job_queue} };
  $self->{_shutdown} = 1;
  undef;
}

sub _command {
  my ($kernel,$self,$state,$sender) = @_[KERNEL,OBJECT,STATE,SENDER];
  return if $self->{_shutdown};
  my $args;
  if ( ref( $_[ARG0] ) eq 'HASH' ) {
	$args = { %{ $_[ARG0] } };
  } else {
	$args = { @_[ARG0..$#_] };
  }

  $state = 'push' if $state eq 'submit';

  $args->{lc $_} = delete $args->{$_} for grep { $_ !~ /^_/ } keys %{ $args };

  my $ref = $kernel->alias_resolve( $args->{session} ) || $sender;
  $args->{session} = $ref->ID();

  if ( !$args->{module} and $state !~ /^(recent|check|indices|package|author|flush)$/i ) {
	warn "No 'module' specified for $state";
	return;
  }

  unless ( $args->{event} ) {
	warn "No 'event' specified for $state";
	return;
  }

  if ( $state =~ /^(package|author)$/ and !$args->{search} ) {
	warn "No 'search' criteria specified for $state";
	return;
  }

  if ( $state eq 'recent' ) {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_recent_modules;
	$args->{program_args} = [ $args->{perl} || $^X ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	my $code = 'my $smoke = CPAN::YACSmoke->new(); print "$_\n" for $smoke->{plugin}->download_list();';
	$args->{program} = [ $perl, '-MCPAN::YACSmoke', '-e', $code ];
    }
  }
  elsif ( $state eq 'check' ) {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_check_yacsmoke;
	$args->{program_args} = [ $args->{perl} || $^X ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	$args->{program} = [ $perl, '-MCPAN::YACSmoke', '-e', 1 ];
    }
    $args->{debug} = 1;
  }
  elsif ( $state eq 'indices' ) {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_reload_indices;
	$args->{program_args} = [ $args->{perl} || $^X ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	my $code = 'CPANPLUS::Backend->new()->reload_indices( update_source => 1 );';
	$args->{program} = [ $perl, '-MCPANPLUS::Backend', '-e', $code ];
    }
  }
  elsif ( $state eq 'author' ) {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_author_search;
	$args->{program_args} = [ $args->{perl} || $^X, $args->{type} || 'cpanid', $args->{search} ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	my $code = 'my $type = shift; my $search = shift; my $cb = CPANPLUS::Backend->new(); my %mods = map { $_->package() => 1 } map { $_->modules() } $cb->search( type => $type, allow => [ qr/$search/ ], [ verbose => 0 ] ); print qq{$_\n} for sort keys %mods;';
	$args->{program} = [ $perl, '-MCPANPLUS::Backend', '-e', $code, $args->{type} || 'cpanid', $args->{search} ];
    }
  }
  elsif ( $state eq 'package' ) {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_package_search;
	$args->{program_args} = [ $args->{perl} || $^X, $args->{type} || 'package', $args->{search} ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	my $code = 'my $type = shift; my $search = shift; my $cb = CPANPLUS::Backend->new(); my %mods = map { $_->package() => 1 } $cb->search( type => $type, allow => [ qr/$search/ ], [ verbose => 0 ] ); print qq{$_\n} for sort keys %mods;';
	$args->{program} = [ $perl, '-MCPANPLUS::Backend', '-e', $code, $args->{type} || 'package', $args->{search} ];
    }
  }
  elsif ( $state eq 'flush' ) {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_flush;
	$args->{program_args} = [ $args->{perl} || $^X, ( $args->{type} eq 'all' ? 'all' : 'old' ) ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	my $code = 'my $type = shift; my $smoke = CPAN::YACSmoke->new(); $smoke->flush($type) if $smoke->can("flush");';
	$args->{program} = [ $perl, '-MCPAN::YACSmoke', '-e', $code, ( $args->{type} eq 'all' ? 'all' : 'old' ) ];
    }
  }
  else {
    if ( $^O eq 'MSWin32' ) {
	$args->{program} = \&_test_module;
	$args->{program_args} = [ $args->{perl} || $^X, $args->{module} ];
    }
    else {
	my $perl = $args->{perl} || $^X;
	my $code = 'my $module = shift; my $smoke = CPAN::YACSmoke->new(); $smoke->test($module);';
	$args->{program} = [ $perl, '-MCPAN::YACSmoke', '-e', $code, $args->{module} ];
    }
  }

  $kernel->refcount_increment( $args->{session}, __PACKAGE__ );

  $args->{cmd} = $state;

  if ( $state eq 'unshift' or $state eq 'recent' ) {
    unshift @{ $self->{job_queue} }, $args;
  }
  else {
    push @{ $self->{job_queue} }, $args;
  }

  $kernel->yield( '_spawn_wheel' );

  undef;
}

sub _sig_child {
  my ($kernel,$self,$thing,$pid,$status) = @_[KERNEL,OBJECT,ARG0..ARG2];
  push @{ $self->{_wheel_log} }, "$thing $pid $status";
  warn "$thing $pid $status\n" if $self->{debug};
  $kernel->delay( '_wheel_idle' );
  my $job = delete $self->{_current_job};
  $job->{status} = $status;
  my $log = delete $self->{_wheel_log};
  if ( $job->{cmd} eq 'recent' ) {
    pop @{ $log };
    s/\x0D$// for @{ $log };
    $job->{recent} = $log;
  }
  elsif ( $job->{cmd} =~ /^(package|author)$/ ) {
    pop @{ $log };
    s/\x0D$// for @{ $log };
    @{ $job->{results} } = grep { $_ !~ /^\[/ } @{ $log };
  }
  else {
    $job->{log} = $log;
  }
  $job->{end_time} = time();
  unless ( $self->{debug} ) {
    delete $job->{program}; 
    delete $job->{program_args};
  }
  $self->{debug} = delete $job->{global_debug};
  $kernel->post( $job->{session}, $job->{event}, $job );
  $kernel->refcount_decrement( $job->{session}, __PACKAGE__ );
  $kernel->yield( '_spawn_wheel' );
  $kernel->sig_handled();
}

sub _spawn_wheel {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  return if $self->{wheel};
  return if $self->{_shutdown};
  my $job = shift @{ $self->{job_queue} };
  return unless $job;
  $self->{wheel} = POE::Wheel::Run->new(
    Program     => $job->{program},
    ProgramArgs => $job->{program_args},
    StdoutEvent => '_wheel_stdout',
    StderrEvent => '_wheel_stderr',
    ErrorEvent  => '_wheel_error',
    CloseEvent  => '_wheel_close',
  );
  unless ( $self->{wheel} ) {
	warn "Couldn\'t spawn a wheel for $job->{module}\n";
	$kernel->refcount_decrement( $job->{session}, __PACKAGE__ );
	return;
  }
  if ( defined $job->{debug} ) {
	$job->{global_debug} = delete $self->{debug};
	$self->{debug} = $job->{debug};
  }
  $self->{_wheel_log} = [ ];
  $self->{_current_job} = $job;
  $job->{PID} = $self->{wheel}->PID();
  $job->{start_time} = time();
  $kernel->sig_child( $job->{PID}, '_sig_child' );
  $kernel->delay( '_wheel_idle', 60 ) unless $job->{cmd} eq 'indices';
  undef;
}

sub _wheel_error {
  $poe_kernel->delay( '_wheel_idle' );
  delete $_[OBJECT]->{wheel};
  undef;
}

sub _wheel_closed {
  $poe_kernel->delay( '_wheel_idle' );
  delete $_[OBJECT]->{wheel};
  undef;
}

sub _wheel_stdout {
  my ($self, $input, $wheel_id) = @_[OBJECT, ARG0, ARG1];
  $self->{_wheel_time} = time();
  push @{ $self->{_wheel_log} }, $input;
  warn $input, "\n" if $self->{debug};
  undef;
}

sub _wheel_stderr {
  my ($self, $input, $wheel_id) = @_[OBJECT, ARG0, ARG1];
  $self->{_wheel_time} = time();
  if ( $^O eq 'MSWin32' and !$self->{_current_job}->{GRP_PID} and my ($pid) = $input =~ /(\d+)/ ) {
     $self->{_current_job}->{GRP_PID} = $pid;
     warn "Grp PID: $pid\n" if $self->{debug};
     return;
  }
  push @{ $self->{_wheel_log} }, $input unless $self->{_current_job}->{cmd} eq 'recent';
  warn $input, "\n" if $self->{debug};
  undef;
}

sub _wheel_idle {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  if ( time() - $self->{_wheel_time} >= $self->{idle} ) {
    push @{ $self->{_wheel_log} }, "Killing current run due to excessive idle";
    warn "Killing current run due to excessive idle\n" if $self->{debug};
    if ( $^O eq 'MSWin32' and $self->{wheel} ) {
	my $grp_pid = $self->{_current_job}->{GRP_PID};
	return unless $grp_pid;
	unless( Win32::Process::KillProcess( $grp_pid, 0 ) ) {
	   warn Win32::FormatMessage( Win32::GetLastError() );
	}
    }
    else {
      if ( $GOT_KILLFAM ) {
	_kill_family( 9, $self->{wheel}->PID() ) if $self->{wheel};
      }
      else {
        $self->{wheel}->kill(9) if $self->{wheel};
      }
    }
  } 
  else {
    $kernel->delay( '_wheel_idle', 60 );
  }
  return;
}

sub _check_yacsmoke {
  my $perl = shift;
  my $cmdline = $perl . q{ -MCPAN::YACSmoke -e 1};
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}

sub _test_module {
  my $perl = shift;
  my $module = shift;
  my $cmdline = $perl . ' -MCPAN::YACSmoke -e "my $module = shift; my $smoke = CPAN::YACSmoke->new(); $smoke->test($module);" ' . $module;
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}

sub _flush {
  my $perl = shift;
  my $type = shift;
  my $cmdline = $perl . ' -MCPAN::YACSmoke -e "my $type = shift; my $smoke = CPAN::YACSmoke->new(); $smoke->flush($type) if $smoke->can(q{flush});" ' . $type;
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}
sub _recent_modules {
  my $perl = shift;
  my $cmdline = $perl . ' -MCPAN::YACSmoke -e "my $smoke = CPAN::YACSmoke->new();print qq{$_\n} for $smoke->{plugin}->download_list();"';
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}

sub _reload_indices {
  my $perl = shift;
  my $cmdline = $perl . ' -MCPANPLUS::Backend -e "CPANPLUS::Backend->new()->reload_indices( update_source => 1 );"';
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}

sub _author_search {
  my $perl = shift;
  my $type = shift;
  my $search = shift;
  my $cmdline = $perl . ' -MCPAN::YACSmoke -e "my $type = shift; my $search = shift; my $cb = CPANPLUS::Backend->new(); my %mods = map { $_->package() => 1 } map { $_->modules() } $cb->search( type => $type, allow => [ qr/$search/ ], [ verbose => 0 ] ); print qq{$_\n} for sort keys %mods;" ' . $type . " " . $search;
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}

sub _package_search {
  my $perl = shift;
  my $type = shift;
  my $search = shift;
  my $cmdline = $perl . ' -MCPAN::YACSmoke -e "my $type = shift; my $search = shift; my $cb = CPANPLUS::Backend->new(); my %mods = map { $_->package() => 1 } $cb->search( type => $type, allow => [ qr/$search/ ], [ verbose => 0 ] ); print qq{$_\n} for sort keys %mods;" ' . $type . " " . $search;
  my $job = Win32::Job->new()
    or die Win32::FormatMessage( Win32::GetLastError() );
  my $pid = $job->spawn( $perl, $cmdline )
    or die Win32::FormatMessage( Win32::GetLastError() );
  warn $pid, "\n";
  my $ok = $job->watch( sub { 0 }, 60 );
  my $hashref = $job->status();
  exit( $hashref->{$pid}->{exitcode} );
}

sub _kill_family {
  my ($signal, @pids) = @_;
  my $pt = Proc::ProcessTable->new;
  my (@procs) =  @{$pt->table};
  my (@kids) = _get_pids( \@procs, @pids );
  @pids = (@pids, @kids);
  kill $signal, reverse @pids;
}

sub _get_pids {
  my($procs, @kids) = @_;
  my @pids;
  foreach my $kid (@kids) {
    foreach my $proc (@$procs) {
      if ($proc->ppid == $kid) {
	my $pid = $proc->pid;
	push @pids, $pid, _get_pids( $procs, $pid );
      } 
    }
  }
  @pids;
}

1;
__END__

=head1 NAME

POE::Component::CPAN::YACSmoke - bringing the power of POE to CPAN smoke testing.

=head1 SYNOPSIS

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
  
  my $smoker = POE::Component::CPAN::YACSmoke->spawn( alias => 'smoker' );
  
  POE::Session->create(
  	package_states => [
  	   'main' => [ qw(_start _stop _results _recent) ],
  	],
  	heap => { perl => $perl, pending => \@pending },
  );
  
  $poe_kernel->run();
  exit 0;
  
  sub _start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];
    if ( @{ $heap->{pending} } ) {
      $kernel->post( 'smoker', 'submit', { event => '_results', perl => $heap->{perl}, module => $_ } ) 
  	for @{ $heap->{pending} };
    }
    else {
      $kernel->post( 'smoker', 'recent', { event => '_recent', perl => $heap->{perl} } ) 
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

  
=head1 DESCRIPTION

POE::Component::CPAN::YACSmoke is a POE-based framework around L<CPANPLUS> and L<CPAN::YACSmoke>.
It receives submissions from other POE sessions, spawns a L<POE::Wheel::Run> to deal with running
CPAN::YACSmoke, captures the output and returns the results to the requesting session.

Only one job request may be processed at a time. If a job is in progress, any jobs submitted are
added to a pending jobs queue.

By default the component uses POE::Wheel::Run to fork another copy of the currently executing perl,
worked out from $^X. You can specify a different perl executable to use though. MSWin32 users please
see the section of this document relating to your platform.

You are responsible for installing and configuring L<CPANPLUS> and L<CPAN::YACSmoke> and setting up
a suitable perl smoking environment.

=head1 CONSTRUCTOR

=over

=item spawn

Spawns a new component session and waits for requests. Takes the following optional arguments:

  'alias', set an alias to send requests to later;
  'options', specify some POE::Session options;
  'debug', see lots of text on your console;
  'idle', adjust the job idle time ( default: 600 seconds ), before jobs get killed;

Returns a POE::Component::CPAN::YACSmoke object.

=back

=head1 METHODS

=over

=item session_id

Returns the POE::Session ID of the component's session.

=item pending_jobs

In a scalar context returns the number of currently pending jobs. In a list context, returns a list of hashrefs
which are the jobs currently waiting in the job queue.

=item shutdown

Terminates the component. Any pending jobs are cancelled and the currently running job is allowed to complete gracefully. Requires no additional parameters.

=back

=head1 INPUT EVENTS

All the events that the component will accept (unless noted otherwise ) require one parameter, a hashref with the following keys defined ( mandatory requirements are shown ):

  'event', an event name for the results to be sent to (Mandatory);
  'module', a module to test, this is passed to CPAN::YACSmoke's test() method
	    so whatever that requires should work (Mandatory);
  'session', which session the result event should go to (Default is the sender);
  'perl', which perl executable to use (Default whatever is in $^X);
  'debug', turn on or off debugging information for this particular job;

It is possible to pass arbitrary keys in the hash. These should be proceeded with an underscore to avoid
possible future API clashes.

=over

=item submit

=item push

Inserts the requested job at the end of the queue ( if there is one ).

=item unshift

Inserts the requested job at the head of the queue ( if there is one ). Guarantees that that job is processed next.

=item shutdown

Terminates the component. Any pending jobs are cancelled and the currently running job is allowed to complete gracefully. Requires no additional parameters.

=item recent

Obtain a list of recent uploads to CPAN.

Takes one parameter, hashref with the following keys defined:

  'event', an event name for the results to be sent to (Mandatory);
  'session', which session the result event should go to (Default is the sender);
  'perl', which perl executable to use (Default whatever is in $^X);

It is possible to pass arbitrary keys in the hash. These should be proceeded with an underscore to avoid
possible future API clashes.

=item author

Obtain a list of distributions for a given author.

Takes one parameter, a hashref with the following keys defined:

  'event', an event name for the results to be sent to (Mandatory);
  'session', which session the result event should go to (Default is the sender);
  'perl', which perl executable to use (Default whatever is in $^X);
  'type', specify the type of search to conduct, 'cpanid', 'author' or 'email', default is 'cpanid';
  'search', a string representing the search criteria to use (Mandatory);

It is possible to pass arbitrary keys in the hash. These should be proceeded with an underscore to avoid
possible future API clashes.

=item package

obtain a list of distributions given criteria to search for.

Takes one parameter, a hashref with the following keys defined:

  'event', an event name for the results to be sent to (Mandatory);
  'session', which session the result event should go to (Default is the sender);
  'perl', which perl executable to use (Default whatever is in $^X);
  'type', specify the type of search to conduct, 'package', 'name', etc., default is 'package';
  'search', a string representing the search criteria to use (Mandatory);

It is possible to pass arbitrary keys in the hash. These should be proceeded with an underscore to avoid
possible future API clashes.

=item check

Checks whether L<CPAN::YACSmoke> is installed. Takes one parameter a hashref with the following keys 
defined:

  'event', an event name for the results to be sent to (Mandatory);
  'session', which session the result event should go to (Default is the sender);
  'perl', which perl executable to use (Default whatever is in $^X);

It is possible to pass arbitrary keys in the hash. These should be proceeded with an underscore to avoid
possible future API clashes.
  
=item indices

Forces an update of the CPANPLUS indices. Takes one parameter, a hashref with the following keys defined:

  'event', an event name for the results to be sent to (Mandatory);
  'session', which session the result event should go to (Default is the sender);
  'perl', which perl executable to use (Default whatever is in $^X);

It is possible to pass arbitrary keys in the hash. These should be proceeded with an underscore to avoid
possible future API clashes.

=back

=head1 OUTPUT EVENTS

Resultant events will have a hashref as ARG0. All the keys passed in as part of the original request will be present
(including arbitrary underscore prefixed ones), with the addition of the following keys:

  'log', an arrayref of STDOUT and STDERR produced by the job;
  'PID', the process ID of the POE::Wheel::Run;
  'status', the $? of the process;
  'start_time', the time in epoch seconds when the job started running;
  'end_time', the time in epoch seconds when the job finished;

The results of a 'recent' request will be same as above apart from an additional key:

  'recent', an arrayref of recently uploaded modules;

The results of a 'package' or 'author' search will be same as other events apart from an additional key:

  'results', an arrayref of the modules returned by the search;

=head1 MSWin32

POE::Component::CPAN::YACSmoke now supports MSWin32 in the same manner as other platforms. L<Win32::Process> is
used to fix the issues surrounding L<POE::Wheel::Run> and forking alternative copies of the perl executable.

The code is still experimental though. Be warned.

=head1 AUTHOR

Chris 'BinGOs' Williams <chris@bingosnet.co.uk>

=head1 KUDOS

Many thanks to all the people who have helped me with developing this module.

Specially to Jos Boumans, the L<CPANPLUS> dude, who has patiently corrected me when
I have asked stupid questions and speedily fixed CPANPLUS when I made disgruntled remarks
about bugs >:)

And to Robert Rothenberg and Barbie for L<CPAN::YACSmoke>.

=head1 SEE ALSO

L<minismoker>

L<POE>

L<CPANPLUS>

L<CPAN::YACSmoke>

L<http://use.perl.org/~BinGOs/journal/>
