extends CharacterBody2D
# extends 表示这个脚本继承 CharacterBody2D（2D 运动学角色体）。
# CharacterBody2D 是一种专门用于"自己控制移动"的物理节点，
# 它不自动受重力/碰撞力推动，而是靠我们写代码设定 velocity（速度）后，
# 调用 move_and_slide() 来发生移动和碰撞检测。


class_name Player


const NORMAL_ANIMATION_PREFIX := &"normal"
# const 定义一个编译期常量（值固定、不可再修改，通常用全大写下划线命名）。
# 这里存的是"普通（行走）动画"的名称前缀，值为 StringName 类型（&"..." 是 StringName 字面量）。
# 例如最终动画名会是 normal_down / normal_up / normal_left / normal_right。

# 子弹场景引用：预加载子弹场景，生成子弹时直接实例化，避免运行时再做资源 IO。
const BULLET_SCENE := preload("res://scene-场景/bullet-Area2d.tscn")
# 武装（强化）形态下玩家身体动画的名称前缀，最终动画名如 armed_down / armed_left。
const ARMED_ANIMATION_PREFIX := &"armed"


# 各 Buff 的"无效果"基准值：倍率 1.0 表示不改变原速度/射速。
const DEFAULT_MOVE_SPEED_MULTIPLIER := 1.0
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
# 螺旋弹幕单次发射后相位的旋转步长（弧度）。PI/12 ≈ 15°，
# 连续射击时相位逐渐累加旋转，形成一圈圈旋转扩散的弹幕效果。
const SPIRAL_PHASE_STEP := PI / 12

# 受击闪烁着色器参数的名称，通过该参数开关/关闭受击闪烁效果。
const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"

# 子弹出生点检测、墙体射线查询使用的碰撞掩码：只检测第 1 层（World/墙体）。
# 碰撞掩码按二进制位选择物理层：1 = 2^0，即第 1 层；
# 这样射线只打墙，不会误伤玩家/敌人/子弹等其它层对象。
const WORLD_COLLISION_MASK := 1


# @onready 表示这个变量要等本节点与其所有子节点都进入场景树、ready 之后才赋值，
# 否则过早访问子节点 $ 路径会得到 null（节点还不存在）。
# $ 是 get_node() 的缩写："$Body-AnimatedSprite2D" 即获取当前节点下名为该名字的子节点。

# 身体动画播放器：后续用它切换/播放四个方向及死亡等动画。
@onready var body_sprite: AnimatedSprite2D = $"Body-AnimatedSprite2D"
# 螺旋强化形态下额外显示的浮游炮特效（独立于身体动画的一层表现）。
@onready var armed_effect_sprite: AnimatedSprite2D = $"Armed-AnimatedSprite2D"
# 射击计时器：只负责限制开火频率（冷却），不管理子弹本体。
@onready var shooting_timer: Timer = $ShootingTimer

# 玩家场景自带的三类音效（位于玩家自己的 AudioContainer 下）：
# 开火、移动脚步、拾取音效。
@onready var shoot_sfx_player: AudioStreamPlayer = $AudioContainer/ShootSfxPlayer
@onready var move_sfx_player: AudioStreamPlayer = $AudioContainer/MoveSfxPlayer
@onready var pickup_sfx_player: AudioStreamPlayer = $AudioContainer/PickupSfxPlayer


var facing_suffix: StringName = &"right"
# var 定义一个实例变量（可读可写），并声明类型为 StringName，初值 &"right"。
# facing_suffix 记录角色当前朝向的后缀（right/left/up/down），
# 初始默认朝右，用来和动画前缀拼出完整动画名。


# 当前移速倍率，由道具效果驱动（1.0 = 不加速）。
var current_move_speed_multiplier: float = DEFAULT_MOVE_SPEED_MULTIPLIER
# 普通射速道具提供的射速倍率。
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 形态道具（如螺旋强化形态）专属的射速倍率。
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 当前玩家形态，决定使用 normal 还是 armed 动画。
var current_form_mode: int = PickupConfig.PlayerFormMode.NORMAL
# 当前弹幕模式，决定普通定向射击还是螺旋弹幕。
var current_shot_pattern: int = PickupConfig.ShotPattern.NORMAL
# 三类 Buff 分别维护剩余持续时间，避免互相覆盖。
var speed_buff_time_left: float = 0.0
var rapid_buff_time_left: float = 0.0
var form_buff_time_left: float = 0.0
# 螺旋弹幕的相位（当前发射角度），用来让连续射击形成旋转感。
var spiral_phase: float = 0.0


