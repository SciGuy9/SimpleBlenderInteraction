# BuildManager.gd
extends Node3D

## --- EXPORTED VARIABLES (Assign in Godot Editor Inspector) ---

# Array to hold the PackedScenes of your buildable parts (e.g., cube_part.tscn)
@export var part_scenes: Array[PackedScene]

# The main camera used for raycasting
@export var camera: Camera3D

# How far the initial placement raycast should check
@export var placement_distance: float = 20.0

# Radius around the raycast hit point to check for nearby parts using a spatial query (for snapping)
@export var snap_query_radius: float = 1.5

# How close a target marker must be to the raycast hit point to be considered for snapping
@export var snap_activation_distance: float = 0.75

# The physics layer number your buildable parts are on (e.g., 2). Ground should be on a different layer (e.g., 1).
@export var build_parts_physics_layer: int = 2

# The physics layer number your ground/environment is on (e.g., 1).
@export var ground_physics_layer: int = 1


## --- CONSTANTS ---

# Prefix used for naming Marker3D connection points in your part scenes
const SNAP_MARKER_PREFIX: String = "Connect_"
# Group name added to placed parts (for potential alternative querying methods, though not used by intersect_shape)
const BUILD_PARTS_GROUP = "build_parts"


## --- INTERNAL VARIABLES ---

# Holds the current transparent preview object (instantiated from part_scenes)
var preview_instance: Node3D = null
# Index of the currently selected part in the part_scenes array
var current_part_index: int = 0
# Where the object *will* be placed (updated each physics frame, includes anti-Z-fighting offset)
var current_placement_transform: Transform3D
# Flag indicating if the current placement is valid (raycast hit AND no overlap)
var can_place: bool = false
# Flag indicating if the current placement is snapped to another part
var is_snapped: bool = false

# Parameters for the snapping spatial shape query
var shape_query_parameters: PhysicsShapeQueryParameters3D
# The shape used for the snapping spatial query (a sphere)
var query_shape: SphereShape3D

# Parameters for the overlap check query
var overlap_query_parameters: PhysicsShapeQueryParameters3D
# Cache the actual collision shape resource of the current preview part
var preview_collision_shape_resource: Shape3D = null

# Bitmask for the initial raycast (checks ground AND build parts)
var raycast_mask: int
# Bitmask for the shape query (checks ONLY build parts)
var shape_query_mask: int


## --- GODOT FUNCTIONS ---

func _ready():
	print("[BuildManager] Initializing...")
	if !camera:
		printerr("[BuildManager] ERROR: Camera not assigned in the Inspector!")
		get_tree().quit() # Or handle appropriately
		return

	if part_scenes.is_empty():
		printerr("[BuildManager] ERROR: No 'Part Scenes' assigned in the Inspector!")
		# Optionally disable building or quit
		return

	# --- Calculate Collision Masks ---
	if build_parts_physics_layer < 1 or build_parts_physics_layer > 32 or \
	   ground_physics_layer < 1 or ground_physics_layer > 32:
		printerr("[BuildManager] ERROR: Physics Layers must be between 1 and 32.")
		return
	if build_parts_physics_layer == ground_physics_layer:
		printerr("[BuildManager] WARNING: Build Parts and Ground should be on different physics layers for optimal querying.")

	raycast_mask = (1 << (ground_physics_layer - 1)) | (1 << (build_parts_physics_layer - 1))
	shape_query_mask = (1 << (build_parts_physics_layer - 1))

	# Optional Debug Prints for masks:
	print("--- Physics Mask Debug ---")
	print("Build Parts Layer: ", build_parts_physics_layer)
	print("Ground Layer: ", ground_physics_layer)
	print("Calculated Raycast Mask (Decimal): ", raycast_mask)
	print("Calculated Shape Query Mask (Decimal): ", shape_query_mask)
	print("Shape Query Mask should ONLY target layer: ", build_parts_physics_layer)
	# print("--------------------------")

	# --- Initialize Snapping Spatial Query ---
	query_shape = SphereShape3D.new()
	query_shape.radius = snap_query_radius
	shape_query_parameters = PhysicsShapeQueryParameters3D.new()
	shape_query_parameters.shape = query_shape
	shape_query_parameters.collision_mask = shape_query_mask
	shape_query_parameters.collide_with_bodies = true
	shape_query_parameters.collide_with_areas = false
	shape_query_parameters.exclude = []
	print("  - Snapping Query Radius: ", snap_query_radius)

	# --- Initialize Overlap Spatial Query Parameters ---
	overlap_query_parameters = PhysicsShapeQueryParameters3D.new()
	# Shape and transform will be set dynamically each frame.
	overlap_query_parameters.collision_mask = shape_query_mask # Check ONLY against other build parts
	overlap_query_parameters.collide_with_bodies = true
	overlap_query_parameters.collide_with_areas = false
	overlap_query_parameters.exclude = []
	print("  - Initialized Overlap Query Parameters.")

	# Select the first part initially
	select_part(0)
	print("[BuildManager] Initialization Complete.")


