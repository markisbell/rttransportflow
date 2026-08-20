class_name Wire
extends RefCounted
## Wire-hygiene readers for gamebridge result frames.
##
## The backend nulls every non-finite float on the wire (`_r()`, contract v2)
## and GDScript `float(null)` is a hard script error — `numf` is the game's
## one guard against that (the P5 blackout-NaN crash). ONE home: it existed
## in five byte-identical copies, and production code (SaveLoad, Campaign)
## imported it from the smoke-test base class.


static func numf(data: Dictionary, key: String, default: float) -> float:
	var value: Variant = data.get(key, default)
	return default if value == null else float(value)