@export var move_speed: float = 120.0
# @export 表示把这个变量暴露到检查器（Inspector）面板里，可直接在编辑器调数值。
# move_speed 是移动速度，单位：像素/秒。初值 120.0，即每秒移动约 120 像素。

# 玩家最大生命值。
@export var max_health: int = 5
# 受伤后进入无敌闪烁的持续时间（秒）。
@export var invincibility_duration: float = 1.0

# 玩家当前生命值，由最大生命值初始化。
var current_health: int = 0
# 无敌剩余时间，大于 0 时忽略新的受伤请求。
var invincibility_time_left: float = 0.0
# 玩家死亡后停止移动和攻击。
var is_dead: bool = false


# 连续开火之间的最短间隔（秒）。
@export var fire_interval: float = 0.18
# 子弹生成时相对玩家中心的偏移距离，避免子弹出生在身体内部。
@export var bullet_spawn_distance: float = 18.0


# _ready 是 Godot 内置回调：节点进入场景树并完成初始化时自动调用一次。
func _ready() -> void:
	# 生命值至少为 1，避免把 max_health 配置成 0/负数时角色"出生即死亡"。
	current_health = maxi(max_health, 1)
	# one_shot = true：计时器到期后自动停止，等待下一次手动 start()，
	# 这样冷却结束时才会放开下一次开火（"按一下打一发"）。
	shooting_timer.one_shot = true
	# 初始冷却时长跟随当前有效射速（尚未拾取射速 Buff 时就是基础间隔）。
	shooting_timer.wait_time = _get_effective_fire_interval()
	# 开场先关闭受击闪烁，防止着色器参数残留导致一直闪。
	_set_hurt_blink_enabled(false)
	# 进入场景后立即按当前朝向播放一次对应动画，避免角色一开始没有正确显示动画帧。
	_update_animation()
	_update_armed_effect()


# _physics_process 是内置回调：每个物理帧调用一次（默认 60 帧/秒，与物理同步）。
# 参数 delta 是本帧与上一物理帧之间的时间间隔（秒），适合放进移动/物理逻辑。
func _physics_process(delta: float) -> void:
	# 先推进无敌时间与道具 Buff 计时（放在死亡判断之前，逻辑见各函数内部）。
	_update_invincibility(delta)
	_update_pickup_effects(delta)

	# 死亡后：清零速度、停脚步音效，不再处理输入与射击。
	if is_dead:
		velocity = Vector2.ZERO
		_set_move_sfx_active(false)
		return

	# var ... := 定义一个局部变量，类型由右侧表达式自动推断（省去显式类型）。
	# Input.get_vector() 读取一组输入动作（负方向、正方向、向上、向下），
	# 返回一个"已经归一化"的 Vector2：八方向输入时长 1（对角不加速），
	# 什么都不按时返回 Vector2.ZERO，即 (0, 0)。
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	# 射击方向独立于移动方向读取，允许"边移动边朝另一方向射击"。
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	# 是否在移动，用于驱动脚步音效的启停。
	var is_moving := move_input != Vector2.ZERO
	# CharacterBody2D 通过 velocity 配合 move_and_slide() 完成移动，
	# move_and_slide() 会自动处理与墙体/边界的碰撞与滑动。
	velocity = move_input * _get_effective_move_speed()
	move_and_slide()
	_set_move_sfx_active(is_moving)

	# 弹幕模式分流：
	# 螺旋形态下自动按相位旋转发射（不读取射击输入）；
	# 普通形态下只有按住射击方向才尝试开火。
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		_try_auto_spiral_shoot()
	elif shoot_input != Vector2.ZERO:
		_try_shoot(shoot_input)

	_update_facing(move_input, shoot_input)
	_update_animation()
	_update_armed_effect()