func _input(event):
	# --- Part Selection (Example: Mouse Wheel) ---
	if event is InputEventMouseButton:
		var selected_part_changed = false
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.is_pressed():
			select_part(current_part_index + 1)
			selected_part_changed = true
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.is_pressed():
			select_part(current_part_index - 1)
			selected_part_changed = true

		if selected_part_changed:
			pass # accept_event() # Consume the event

	# --- Placing the Part ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Check final can_place flag which includes overlap check
		if can_place and preview_instance:
			# print("[Input] Attempting to place part.")
			place_part()
		# else:
			# print("[Input] Clicked, but cannot place (can_place=", can_place, ", preview_instance valid=", is_instance_valid(preview_instance), ")")


func _physics_process(delta):
	# --- Prerequisites ---
	if !camera or !preview_instance:
		if is_instance_valid(preview_instance) and preview_instance.visible:
			preview_instance.hide()
		can_place = false
		return

	# --- Get Physics State and Mouse Position ---
	var space_state = get_world_3d().direct_space_state
	var mouse_pos = get_viewport().get_mouse_position()

	# --- 1. Raycasting ---
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_end = ray_origin + camera.project_ray_normal(mouse_pos) * placement_distance
	var ray_query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	ray_query.collide_with_areas = false
	ray_query.collide_with_bodies = true
	ray_query.collision_mask = raycast_mask

	# Exclude the preview instance from the raycast
	var exclude_list = []
	if preview_instance and preview_instance.has_method("get_rid"):
		exclude_list = [preview_instance.get_rid()]
	ray_query.exclude = exclude_list

	var result = space_state.intersect_ray(ray_query)

	# --- Processing ---
	var potential_placement_transform = Transform3D()
	var calculated_placement = false
	var hit_normal = Vector3.UP
	var snapped_to_part = null # <-- Store the object we snapped to

	is_snapped = false # Reset snap state each frame

	if result:
		hit_normal = result.normal
		var hit_position = result.position

		# --- Snapping Check ---
		shape_query_parameters.transform = Transform3D(Basis.IDENTITY, hit_position)
		shape_query_parameters.exclude = exclude_list # Exclude preview
		var nearby_results = space_state.intersect_shape(shape_query_parameters)

		# Call modified find_snap_point
		var snap_result: Dictionary = find_snap_point(hit_position, nearby_results)

		# Determine potential base transform
		if snap_result != {}: # Check if dictionary was returned
			potential_placement_transform = snap_result.transform
			snapped_to_part = snap_result.target_part # <-- Get the target part
			is_snapped = true
			calculated_placement = true # Found a potential placement via snapping
		else:
			# No snap, use default placement if ray hit
			potential_placement_transform = Transform3D(Basis.IDENTITY, hit_position)
			is_snapped = false
			calculated_placement = true # Found a potential placement via raycast

	# --- Overlap Check ---
	var is_overlapping = false
	if calculated_placement: # Only check overlap if we have a potential spot
		if preview_collision_shape_resource:
			overlap_query_parameters.transform = potential_placement_transform
			overlap_query_parameters.shape = preview_collision_shape_resource

			# --- ADJUST EXCLUSION LIST ---
			var current_exclude_list = []
			# Always exclude the preview instance itself
			if preview_instance and preview_instance.has_method("get_rid"):
				current_exclude_list.append(preview_instance.get_rid())
			# *IF SNAPPED*, also exclude the object we snapped onto
			if is_snapped and is_instance_valid(snapped_to_part) and snapped_to_part.has_method("get_rid"):
				current_exclude_list.append(snapped_to_part.get_rid())
				# print("  - Overlap Check: Excluding preview AND snap target '", snapped_to_part.name, "'")
			# else:
				# print("  - Overlap Check: Excluding only preview.")

			overlap_query_parameters.exclude = current_exclude_list
			# --- END ADJUSTMENT ---

			var overlap_results = space_state.intersect_shape(overlap_query_parameters)
			if not overlap_results.is_empty():
				is_overlapping = true
				# print("    - OVERLAP DETECTED with other objects!")
		else:
			# print("Warning: Cannot check overlap, preview shape missing.")
			is_overlapping = true # Prevent placement if shape is missing

	# --- Final Decision ---
	# Allow placement if we calculated a spot AND it's not overlapping
	# (Overlap check now correctly excludes snap target if needed)
	can_place = calculated_placement and not is_overlapping

	if can_place:
		# Apply anti-Z-fighting offset
		var offset_amount = 0.005 if is_snapped else 0.01
		current_placement_transform = potential_placement_transform
		current_placement_transform.origin += hit_normal * offset_amount

		# Update preview
		preview_instance.global_transform = current_placement_transform
		if not preview_instance.visible:
			preview_instance.show()
	else:
		# Cannot place
		is_snapped = false # Reset snap state if cannot place
		if is_instance_valid(preview_instance) and preview_instance.visible:
			preview_instance.hide()


