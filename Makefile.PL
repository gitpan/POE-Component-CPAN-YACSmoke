use inc::Module::Install;
name 'POE-Component-CPAN-YACSmoke';
author 'Chris Williams <chris@bingosnet.co.uk>';
license 'perl';
version_from 'lib/POE/Component/CPAN/YACSmoke.pm';
abstract_from 'lib/POE/Component/CPAN/YACSmoke.pm';
build_requires 'Test::More' => 0.47;
requires 'POE' => 0.38;
requires 'File::Spec' => 0;
if ( $^O eq 'MSWin32' ) {
  requires 'Win32::Process' => 0;
  requires 'Win32::Job' => 0;
}
else {
  my $value = prompt( 'Do you want to enable optional Proc::ProcessTable support [y/N]?', 'N' );
  requires 'Proc::ProcessTable' => 0 if $value =~ /^Y/i;
}
install_script 'bin/minismoker';
WriteAll();