# 根据当前朝向拼出动画名，并在动画实际变化时再切换播放。
func _update_animation() -> void:
	# 用格式字符串 "%s_%s" 把动画前缀和朝向后缀拼接，例如 "armed" + "right" -> "armed_right"。
	# % [a, b] 表示把 a、b 分别填入两个 %s 占位符；动画名统一用 StringName。
	var animation_name := StringName("%s_%s" % [_get_animation_prefix(), facing_suffix])

	# 若当前形态（如 armed）没有对应朝向的动画，回退到普通形态的同朝向动画，
	# 保证"动画资源缺失"时角色不至于什么都不播。
	if not body_sprite.sprite_frames.has_animation(animation_name):
		var fallback_animation_name := StringName("%s_%s" % [NORMAL_ANIMATION_PREFIX, facing_suffix])
		if not body_sprite.sprite_frames.has_animation(fallback_animation_name):
			# 两个名字都没有时打印警告并退出，防止播放不存在的动画报错。
			push_warning("Missing player animation: %s" % animation_name)
			return
		animation_name = fallback_animation_name

	# 只有动画确实变化时才 play，避免每帧重复重启动画。
	if body_sprite.animation != animation_name:
		body_sprite.play(animation_name)


# 更新角色朝向：射击方向优先于移动方向，决定当前显示的角色朝向。
func _update_facing(move_input: Vector2, shoot_input: Vector2) -> void:
	# 螺旋形态下射击方向持续旋转、不适合用来定朝向，
	# 因此只跟随移动方向更新朝向；站着不动则保持原朝向。
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		if move_input != Vector2.ZERO:
			facing_suffix = _vector_to_facing_suffix(move_input)
		return

	# 普通形态：优先按射击方向转向（打哪边脸朝哪边），
	# 没有射击输入时才退回按移动方向转向。
	if shoot_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(shoot_input)
	elif move_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(move_input)


# 尝试发射子弹：先检查冷却，再根据当前弹幕模式发射。
func _try_shoot(shoot_input: Vector2) -> void:
	# 冷却未结束（计时器仍在走）则跳过本次射击。
	if not shooting_timer.is_stopped():
		return

	var shoot_direction := shoot_input.normalized()
	# _fire_bullets 返回本次是否真的生成了子弹（可能因墙壁阻挡而失败）。
	var has_spawned_bullet := _fire_bullets(shoot_direction)
	# 只有成功生成子弹才播放开火音效。
	if has_spawned_bullet:
		_play_sfx(shoot_sfx_player)
	# 无论是否生成子弹都会启动冷却：被墙挡住时同样消耗一次冷却，
	# 避免玩家贴墙按住射击时每帧都发起无效的射线/生成尝试（防刷枪）。
	shooting_timer.start(_get_effective_fire_interval())


# 敌人或其他伤害来源统一通过这个入口让玩家受伤。
# 返回 true 表示本次伤害已生效（含致死），false 表示被无敌/死亡/非法参数拦截。
func apply_damage(amount: int) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false
	# 无敌时间内忽略一切伤害（受击后的短暂喘息窗口）。
	if invincibility_time_left > 0.0:
		return false

	current_health = maxi(current_health - amount, 0)
	if current_health <= 0:
		_die()
		return true

	# 未致死则进入无敌闪烁，避免同一帧内被多段伤害连续扣血。
	_start_invincibility()
	return true


# 获取玩家当前生命值（供 HUD/结算逻辑读取，避免外部直接访问内部变量）。
func get_current_health() -> int:
	return current_health


# 根据当前弹幕模式发射子弹，并返回这次是否至少成功生成了一枚子弹。
func _fire_bullets(base_direction: Vector2) -> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		# 螺旋形态：沿基准方向及其正后方各生成一枚，形成"双向对射"。
		# base_direction.rotated(PI) 即旋转 180° 得到反方向。
		var has_spawned_forward_bullet := _spawn_bullet(base_direction)
		var has_spawned_backward_bullet := _spawn_bullet(base_direction.rotated(PI))
		# 推进螺旋相位：wrapf 保证始终落在 [0, TAU)（整整一圈），下次发射方向会进一步旋转。
		spiral_phase = wrapf(spiral_phase + SPIRAL_PHASE_STEP, 0.0, TAU)
		return has_spawned_forward_bullet or has_spawned_backward_bullet

	return _spawn_bullet(base_direction)


