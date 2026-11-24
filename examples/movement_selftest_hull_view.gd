extends "res://examples/movement_selftest_physics.gd"

## The hull view sections of the movement self-test (no physics server needed).


## GSPlayerHullView: the ring, the one rule on both ends, and the client's fill.
func _test_hull_view() -> void:
	_section("hull view: ring record and lookup, a missing tick, a teleport cut, resolve clamping")
	var view := GSPlayerHullView.new()
	view.is_server = true
	view.capacity = 8
	view.snap_fn = func(feet: Vector3) -> Vector3: return Vector3(roundf(feet.x * 100.0) * 0.01, feet.y, feet.z)
	for t in range(10, 14):
		view.record(t, {1: Vector3(0, 0, 0), 2: Vector3(float(t - 10) + 0.004, 0, 0)})
	_check(view.ring_at(2, 12) == Vector3(2.0, 0, 0), "a recorded foot is snapped to the wire grid (2.004 -> 2.0)")
	_check(view.ring_at(2, 99) == null and view.ring_at(7, 12) == null, "a tick or player never recorded is null")
	var mid: Variant = view.ring_between(2, 11, 13, 12.0)
	_check(mid is Vector3 and is_equal_approx((mid as Vector3).x, 2.0), "ring_between blends the pair at the render tick (x %s)" % [mid])
	var clamped: Variant = view.ring_between(2, 11, 12, 20.0)
	_check(clamped is Vector3 and is_equal_approx((clamped as Vector3).x, 2.0), "a render tick past the pair holds the newer sample")
	var near: Variant = view.ring_near(2, 11.5)
	_check(near is Vector3 and is_equal_approx((near as Vector3).x, 1.5), "ring_near with no bracket blends the two ticks around render (1.5)")

	var misses: int = view.counts["miss"]
	_check(view.ring_between(2, 3, 4, 3.5) == null and view.counts["miss"] == misses + 1, "a tick the ring never held is a miss: null and counted")
	view.record(30, {1: Vector3.ZERO, 2: Vector3.ZERO})
	_check(view.ring_at(2, 12) != null, "a gap in ticks keeps older entries (only tick - capacity is erased)")
	for t in range(50, 61):
		view.record(t, {1: Vector3.ZERO, 2: Vector3.ZERO})
	_check(view.ring_at(2, 52) == null and view.ring_at(2, 53) != null, "recording every tick keeps exactly capacity ticks (52 gone, 53 held at capacity 8)")

	view.record(40, {1: Vector3.ZERO, 2: Vector3(50, 0, 0)})
	view.record(41, {1: Vector3.ZERO, 2: Vector3(0, 0, 0)})
	var cuts: int = view.counts["teleport"]
	_check(view.ring_between(2, 40, 41, 40.5) == null and view.counts["teleport"] == cuts + 1, "a 50 m jump inside the pair is a teleport: null, hull stays")
	view.record(42, {1: Vector3.ZERO})
	_check(view.ring_at(2, 42) == null and view.ring_at(2, 41) == null, "a player absent from a record is forgotten")

	# resolve: render tick, and a pair stepped on over a repeated command.
	var r := GSPlayerHullView.resolve(4, 100, 2, 2, 100)
	_check(r[0] == 99.0 and r[1] == 98 and r[2] == 2, "resolve: render = tick - lag_q/4, older = command tick - back")
	var stepped := GSPlayerHullView.resolve(8, 100, 6, 2, 110)
	_check(stepped[0] == 108.0 and stepped[1] == 108, "a repeated command steps its pair on by span until it brackets render: older %s" % [stepped[1]])
	var nobracket := GSPlayerHullView.resolve(4, 100, -1, 0, 100)
	_check(nobracket[1] == -1 and nobracket[0] == 99.0, "no bracket named: older -1")
	_check(GSPlayerHullView.resolve(4, -1, 5, 2, 100)[1] == -1, "a bracket with no command tick is none")
	var zero_span := GSPlayerHullView.resolve(80, 100, 5, 0, 100)
	_check(zero_span[1] == 95, "span 0 never steps (no divide by zero)")

	# feet_for through view_fn, server side.
	var sent: Array = [4, 12, 2, 2]
	view.capacity = 8
	view.view_fn = func(mover: Variant) -> Variant: return sent if mover == 1 else null
	for t in range(10, 14):
		view.record(t, {1: Vector3.ZERO, 2: Vector3(float(t - 10), 0, 0)})
	var answer: Variant = view.feet_for(1, 2, 12)
	_check(answer is Vector3 and is_equal_approx((answer as Vector3).x, 1.0), "feet_for: the other at render tick 11 in the 10..12 bracket, 1.0 (got %s)" % [answer])
	var none_before: int = view.counts["none"]
	_check(view.feet_for(3, 2, 12) == null and view.counts["none"] == none_before + 1, "a mover that sent no view: null, counted none")
	sent[0] = -1
	_check(view.feet_for(1, 2, 12) == null, "a negative lag is no view")

	# The client end: client_fn is asked with the resolved bracket.
	var client := GSPlayerHullView.new()
	var asked: Array = []
	client.view_fn = func(_m: Variant) -> Variant: return [8, 12, 2, 2]
	client.client_fn = func(other: Variant, older: int, span: int, render: float) -> Variant:
		asked.append([other, older, span, render])
		return Vector3(1, 0, 0)
	_check(client.feet_for(1, 2, 12) == Vector3(1, 0, 0) and asked == [[2, 10, 2, 10.0]], "client: asked for the same bracket the server resolves: %s" % [asked])
	_check(client.counts["interp"] == 1, "and counted as an interpolated answer")

	# The client's fill.
	_check(GSPlayerHullView.lag_q_for(100, 98.0, 31) == 8, "lag_q_for: two ticks behind is 8 quarter ticks")
	_check(GSPlayerHullView.lag_q_for(100, 120.0, 31) == 0 and GSPlayerHullView.lag_q_for(100, 0.0, 31) == 31, "lag_q_for clamps to 0..max")
	_check(GSPlayerHullView.bracket_for(100, Vector2i(94, 96), 4, 2) == [6, 2], "bracket_for: back and span")
	_check(GSPlayerHullView.bracket_for(100, Vector2i(60, 62), 4, 2) == [-1, 0], "a back that does not fit its bits is left out, not wrapped")
	_check(GSPlayerHullView.bracket_for(100, Vector2i(-1, -1), 4, 2) == [-1, 0], "no bracket stays none")
	_done()
