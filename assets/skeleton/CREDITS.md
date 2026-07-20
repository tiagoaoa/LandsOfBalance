# Skeleton Warrior Asset

`skeleton_axe.fbx` + `textures/` — "free skeleton man axe" pack supplied by
the project owner (~/Downloads/free-skeleton-man-axe.zip; Skyrim-style
draugr NPC rig with battleaxe, source page/author unrecorded — verify the
pack's license before shipping). The previous Flare "Skeletal Knight"
(CC-BY, Clint Bellanger) was removed at the owner's request.

The game strips the FBX's C4D editor camera and baked taunt clip and
animates the rig procedurally via `enemies/skeleton_anim.gd`; materials
are rebuilt in `enemies/skeleton.gd` from the pack's texture set
(skeleton.jpeg/_n, draugrbattleaxe_m/_n).