# 实例化并生成一枚子弹。
func _spawn_bullet(shoot_direction: Vector2) -> bool:
	# 先做出生点射线检测：从玩家中心到子弹出生点之间被墙挡住就不生成。
	if not _can_spawn_bullet(shoot_direction):
		return false

	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return false

	# top_level = true：让子弹脱离父节点变换、直接使用世界坐标移动，
	# 这样即使父节点（主场景）有位移/缩放也不影响子弹轨迹。
	bullet.top_level = true
	# 注入飞行方向（setup 内部会自动归一化为单位向量）。
	bullet.setup(shoot_direction)

	# 子弹挂到当前主场景下而不是玩家节点下，避免跟随玩家一起移动。
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false

	spawn_parent.add_child(bullet)
	# 注意：必须先 add_child 再设置 global_position——
	# 入树时节点变换会被重置，若在入树前设置位置会被覆盖，top_level 节点同样适用此顺序。
	bullet.global_position = global_position + shoot_direction * bullet_spawn_distance
	return true


# 发射前先检查从玩家中心到子弹出生点的路径是否被世界碰撞挡住。
func _can_spawn_bullet(shoot_direction: Vector2) -> bool:
	var spawn_position := global_position + shoot_direction * bullet_spawn_distance
	# direct_space_state：当前 2D 物理世界的只读查询接口，用于射线/形状查询。
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return true

	# 构造一条射线查询：起点=玩家中心，终点=子弹出生点，只检测墙体层（掩码 1）。
	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		spawn_position,
		WORLD_COLLISION_MASK
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	# 排除玩家自己，避免射线起点就命中自身而误判为"被墙挡住"。
	query.exclude = [get_rid()]

	var hit_result: Dictionary = space_state.intersect_ray(query)
	# 字典为空 = 路径畅通，允许生成子弹。
	return hit_result.is_empty()


# 螺旋形态下自动按固定节奏朝 360 度方向旋转发射。
func _try_auto_spiral_shoot() -> void:
	if not shooting_timer.is_stopped():
		return

	# 以当前相位作为发射方向（Vector2.RIGHT 为 0° 基准，再旋转 spiral_phase 弧度）。
	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	var has_spawned_bullet := _fire_bullets(spiral_direction)
	if has_spawned_bullet:
		_play_sfx(shoot_sfx_player)
	shooting_timer.start(_get_effective_fire_interval())


# 每帧更新道具 Buff 剩余时间，并在到期后恢复默认状态。
func _update_pickup_effects(delta: float) -> void:
	# 移速 Buff：倒计时归零时恢复默认移速倍率。
	if speed_buff_time_left > 0.0:
		speed_buff_time_left = maxf(speed_buff_time_left - delta, 0.0)
		if speed_buff_time_left <= 0.0:
			current_move_speed_multiplier = DEFAULT_MOVE_SPEED_MULTIPLIER

	# 射速 Buff：归零时恢复默认射速倍率，并刷新射击冷却计时器。
	if rapid_buff_time_left > 0.0:
		rapid_buff_time_left = maxf(rapid_buff_time_left - delta, 0.0)
		if rapid_buff_time_left <= 0.0:
			rapid_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			_refresh_shooting_timer_wait_time()

	# 形态 Buff：归零时退回普通形态/普通弹幕，一并清掉形态专属射速与螺旋相位。
	if form_buff_time_left > 0.0:
		form_buff_time_left = maxf(form_buff_time_left - delta, 0.0)
		if form_buff_time_left <= 0.0:
			current_form_mode = PickupConfig.PlayerFormMode.NORMAL
			current_shot_pattern = PickupConfig.ShotPattern.NORMAL
			form_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			spiral_phase = 0.0
			_refresh_shooting_timer_wait_time()


# 更新玩家无敌时间，并在结束时关闭闪烁效果。
func _update_invincibility(delta: float) -> void:
	if invincibility_time_left <= 0.0:
		return

	invincibility_time_left = maxf(invincibility_time_left - delta, 0.0)
	# 计时还未归零，继续保持无敌/闪烁状态。
	if invincibility_time_left > 0.0:
		return

	# 计时归零：关闭受击闪烁，恢复正常显示。
	_set_hurt_blink_enabled(false)


