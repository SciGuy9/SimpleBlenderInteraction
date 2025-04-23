# orbit_camera_wasd.gd
extends Camera3D

@export_group("Orbit Camera Settings")
@export var min_zoom_distance: float = 5.0 # Closest the camera can get
@export var max_zoom_distance: float = 50.0 # Furthest the camera can get
@export var zoom_speed: float = 10.0 # Units per second for zooming
@export var rotation_speed_deg: float = 90.0 # Degrees per second for orbiting
@export var target_origin: Vector3 = Vector3.ZERO # The point the camera orbits around and zooms towards

var distance_to_origin: float = 0.0
var current_angle_y: float = 0.0 # Angle in radians around the Y axis (horizontal orbit)
var initial_height: float = 0.0 # The camera's constant height offset from the target_origin's Y

func _ready():
	# Calculate initial distance, angle, and height based on the camera's starting position
	var relative_pos = global_transform.origin - target_origin
	distance_to_origin = relative_pos.length()

	# Handle cases where the camera starts exactly at the target origin (distance is 0)
	if distance_to_origin < 0.001:
		# Set a default distance if starting at origin
		distance_to_origin = (min_zoom_distance + max_zoom_distance) / 2.0
		# Set a default relative position for angle calculation (e.g., slightly on +Z axis)
		relative_pos = Vector3(0, 0, distance_to_origin)

	# Calculate the initial horizontal angle relative to the target origin in the XZ plane
	# atan2(x, z) gives the angle from the +Z axis towards the +X axis
	current_angle_y = atan2(relative_pos.x, relative_pos.z)

	# Store the initial vertical offset from the target origin's Y coordinate
	initial_height = relative_pos.y

	# Ensure the initial distance is within the allowed limits
	distance_to_origin = clamp(distance_to_origin, min_zoom_distance, max_zoom_distance)

	# Immediately update the camera's position and orientation based on the calculated state
	_update_camera_transform()

func _process(delta):
	# --- Handle Input ---
	var zoom_input = 0.0
	# W key: Zoom In (decrease distance)
	if Input.is_action_pressed("move_forward"): # You'll need to set up "move_forward" for W
		zoom_input -= 1.0
	# S key: Zoom Out (increase distance)
	if Input.is_action_pressed("move_backward"): # You'll need to set up "move_backward" for S
		zoom_input += 1.0

	var rotate_input = 0.0
	# A key: Rotate Left (increase angle)
	if Input.is_action_pressed("rotate_left"): # You'll need to set up "rotate_left" for A
		rotate_input += 1.0
	# D key: Rotate Right (decrease angle)
	if Input.is_action_pressed("rotate_right"): # You'll need to set up "rotate_right" for D
		rotate_input -= 1.0

	# --- Update State (Distance and Angle) ---
	if zoom_input != 0:
		distance_to_origin += zoom_input * zoom_speed * delta
		# Clamp the distance to stay within the defined limits
		distance_to_origin = clamp(distance_to_origin, min_zoom_distance, max_zoom_distance)

	if rotate_input != 0:
		# Convert rotation speed from degrees to radians
		current_angle_y += rotate_input * deg_to_rad(rotation_speed_deg) * delta
		# Optional: Keep angle within a 0 to 2PI range to prevent floating point buildup
		# current_angle_y = fmod(current_angle_y, 2 * PI)

	# --- Update Camera Position and Rotation ---
	# Only update the transform if there was any input or if it's the first frame
	# (The check isn't strictly necessary because the calculations are cheap,
	# but it's good practice if the update_camera_transform was expensive)
	if zoom_input != 0 or rotate_input != 0 or Engine.get_process_frames() == 1:
		_update_camera_transform()

# Helper function to update the camera's actual transform based on calculated state
func _update_camera_transform():
	# Calculate the new position based on the distance, angle, and maintained height
	# We use sin for the X coordinate and cos for the Z coordinate when rotating around Y
	# The angle `current_angle_y` is measured from the +Z axis.
	var pos_x = target_origin.x + distance_to_origin * sin(current_angle_y)
	var pos_z = target_origin.z + distance_to_origin * cos(current_angle_y)
	# Maintain the initial height relative to the target origin's Y
	var pos_y = target_origin.y + initial_height

	# Set the camera's global position
	global_transform.origin = Vector3(pos_x, pos_y, pos_z)

	# Make the camera look directly at the target origin
	look_at(target_origin, Vector3.UP)