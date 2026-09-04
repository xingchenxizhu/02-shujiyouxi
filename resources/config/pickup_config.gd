extends Resource
# 道具静态配置资源（ScriptableObject 等价物）：
# 策划可在编辑器中新建 .tres 配置每种道具的效果数值，
# 运行时脚本只读取这些字段，不包含任何逻辑。

class_name PickupConfig

# 道具大类标签：主要用于编辑器区分用途；
# 真正决定效果的是下面的 move_speed_multiplier /
# fire_rate_multiplier / player_form_mode / shot_pattern 字段组合。
enum PickupType {
	SPEED,
	RAPID,
	SPIRAL,
}

# 玩家形态模式：NORMAL=普通（normal_* 动画）/ ARMED=武装（armed_* 动画 + 浮游炮特效）。
enum PlayerFormMode {
	NORMAL,
	ARMED,
}

# 弹幕模式：NORMAL=按移动/射击方向定向单发 / SPIRAL=双向螺旋自动发射。
enum ShotPattern {
	NORMAL,
	SPIRAL,
}

@export_group("基础信息")
# 用于标记道具类型，便于在编辑器和逻辑中区分不同效果。
@export var pickup_type: PickupType = PickupType.SPEED
# 显示名称，便于在编辑器和调试信息中识别用途。
@export var display_name: String = "移速道具"
# 掉落权重，数值越大越容易在随机掉落时被抽中；设为 0 表示不参与掉落。
@export_range(0.0, 1000.0, 0.1, "or_greater") var drop_weight: float = 1.0


@export_group("显示资源")
# 道具在场景中显示的静态图标资源。
@export var icon_texture: Texture2D

@export_group("Buff 效果")
# 道具效果持续时间，单位为秒。
# 语义（与 player_character_body_2d.gd 的 apply_pickup 保持一致）：
#   duration > 0  → 限时 Buff：到期后恢复默认状态；
#   duration <= 0（0 或负值）→ 永久生效：剩余时间被设为 INF，
#                   直到被同类型道具覆盖或游戏结束。请谨慎配置。
@export_range(0.0, 120.0, 0.1, "or_greater") var duration: float = 5.0
# 玩家移速倍率，1.0 表示不改变，1.2 表示提升 20%。
@export_range(0.1, 5.0, 0.05, "or_greater") var move_speed_multiplier: float = 1.0
# 玩家射速倍率，1.0 表示不改变，1.5 表示射速提升 50%。
@export_range(0.1, 5.0, 0.05, "or_greater") var fire_rate_multiplier: float = 1.0


@export_group("形态与弹幕")
# 玩家拾取后切换到的形态模式（NORMAL=不变，ARMED=武装强化形态）。
@export var player_form_mode: PlayerFormMode = PlayerFormMode.NORMAL
# 玩家拾取后使用的弹幕模式（NORMAL=定向单发，SPIRAL=双向螺旋）。
@export var shot_pattern: ShotPattern = ShotPattern.NORMAL