# 计算当前有效移动速度：基础速度 × 当前移速倍率。
func _get_effective_move_speed() -> float:
	return move_speed * current_move_speed_multiplier


# 计算当前有效开火间隔。射速倍率越高，开火间隔越短。
func _get_effective_fire_interval() -> float:
	# maxf(..., 0.01) 兜底：防止倍率异常导致间隔为 0 或负数，避免计时器行为异常。
	return maxf(fire_interval / _get_effective_fire_rate_multiplier(), 0.01)


# 强化形态激活时优先使用形态自带的射速倍率，否则退回普通射速倍率。
func _get_effective_fire_rate_multiplier() -> float:
	if _has_active_form_override():
		return maxf(form_fire_rate_multiplier, 0.01)

	return maxf(rapid_fire_rate_multiplier, 0.01)


# 只要玩家仍处于特殊形态或特殊弹幕模式，就视为强化仍在生效。
func _has_active_form_override() -> bool:
	return (
		current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)


# 统一刷新射击计时器的基础间隔，避免 Buff 生效后仍使用旧数值。
func _refresh_shooting_timer_wait_time() -> void:
	var new_interval := _get_effective_fire_interval()
	shooting_timer.wait_time = new_interval

	# 如果玩家在冷却途中拾取了更快的射速 Buff，需要让当前这次冷却也立刻缩短。
	if shooting_timer.is_stopped():
		return
	if shooting_timer.time_left <= new_interval:
		return
	shooting_timer.start(new_interval)


# 开启玩家受伤后的无敌闪烁状态。
func _start_invincibility() -> void:
	invincibility_time_left = maxf(invincibility_duration, 0.0)
	# 只有时长 > 0 才开启闪烁，避免无效配置下意外闪烁。
	_set_hurt_blink_enabled(invincibility_time_left > 0.0)


# 统一设置玩家受击闪烁开关，便于后续与其他表现逻辑解耦。
func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)


# 玩家生命值归零时进入死亡状态：停止一切行为并隐藏强化特效。
func _die() -> void:
	is_dead = true
	velocity = Vector2.ZERO
	invincibility_time_left = 0.0
	_set_hurt_blink_enabled(false)
	shooting_timer.stop()
	_set_move_sfx_active(false)
	armed_effect_sprite.visible = false
	armed_effect_sprite.stop()


# 根据当前形态选择动画前缀：ARMED 形态用 armed_*，否则 normal_*。
func _get_animation_prefix() -> StringName:
	if current_form_mode == PickupConfig.PlayerFormMode.ARMED:
		return ARMED_ANIMATION_PREFIX

	return NORMAL_ANIMATION_PREFIX


# 强化螺旋形态下显示浮游炮动画，结束后隐藏并停止播放。
func _update_armed_effect() -> void:
	var is_armed := current_form_mode == PickupConfig.PlayerFormMode.ARMED

	# 非强化形态：确保特效隐藏且停止播放（加 visible/is_playing 判断保持幂等）。
	if not is_armed:
		if armed_effect_sprite.visible:
			armed_effect_sprite.visible = false
		if armed_effect_sprite.is_playing():
			armed_effect_sprite.stop()
		return

	# 强化形态：先保证可见，再保证正在播放。
	if not armed_effect_sprite.visible:
		armed_effect_sprite.visible = true
	if armed_effect_sprite.is_playing():
		return
	# 防御：特效节点没有动画资源时直接跳过播放。
	if armed_effect_sprite.sprite_frames == null:
		return
	# 播放默认动画（该特效场景只有 "default" 一段循环动画）。
	if armed_effect_sprite.sprite_frames.has_animation(&"default"):
		armed_effect_sprite.play(&"default")


