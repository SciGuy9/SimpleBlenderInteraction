# BuildManager.gd
extends Node3D

## --- EXPORTED VARIABLES (Assign in Godot Editor Inspector) ---

# Array to hold the PackedScenes of your buildable parts (e.g., cube_part.tscn)
@export var part_scenes: Array[PackedScene]

# The main camera used for raycasting
@export var camera: Camera3D

# How far the initial placement raycast should check
@export var placement_distance: float = 20.0

# Radius around the raycast hit point to check for nearby parts using a spatial query
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
# Where the object *will* be placed (updated each physics frame)
var current_placement_transform: Transform3D
# Flag indicating if the current placement is valid (raycast hit)
var can_place: bool = false
# Flag indicating if the current placement is snapped to another part
var is_snapped: bool = false

# Parameters for the spatial shape query (optimized check for nearby parts)
var shape_query_parameters: PhysicsShapeQueryParameters3D
# The shape used for the spatial query (a sphere in this case)
var query_shape: SphereShape3D
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
	# Ensure layers are valid (1 to 32)
	if build_parts_physics_layer < 1 or build_parts_physics_layer > 32 or \
	   ground_physics_layer < 1 or ground_physics_layer > 32:
		printerr("[BuildManager] ERROR: Physics Layers must be between 1 and 32.")
		return
	if build_parts_physics_layer == ground_physics_layer:
		printerr("[BuildManager] WARNING: Build Parts and Ground should be on different physics layers for optimal querying.")

	# Raycast should hit both ground and parts
	raycast_mask = (1 << (ground_physics_layer - 1)) | (1 << (build_parts_physics_layer - 1))
	# Shape query should only hit parts
	shape_query_mask = (1 << (build_parts_physics_layer - 1))

	print("  - Raycast Mask (Binary): ", PackedInt32Array([raycast_mask]).to_byte_array().hex_encode())
	print("  - Shape Query Mask (Binary): ", PackedInt32Array([shape_query_mask]).to_byte_array().hex_encode())


	# --- Initialize Spatial Query ---
	query_shape = SphereShape3D.new()
	query_shape.radius = snap_query_radius

	shape_query_parameters = PhysicsShapeQueryParameters3D.new()
	shape_query_parameters.shape = query_shape
	shape_query_parameters.collision_mask = shape_query_mask # IMPORTANT: Use the calculated mask
	shape_query_parameters.collide_with_bodies = true
	shape_query_parameters.collide_with_areas = false
	shape_query_parameters.exclude = [] # Initialize exclude array

	print("  - Shape Query Radius: ", snap_query_radius)

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

		# if selected_part_changed:
		# 	accept_event() # Consume the event so other things don't use the scroll

	# --- Placing the Part ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if can_place and preview_instance: # Check if we have a valid placement spot
			print("[Input] Attempting to place part.")
			place_part()
		else:
			print("[Input] Clicked, but cannot place (can_place=", can_place, ", preview_instance valid=", is_instance_valid(preview_instance), ")")


