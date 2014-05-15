use 5.005;

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
	NAME		=> "Mojolicious::Plugin::AppCacheManifest",
	ABSTRACT_FROM	=> "lib/Mojolicious/Plugin/AppCacheManifest.pm",
	VERSION_FROM	=> "lib/Mojolicious/Plugin/AppCacheManifest.pm",
	PREREQ_PM	=> {
		Mojolicious	=> 0,
	},
	AUTHOR		=> 'Simon Bertrang <janus@cpan.org>',
);

