#!/usr/bin/perl

use strict;
use warnings;
use v5.18;

use Config::Tiny;
use Getopt::Long;

use POSIX qw(WNOHANG);

my $config;

my $fname = "$ENV{HOME}/.config/unison-runner.cfg";
print STDERR "fname: $fname\n";
if ( -f $fname ) {
  $config = Config::Tiny->read( $fname );
} else {
  $config = Config::Tiny->new();
}

my $app = UnisonRunner->new($config);
$app->run();

package UnisonRunner;

use Moo;
use Gtk3 -init;

sub FATAL;

sub new {
  my ($class, $config) = @_;

use Data::Dumper;
print STDERR Dumper( $config );

  my $max_syncs = $config->{_}->{max_children} || 2;
  my $netdir    = $config->{_}->{netroot} || "$ENV{HOME}/netdir";
  $netdir       = "$ENV{HOME}/$netdir" unless $netdir =~ m{\A/};

  my $frequency = $config->{_}->{frequency} || 60;

  my $self = bless {
      _childs       => [],
      _running      => {},
      __netdir      => $netdir,
      __max_syncs   => $max_syncs,
      __frequency   => $frequency,
    };

  my %syncs = ();
  for my $k (keys %$config) {
    next if $k eq '_';
   
    my $cfg = $config->{ $k };

    my $sync = $self->_parse_config( $cfg );
    if ($sync) {
      $sync->{name} = $k;
      $syncs{ $k } = $sync;
    }
  }

  $self->{_syncs} = \%syncs;
  use Data::Dumper;
  print STDERR Dumper( $self->{_syncs} );

  my $icon = Gtk3::StatusIcon->new_from_file(
      "/usr/share/icons/gnome-colors-common/32x32/apps/bluefish.png"
    );

  $icon->set_title( 'Unison Runner' );

  $icon->signal_connect( 'popup-menu' => sub { $self->_popup_menu } );
  $icon->signal_connect( 'activate'   => sub { dump_params('activate', @_) } );

  $self->{icon} = $icon;

  my $timer = Glib::Timeout->add( 250 => sub { $self->on_timeout } );
  $self->{timer} = $timer;

  return $self;
}