func _physics_process(delta):
	# Ensure prerequisites are met
	if !camera or !preview_instance:
		# Hide preview if it somehow exists but shouldn't
		if is_instance_valid(preview_instance) and preview_instance.visible:
			# print("[Physics] Hiding preview (no camera or invalid state)")
			preview_instance.hide()
		can_place = false
		return

	# --- 1. Raycasting ---
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_end = ray_origin + camera.project_ray_normal(mouse_pos) * placement_distance
	var space_state = get_world_3d().direct_space_state # Get physics world state

	# Configure raycast query
	var ray_query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	ray_query.collide_with_areas = false
	ray_query.collide_with_bodies = true
	ray_query.collision_mask = raycast_mask # Use the specific mask

	# Exclude the preview instance from the raycast
	if preview_instance and preview_instance.has_method("get_rid"):
		ray_query.exclude = [preview_instance.get_rid()]
	else:
		ray_query.exclude = []

	# Perform the raycast
	var result = space_state.intersect_ray(ray_query)

	# --- 2. Process Raycast Result ---
	if result:
		# print("[Physics] Raycast Hit!")
		can_place = true
		var hit_position = result.position
		var hit_normal = result.normal
		var hit_collider_node = result.collider as Node # Get the node that was hit
		# print("  - Hit Position: ", hit_position)
		# print("  - Hit Normal: ", hit_normal)
		# print("  - Hit Object: ", hit_collider_node.name if is_instance_valid(hit_collider_node) else "Invalid/Null")


		# --- 3. OPTIMIZED: Spatial Query for Nearby Parts ---
		shape_query_parameters.transform = Transform3D(Basis.IDENTITY, hit_position) # Center query shape at hit pos

		# Exclude the preview instance from the shape query too
		if preview_instance and preview_instance.has_method("get_rid"):
			shape_query_parameters.exclude = [preview_instance.get_rid()]
		else:
			shape_query_parameters.exclude = []

		# print("  - Performing Shape Query at: ", hit_position)
		var nearby_results = space_state.intersect_shape(shape_query_parameters)
		# print("  - Found ", nearby_results.size(), " nearby objects.")

		# --- ADD THIS ---
		if nearby_results.size() > 0:
			for collision_info in nearby_results:
				var obj = collision_info.collider
		# --- End of Add ---

		# --- 4. Snapping Calculation (using nearby_results) ---
		is_snapped = false
		# print("  - Calling find_snap_point...")
		var potential_snap_transform = find_snap_point(hit_position, nearby_results)


		# --- 5. Determine Final Placement Transform & Update Preview ---
		if potential_snap_transform != Transform3D(): # Check if find_snap_point returned a valid (non-default) Transform
			# print("  - Snapping SUCCESSFUL!")
			current_placement_transform = potential_snap_transform
			is_snapped = true
			# Apply a tiny offset along the hit normal when snapped to avoid physics fighting
			# Adjust multiplier if needed, depends on snapping calculation precision
			# current_placement_transform.origin += hit_normal * 0.001
		else:
			# print("  - Snapping FAILED or N/A. Using default placement.")
			# Default placement: Place slightly above the surface pointed at
			current_placement_transform = Transform3D(Basis.IDENTITY, hit_position + hit_normal * 0.01)
			# Optional: Basic rotation alignment (can conflict with snapping)
			# current_placement_transform = current_placement_transform.looking_at(hit_position + hit_normal, Vector3.UP)

		# Update preview instance position and visibility
		preview_instance.global_transform = current_placement_transform
		# TODO: Update preview material color based on `is_snapped` for visual feedback
		# Example (requires finding the MeshInstance3D child):
		# var mesh = find_mesh_instance_recursive(preview_instance)
		# if mesh and mesh.material_override:
		# 	 mesh.material_override.albedo_color = Color.GREEN if is_snapped else Color(1,1,1,0.5)

		if not preview_instance.visible:
			# print("[Physics] Showing Preview Instance.")
			preview_instance.show()

	else:
		# No raycast hit
		# print("[Physics] Raycast Miss.")
		can_place = false
		is_snapped = false
		if is_instance_valid(preview_instance) and preview_instance.visible:
			# print("[Physics] Hiding Preview Instance.")
			preview_instance.hide()


## --- PART MANAGEMENT FUNCTIONS ---

func select_part(index: int):
	if part_scenes.is_empty():
		printerr("[SelectPart] No part scenes available!")
		return

	# Clamp index to wrap around the available parts
	current_part_index = wrap(index, 0, part_scenes.size())

	# Remove old preview instance if it exists
	if is_instance_valid(preview_instance):
		print("  - Removing old preview instance.")
		preview_instance.queue_free()
		preview_instance = null # Clear reference immediately

	# Create new preview instance
	var selected_scene = part_scenes[current_part_index]
	if selected_scene:
		print("  - Instantiating preview for: ", selected_scene.resource_path)
		preview_instance = selected_scene.instantiate()

		# Configure preview to be non-interactive and transparent
		if preview_instance is CollisionObject3D:
			# Disable collision response (important!)
			preview_instance.set_collision_layer_value(build_parts_physics_layer, false) # Turn off its own layer
			preview_instance.set_collision_mask_value(build_parts_physics_layer, false) # Don't collide with other parts
			preview_instance.set_collision_mask_value(ground_physics_layer, false) # Don't collide with ground
			# For RigidBody3D, also freeze it
			if preview_instance is RigidBody3D:
				preview_instance.freeze = true
				print("    - Froze RigidBody3D preview.")
			print("    - Disabled collision for preview.")


		# Find the mesh to make transparent (adjust child node path if needed)
		var mesh_instance = find_mesh_instance_recursive(preview_instance)
		if mesh_instance:
			var mat = StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(1.0, 1.0, 1.0, 0.5) # White, 50% transparent
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED # Optional: Render both sides if needed
			mesh_instance.material_override = mat
			print("    - Applied transparent material override.")
		else:
			print("    - WARNING: Could not find MeshInstance3D in preview part to apply material.")

		# Add preview instance as a child of BuildManager (so it's not part of the main placed objects scene)
		add_child(preview_instance)
		preview_instance.hide() # Hide initially until placement is calculated
		print("  - Preview instance created and configured.")
	else:
		preview_instance = null
		printerr("[SelectPart] ERROR: Selected part scene at index ", current_part_index, " is null!")


