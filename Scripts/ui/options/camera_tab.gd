class_name OptionsCameraTab
extends OptionsTab

# Camera tab — how the third-person camera frames play. Its own tab because the
# four controls form a cohesive viewing-preference group.

var _camera_mode_btn: OptionButton = null
var _tilt_slider: HSlider = null
var _tilt_label: Label = null
var _fov_slider: HSlider = null
var _fov_label: Label = null
var _cam_dist_slider: HSlider = null
var _cam_dist_label: Label = null

func _build_content() -> void:
	_camera_mode_btn = OptionButton.new()
	_camera_mode_btn.custom_minimum_size = Vector2(160, 40)
	_camera_mode_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.CAMERA_MODE_LABELS.size():
		_camera_mode_btn.add_item(PlayerPrefs.CAMERA_MODE_LABELS[i], i)
	_camera_mode_btn.selected = PlayerPrefs.camera_mode
	_camera_mode_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Mode", _camera_mode_btn))

	_tilt_slider = HSlider.new()
	_tilt_slider.min_value = PlayerPrefs.CAMERA_TILT_MIN
	_tilt_slider.max_value = PlayerPrefs.CAMERA_TILT_MAX
	_tilt_slider.step = 0.5
	_tilt_slider.value = PlayerPrefs.camera_tilt_deg
	_tilt_slider.value_changed.connect(func(_v: float) -> void: _notify_changed())
	_tilt_label = _value_label("%.1f°" % PlayerPrefs.camera_tilt_deg)
	_tilt_slider.value_changed.connect(func(v: float) -> void: _tilt_label.text = "%.1f°" % v)
	add_child(_slider_row("Tilt", _tilt_slider, _tilt_label))

	_fov_slider = HSlider.new()
	_fov_slider.min_value = PlayerPrefs.FOV_MIN
	_fov_slider.max_value = PlayerPrefs.FOV_MAX
	_fov_slider.step = 1.0
	_fov_slider.value = PlayerPrefs.fov
	_fov_slider.value_changed.connect(func(_v: float) -> void: _notify_changed())
	_fov_label = _value_label("%d°" % int(PlayerPrefs.fov))
	_fov_slider.value_changed.connect(func(v: float) -> void: _fov_label.text = "%d°" % int(v))
	add_child(_slider_row("FOV", _fov_slider, _fov_label))

	_cam_dist_slider = HSlider.new()
	_cam_dist_slider.min_value = PlayerPrefs.CAMERA_DISTANCE_MIN
	_cam_dist_slider.max_value = PlayerPrefs.CAMERA_DISTANCE_MAX
	_cam_dist_slider.step = 0.05
	_cam_dist_slider.value = PlayerPrefs.camera_distance
	_cam_dist_slider.value_changed.connect(func(_v: float) -> void: _notify_changed())
	_cam_dist_label = _value_label("%.2fx" % PlayerPrefs.camera_distance)
	_cam_dist_slider.value_changed.connect(func(v: float) -> void: _cam_dist_label.text = "%.2fx" % v)
	add_child(_slider_row("Distance", _cam_dist_slider, _cam_dist_label))

func read_controls() -> Dictionary:
	return {
		"camera_mode": _camera_mode_btn.selected,
		"camera_tilt_deg": _tilt_slider.value,
		"fov": _fov_slider.value,
		"camera_distance": _cam_dist_slider.value,
	}

func apply_values(v: Dictionary) -> void:
	_camera_mode_btn.selected = v.camera_mode
	_tilt_slider.value = v.camera_tilt_deg
	_fov_slider.value = v.fov
	_cam_dist_slider.value = v.camera_distance
