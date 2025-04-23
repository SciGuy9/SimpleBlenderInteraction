extends Node3D

# --- Variables ---
# Assign via Inspector or load dynamically later
@export var part_scenes: Array[PackedScene] # Array to hold Cube, Wedge etc.
@export var camera: Camera3D
@export var placement_distance: float = 20.0

# Snapping parameters
@export var snap_check_radius: float = 2.0 # How close parts need to be to check for snaps
@export var snap_activation_distance: float = 0.75 # How close raycast hit must be to a target marker to activate snapping
@export var snap_marker_prefix: String = "Connect_" # Prefix for our connection Marker3Ds

# Internal state
var current_part_index: int = 0
var preview_instance: Node3D = null # Holds the transparent preview object
var current_placement_transform: Transform3D # Where the object *will* be placed
var can_place: bool = false
var is_snapped: bool = false

# Group name for easily finding placed parts
const BUILD_PARTS_GROUP = "build_parts"


func _ready():
	if !camera:
		printerr("BuildManager: Camera not assigned!")
	# Select the first part initially
	select_part(0)


func _input(event):
	# --- Part Selection (Example: Mouse Wheel) ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.is_pressed():
			select_part(current_part_index + 1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.is_pressed():
			select_part(current_part_index - 1)

	# --- Placing the Part ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if can_place and preview_instance: # Check if we have a valid placement spot
			place_part()


func _physics_process(delta):
	if !camera or !preview_instance:
		can_place = false
		if preview_instance: preview_instance.hide() # Hide if no camera/part selected
		return

	# --- Raycasting ---
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_end = ray_origin + camera.project_ray_normal(mouse_pos) * placement_distance
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# Optional: Exclude the preview instance itself if it has collision temporarily enabled
	# query.exclude = [preview_instance.get_rid()] if preview_instance and preview_instance.has_meta("RID") else []

	var result = space_state.intersect_ray(query)

	if result:
		can_place = true
		var hit_position = result.position
		var hit_normal = result.normal
		var hit_collider = result.collider # The object that was hit

		# --- Snapping Calculation ---
		is_snapped = false
		var potential_snap_transform = find_snap_point(hit_position, hit_collider)

		if potential_snap_transform: # Check if find_snap_point returned a valid Transform
			current_placement_transform = potential_snap_transform
			is_snapped = true
		else:
			# Default placement: Place slightly above the surface
			current_placement_transform = Transform3D(Basis(), hit_position + hit_normal * 0.01)
			# Basic rotation alignment (optional, can conflict with snapping)
			# current_placement_transform = current_placement_transform.looking_at(hit_position + hit_normal, Vector3.UP)

		# Update preview instance
		preview_instance.global_transform = current_placement_transform
		# Maybe change color if snapped? (Requires accessing material)
		# preview_instance.get_node("MeshInstance3D_Child_Name").material_override.albedo_color = Color.GREEN if is_snapped else Color.WHITE * Color(1,1,1,0.5)
		preview_instance.show()

	else:
		# No raycast hit
		can_place = false
		is_snapped = false
		if preview_instance:
			preview_instance.hide()


# --- Part Management Functions ---

func select_part(index: int):
	if part_scenes.is_empty():
		printerr("No part scenes assigned to BuildManager!")
		return

	# Clamp index
	current_part_index = wrap(index, 0, part_scenes.size())

	# Remove old preview
	if is_instance_valid(preview_instance):
		preview_instance.queue_free()

	# Create new preview
	var selected_scene = part_scenes[current_part_index]
	if selected_scene:
		preview_instance = selected_scene.instantiate()
		# Make preview non-functional and semi-transparent
		if preview_instance is RigidBody3D:
			preview_instance.freeze = true # Stop physics simulation
			# Or set mode to Static/Kinematic temporarily if needed
		# Disable collision response (important!)
		if preview_instance.has_method("set_collision_layer_value"):
			preview_instance.set_collision_layer_value(1, false) # Assuming layer 1 is default
			preview_instance.set_collision_mask_value(1, false)

		# Find the mesh to make transparent (adjust path if needed)
		var mesh_instance = find_mesh_instance_recursive(preview_instance)
		if mesh_instance:
			var mat = StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(1.0, 1.0, 1.0, 0.5) # White, 50% transparent
			mesh_instance.material_override = mat
		else:
			print("Warning: Could not find MeshInstance3D in preview part to apply material.")

		add_child(preview_instance) # Add preview to the BuildManager node
		preview_instance.hide() # Hide initially
	else:
		preview_instance = null


func find_mesh_instance_recursive(node: Node) -> MeshInstance3D:
	# Helper to find the first mesh instance in the preview part's hierarchy
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found = find_mesh_instance_recursive(child)
		if found:
			return found
	return null


func place_part():
	var scene_to_instantiate = part_scenes[current_part_index]
	if !scene_to_instantiate:
		printerr("Cannot place null part scene!")
		return

	var new_part = scene_to_instantiate.instantiate()

	if new_part is Node3D:
		get_tree().current_scene.add_child(new_part) # Add to main scene
		new_part.global_transform = current_placement_transform # Use calculated transform (snapped or free)

		# Add to group for future snapping checks
		new_part.add_to_group(BUILD_PARTS_GROUP)

		# If it was a RigidBody and snapped, potentially wake it (though gravity should do this)
		if new_part is RigidBody3D and is_snapped:
			new_part.sleeping = false

		# Prepare for next placement: Select the same part again to create a new preview
		# This prevents trying to place the now-visible preview instance.
		var idx_to_reselect = current_part_index
		preview_instance = null # Invalidate current preview handle
		select_part(idx_to_reselect)


	else:
		printerr("Instantiated part is not a Node3D!")
		new_part.queue_free()


# --- Snapping Logic Core ---

func find_snap_point(ray_hit_pos: Vector3, hit_collider: Object) -> Transform3D:
	var best_snap_transform = Transform3D() # Use Variant type for nullable return
	var found_snap = false
	var min_dist_sq = snap_activation_distance * snap_activation_distance # Check against squared distances

	# Get markers from the preview object
	var preview_markers = get_markers_recursive(preview_instance, snap_marker_prefix)
	
	if preview_markers.is_empty(): return best_snap_transform # No markers on preview, cannot snap

	# Find nearby existing parts
	# Note: Using get_nodes_in_group can be slow for many objects. Spatial partitioning is better for large scenes.
	for node in get_tree().get_nodes_in_group(BUILD_PARTS_GROUP):
		if not node is Node3D: continue # Skip non-3D nodes
		var existing_part = node as Node3D

		# Basic proximity check (optional, broad phase)
		if existing_part.global_position.distance_squared_to(ray_hit_pos) > snap_check_radius * snap_check_radius:
			continue

		# Get markers from the existing part
		var target_markers = get_markers_recursive(existing_part, snap_marker_prefix)

		if target_markers.is_empty(): continue # Skip parts with no markers

		# --- Compare Markers ---
		for target_marker in target_markers:
			var target_marker_global_pos = target_marker.global_position

			# Check if this target marker is close enough to where the player is pointing
			var dist_sq_to_hit = target_marker_global_pos.distance_squared_to(ray_hit_pos)
			if dist_sq_to_hit < min_dist_sq:

				# Now check compatible markers on the preview part
				for preview_marker in preview_markers:
					if are_markers_compatible(target_marker.name, preview_marker.name):
						# --- Calculate Snapped Transform ---
						# Basic Position Snap (No Rotation Yet):
						# We want preview_marker's global position to align with target_marker's global position.
						# The preview object's origin needs to be offset from the target marker
						# by the inverse of the preview marker's local position.

						# 1. Get target marker's transform
						var target_marker_global_transform = target_marker.global_transform

						# 2. Get preview marker's local transform relative to the preview instance
						var preview_marker_local_transform = preview_marker.transform

						# TODO: Calculate desired rotation for preview_instance (e.g., 180 deg flip)
						# For now, assume preview instance keeps its default orientation (Identity Basis)
						var preview_basis = Basis() # No rotation applied yet

						# 3. Calculate the offset vector from preview origin to preview marker, in world space (if preview had desired rotation)
						var offset_in_world = preview_basis * preview_marker_local_transform.origin

						# 4. Calculate the desired global origin for the preview instance
						var snapped_origin = target_marker_global_transform.origin - offset_in_world

						# 5. Create the final transform
						var potential_transform = Transform3D(preview_basis, snapped_origin)


						# Update best snap if this is the closest valid one found so far
						min_dist_sq = dist_sq_to_hit # This marker is now the closest valid target
						best_snap_transform = potential_transform
						found_snap = true
						# Optional: Break inner loop if only one snap per target marker is desired
						# break

					else:
						print("Nothing")


	if found_snap:
		return best_snap_transform
	else:
		return Transform3D() # Return Identity, signifying no valid snap found


# Helper to get Marker3D children with the correct prefix
# REVISED Helper to find Marker3D children recursively
func get_markers_recursive(parent_node: Node, prefix: String) -> Array[Marker3D]:
	var markers: Array[Marker3D] = []
	if not parent_node: return markers
	for child in parent_node.get_children():
		if child is Marker3D and child.name.begins_with(prefix):
			markers.append(child)
		# Recursively check children of this child
		markers.append_array(get_markers_recursive(child, prefix))
	return markers

# In find_snap_point, call the recursive version:
# var preview_markers = get_markers_recursive(preview_instance, snap_marker_prefix)
# var target_markers = get_markers_recursive(existing_part, snap_marker_prefix)


# Check if two markers can connect based on naming convention
# Example: Connect_PX connects to Connect_NX
func are_markers_compatible(marker_name1: String, marker_name2: String) -> bool:
	if not marker_name1.begins_with(snap_marker_prefix) or not marker_name2.begins_with(snap_marker_prefix):
		return false # Doesn't follow convention

	var type1 = marker_name1.trim_prefix(snap_marker_prefix) # e.g., "PX", "NY"
	var type2 = marker_name2.trim_prefix(snap_marker_prefix)

	# Check for opposite pairs
	if type1 == "PX" and type2 == "NX": return true
	if type1 == "NX" and type2 == "PX": return true
	if type1 == "PY" and type2 == "NY": return true
	if type1 == "NY" and type2 == "PY": return true
	if type1 == "PZ" and type2 == "NZ": return true
	if type1 == "NZ" and type2 == "PZ": return true

	return false # Not a compatible pair
