extends Node3D

# --- Variables ---
# Assign the scene for the part you want to place in the Inspector
@export var part_to_place: PackedScene 

# Reference to the camera (assign in the Inspector or get dynamically)
@export var camera: Camera3D 

# How far the placement ray should check
@export var placement_distance: float = 20.0 

# Optional: A visual marker to show where the part will be placed
@export var placement_marker: Node3D # Assign a simple MeshInstance3D scene here

var current_placement_position: Vector3
var current_placement_normal: Vector3
var can_place: bool = false

func _ready():
    if !camera:
        printerr("BuildManager: Camera not assigned!")
    if placement_marker:
        placement_marker.hide() # Hide marker initially

func _input(event):
    # --- Part Selection (Very Basic) ---
    # Replace this later with UI buttons!
    if event.is_action_pressed("ui_accept"): # Default: Space bar
        # Change which part scene is loaded here if needed
        print("Selected part: ", part_to_place.resource_path if part_to_place else "None")

    # --- Placing the Part ---
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        if can_place and part_to_place:
            place_part()

func _physics_process(_delta):
    if !camera or !part_to_place:
        return

    # --- Raycasting for Placement Position ---
    var mouse_pos = get_viewport().get_mouse_position()
    var ray_origin = camera.project_ray_origin(mouse_pos)
    var ray_end = ray_origin + camera.project_ray_normal(mouse_pos) * placement_distance

    var space_state = get_world_3d().direct_space_state
    # Add collision masks/layers later for more control
    var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end) 
    query.collide_with_areas = false # Don't hit areas
    query.collide_with_bodies = true  # Hit physics bodies

    var result = space_state.intersect_ray(query)

    if result:
        can_place = true
        current_placement_position = result.position
        current_placement_normal = result.normal

        # Update placement marker position and orientation (optional)
        if placement_marker:
            placement_marker.global_position = current_placement_position + Vector3(0, 1, 0)
            # Optional: Align marker to surface normal (basic alignment)
            # placement_marker.look_at(current_placement_position + current_placement_normal, Vector3.UP) 
            placement_marker.show()
    else:
        can_place = false
        if placement_marker:
            placement_marker.hide()


func place_part():
    if !part_to_place:
        printerr("No part selected to place!")
        return

    var new_part = part_to_place.instantiate()

    # Check if the new part is a Node3D (it should be)
    if new_part is Node3D:
        # Add the part to the main scene tree
        get_tree().current_scene.add_child(new_part) 
        
        # Set its initial position based on the raycast result
        new_part.global_position = current_placement_position + Vector3(0, 1, 0)

        # Optional: Basic orientation based on normal (might need refinement)
        # new_part.look_at(current_placement_position + current_placement_normal, Vector3.UP)

        print("Placed part at: ", new_part.global_position)
    else:
        printerr("Instantiated part is not a Node3D!")
        new_part.queue_free() # Clean up if it's not the right type