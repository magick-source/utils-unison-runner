#!/usr/bin/perl

use strict;
use warnings;

use Config::Tiny;
use Getopt::Long;

my $config = Config::Tiny->new();


my $app = UnisonRunner->new($config);
$app->run();

package UnisonRunner;

use Moo;
use Gtk3 -init;

sub new {
  my ($class) = @_;

  my $self = bless {};

  my $icon = Gtk3::StatusIcon->new_from_file(
      "/usr/share/icons/gnome-colors-common/32x32/apps/bluefish.png"
    );

  $icon->set_title( 'Unison Runner' );

  $icon->signal_connect( 'popup-menu' => sub { $self->_popup_menu } );
  $icon->signal_connect( 'activate'   => sub { dump_params('activate', @_) } );

  $self->{icon} = $icon;

  my $timer = Glib::Timeout->add( 250 => sub { $self->handle_childs } );
  $self->{timer} = $timer;

  return $self;
}

sub run {
  Gtk3->main();
}

sub activate {

}

sub _popup_menu {
  my $menu = Gtk3::Menu->new();

  my $_mn_quit = Gtk3::ImageMenuItem->new_with_label("Quit");
  $_mn_quit->signal_connect( activate  => \&_end_runner );
  $menu->add( $_mn_quit );
 
  $menu->show_all;

  $app->{menu} = $menu;

  $menu->show;
  $menu->popup_at_pointer();

  return 1;
}

sub _end_runner {
  Gtk3->main_quit;
  return 0;
}

sub handle_childs {
  print STDERR time, ": handling childs\n";
}

sub dump_params {
  my @params = @_;

  use Data::Dumper;
  print STDERR "opened menu: ", Dumper( \@params );

  return 0;
}