# 道具统一通过这个入口影响玩家，Pickup 场景不直接改玩家内部细节。
func apply_pickup(config: PickupConfig) -> bool:
	if config == null:
		return false

	var applied := false
	# 需要刷新射击冷却计时器的缓冲标记（射速/形态类 Buff 会影响冷却时长）。
	var should_refresh_shooting_timer := false
	# duration 语义（与 pickup_config.gd 注释保持一致）：
	#   duration > 0  → 限时 Buff，剩余时间按帧递减，归零后恢复默认；
	#   duration <= 0 → 永久生效：把剩余时间设为正无穷（INF），
	#                    _update_pickup_effects 的倒计时永远无法归零，
	#                    直到被同类型道具覆盖或游戏结束。
	var buff_duration := maxf(config.duration, 0.0)
	if buff_duration <= 0.0:
		buff_duration = INF
	# 形态/弹幕任一有覆盖，才算"强化形态类道具"。
	var has_form_override := (
		config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or config.shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	# 射速倍率 != 1.0 才算"射速改动"（用近似比较避免浮点误差）。
	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)

	# 移速类：直接覆盖移速倍率并重置 Buff 倒计时。
	if not is_equal_approx(config.move_speed_multiplier, DEFAULT_MOVE_SPEED_MULTIPLIER):
		current_move_speed_multiplier = config.move_speed_multiplier
		speed_buff_time_left = buff_duration
		applied = true

	# 普通射速道具与形态专属射速拆开维护，避免螺旋形态的射速被其他 Buff 状态覆盖。
	if has_fire_rate_override and not has_form_override:
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
		rapid_buff_time_left = buff_duration
		should_refresh_shooting_timer = true
		applied = true

	# 形态类：切换形态/弹幕，并带上形态专属射速（未配置射速时用默认 1.0）。
	if has_form_override:
		current_form_mode = config.player_form_mode
		current_shot_pattern = config.shot_pattern
		form_fire_rate_multiplier = (
			config.fire_rate_multiplier if has_fire_rate_override else DEFAULT_FIRE_RATE_MULTIPLIER
		)
		form_buff_time_left = buff_duration
		# 重新进入螺旋形态时相位清零，保证每次变身的弹幕起点一致。
		spiral_phase = 0.0
		should_refresh_shooting_timer = true
		applied = true

	# 射速/形态变化后刷新冷却计时器，让新倍率立即生效。
	if should_refresh_shooting_timer:
		_refresh_shooting_timer_wait_time()

	# 只有真正应用了某个效果才播放拾取音效；纯标签/无效果的配置返回 false，不消耗道具。
	if applied:
		_play_sfx(pickup_sfx_player)
	return applied


# 主场景在结算时可调用这个接口，统一关闭玩家仍在播放的运行时音频。
func stop_runtime_audio() -> void:
	_set_move_sfx_active(false)
	if shoot_sfx_player != null and shoot_sfx_player.playing:
		shoot_sfx_player.stop()
	if pickup_sfx_player != null and pickup_sfx_player.playing:
		pickup_sfx_player.stop()


# 根据移动状态启停移动音效（循环脚步声）。
func _set_move_sfx_active(active: bool) -> void:
	if move_sfx_player == null or move_sfx_player.stream == null:
		return

	if active:
		if not move_sfx_player.playing:
			move_sfx_player.play()
		return

	if move_sfx_player.playing:
		move_sfx_player.stop()


# 一次性音效统一使用"停止后重新播放"逻辑，避免快速触发时无法从头开始。
func _play_sfx(audio_player: AudioStreamPlayer) -> void:
	if audio_player == null or audio_player.stream == null:
		return

	audio_player.stop()
	audio_player.play()


# 自定义辅助函数：输入任意一个二维方向向量，输出对应的四方向后缀。
func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	# 比较水平分量与垂直分量的"绝对值大小"：
	# 若水平分量绝对值更大（或相等），说明主要是左右移动，优先判定为 left/right。
	# 这样做能让斜向输入二选一，避免四方向动画对对角方向出现歧义。
	if abs(direction.x) >= abs(direction.y):
		# 三元表达式（真值 if 条件 else 假值）：
		# 水平分量 > 0 时朝右 &"right"，否则朝左 &"left"。
		return &"right" if direction.x > 0.0 else &"left"

	# 走到这里说明垂直分量绝对值更大，判定上下：
	# 注意 Godot 2D 的 y 轴向下为正，所以 direction.y > 0 是"向下" &"down"，否则 &"up"。
	return &"down" if direction.y > 0.0 else &"up"
