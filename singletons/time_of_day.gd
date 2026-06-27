extends Node
## DC1 time-of-day clock (autoload). FOUR discrete, PLAYER-SET times — DC1's clock is set via the georama editor
## (`EdSetClock`), not a real-time tick. Drives: the interior scene variant (m/e/n), the town's dynamic sky slot
## (the 12-slot cfg lighting table), and torch/lamp on/off. Only e/m/n exist on disc, so AFTERNOON reuses the
## morning 'm' interior bake; the town gives it a slightly-later sub-slot.

enum Period { MORNING = 0, AFTERNOON = 1, DUSK = 2, NIGHT = 3 }

const SUFFIX := { Period.MORNING: "m", Period.AFTERNOON: "m", Period.DUSK: "e", Period.NIGHT: "n" }
const TOWN_SLOT := { Period.MORNING: 0, Period.AFTERNOON: 1, Period.DUSK: 3, Period.NIGHT: 6 }  # 0-based into the 12-slot table (1 = bright-blue noon)
const NAMES := { Period.MORNING: "Morning", Period.AFTERNOON: "Afternoon", Period.DUSK: "Dusk", Period.NIGHT: "Night" }

var current_time: int = Period.MORNING
var day: int = 1

signal time_changed(new_time: int)
signal day_changed(new_day: int)

func suffix() -> String:
	return SUFFIX[current_time]

func town_slot() -> int:
	return TOWN_SLOT[current_time]

func fires_lit() -> bool:
	return current_time == Period.DUSK or current_time == Period.NIGHT

func time_name() -> String:
	return NAMES[current_time]

func set_time(t: int) -> void:
	if t == current_time:
		return
	current_time = t
	time_changed.emit(t)

## debug: advance to the next time of day.
func cycle() -> void:
	current_time = (current_time + 1) % 4
	time_changed.emit(current_time)

## sleeping/inn: next day, reset to morning.
func advance_day() -> void:
	day += 1
	day_changed.emit(day)
	set_time(Period.MORNING)
