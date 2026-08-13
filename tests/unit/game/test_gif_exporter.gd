extends GutTest

# GifExporter's pure path-building helpers. The encode itself is covered by
# test_gif_encoder.gd; what's here is the part that touches the filesystem with
# player-supplied text in it.


func test_slugify_keeps_alphanumerics_and_lowercases() -> void:
	assert_eq(GifExporter._slugify("Gretzky"), "gretzky", "plain name")
	assert_eq(GifExporter._slugify("MacKinnon99"), "mackinnon99", "digits kept")


func test_slugify_strips_path_and_shell_characters() -> void:
	# Scorer names are player-supplied and land in a filename, so anything that
	# would escape the clips directory or confuse a shell has to be gone.
	assert_eq(GifExporter._slugify("../../etc/passwd"), "etcpasswd", "path traversal")
	assert_eq(GifExporter._slugify("a/b\\c"), "abc", "separators")
	assert_eq(GifExporter._slugify("drop\"table'"), "droptable", "quotes")
	assert_eq(GifExporter._slugify("C:name"), "cname", "drive colon")


func test_slugify_collapses_spacing_runs_to_single_dashes() -> void:
	assert_eq(GifExporter._slugify("Wayne  Gretzky"), "wayne-gretzky", "double space")
	assert_eq(GifExporter._slugify("Wayne - Gretzky"), "wayne-gretzky", "spaced dash")


func test_slugify_trims_trailing_separators() -> void:
	assert_eq(GifExporter._slugify("Gretzky "), "gretzky", "trailing space")
	assert_eq(GifExporter._slugify("  "), "", "separators only")


func test_slugify_yields_empty_for_names_with_nothing_usable() -> void:
	# A name in a non-Latin script slugs to nothing; the caller must fall back to
	# the timestamp alone rather than producing a file called "goal_.gif".
	assert_eq(GifExporter._slugify("グレツキー"), "", "non-latin name")
	assert_eq(GifExporter._slugify(""), "", "empty name")


func test_slugify_bounds_length() -> void:
	var long_name: String = "a".repeat(200)
	assert_eq(GifExporter._slugify(long_name).length(), 32, "capped at 32 characters")


func test_export_is_refused_when_there_is_nothing_to_encode() -> void:
	var exporter := GifExporter.new()
	autofree(exporter)
	assert_false(exporter.export_frames([] as Array[Image], 20, "gretzky"),
			"empty frame list refused")
	assert_false(exporter.is_busy(), "no thread started")
