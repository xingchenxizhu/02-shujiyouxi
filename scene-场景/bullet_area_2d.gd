extends Area2D

class_name Bullet

# ==============================================================
# Bullet（子弹）
# --------------------------------------------------------------
# 说明：
#   本脚本是一个基于 Area2D 的"子弹"组件。Area2D 本身不做物理推动，
#   而是负责"区域重叠检测 + 信号回调"，非常适合子弹这类
#   （a）飞行速度快、（b）只需感知"是否碰到东西"、
#   （c）碰到后立即消失 的对象。
#
# 工作流程：
#   1. 外部（如玩家/敌人）在生成子弹节点后，调用 setup() 注入飞行方向。
#   2. 每个物理帧 _physics_process() 中让子弹沿方向前进。
#   3. 前进前先用"射线查询(raycast)"检测这一帧是否撞到墙体（世界碰撞层），
#      撞到则立即销毁，避免高速子弹"穿墙"。
#   4. 撞到任何 Area2D（除了其他 Bullet）时，通过 area_entered 信号销毁自己。
#   5. 超出最长存活时间 max_lifetime 后自动销毁，防止子弹永久残留。
# ==============================================================


# 世界物体（墙体等静态刚体）的碰撞掩码。
# --------------------------------------------------------------
# 注意：Area2D 的 collision_mask 按"二进制位"选择物理层，而不是层的编号。
# 例如：要与第 1 层碰撞 → 值 1（2^0）
#       要与第 2 层碰撞 → 值 2（2^1）
#       要与第 N 层碰撞 → 值 2^(N-1)
# 本项目的墙体统一放在第 1 层，因此这里写 1。
# （注释里保留原拼写 WORL_COLLTSION_MASK，仅作说明，值不改变）
const WORL_COLLTSION_MASK := 1


# 子弹飞行速度，单位：像素/秒。
# @export 表示可在 Godot 编辑器的 Inspector 面板中直接修改该值。
@export var speed: float = 320.0


# 子弹最大存活时间，单位：秒。
# 用于防止子弹未命中任何目标时永远留在场景中（内存泄漏/性能浪费）。
@export var max_lifetime: float = 2.0


# 子弹当前的飞行方向（单位向量更优，但这里允许任意向量，setup 会归一化）。
var direction: Vector2 = Vector2.RIGHT


# 剩余存活时间（秒）。在 _ready 中被初始化为 max_lifetime，
# 每帧递减，减到 0 以下时自动销毁。
var remaining_lifetime: float = 0.0


# ==============================================================
# _ready()：节点进入场景树时调用一次。
# --------------------------------------------------------------
# 这里做的事：
#   1. 将剩余寿命设为最大寿命，作为计时起点。
#   2. 连接 Area2D 的 area_entered 信号——当另一个 Area2D 进入
#      本子弹的碰撞区域时，会回调 _on_area_entered()。
# ==============================================================
func _ready() -> void:
	remaining_lifetime = max_lifetime
	area_entered.connect(_on_area_entered)


# ==============================================================
# setup()：由外部（子弹的生成方）在生成后调用，
# 用于注入子弹的初始飞行方向。
# --------------------------------------------------------------
# 参数：
#   initial_direction - 期望的飞行方向向量
# 处理：
#   调用 normalized() 将其归一化为长度为 1 的单位向量，
#   这样乘以 speed 时移动速度就是恒定的 speed（与方向无关）。
# ==============================================================
func setup(initial_direction: Vector2) -> void:
	direction = initial_direction.normalized()


# ==============================================================
# _physics_process()：每个物理帧调用一次（帧率与物理步进同步）。
# --------------------------------------------------------------
# 参数：
#   delta - 上一物理帧到本帧经过的时间（秒）。
# 逻辑：
#   1. 计算"本帧的起始位置"与"本帧的结束位置"。
#   2. 用射线查询检测从起始到结束的这段路径是否会撞到墙体：
#       若会撞到 → 立即销毁子弹（queue_free），结束本帧。
#   3. 若不会撞到 → 把子弹真正移动到结束位置。
#   4. 衰减剩余寿命；寿命耗尽时销毁，保证子弹不会无限存活。
# ==============================================================
func _physics_process(delta: float) -> void:
	var current_position := global_position
	var next_position := current_position + direction * speed * delta

	if _will_hit_world(current_position, next_position):
		queue_free()
		return

	global_position = next_position

	# 没有命中任何对象时，也要在超时后自动清理。
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		queue_free()


# ==============================================================
# _will_hit_world()：判断本帧这段飞行路径是否会撞到"世界"（墙体）。
# --------------------------------------------------------------
# 为什么要用射线查询？
#   如果只依赖 Area2D / PhysicsBody2D 的"区域重叠"或"碰撞回调"，
#   当子弹速度很快时，一帧可能移动几十像素，足以"跳"过一段
#   零厚度的边界或很薄的墙体（即所谓的"隧道效应"/tunneling）。
#   做法是：在移动之前，用一条射线覆盖"本帧将要走过的整段路径"，
#   只要整段路径上有任何遮挡，就判定为命中，从而杜绝穿墙。
#
# 参数：
#   from_position - 本帧起点（当前全局位置）
#   to_position   - 本帧终点（即将移动到的全局位置）
# 返回：
#   true  - 这段路径会命中世界墙体，应当停止移动并销毁
#   false - 路径畅通，可以正常移动
# ==============================================================
func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	# 获取当前 2D 世界的"直接空间状态"(direct space state)，
	# 它是物理引擎提供的一个只读对象，用于做射线/形状等查询。
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return false

	# 构造一条射线查询参数：
	#   起点 from_position、终点 to_position（两点即定义一条线段），
	#   并且只检测碰撞掩码为 WORL_COLLTSION_MASK 的物理层（即墙体层）。
	var query := PhysicsRayQueryParameters2D.create(
		from_position,
		to_position,
		WORL_COLLTSION_MASK
		
	)
	# 只检测 PhysicsBody2D（如 StaticBody2D / RigidBody2D，即墙）。
	query.collide_with_bodies = true
	# 不检测 Area2D（子弹之间的重叠由 signal 处理，避免干扰）。
	query.collide_with_areas = false

	# 执行射线查询，返回命中的信息字典（如碰撞点、法线、对象等）。
	var hit_result: Dictionary = space_state.intersect_ray(query)
	# 如果字典非空，说明这条路径上有东西挡住了，返回 true。
	return not hit_result.is_empty()


# ==============================================================
# _on_area_entered()：当另一个 Area2D 进入本子弹的碰撞区域时触发。
# --------------------------------------------------------------
# 参数：
#   area - 与本子弹发生重叠的那个 Area2D
# 逻辑：
#   1. 如果该 Area2D 也是 Bullet（同类子弹），则直接忽略，
#      让子弹之间可以互相穿过，不互相消耗。
#   2. 否则认为命中了目标，销毁自己（queue_free）。
#      （如需对命中目标造成伤害，通常在这里通过 area 拿到目标，
#        调用其 take_damage() 之类的方法后再销毁自己。）
# ==============================================================
func _on_area_entered(area: Area2D) -> void:
	if area is Bullet:
		return

	queue_free()