func place_part():
	var scene_to_instantiate = part_scenes[current_part_index]
	if !scene_to_instantiate:
		printerr("[PlacePart] ERROR: Cannot place null part scene!")
		return

	print("[PlacePart] Instantiating final part: ", scene_to_instantiate.resource_path)
	var new_part = scene_to_instantiate.instantiate()

	if new_part is Node3D:
		# Add the part to the main scene tree (assumes BuildManager is NOT the root of the main scene)
		# If BuildManager IS the root, use get_parent().add_child(new_part) or adjust logic
		get_tree().current_scene.add_child(new_part)

		new_part.global_transform = current_placement_transform # Use calculated transform (snapped or free)
		print("  - Placed part at Global Transform: ", new_part.global_transform)

		# Add to group for potential future use (though not used by current snapping)
		new_part.add_to_group(BUILD_PARTS_GROUP)
		print("  - Added part to group: ", BUILD_PARTS_GROUP)

		# If it's a RigidBody and was placed snapped, ensure it's active
		if new_part is RigidBody3D:
			new_part.sleeping = false # Wake it up

		# Prepare for next placement: Re-select the current part to create a *new* preview
		# This prevents trying to interact with the just-placed visible object.
		var idx_to_reselect = current_part_index
		if is_instance_valid(preview_instance):
			preview_instance.queue_free() # Ensure old preview is gone
		preview_instance = null # Invalidate current preview handle
		print("  - Resetting preview instance.")
		select_part(idx_to_reselect) # Generate a fresh preview

	else:
		printerr("[PlacePart] ERROR: Instantiated part is not a Node3D!")
		new_part.queue_free() # Clean up if it's the wrong type


## --- SNAPPING LOGIC CORE ---

# Finds the best snap point based on nearby objects and marker compatibility
func find_snap_point(ray_hit_pos: Vector3, nearby_shape_results: Array) -> Transform3D:
	# print("[FindSnapPoint] Checking for snaps near hit position: ", ray_hit_pos)
	var best_snap_transform = Transform3D() # Default Identity transform signifies "no snap"
	var found_snap = false
	# Use squared distances for efficiency (avoid sqrt)
	var min_dist_sq = snap_activation_distance * snap_activation_distance
	var closest_valid_snap_dist_sq = INF # Keep track of the closest valid snap found

	var preview_markers = get_markers(preview_instance)
	if preview_markers.is_empty():
		# print("  - No markers found on preview instance. Cannot snap.")
		return best_snap_transform # No markers on preview, cannot snap

	# print("  - Preview Markers: ", preview_markers.map(func(m): return m.name))

	# --- Iterate through ONLY the nearby objects found by intersect_shape ---
	# print("  - Checking ", nearby_shape_results.size(), " nearby objects from shape query.")
	for collision_info in nearby_shape_results:
		var existing_part = collision_info.collider as Node3D
		if not is_instance_valid(existing_part): continue # Skip if instance is somehow invalid

		# print("    - Checking existing part: ", existing_part.name)
		var target_markers = get_markers(existing_part)
		if target_markers.is_empty():
			# print("      - No markers found on this existing part. Skipping.")
			continue # Skip parts with no markers

		# print("      - Target Markers: ", target_markers.map(func(m): return m.name))

		# --- Compare Markers ---
		for target_marker in target_markers:
			var target_marker_global_pos = target_marker.global_position
			# Check if this target marker is close enough to where the player is pointing
			var dist_sq_to_hit = target_marker_global_pos.distance_squared_to(ray_hit_pos)

			# print("        - Target Marker '", target_marker.name, "' at ", target_marker_global_pos)
			# print("          - DistanceSq to RayHit: ", dist_sq_to_hit, " (ThresholdSq: ", min_dist_sq, ")")

			if dist_sq_to_hit < min_dist_sq:
				# print("          - Target marker is close enough to ray hit!")
				# Now check compatible markers on the preview part
				for preview_marker in preview_markers:
					# print("            - Comparing with Preview Marker '", preview_marker.name, "'")
					if are_markers_compatible(target_marker.name, preview_marker.name):
						# print("              - COMPATIBLE pair found!")
						# --- Calculate Snapped Transform ---
						# Basic Position Snap (No Rotation Yet - Assumes markers face opposite directions implicitly):
						var target_marker_global_transform = target_marker.global_transform
						var preview_marker_local_transform = preview_marker.transform

						# TODO: Calculate desired rotation (Basis) for alignment
						var preview_basis = Basis.IDENTITY # No rotation applied yet

						# Calculate the offset vector from preview origin to preview marker, in world space
						var offset_in_world = preview_basis * preview_marker_local_transform.origin

						# Inside the loop where markers are compatible:
						# print("    - Snapping Preview Marker: '", preview_marker.name, "' Local Pos: ", preview_marker.transform.origin)
						# print("    - Snapping Target Marker: '", target_marker.name, "' Global Pos: ", target_marker.global_transform.origin)
						# # ... calculate offset_in_world ...
						# print("    - Calculated Offset in World: ", offset_in_world)
						# ... calculate snapped_origin ...

						# Calculate the desired global origin for the preview instance
						var snapped_origin = target_marker_global_transform.origin - offset_in_world
						# print("    - Calculated Snapped Origin: ", snapped_origin)

						var potential_transform = Transform3D(preview_basis, snapped_origin)
						# print("              - Calculated potential snap transform: ", potential_transform)

						# Check if this snap point is the closest valid one found so far
						if dist_sq_to_hit < closest_valid_snap_dist_sq:
							# print("              - This is the NEW closest valid snap!")
							closest_valid_snap_dist_sq = dist_sq_to_hit
							best_snap_transform = potential_transform
							found_snap = true
						# else:
							# print("              - Found compatible snap, but it's further than a previous one.")

						# Optional: break inner loop if only one snap per target marker is desired
						# break
	# End of loops

	if found_snap:
		# print("[FindSnapPoint] Returning BEST snap transform: ", best_snap_transform)
		return best_snap_transform
	else:
		# print("[FindSnapPoint] No compatible snaps found.")
		return Transform3D() # Return default Identity transform


