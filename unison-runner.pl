#!/usr/bin/perl

use strict;
use warnings;
use v5.18;

use Config::Tiny;
use Getopt::Long;

use POSIX qw(WNOHANG);

my $config;

my $fname       = "$ENV{HOME}/.config/unison-runner.cfg";
my $run_for     = 0;
my $end_at      = 0;
my $show_window = 0;

GetOptions(
    "config_file=s" => \$fname,
    "run_for=i"     => \$run_for,
    "show_window"   => \$show_window,
  );

if ($run_for) {
  $end_at = time + $run_for;
}

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

  my $max_syncs = $config->{_}->{max_children} || 2;
  my $netdir    = $config->{_}->{netroot} || "$ENV{HOME}/netdir";
  $netdir       = "$ENV{HOME}/$netdir" unless $netdir =~ m{\A/};

  my $frequency = $config->{_}->{frequency} || 300;

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

  my $icon = Gtk3::StatusIcon->new_from_icon_name( 'emblem-new' );

  $icon->set_title( 'Unison Runner' );

  $icon->signal_connect( 'popup-menu' => sub { $self->_popup_menu } );
  $icon->signal_connect( 'activate'   => sub { $self->activate } );

  $self->{icon} = $icon;

  my $timer = Glib::Timeout->add( 250 => sub { $self->on_timeout } );
  $self->{timer} = $timer;

  $self->activate if $show_window;

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

  return unless $sync{local} and $sync{remote};

  if (exists $cfg->{paths}) {
    my @paths = split /\s*,\s*/, $cfg->{paths};
    $sync{ paths } = \@paths;
  }

  if (exists $cfg->{ignore} ) {
    my @ignore = split /\s*,\s*/, $cfg->{ignore};
    $sync{ ignore } = \@ignore;
  }

  $sync{status} = 'new';

  return \%sync;
}

sub run {
  Gtk3->main();
}

sub on_timeout {
  my ($self) = @_;

  $self->stop
    if ($end_at and time > $end_at and !$self->{stopping});

  $self->handle_childs;

  return 1;
}

sub activate {
  my ($self) = @_;

  if (my $window = $self->{window}) {
    $window->present;
    return;
  }

  my $window = $self->{window} = Gtk3::Window->new;
  $window->set_title("Unison Runner Status");
  $window->set_border_width(10);

  $window->signal_connect (destroy => sub {
      delete $self->{window};
      delete $self->{objs};
    });

  my $main = Gtk3::VBox->new(0, 10);
  for my $sname (sort keys %{ $self->{_syncs} }) {
    my $sync = $self->{_syncs}->{$sname};
    $main->add( $self->_sync_frame( $sync ) );
  }

  my $frame = Gtk3::Frame->new();
  $main->add( $frame );

  my $hbox = Gtk3::HBox->new(0, 5);
  $hbox->set_border_width( 5 );
  $hbox->set_halign( 'end' );
  $frame->add( $hbox );

  my $button = Gtk3::Button->new_from_stock('gtk-close');
  $button->signal_connect( clicked => sub { $self->{window}->destroy; } );
  $hbox->add( $button );

  $button = Gtk3::Button->new_from_stock('gtk-quit');
  $button->signal_connect( clicked => sub { $self->_end_runner } );
  $hbox->add( $button );

  $window->add( $main );

  $window->show_all;

  return 1;
}

sub _sync_frame {
  my ($self, $sync) = @_;

  my $frame = Gtk3::Frame->new( " $sync->{name} " );

  my $hbox = Gtk3::HBox->new( 0, 5);
  $hbox->set_border_width( 5 );
  $frame->add( $hbox );

  my $icon = Gtk3::Image->new();
  $icon->set_valign('start');
  $hbox->add( $icon );


  my $vbox = Gtk3::VBox->new(0, 5);
  my $label = Gtk3::Label->new("local : $sync->{local}");
  $label->set_halign( 'start' );
  $vbox->add( $label );
  
  $label = Gtk3::Label->new("remote: $sync->{remote}");
  $label->set_halign( 'start' );
  $vbox->add( $label );

  my $slabel = Gtk3::Label->new("");
  $slabel->set_halign( 'start' );
  $vbox->add( $slabel );


  $vbox->add( Gtk3::HSeparator->new() );

  my $outbox = Gtk3::HBox->new( 0, 5 );
  my $olabel = Gtk3::Label->new('');
  $outbox->add( $olabel );

  my $imore = Gtk3::Button->new_from_icon_name('emblem-documents', 4);
  $imore->signal_connect( clicked => sub { $self->_show_output( $sync ) } );
  $outbox->add( $imore );

  $outbox->set_halign( 'start' );
  $vbox->add( $outbox );

  $self->{objs}->{ $sync->{name} } = {
      icon    => $icon,
      output  => $olabel,
      status  => $slabel,
    };

  $hbox->add( $vbox );

  $self->_update_sync( $sync );

  return $frame;
}

sub _update_sync {
  my ($self, $sync) = @_;

  return unless $self->{window} and $self->{objs};

  my $objs = $self->{objs}->{ $sync->{name} };

  my $iname = _icon_for_status( $sync->{status} );
  my $size = 5; # GTK_ICON_SIZE_DND (32px)
  $objs->{icon}->set_from_icon_name( $iname, $size );

  my $outend = (split /\n/, ($sync->{last_output}||''))[-1];
  $objs->{output}->set_text( $outend || '' );

  $objs->{status}->set_text("status: $sync->{status}");

  return;
}

