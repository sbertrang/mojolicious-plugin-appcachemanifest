package Mojolicious::Plugin::AppCacheManifest;

use Mojo::Base qw( Mojolicious::Plugin );

our $VERSION = "0.01";
our %MANIFEST;

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
	my $redir = qr!\A (.*?) /+ [^/]+ \. (?: $re ) \z!x;
	my $retype = qr!\A text / cache \- manifest \b!x;
	my $dirs = $app->static->paths();

	$app->log->info( "setting up " . __PACKAGE__ . " $VERSION: @$dirs" );
	$app->hook( after_dispatch => sub {
		my $tx = shift->tx();
		my $req = $tx->req();
		my $res = $tx->res();

		return unless # extension matches
		    my ( $dir ) = $req->url->path() =~ $redir;

		return unless # mime type matches as well
		    ( $res->headers->content_type() // "" ) =~ $retype;

		my $path = $res->content->asset->path();
		my $mtime = ( stat( $path ) )[9];
		my $time = time();
		my $last_modified;
		my $output;

		if ( exists( $MANIFEST{ $path } ) &&
		             $MANIFEST{ $path }[0] >= $mtime &&
		             $MANIFEST{ $path }[1] + $timeout > $time ) {
			$last_modified = $MANIFEST{ $path }[2];
			$output = $MANIFEST{ $path }[3];
		}
		else {
			my $manifest = $self->parse( $res->body() );

			$last_modified = $self->max_last_modified( $manifest, $path, $dirs, $mtime );
			$output = $self->generate( $manifest, $last_modified );

			$MANIFEST{ $path } = [ $last_modified->epoch(), $time, $last_modified, $output ]
				if $timeout > 0;
		}

		$res->headers->last_modified( $last_modified );
		$res->body( $output );
	} );
}

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
	my ( $self, $manifest, $path, $dirs, $maxmtime ) = @_;
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

1;

__END__

=head1 NAME

Mojolicious::Plugin::AppCacheManifest - Offline Web Applications support for Mojolicious

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin( "AppCacheManifest" );
  $self->plugin( "AppCacheManifest" => { extension => "manifest" } );
  $self->plugin( "AppCacheManifest" => { extension => [qw[ appcache manifest mf ]] } );
  $self->plugin( "AppCacheManifest" => { timeout => 0 } );
  
  # Mojolicious::Lite
  plugin "AppCacheManifest";
  plugin "AppCacheManifest" => { extension => "manifest" };
  plugin "AppCacheManifest" => { extension => [qw[ appcache manifest mf ]] };
  plugin "AppCacheManifest" => { timeout => 0 };

=head1 DESCRIPTION

This plugin manages appcache manifest timeouts.
It scans the manifest, checks modification of individual files and returns accordingly.

=head1 OPTIONS

=head2 extension

  # Mojolicious::Lite
  plugin "AppCacheManifest" => { extension => "manifest" };
  plugin "AppCacheManifest" => { extension => [qw[ appcache manifest mf ]] };

Manifest file extension, defaults to C<appcache> and allows array references
to pass multiple extensions.

=head2 timeout

  # Mojolicious::Lite
  plugin "AppCacheManifest" => { timeout => 0 };

Cache timeout after which manifests get fully checked again, defaults to
C<600> seconds (5 minutes). A timeout of C<0> disables the memory cache.

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
it under the same terms as Perl itself.

=cut

