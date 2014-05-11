package Mojolicious::Plugin::AppCacheManifest;

use Mojo::Base qw( Mojolicious::Plugin );

our $VERSION = "0.01";

sub parse
{
	my ( $self, $body ) = @_;

	return undef unless # check and remove header
	    $body =~ s!\A CACHE [ ] MANIFEST [ \t\r\n] \s* !!sx;

	# split sections by header; prepend header for initial section
	my @body = ( "CACHE", split( m/
	    ^ \s* ( CACHE | FALLBACK | NETWORK | SETTINGS ) \s* :? \s* \r?\n \s*
	/mx, $body ) );

	my %seen;
	my %manifest;

	while ( my $header = shift( @body ) ) {
		my @lines = grep( +(
		    ! m!\A [#] !x
		), split( m! \s* \r?\n \s* !x, shift( @body ) ) );

		push( @{ $manifest{ $header } }, map $header eq "FALLBACK" ? (
		    m!\A ( \S+ ) \s+ ( \S+ )!x && ! $seen{ $header, $1, $2 }++
		        ? ( $1, $2 ) : ()
		) : (
		    m!\A ( \S+ )            !x && ! $seen{ $header, $1 }++
		        ? ( $1 ) : ()
		), @lines );
	}

	return \%manifest;
}

sub max_last_modified
{
	my ( $self, $manifest, $path, $dirs ) = @_;
	my $maxmtime = ( stat( $path ) )[9];
	my @paths = map Mojo::URL->new( $_ )->path(), @{ $manifest->{CACHE} };

	for my $parts ( grep $_->[0] ne "..", map $_->canonicalize->parts(), @paths ) {
		my $path = join( "/", @$parts );
		my @stat;

		@stat = stat( "$_/$path" ) and last
			for @$dirs;

		$maxmtime = $stat[9] if @stat && $stat[9] > $maxmtime;
	}

	return Mojo::Date->new( $maxmtime );
}

sub generate
{
	my ( $self, $manifest, $date ) = @_;
	my @output = (
		"CACHE MANIFEST",
		"# $date",
	);

	push( @output, "CACHE:", @{ $manifest->{CACHE} } )
		if $manifest->{CACHE};

	if ( my $fallback = $manifest->{FALLBACK} ) {
		push( @output, "FALLBACK:", map +(
		    $fallback->[ $_ * 2 ] .
		    " " .
		    $fallback->[ $_ * 2 + 1 ]
		), 0 .. @$fallback / 2 - 1 );
	}

	push( @output, "$_:", @{ $manifest->{ $_ } } )
		for grep $manifest->{ $_ }, qw( SETTINGS NETWORK );

	return join( "\n", @output, "" ); # trailing newline
}

sub register
{
	my ( $self, $app, $conf ) = @_;
	my $extension = $conf->{extension} // "appcache";
	my $timeout = $conf->{timeout} // 60 * 5;
	my $re = join( "|", map quotemeta,
	    ref( $extension )
	     ?  @$extension
	     : ( $extension )
	);

	my $paths = $app->static->paths();

	$app->log->info( "setting up " . __PACKAGE__ . " $VERSION: @$paths" );

	$self->{timeout} = $timeout;

	$app->hook( after_dispatch => sub {
		my $tx = shift->tx();
		my $req = $tx->req();
		my $res = $tx->res();

		# skip it without a matching extension
		return unless
		    $req->url->path =~ m!\A .* \. (?: $re ) \z!x;

		return unless
		    ( $res->headers->content_type() // "" ) =~ m!\A text / cache \- manifest \b!x;


		# absolute path to source file
		my $path = $res->content->asset->path();

		# get static output
		my $body = $res->body();

		# 
		my $output = $self->_get_manifest( $app, $path, $body );

		# and deliver dynamic version instead
		$res->body( $output );
	} );
}

sub _get_manifest
{
	my ( $self, $app, $path, $cache ) = @_;
	my $log = $app->log();
	my $home = $app->home();
	my ( $dir ) = $path =~ m!\A (.*) / [^/]+ \z!x;

	# remove blank lines
	$cache =~ s! ^ \s* \r?\n !!gmx;

	# remove comments
	$cache =~ s! ^ \s* [#] .*? \r?\n !!gmx;

	# remove leading spaces
	$cache =~ s! ^ \s* !!gmx;

	# remove trailing spaces
	$cache =~ s! \s* $ !!gmx;


	my $resection = qr/CACHE[ ]MANIFEST|CACHE|NETWORK|FALLBACK/;

	my @cache = split( m/ ^ \s* ($resection) \s* :? \s* \r?\n /msx, $cache );

	# drop first empty element due to splitting
	if ( length( shift( @cache ) // "" ) ) {
		$log->error( "garbage before or no manifest header: $path" );
		return undef;
	}

	if ( $cache[0] ne "CACHE MANIFEST" ) {
		$log->error( "first line is not a cache manifest: $path" );
		return undef;
	}

	my %cache = map +(
		$cache[ $_ * 2 ],
		[ split( m!\r?\n!, $cache[ $_ * 2 + 1 ] ) ]
	), 0 .. @cache / 2 - 1;

	my %files = map +(
		map +( $_, undef ), @{ $cache{ $_ } }
	), "CACHE MANIFEST", "CACHE";

	my @files = sort( keys( %files ) );

	state %maxmtime;
	state %checktime;

	$maxmtime{ $path } //= 0;
	$checktime{ $path } //= 0;

	if ( ( my $time = time() ) > $checktime{ $path } + $self->{timeout} ) {
		$log->debug( "check file timestamps: $path" );

		for my $file ( @files ) {
			my $xpath;

			# with / relative to public dir
			if ( $file =~ m!\A /+ ( .*? ) \z!x ) {
				$xpath = $home->rel_file( $1 );
			}
			# urls are like / and match the public dir
			elsif ( $file =~ m!\A (?: https? : )? // [^/]+ /+ (.*?) \z!ix ) {
				$xpath = $home->rel_file( $1 );
			}
			# without / relative to appcache file
			else {
				$xpath = "$dir/$file";
			}

			my $mtime = stat( $xpath )
				? ( stat( _ ) )[9]
				: 0
			;

			$maxmtime{ $path } = $mtime
				if $mtime > $maxmtime{ $path };
		}

		$checktime{ $path } = $time;
	}

	my $output = sprintf( "CACHE MANIFEST\n# epoch: %s\nCACHE:\n%s\n",
		$maxmtime{ $path },
		join( "\n", @files )
	);

	if ( @{ $cache{"NETWORK"} || [] } > 0 ) {
		$output .= "NETWORK:\n"
			. join( "\n", @{ $cache{"NETWORK"} } ) . "\n"
		;
	}

	return $output;
}

1;

__END__

=head1 NAME

Mojolicious::Plugin::AppCacheManifest - Offline Web Applications support for Mojolicious

=head1 SYNOPSIS

=head2 Mojolicious::Lite

  # default usage with *.appcache
  plugin "AppCacheManifest";

  # switching to *.mf extension
  plugin "AppCacheManifest" => { extension => "mf" };

  # supporting multiple extensions
  plugin "AppCacheManifest" => { extension => [qw[ appcache manifest mf ]] };
 
=head2 Mojolicious

  # using the defaults
  sub startup {
    $self->plugin( "AppCacheManifest" );
  }

  # changing the cache timeout
  sub startup {
    $self->plugin( "AppCacheManifest" => { timeout => 10 } );
  }

=head1 DESCRIPTION

This plugin manages appcache manifest timeouts.
It scans the manifest, checks modification of individual files and returns accordingly.

=head1 SEE ALSO

=over 8

=item L<HTML5::Manifest>

different approach by generating a manifest programmatically

=back

=head1 AUTHOR

Simon Bertrang, E<lt>janus@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 by Simon Bertrang

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.18.2 or,
at your option, any later version of Perl 5 you may have available.

=cut