sub _show_output {
  my ($self, $sync) = @_;

  if ( $self->{owindow} ) {
    $self->_update_output_window( $sync );
    return;
  }

  my $owindow = $self->{owindow} = Gtk3::Window->new();
  $owindow->set_border_width(10);
  $owindow->set_icon_name( 'emblem-documents' );
  $owindow->set_default_size( 350, 350 );

  $owindow->signal_connect (destroy => sub {
      delete $self->{owindow};
      delete $self->{otextbuffer};
    });

  my $vbox = Gtk3::VBox->new( 0, 5 );
  $owindow->add( $vbox );

  my $frame = Gtk3::Frame->new();
  $vbox->set_homogeneous(0);
  $vbox->add( $frame );

  my $swin = Gtk3::ScrolledWindow->new(undef, undef);
  $swin->set_policy( 'automatic', 'automatic' );
  $swin->set_shadow_type('in');
  $swin->set_halign('fill');
  $swin->set_valign('fill');
  $swin->set_hexpand( 1 );
  $swin->set_vexpand( 1 );

  $frame->add( $swin );

  my $otext = Gtk3::TextView->new();
  $self->{otextbuffer} = $otext->get_buffer();

  $swin->add( $otext );
 
  $frame = Gtk3::Frame->new();

  my $hbox = Gtk3::HBox->new(0, 5);
  $hbox->set_border_width( 5 );
  $hbox->set_halign( 'end' );
  $frame->add( $hbox );

  my $button = Gtk3::Button->new_from_stock('gtk-close');
  $button->signal_connect( clicked => sub { $self->{owindow}->destroy; } );
  $hbox->add( $button );
   
  $vbox->pack_end( $frame, 0, 1, 5 );

  $owindow->show_all;
  $self->_update_output_window( $sync );

  return;
}

sub _update_output_window {
  my ($self, $sync) = @_;

  my $owindow = $self->{owindow};
  $owindow->set_title("Output for sync '$sync->{name}'");

  my $buff = $self->{otextbuffer};
  $buff->set_text( $sync->{last_output}, length $sync->{last_output} );

  $owindow->present;

  return;
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
      $self->_handle_ending( $fin );
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

  unless ($to_run) {
    $self->_update_status();
    return;
  }

  $to_run->{status} = 'sync';

  my $child = $self->fork_child( sub {
      _sync_handler( $to_run );
    });
 
  $child->{sync_name} = $to_run->{name}
    if $child;

  $self->{_running}->{ $to_run->{name} } = $child;

  $self->_update_status( $to_run );

  return;
}

sub _icon_for_status {
  my ($status) = @_;

  my $iname = {
      ok      => 'emblem-default',
      new     => 'emblem-new',
      error   => 'emblem-important',
      skiped  => 'emblem-unreadable',
      sync    => 'emblem-synchronizing',
    }->{ $status } || 'emblem-generic';
 
  return $iname;
}

sub _update_status {
  my ($self, $sync) = @_;

  my $status;
  my %status = ();
  $status{ $_->{status} }++
    for values %{ $self->{_syncs} };
  for my $st (qw( sync error skiped new ok )) {
    if ( $status{ $st } ) {
      $status = $st;
      last;
    }
  }

  my $iname = _icon_for_status( $status );

  $self->{icon}->set_from_icon_name( $iname );
  if ( $self->{ window } ) {
    $self->{window}->set_icon_name( $iname );
    if ( $sync ) {
      $self->_update_sync( $sync );
    }
  }

  return;
}

sub _handle_ending {
  my ($self, $fin) = @_;

  my $sname = $fin->{sync_name};

  my $sync = $self->{_syncs}->{ $sname };
  $sync->{run_after} = time + $self->{__frequency};
  my $pid = $fin->{pid};

  $sync->{status} = $fin->{exit_code} ? 'error' : 'ok';

  delete $sync->{last_output};
  
  my $outfname = "/tmp/unirun.$pid.out";
  if ( -f $outfname ) {
    open my $fh, '<', $outfname;
    if ($fh) {
      local $/=undef;
      my $out = <$fh>;

      $sync->{last_output} = $out;

      if ($sync->{status} eq 'error') {
        if ($out =~ m{SKIPing}) {
          $sync->{status} = 'skiped';
        }
      }
      print STDERR "Error for $sname:\n$out\n------------\n\n"
        if $sync->{had_errors} and -t STDERR;

      close $fh;
    }

    unlink $outfname;
  }

  delete $self->{_running}->{ $sname };

  $self->_update_status( $sync );

  return;
}

sub _sync_handler {
  my ($to_run) = @_;

  my $bin  = '/usr/bin/unison'; 
  my @args = ('-log=false', '-auto', '-batch', '-fat');

  push @args, $to_run->{local}, $to_run->{remote};

  if ($to_run->{paths}) {
    push @args, '-path', $_
      for @{ $to_run->{paths} };
  }

  close STDERR;
  open STDERR, '>', "/tmp/unirun.$$.out";
  close STDOUT;
  open STDOUT, '>&', \*STDERR;

  print STDERR "remote: $to_run->{remote}\n";

  my @pargs = map { "'$_'" } @args;
  print STDERR "sync command: {\n $bin @pargs \n}\n";

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
      exit 1;
    }
  }

  # exec doesn't return
  # - which is what we want for any error to propagate
  exec { $bin } @args;
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
          $_->{exit_code} = $ec >> 8;
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
