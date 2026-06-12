class_name FlashOverlay
extends Node

# Two full-screen feedback overlays that don't intercept input. Flash on
# layer 25 (over everything), vignette on layer 24 (just under flash).

var _flash_rect: ColorRect = null
var _vignette_rect: ColorRect = null


func _ready() -> void:
	_flash_rect = _build_layer(25, Color(1.0, 1.0, 1.0, 0.0))
	_vignette_rect = _build_layer(24, Color(0.85, 0.05, 0.05, 0.0))


func _build_layer(layer_index: int, initial_color: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = initial_color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(rect)
	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = layer_index
	canvas_layer.add_child(root)
	add_child(canvas_layer)
	return rect


func flash(color: Color, intensity: float = 0.45, duration: float = 0.35) -> void:
	if not PlayerPrefs.screen_flash:
		return
	_flash_rect.color = Color(color.r, color.g, color.b, intensity)
	_flash_rect.modulate.a = 1.0
	var t := create_tween()
	t.tween_property(_flash_rect, "modulate:a", 0.0, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func vignette_pulse(intensity: float, duration: float = 0.5) -> void:
	if not PlayerPrefs.screen_flash:
		return
	_vignette_rect.modulate.a = intensity
	var t := create_tween()
	t.tween_property(_vignette_rect, "modulate:a", 0.0, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