## --- PART MANAGEMENT FUNCTIONS ---

func select_part(index: int):
	if part_scenes.is_empty():
		printerr("[SelectPart] No part scenes available!")
		return

	current_part_index = wrap(index, 0, part_scenes.size())
	# print("[SelectPart] Selected part index: ", current_part_index)

	# Remove old preview instance if it exists
	if is_instance_valid(preview_instance):
		# print("  - Removing old preview instance.")
		preview_instance.queue_free()
		preview_instance = null
		preview_collision_shape_resource = null # Clear cached shape

	# Create new preview instance
	var selected_scene = part_scenes[current_part_index]
	if selected_scene:
		# print("  - Instantiating preview for: ", selected_scene.resource_path)
		preview_instance = selected_scene.instantiate()

		# Hide immediately before adding to tree
		preview_instance.hide()

		# Cache the Collision Shape Resource
		var collision_shape_node = find_collision_shape_recursive(preview_instance)
		if collision_shape_node and collision_shape_node.shape:
			preview_collision_shape_resource = collision_shape_node.shape
			# print("    - Cached Collision Shape Resource: ", preview_collision_shape_resource)
		else:
			preview_collision_shape_resource = null
			print("    - WARNING: Could not find valid CollisionShape3D/Shape resource in preview part!")

		# Configure preview to be non-interactive and transparent
		if preview_instance is CollisionObject3D:
			preview_instance.set_collision_layer_value(build_parts_physics_layer, false)
			preview_instance.set_collision_mask_value(build_parts_physics_layer, false)
			preview_instance.set_collision_mask_value(ground_physics_layer, false)
			if preview_instance is RigidBody3D:
				preview_instance.freeze = true
			# print("    - Disabled collision for preview.")

		# Apply transparent material override
		var mesh_instance = find_mesh_instance_recursive(preview_instance)
		if mesh_instance:
			var mat = StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(1.0, 1.0, 1.0, 0.5) # White, 50% transparent
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED # Optional
			mesh_instance.material_override = mat
			# print("    - Applied transparent material override.")
		# else: print("    - WARNING: Could not find MeshInstance3D in preview part.")

		# Add preview instance as a child of BuildManager
		add_child(preview_instance)
		# print("  - Preview instance created and added to BuildManager (hidden).")
	else:
		preview_instance = null
		preview_collision_shape_resource = null
		printerr("[SelectPart] ERROR: Selected part scene at index ", current_part_index, " is null!")


func place_part():
	# Use the final can_place flag, which includes the overlap check
	if not can_place or not preview_instance:
		# print("[PlacePart] Cannot place part (can_place=", can_place, ", preview valid=", is_instance_valid(preview_instance), ")")
		return

	var scene_to_instantiate = part_scenes[current_part_index]
	if !scene_to_instantiate:
		printerr("[PlacePart] ERROR: Cannot place null part scene!")
		return

	# print("[PlacePart] Instantiating final part: ", scene_to_instantiate.resource_path)
	var new_part = scene_to_instantiate.instantiate()

	if new_part is Node3D:
		# Add the part to the main scene tree
		get_tree().current_scene.add_child(new_part)

		# Use the final transform which includes the anti-Z-fighting offset
		new_part.global_transform = current_placement_transform
		# print("  - Placed part at Global Transform: ", new_part.global_transform)

		# Add to group
		new_part.add_to_group(BUILD_PARTS_GROUP)
		# print("  - Added part to group: ", BUILD_PARTS_GROUP)

		# Wake up RigidBody
		if new_part is RigidBody3D:
			new_part.sleeping = false

		# Prepare for next placement: Reset preview
		var idx_to_reselect = current_part_index
		if is_instance_valid(preview_instance):
			preview_instance.queue_free()
		preview_instance = null
		# print("  - Resetting preview instance.")
		select_part(idx_to_reselect)

	else:
		printerr("[PlacePart] ERROR: Instantiated part is not a Node3D!")
		new_part.queue_free()


## --- SNAPPING LOGIC CORE ---