sub _parse_config {
  my ($self, $cfg) = @_;

  my %sync = ();
  if (exists $cfg->{local}) {
    my $local = $cfg->{local};
    $local = "$ENV{HOME}/$local" unless $local =~ m{\A/};

    $sync{ local } = $local;
  }

  if (exists $cfg->{remote} ) {
    my $remote = $cfg->{remote};
    $remote = "$self->{__netdir}/$remote"
      unless $remote =~ m{\A/} or $remote =~ m{\A\w+://};
    $sync{ remote } = $remote;
  }

  if (exists $cfg->{paths}) {
    my @paths = split /\s*,\s*/, $cfg->{paths};
    $sync{ paths } = \@paths;
  }

  if (exists $cfg->{ignore} ) {
    my @ignore = split /\s*,\s*/, $cfg->{ignore};
    $sync{ ignore } = \@ignore;
  }

  return \%sync;
}

sub run {
  Gtk3->main();
}

sub on_timeout {
  my ($self) = @_;

  $self->handle_childs;

  return 1;
}

sub activate {

}

sub _popup_menu {
  my ($self) = @_;

  my $menu = Gtk3::Menu->new();

  my $_mn_quit = Gtk3::ImageMenuItem->new_with_label("Quit");
  $_mn_quit->signal_connect( activate  => sub { $self->_end_runner } );
  $menu->add( $_mn_quit );
 
  $menu->show_all;

  $app->{menu} = $menu;

  $menu->show;
  $menu->popup_at_pointer();

  return 1;
}

sub _end_runner {
  my ($self) = @_;
  $self->stop;

  return 0;
}

sub handle_childs {
  my ($self) = @_;
  
  my $done = 0;
  my $finished = $self->wait_for_children();
  if ( @$finished ) {
    for my $fin (@$finished) {
      my $sname = $fin->{sync_name};

      my $sync = $self->{_syncs}->{ $sname };
      $sync->{run_after} = time + $self->{__frequency};

      delete $self->{_running}->{ $sname };
    }
  }

  return Gtk3->main_quit()
    if ( $self->{stopping} and !(@{$self->{_childs}}) );

  my $running = scalar @{ $self->{_childs} };
  return if $running >= $self->{__max_syncs};

  my ($to_run) = grep {
      (($_->{ run_after} || 0 ) < time)
      and !$self->{_running}->{ $_->{name} }
    } values %{ $self->{_syncs} };

  return unless $to_run;

  my $child = $self->fork_child( sub {
      _sync_handler( $to_run );
    });
 
  $child->{sync_name} = $to_run->{name}
    if $child;

  $self->{_running}->{ $to_run->{name} } = $child;

  print STDERR time, ": handling childs\n";
}


sub _sync_handler {
  my ($to_run) = @_;
 
  my @parts = ('/usr/bin/unison', '-auto', '-batch', '-smb');

  push @parts, $to_run->{local}, $to_run->{remote};

  if ($to_run->{paths}) {
    push @parts, '-path', $_
      for @{ $to_run->{paths} };
  }

  print STDERR "remote: $to_run->{remote}\n";
  if ( $to_run->{remote} =~ m{\A/} ) {
    # just checking is not enough in the cases where
    # the path is part of a smbnetfs mountpoint
    # as it says that the directory exists
    # but only allows you to read it if it really exists
    my $error = 0;
    opendir(my $dir, $to_run->{remote}) || do { $error = 1 };
    my @files;
    if (!$error ) {
      @files = readdir $dir;
    }

    unless ( $dir and @files ) {
      print STDERR "$$: remote '$to_run->{remote}' is missing - SKIPing\n";
      return;
    }
  }

  use Data::Dumper;
  print STDERR "$$: running: ", Dumper( $to_run => \@parts);

  sleep 2;

  print STDERR "$$: runned\n";

  return;
}

sub dump_params {
  my @params = @_;

  use Data::Dumper;
  print STDERR "opened menu: ", Dumper( \@params );

  return 0;
}

# Handle forks and waiting for them
sub fork_child {
  my ($self, $sub) = @_;

  my $pid = fork;
  if ($pid) {
    my %pid = (
        pid         => $pid,
        start_time  => time,
      );

    push @{ $self->{_childs} }, \%pid;

    return \%pid;

  } elsif (defined $pid) {
    srand();
    eval {
      $sub->();
      1;
    } or do {
      my $err = $@ || 'Zombie error';
      FATAL "Error in child process: ", $err;
    };

    exit 0;
  }

  FATAL "Could not fork child process: $!";
}

sub wait_for_children {
  my ($self) = @_;

  my @done;

  @{ $self->{_childs} } = grep {
      print STDERR "checking $_->{pid}\n";
      my $pid = waitpid $_->{pid}, POSIX::WNOHANG;

      if ($pid) {
        my $ec = $?;
        if ($ec & 127) {
          $_->{exit_code} = $ec;
          $_->{exit_with_signal} = ($ec & 127);
          $_->{exit_with_coredump} = !!($ec & 128);
        } else {
          $_->{exit_cocde} = $ec >> 8;
        }

        $_->{exit_time} = time;
        $_->{elapsed_time} = $_->{exit_time} - $_->{start_time};

        push @done, $_;
      }

      !$pid;
    } @{ $self->{_childs} };

  return \@done;
}

sub stop {
  my ($self) = @_;

  $self->{stopping} = 1;
}

sub FATAL {
  # We need to do this differently - because we want to show this errors
  #   in the GTK app.
  print STDERR  "FATAL :", @_,"\n\n";
}
