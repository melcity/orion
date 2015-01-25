#!/usr/bin/perl

# ORION - Automated timelapse image capture and stacking for Raspberry Pi and the Pi camera
# (c) 2015 David Ponevac (david at davidus dot sk) www.davidus.sk
#
# Main app
#
# version 1.0 [2015-01-23]

##
## libraries
##

use strict;
use warnings;

use Proc::Daemon;
use IO::All;
use Time::Piece;
use DateTime;
use DateTime::Event::Sunrise;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Orion::Helper qw(prepare_directory prepare_stack_command prepare_capture_command read_settings log_message);

##
## variables
##

my $imaging_flag_file = "/var/run/orion.imaging";
my $processing_flag_file = "/var/run/orion.processing";
my $temp_dir = "/var/www/temp";
my $temp_file = "orion-%08d.jpg";
my $destination_dir = "/var/www";
my $destination_file = "orion-%s.jpg";

my $email = undef;
my $url = "http://orion.davidus.sk/process.php";

my $longitude = -81.4622782;
my $latitude = 30.2416795;
my $altitude = -15;

my $timeout = 0;
my $timelapse = 1100;
my $iso = 400;
my $exposure = "night";
my $shutter_speed = 1000000;
my $quality = 80;
my $width = 800;
my $height = 600;

my ($destination, $command);
my $is_daemon = defined $ARGV[0] && $ARGV[0] eq "-d" ? 1 : 0;

##
## code
##

# init daemon
if ($is_daemon) {
	Proc::Daemon::Init;
	my $continue = 1;
	$SIG{TERM} = sub { $continue = 0; };
}

# main loop
while (1) {
	# get sunrise/sunset times
	my $sun = DateTime::Event::Sunrise->new(longitude => $longitude, latitude  => $latitude, altitude => $altitude);
	my $time_now = DateTime->now();
	my $sun_set = $sun->sunset_datetime($time_now);
	my $time_tomorrow = $sun_set->clone()->add_duration(DateTime::Duration->new(days => 1));
	my $sun_rise = $sun->sunrise_datetime($time_tomorrow);
	my $duration_minutes = $sun_rise->subtract_datetime($sun_set)->in_units("minutes");

	# read settings
	my %settings = read_settings("$Bin/../data/settings.json");

	# set variables
	$temp_dir = exists $settings{storage}{temp} ? $settings{storage}{temp} : $temp_dir;
	$destination_dir = exists $settings{storage}{final} ? $settings{storage}{final} : $destination_dir;

	$email = defined $settings{user}{email} ? defined $settings{user}{email} : undef;
	$url =  defined $settings{user}{url} ? defined $settings{user}{url} : undef;

	$longitude = exists $settings{location}{lon} ? $settings{location}{lon} * 1 : $longitude;
	$latitude = exists $settings{location}{lat} ? $settings{location}{lat} * 1 : $latitude;
	$altitude = exists $settings{location}{alt} ? $settings{location}{alt} * 1 : $altitude;

	$timeout = $duration_minutes * 60 * 1000;
	$timelapse = exists $settings{camera}{timelapse} ? $settings{camera}{timelapse} * 1 : $timelapse;
	$iso = exists $settings{camera}{iso} ? $settings{camera}{iso} * 1 : $iso;
	$exposure = exists $settings{camera}{exposure} ? $settings{camera}{exposure} : $exposure;
	$shutter_speed = exists $settings{camera}{shutter_speed} ? $settings{camera}{shutter_speed} * 1 : $shutter_speed;
	$quality = exists $settings{camera}{quality} ? $settings{camera}{quality} * 1 : $quality;
	$width = exists $settings{camera}{width} ? $settings{camera}{width} * 1 : $width;
	$height = exists $settings{camera}{height} ? $settings{camera}{height} * 1 : $height;

	# output some relevant info
	log_message("Latitude: " . $latitude . "\n", $is_daemon);
	log_message("Longitude: " . $longitude . "\n", $is_daemon);
	log_message("Altitude: " . $altitude . "\n\n", $is_daemon);

	log_message("Now: " . $time_now->datetime() . "\n", $is_daemon);
	log_message("Sunset: " . $sun_set->datetime() . "\n", $is_daemon);
	log_message("Sunrise: " . $sun_rise->datetime() . "\n", $is_daemon);
	log_message("Duration: " . $duration_minutes . "m\n\n", $is_daemon);

	log_message("Imaging duration: " . $timeout . "ms\n", $is_daemon);
	log_message("Time between shots: " . $timelapse . "ms\n", $is_daemon);
	log_message("Shutter speed: " . ($shutter_speed/1000) . "ms\n", $is_daemon);

	# prepare directories
	$temp_dir = prepare_directory($temp_dir);
	$destination_dir = prepare_directory($destination_dir);

	# capture if after sunset and before sunrise
	if ((DateTime->compare($time_now, $sun_rise) == -1) && (DateTime->compare($time_now, $sun_set) == 1)) {
		log_message("Starting imaging at " . localtime() . "\n", $is_daemon);

		# write flag
		`touch $imaging_flag_file`;

		# prepare temp file
		$destination = $temp_dir . "/" . $temp_file;

		# assemble command
		$command = prepare_capture_command($timeout, $timelapse, $iso, $exposure, 1, $shutter_speed, $quality, $width, $height, $destination);

		# take shots
		`$command`;

		# remove flag
		`rm -f $imaging_flag_file`;

		log_message("Stopped imaging at " . localtime() . "\n", $is_daemon);
	}

	# process images if any
	if (!io($temp_dir)->empty) {
		log_message("Starting stacking at " . localtime() . "\n", $is_daemon);

		# write flag
		`touch $processing_flag_file`;

		# prepare final image
		my $date = localtime()->strftime('%F');
		$destination = $destination_dir . "/" . sprintf($destination_file, $date);

		# assemble command
		$command = prepare_stack_command($temp_dir, $destination, "max");

		# stack
		`$command`;

		# remove flag
		`rm -f $processing_flag_file`;

		log_message("Stopped stacking at " . localtime() . "\n", $is_daemon);

		log_message("Cleaning up temp directory: " . $temp_dir . "\n", $is_daemon);

		# clean up
		`rm -f $temp_dir/*.jpg`;

		# upload to server
		if ($email && $url) {
			`curl -F"email=$email&lat=$latitude&lon=$longitude" -F"file=@$destination" $url`;
		}
	}

	log_message("--\n\n", $is_daemon);

	# mmm, delicious sleep
	sleep(30);
}
