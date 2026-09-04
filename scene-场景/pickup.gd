extends Area2D
# 掉落道具脚本：基于 Area2D 做"玩家进入即拾取"的重叠检测。
# Area2D 负责区域重叠检测与信号回调；拾取效果的具体应用委托给玩家脚本（apply_pickup）。

class_name Pickup

# 到期闪烁着色器参数名。
const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"


# 当前掉落物使用的配置资源。
@export var config: PickupConfig
# 道具在消失前多久开始闪烁提示（到期预警窗口）。
@export_range(0.0, 10.0, 0.1, "or_greater") var blink_before_expire: float = 1.2

# @onready：节点进入场景树后才可取子节点引用。
@onready var sprite: Sprite2D = $Sprite2D
@onready var lifetime_timer: Timer = $LifeTimer

# 闪烁一旦开启就保持到道具消失为止（不恢复），标记已进入"即将消失"状态。
var is_expiring: bool = false


# 初始化显示图标、寿命计时与拾取检测。
func _ready() -> void:
	# 玩家身体进入区域 → 尝试拾取。
	body_entered.connect(_on_body_entered)
	# 寿命计时结束 → 自动销毁。
	lifetime_timer.timeout.connect(_on_lifetime_timer_timeout)
	# 一次性计时：到期触发一次 timeout 即停止，不自动重启。
	lifetime_timer.one_shot = true
	# wait_time <= 0 表示"不限寿命"（永不过期、永不闪烁），此时不启动计时器。
	if lifetime_timer.wait_time > 0.0:
		lifetime_timer.start()
	# 初始关闭闪烁，防止着色器参数残留导致开场就闪。
	_set_blink_enabled(false)
	_apply_config_to_visual()


# 道具临近消失时开启闪烁提示。
func _process(_delta: float) -> void:
	# 已进入消失预警阶段就不重复处理。
	if is_expiring:
		return
	# 不限寿命（wait_time <= 0 未启动）或计时器已停止时
	# 没有"剩余时间"概念，直接跳过（该分支在任何运行顺序下都安全）。
	if lifetime_timer.is_stopped():
		return
	# 剩余寿命还大于闪烁阈值，还没到提示时机。
	if lifetime_timer.time_left > blink_before_expire:
		return

	# 剩余寿命进入 [0, blink_before_expire] 区间：开启闪烁并锁定状态。
	is_expiring = true
	_set_blink_enabled(true)


# 将配置中的图标资源应用到显示节点上。
func _apply_config_to_visual() -> void:
	if config == null:
		push_warning("Pickup config is missing.")
		return

	sprite.texture = config.icon_texture


# 玩家进入后，将配置统一交给玩家处理；是否应用 Buff 由玩家自己决定。
func _on_body_entered(body: Node2D) -> void:
	if config == null:
		return
	# 只响应玩家（Area2D 碰撞掩码已限定 Player 层，类型判断是双保险）。
	var player := body as Player
	if player == null:
		return
	# apply_pickup 返回是否真正应用了某个效果：
	# 已应用 → 销毁道具；纯标签/无效果的配置返回 false → 道具留在原地。
	if player.apply_pickup(config):
		queue_free()


# 道具寿命结束后自动消失。
func _on_lifetime_timer_timeout() -> void:
	queue_free()


# 统一控制道具是否使用闪烁效果。
func _set_blink_enabled(enabled: bool) -> void:
	var sprite_material := sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)