# Finds the best snap point based on nearby objects and marker compatibility
# Finds the best snap point and the object snapped to.
# Returns: Dictionary { "transform": Transform3D, "target_part": Node3D } or null if no snap.
func find_snap_point(ray_hit_pos: Vector3, nearby_shape_results: Array) -> Dictionary:
	var best_snap_transform = Transform3D()
	var best_target_part = null # <-- Store the target part
	var found_snap = false
	var min_dist_sq = snap_activation_distance * snap_activation_distance
	var closest_valid_snap_dist_sq = INF

	var preview_markers = get_markers(preview_instance)
	if preview_markers.is_empty():
		return {};

	for collision_info in nearby_shape_results:
		var existing_part = collision_info.collider as Node3D
		if not is_instance_valid(existing_part): continue

		var target_markers = get_markers(existing_part)
		if target_markers.is_empty(): continue

		for target_marker in target_markers:
			var target_marker_global_pos = target_marker.global_position
			var dist_sq_to_hit = target_marker_global_pos.distance_squared_to(ray_hit_pos)

			if dist_sq_to_hit < min_dist_sq:
				for preview_marker in preview_markers:
					if are_markers_compatible(target_marker.name, preview_marker.name):
						# Calculate Snapped Transform (Position Only)
						var target_marker_global_transform = target_marker.global_transform
						var preview_marker_local_transform = preview_marker.transform
						var preview_basis = Basis.IDENTITY
						var offset_in_world = preview_basis * preview_marker_local_transform.origin
						var snapped_origin = target_marker_global_transform.origin - offset_in_world
						var potential_transform = Transform3D(preview_basis, snapped_origin)

						# Check if this is the closest valid snap
						if dist_sq_to_hit < closest_valid_snap_dist_sq:
							closest_valid_snap_dist_sq = dist_sq_to_hit
							best_snap_transform = potential_transform
							best_target_part = existing_part # <-- Store the target
							found_snap = true

	if found_snap:
		# Return dictionary with results
		return {
			"transform": best_snap_transform,
			"target_part": best_target_part
		}
	else:
		# Return null if no snap found
		return {}


## --- HELPER FUNCTIONS ---

# Choose ONE of these get_markers implementations based on your scene structure:

# OPTION A: Non-Recursive (Use if markers are DIRECT children of the root node in part scenes)
# func get_markers(parent_node: Node) -> Array[Marker3D]:
# 	var markers: Array[Marker3D] = []
# 	if not parent_node: return markers
# 	for child in parent_node.get_children():
# 		if child is Marker3D and child.name.begins_with(SNAP_MARKER_PREFIX):
# 			markers.append(child)
# 	return markers

# OPTION B: Recursive (Use if markers might be nested deeper)
func get_markers(parent_node: Node) -> Array[Marker3D]:
	var markers: Array[Marker3D] = []
	if parent_node:
		_find_markers_recursive(parent_node, markers)
	return markers

func _find_markers_recursive(current_node: Node, markers_array: Array[Marker3D]):
	if not is_instance_valid(current_node): return
	if current_node is Marker3D and current_node.name.begins_with(SNAP_MARKER_PREFIX):
		markers_array.append(current_node)
	for child in current_node.get_children():
		_find_markers_recursive(child, markers_array)


# Helper to find the first MeshInstance3D in a node hierarchy (recursive)
func find_mesh_instance_recursive(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found = find_mesh_instance_recursive(child)
		if found:
			return found
	return null

# Helper to find the first CollisionShape3D node in a hierarchy (recursive)
func find_collision_shape_recursive(node: Node) -> CollisionShape3D:
	if node is CollisionShape3D:
		return node
	for child in node.get_children():
		var found = find_collision_shape_recursive(child)
		if found:
			return found
	return null


# Check if two markers can connect based on naming convention
func are_markers_compatible(marker_name1: StringName, marker_name2: StringName) -> bool:
	var s_name1 = str(marker_name1)
	var s_name2 = str(marker_name2)

	if not s_name1.begins_with(SNAP_MARKER_PREFIX) or not s_name2.begins_with(SNAP_MARKER_PREFIX):
		return false

	var type1 = s_name1.trim_prefix(SNAP_MARKER_PREFIX)
	var type2 = s_name2.trim_prefix(SNAP_MARKER_PREFIX)

	# Check for opposite pairs (case-sensitive)
	if type1 == "PX" and type2 == "NX": return true
	if type1 == "NX" and type2 == "PX": return true
	if type1 == "PY" and type2 == "NY": return true
	if type1 == "NY" and type2 == "PY": return true
	if type1 == "PZ" and type2 == "NZ": return true # Keep if using Z-axis markers
	if type1 == "NZ" and type2 == "PZ": return true # Keep if using Z-axis markers

	return false