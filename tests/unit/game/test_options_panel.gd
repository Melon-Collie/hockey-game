extends GutTest

# Guards the Options panel after its split into per-tab scripts
# (Scripts/ui/options/*). Two things it protects:
#
# 1. Compile guard — the tab scripts have class_names but are only instanced by
#    OptionsPanel at runtime, so a parse error (bad type, renamed PlayerPrefs
#    field) would otherwise never surface in tests.
# 2. Key-partition invariant — the panel's dirty-compare (_read_controls() !=
#    _original) and its Apply write only work if every tab's read_controls()
#    contributes a disjoint slice whose union exactly equals _snapshot()'s keys.
#    _defaults() is deliberately _snapshot() minus "locale" (the language dropdown
#    is never reverted by Cancel/Defaults). This test pins all of that.

const _TAB_SCRIPTS: Array[String] = [
	"res://Scripts/ui/options/options_tab.gd",
	"res://Scripts/ui/options/gameplay_tab.gd",
	"res://Scripts/ui/options/camera_tab.gd",
	"res://Scripts/ui/options/video_tab.gd",
	"res://Scripts/ui/options/audio_tab.gd",
	"res://Scripts/ui/options/controls_tab.gd",
	"res://Scripts/ui/options/accessibility_tab.gd",
]


func test_tab_scripts_compile() -> void:
	for path: String in _TAB_SCRIPTS:
		var script: GDScript = load(path)
		assert_not_null(script, "%s failed to compile" % path)


func test_options_panel_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/options_panel.gd")
	assert_not_null(script, "options_panel.gd failed to compile")


# One panel is built for the whole suite (the assertions are read-only), keeping
# the headless Control/RID churn to a single instance.
var _panel: OptionsPanel = null


func before_all() -> void:
	_panel = OptionsPanel.new()
	add_child(_panel)   # triggers _ready() → builds all tabs


func after_all() -> void:
	_panel.free()
	_panel = null


func test_read_controls_partitions_snapshot_keys() -> void:
	var read_keys: Array = _panel._read_controls().keys()
	var snap_keys: Array = _panel._snapshot().keys()
	read_keys.sort()
	snap_keys.sort()
	assert_eq(read_keys, snap_keys,
		"merged read_controls() keys must exactly equal _snapshot() keys")


func test_defaults_is_snapshot_minus_locale() -> void:
	var snap: Dictionary = _panel._snapshot()
	var defaults: Dictionary = _panel._defaults()
	# Every default key is a real setting.
	for k: String in defaults:
		assert_true(snap.has(k), "_defaults() key '%s' is not in _snapshot()" % k)
	# The only key snapshot carries that defaults omits is "locale".
	var missing: Array = []
	for k: String in snap:
		if not defaults.has(k):
			missing.append(k)
	assert_eq(missing, ["locale"],
		"_defaults() should omit exactly 'locale' relative to _snapshot()")


func test_opens_clean_no_pending_apply() -> void:
	# Freshly opened with no edits, read state matches the snapshot baseline, so
	# Apply is disabled.
	assert_eq(_panel._read_controls(), _panel._original,
		"read state should match baseline on open")
	assert_true(_panel._apply_btn.disabled, "Apply should be disabled on open")
