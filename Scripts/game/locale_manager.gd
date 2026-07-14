class_name LocaleManager

# Application-layer localization seam. Owns the list of shipped languages and
# the single choke point that pushes a chosen locale into Godot's
# TranslationServer. Kept out of the domain layer on purpose: it touches engine
# singletons (TranslationServer, OS), so it lives with the rest of the
# application glue and stays out of the pure/unit-testable rule classes.
#
# The translation catalogue itself is data, not code: locale/translations.csv
# (imported to res://locale/translations.*.translation, registered in
# project.godot → [internationalization]). Adding a language means adding a
# column to that CSV and an entry here — no code sweep. Adding a *string* means
# adding a row to the CSV and calling tr("KEY") at the display seam.
#
# The stored preference is a code string on PlayerPrefs.locale: "" means
# "follow the OS language" (resolved to a shipped locale, else English); a
# non-empty code ("en", "es") forces that language.

# Shipped languages, in menu order. `code` is the locale passed to
# TranslationServer / stored in prefs; `native_name` is what the picker shows
# (each language named in itself, the localization convention).
const SUPPORTED: Array[Dictionary] = [
	{"code": "en", "native_name": "English"},
	{"code": "es", "native_name": "Español"},
]

# Fallback when a stored/OS locale isn't one we ship. Matches
# project.godot → locale/fallback so tr() and the picker agree.
const DEFAULT_LOCALE: String = "en"


# Push `stored` (a PlayerPrefs.locale value) into the TranslationServer. Safe to
# call at any time; every UI tr() reads the active locale on its next build.
static func apply(stored: String) -> void:
	TranslationServer.set_locale(resolve(stored))


# Turn a stored preference into a concrete shipped locale code.
#   ""            → the OS language if we ship it, else DEFAULT_LOCALE
#   "en" / "es"   → that code if shipped, else DEFAULT_LOCALE
static func resolve(stored: String) -> String:
	if stored != "":
		return stored if is_supported(stored) else DEFAULT_LOCALE
	var os_lang: String = OS.get_locale_language()
	return os_lang if is_supported(os_lang) else DEFAULT_LOCALE


static func is_supported(code: String) -> bool:
	for entry: Dictionary in SUPPORTED:
		if entry["code"] == code:
			return true
	return false


# Index of a stored code within SUPPORTED, or -1 when it isn't an explicit
# shipped code (e.g. "" for "follow OS"). Drives the Options picker selection.
static func index_of(code: String) -> int:
	for i: int in SUPPORTED.size():
		if SUPPORTED[i]["code"] == code:
			return i
	return -1