## --- HELPER FUNCTIONS ---

# Helper to get Marker3D children with the correct prefix (non-recursive)
# func get_markers(parent_node: Node) -> Array[Marker3D]:
# 	var markers: Array[Marker3D] = []
# 	if not parent_node: return markers
# 	for child in parent_node.get_children():
# 		if child is Marker3D and child.name.begins_with(SNAP_MARKER_PREFIX):
# 			markers.append(child)
# 	return markers

# RECURSIVE Helper to get Marker3D children with the correct prefix from any depth
func get_markers(parent_node: Node) -> Array[Marker3D]:
	var markers: Array[Marker3D] = []
	_find_markers_recursive(parent_node, markers) # Start the recursive search
	return markers

# Internal recursive function - DO NOT call this directly from elsewhere
func _find_markers_recursive(current_node: Node, markers_array: Array[Marker3D]):
	if not is_instance_valid(current_node):
		return

	# Check the current node itself
	if current_node is Marker3D and current_node.name.begins_with(SNAP_MARKER_PREFIX):
		markers_array.append(current_node)

	# Recursively check all children
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

# Check if two markers can connect based on naming convention
# Example: Connect_PX connects to Connect_NX
func are_markers_compatible(marker_name1: StringName, marker_name2: StringName) -> bool:
	# Convert StringName to String for easier manipulation if needed, though comparisons work
	var s_name1 = str(marker_name1)
	var s_name2 = str(marker_name2)

	if not s_name1.begins_with(SNAP_MARKER_PREFIX) or not s_name2.begins_with(SNAP_MARKER_PREFIX):
		return false # Doesn't follow convention

	var type1 = s_name1.trim_prefix(SNAP_MARKER_PREFIX) # e.g., "PX", "NY"
	var type2 = s_name2.trim_prefix(SNAP_MARKER_PREFIX)

	# Check for opposite pairs (case-sensitive)
	if type1 == "PX" and type2 == "NX": return true
	if type1 == "NX" and type2 == "PX": return true
	if type1 == "PY" and type2 == "NY": return true
	if type1 == "NY" and type2 == "PY": return true
	if type1 == "PZ" and type2 == "NZ": return true
	if type1 == "NZ" and type2 == "PZ": return true

	# print("      - Compatibility Check: '", type1, "' vs '", type2, "' -> FALSE")
	return false # Not a compatible pair
