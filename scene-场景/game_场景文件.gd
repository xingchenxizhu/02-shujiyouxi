extends Node2D
# 主场景（世界）脚本：负责刷怪调度、关卡倒计时、HUD 更新与胜负结算。
# 玩家/敌人/子弹/道具各有独立脚本，这里只做"世界级"的流程编排与状态汇总。


# 结算弹窗文案常量，集中管理便于统一修改。
const RESULT_TITLE_WIN := "你赢了"
const RESULT_TITLE_LOSE := "你输了"
const RESULT_MESSAGE_WIN := "你成功坚持到了倒计时结束。"
const RESULT_MESSAGE_LOSE := "玩家生命值已归零。"
const RESULT_OK_BUTTON_TEXT := "结束游戏"


# 默认敌人场景与四种敌人配置资源。
@export_group("刷怪资源")
@export var enemy_scene: PackedScene = preload("res://scene-场景/enemy.tscn")
@export var enemy_configs: Array[EnemyConfig] = [
	preload("res://resources/config/enemy_basic.tres"),
	preload("res://resources/config/enemy_shelled.tres"),
	preload("res://resources/config/enemy_fast.tres"),
	preload("res://resources/config/enemy_bomber.tres"),
]

@export_group("刷怪节奏")
# 开局立即刷出的敌人数，用于快速验证系统是否正常工作。
@export_range(0, 100, 1, "or_greater") var initial_spawn_count: int = 1
# 每次计时器触发时生成的敌人数。
@export_range(1, 20, 1, "or_greater") var spawn_count_per_tick: int = 1
# 开局时的刷怪间隔（秒）。
@export_range(0.1, 60.0, 0.1, "or_greater") var spawn_interval: float = 1.5
# 关卡后期允许缩短到的最小刷怪间隔（秒）。
@export_range(0.1, 60.0, 0.1, "or_greater") var min_spawn_interval: float = 0.6
# 场上允许同时存在的最大敌人数，避免无限堆积拖慢性能。
@export_range(1, 200, 1, "or_greater") var max_alive_enemies: int = 12
# 注：旧版基于"游戏累计运行时间"的刷怪加速配置（spawn_acceleration_duration /
# game_time_elapsed）已删除，刷怪间隔改为随"关卡剩余时间"动态缩短，
# 见 _get_current_spawn_interval()。

@export_group("关卡 UI")
# 关卡倒计时总时长，单位为秒。
@export_range(1.0, 3600.0, 1.0, "or_greater") var stage_duration: float = 60.0


# 主场景中的核心引用：@onready 保证节点进入场景树后再取值，
# 提前访问 $ 路径只会得到 null。
@onready var player: Player = $Player
@onready var enemy_container: Node2D = $EnemyContainer
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer

@onready var life_count_label: Label = $HUDLayer/LifeCountLabel
@onready var time_bar: Sprite2D = $HUDLayer/TimeBar
@onready var result_dialog: AcceptDialog = $AcceptDialog

# HUD 各元素引用：用于把写死在世界坐标上的图标/文本按"屏幕边缘"重新锚定。
@onready var life_icon: Sprite2D = $HUDLayer/Lifelcon
@onready var time_icon: Sprite2D = $HUDLayer/Timelcon

# 基准分辨率下的 HUD 世界坐标（与 tscn 中的初始写死值一致），用于全屏时换算锚定。
const BASE_VIEWPORT := Vector2(960.0, 540.0)
const LIFE_ICON_POS := Vector2(-145.0, 71.0)
const LIFE_LABEL_POS := Vector2(-129.0, 63.0)
const TIME_ICON_POS := Vector2(-145.0, 95.0)
const TIME_BAR_POS := Vector2(-105.0, 95.0)

# 背景音乐与结算音效：只存在于主场景 AudioContainer 下。
# （开火/移动/拾取音效属于玩家场景自己的 AudioContainer，由玩家脚本自行引用。）
@onready var bgm_player: AudioStreamPlayer = $AudioContainer/BgmPlayer
@onready var result_win_sfx_player: AudioStreamPlayer = $AudioContainer/ResultWinSfxPlayer
@onready var result_lose_sfx_player: AudioStreamPlayer = $AudioContainer/ResultLoseSfxPlayer


# 随机数生成器，专门用于挑选出生点和敌人配置（独立实例，不污染全局随机种子）。
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()
# 缓存出生点，避免每次刷怪都重新遍历场景树。
var enemy_spawn_points: Array[Marker2D] = []
# 缓存有效的敌人配置资源，自动忽略空条目。
var available_enemy_configs: Array[EnemyConfig] = []

# 当前关卡倒计时剩余秒数。
var stage_time_left: float = 0.0
# 记录时间条原始横向缩放，便于按百分比缩短。
var time_bar_full_scale_x: float = 1.0
# 记录时间条左边缘位置，保证缩放时从左往右收缩。
# 注意：该值只代表"基准分辨率下"的左边缘；全屏/窗口缩放后时间条会被
# _apply_hud_anchor_layout() 重新锚定，因此每帧收缩时要用"当前锚定位置 + 增量"
# 反推新的左边缘（见 _update_time_bar 中的 _time_bar_anchor_offset_x）。
var time_bar_left_edge_x: float = 0.0
# 锚定后"当前 position.x"相对基准左边缘的增量：position_anchor = left_edge_base * scale + offset。
# 由于锚定用的是统一 scale_factor，这里缓存 offset 供每帧收缩时还原右移后的正确左边缘。
var _time_bar_anchor_offset_x: float = 0.0
# 记录时间条贴图原始宽度，用于在 centered 模式下修正位置。
var time_bar_texture_width: float = 0.0
# 是否已经进入结算状态，避免重复弹出结果窗口。
var is_result_displayed: bool = false

# 当前视口（可视区域）尺寸，用于 HUD 锚定换算；由 size_changed 回调实时刷新。
var _viewport_size: Vector2 = BASE_VIEWPORT


# 初始化刷怪系统：缓存出生点、缓存配置、刷出初始敌人并启动定时器。
func _ready() -> void:
	# 随机化种子，保证每局的出生点/配置/掉落都不相同。
	random_generator.randomize()
	_configure_result_dialog()
	_setup_hud()
	_setup_hud_anchors()

	# 监听视口尺寸变化（窗口缩放/切换全屏都会触发），实时重算 HUD 位置与弹窗大小。
	get_viewport().size_changed.connect(_on_viewport_size_changed)

	_collect_enemy_spawn_points()
	_collect_enemy_configs()
	_configure_enemy_spawn_timer()
	_spawn_initial_enemies()
	_start_enemy_spawn_timer()


# 每帧推进关卡倒计时，并根据剩余时间动态调整刷怪间隔与 HUD 显示。
func _process(delta: float) -> void:
	# 已进入结算后不再推进任何世界状态，保证画面定格在结算画面。
	if is_result_displayed:
		return

	_update_stage_timer(delta)
	_update_spawn_interval()
	_update_hud()
	_check_game_result()


# 配置结算弹窗，使其在暂停状态下仍可交互，并统一由代码控制显示。
func _configure_result_dialog() -> void:
	# 禁用 Esc 关闭：结算结果必须由玩家点"结束游戏"按钮确认退出。
	result_dialog.dialog_close_on_escape = false
	result_dialog.ok_button_text = RESULT_OK_BUTTON_TEXT
	result_dialog.hide()

	# 所有关闭路径（确定/关闭请求/取消）都收敛到同一个退出回调；
	# is_connected 防止重复连接导致回调被调用多次。
	if not result_dialog.confirmed.is_connected(_on_result_dialog_exit_requested):
		result_dialog.confirmed.connect(_on_result_dialog_exit_requested)
	if not result_dialog.close_requested.is_connected(_on_result_dialog_exit_requested):
		result_dialog.close_requested.connect(_on_result_dialog_exit_requested)
	if not result_dialog.canceled.is_connected(_on_result_dialog_exit_requested):
		result_dialog.canceled.connect(_on_result_dialog_exit_requested)


# 缓存时间条的初始尺寸信息，并刷新一次开场 HUD。
func _setup_hud() -> void:
	# 倒计时初始值 = 关卡总时长（maxf 兜底防止负数配置）。
	stage_time_left = maxf(stage_duration, 0.0)

	# 记录原始横向缩放，之后按 fill_ratio 百分比缩放。
	time_bar_full_scale_x = time_bar.scale.x
	if time_bar.texture != null:
		time_bar_texture_width = time_bar.texture.get_width()
	# centered 模式下贴图以节点位置为中心，需要反推出左边缘坐标；
	# 非 centered 模式下左边缘就是 position.x 本身。
	if time_bar.centered:
		time_bar_left_edge_x = time_bar.position.x - (time_bar_texture_width * time_bar_full_scale_x * 0.5)
	else:
		time_bar_left_edge_x = time_bar.position.x

	_update_hud()


# 把 HUD 元素按"屏幕边缘"锚定，保证不同分辨率/全屏下不会飘到奇怪位置。
# 思路：基准 960×540 时它们停在 tscn 里写死的位置；其他分辨率下按基准比例
# 换算成相对屏幕边缘的偏移，让 UI 始终贴住画面左上角、并与视觉整体等比缩放。
func _setup_hud_anchors() -> void:
	_viewport_size = get_viewport_rect().size
	_apply_hud_anchor_layout()


# 视口尺寸变化回调：重新读取可视区域并刷新 HUD 与弹窗布局。
func _on_viewport_size_changed() -> void:
	_viewport_size = get_viewport_rect().size
	_apply_hud_anchor_layout()


# 按当前视口尺寸重算 HUD 各元素位置，以及弹窗尺寸。
# 使用 get_viewport_rect 是因为 canvas_items 拉伸下它就是"所见即所得"的屏幕区域，
# 锚定计算直接锚在屏幕边缘（0,0），等价于 CanvasLayer/Control 的左上角锚点。
func _apply_hud_anchor_layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	# 以屏幕宽做等比：沿用基准 960 的视觉布局，全屏放大时按比例同时放远，
	# 避免在更宽的屏幕上挤成一团、也更贴合 canvas_items 的等比缩放观感。
	var base_width := maxf(BASE_VIEWPORT.x, 1.0)
	var scale_factor := viewport_size.x / base_width

	# 图标/精灵：直接按比例重设世界位置（屏幕左上角为基准）。
	life_icon.position = LIFE_ICON_POS * scale_factor
	time_icon.position = TIME_ICON_POS * scale_factor
	time_bar.position = TIME_BAR_POS * scale_factor

	# 记录锚定后的时间条位置相对基准左边缘的增量，
	# 使每帧收缩（_update_time_bar）能基于"锚定后的新位置"还原左边缘，而不是写回基准坐标。
	_time_bar_anchor_offset_x = time_bar.position.x - (time_bar_left_edge_x * scale_factor)

	# Label 用 offset_left/top 表达位置（它原本没有 position）。
	life_count_label.offset_left = LIFE_LABEL_POS.x * scale_factor
	life_count_label.offset_top = LIFE_LABEL_POS.y * scale_factor

	# 结算弹窗：按视口宽度比例缩放尺寸，全屏下不再显得过小。
	result_dialog.size = _scaled_dialog_size(viewport_size)


# 计算结算弹窗的目标尺寸：以 960 宽为基准，按视口宽度等比缩放并夹在合理区间。
func _scaled_dialog_size(viewport_size: Vector2) -> Vector2i:
	var ratio := clampf(viewport_size.x / maxf(BASE_VIEWPORT.x, 1.0), 1.0, 1.8)
	var target := Vector2(200.0, 100.0) * ratio
	return Vector2i(roundi(target.x), roundi(target.y))


# 关卡倒计时持续递减，到 0 后保持不再继续减少。
func _update_stage_timer(delta: float) -> void:
	if stage_time_left <= 0.0:
		stage_time_left = 0.0
		return

	stage_time_left = maxf(stage_time_left - delta, 0.0)


# 统一刷新生命文本与时间条，避免 UI 更新代码散落在不同位置。
func _update_hud() -> void:
	_update_life_count_label()
	_update_time_bar()


# 将玩家当前生命值显示为"x 数字"的形式。
func _update_life_count_label() -> void:
	life_count_label.text = "x %d" % _get_player_current_health()


# 按倒计时百分比缩放时间条，并修正位置让它始终从左往右缩短。
func _update_time_bar() -> void:
	# fill_ratio = 剩余时间 / 总时长，取值 [0, 1]；
	# stage_duration <= 0 时保持全空（0.0），避免除零。
	var fill_ratio := 0.0
	if stage_duration > 0.0:
		fill_ratio = clampf(stage_time_left / stage_duration, 0.0, 1.0)

	# 只缩放横向（scale.x），纵向不动，让时间条宽度体现剩余时间占比。
	time_bar.scale.x = time_bar_full_scale_x * fill_ratio

	# 非 centered 模式：左边缘固定，直接把位置恢复到原始左边缘即可。
	# 全屏锚定后 position 已被 _apply_hud_anchor_layout 重设，这里要用
	# "基准左边缘 × 当前缩放 + 锚定增量"还原正确的左边缘，避免写回基准坐标。
	if not time_bar.centered:
		var scale_factor := get_viewport_rect().size.x / maxf(BASE_VIEWPORT.x, 1.0)
		time_bar.position.x = (time_bar_left_edge_x * scale_factor) + _time_bar_anchor_offset_x
		return

	# centered 模式：贴图以节点位置为中心，按当前宽度重新计算中心坐标，
	# 使左边缘 fixed 不变，实现"从左往右收缩"的视觉效果。
	var current_width := time_bar_texture_width * time_bar.scale.x
	time_bar.position.x = time_bar_left_edge_x + (current_width * 0.5)


# 根据当前游戏状态判断是否触发胜利或失败结算。
func _check_game_result() -> void:
	# 倒计时归零 → 胜利（存活到最后一刻）。
	if stage_time_left <= 0.0:
		_show_result_dialog(RESULT_TITLE_WIN, RESULT_MESSAGE_WIN)
		return

	# 玩家生命值归零 → 失败。
	if _get_player_current_health() <= 0:
		_show_result_dialog(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)


# 弹出结算窗口前暂停整个世界，并将焦点交给确定按钮。
func _show_result_dialog(result_title: String, result_message: String) -> void:
	if is_result_displayed:
		return

	is_result_displayed = true
	result_dialog.title = result_title
	result_dialog.dialog_text = result_message
	# 先停 BGM 并播放结算音效，再暂停世界。
	# 结算音效节点在 tscn 中配置为 process_mode=ALWAYS，暂停后仍能完整播放。
	_play_result_audio(result_title)

	_stop_world()
	result_dialog.popup_centered()

	# 聚焦"结束游戏"按钮，纯键盘操作可直接回车退出。
	var ok_button := result_dialog.get_ok_button()
	if ok_button != null:
		ok_button.grab_focus()


# 统一停止刷怪、冻结场景树，让结算窗口成为唯一可交互内容。
func _stop_world() -> void:
	enemy_spawn_timer.stop()
	player.stop_runtime_audio()
	# 时间缩放 0 + 场景树暂停：普通节点（默认 PAUSABLE）全部冻结。
	# AcceptDialog 在 tscn 中 process_mode=WHEN_PAUSED(2)：暂停时照常处理输入，
	# 因此结算弹窗可以正常点击/回车；结算音效节点为 ALWAYS(3)，暂停时继续发声。
	Engine.time_scale = 0.0
	get_tree().paused = true


# 结算前先停止背景音乐，再播放对应的胜利或失败音效。
func _play_result_audio(result_title: String) -> void:
	if bgm_player.playing:
		bgm_player.stop()

	if result_title == RESULT_TITLE_WIN:
		_play_sfx(result_win_sfx_player)
		return

	if result_title == RESULT_TITLE_LOSE:
		_play_sfx(result_lose_sfx_player)


# 一次性音效统一使用"停止后重新播放"的方式，保证重复触发时能从头开始。
func _play_sfx(audio_player: AudioStreamPlayer) -> void:
	if audio_player == null or audio_player.stream == null:
		return

	audio_player.stop()
	audio_player.play()


# 结算窗口的所有关闭路径都统一结束游戏，保持单局流程最简。
func _on_result_dialog_exit_requested() -> void:
	get_tree().quit()


# 通过玩家对外暴露的接口读取当前生命值，避免 Game 直接依赖玩家内部变量。
func _get_player_current_health() -> int:
	return player.get_current_health()


# 从 EnemySpawnPoints 节点下收集所有 Marker2D 作为可选出生点。
func _collect_enemy_spawn_points() -> void:
	enemy_spawn_points.clear()

	# 遍历子节点并做类型过滤：只有 Marker2D 才视为有效出生点。
	for child in enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			enemy_spawn_points.append(spawn_point)

	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")


# 缓存有效的敌人配置资源，便于后续随机挑选。
func _collect_enemy_configs() -> void:
	available_enemy_configs.clear()

	# 数组可能混入空槽（如资源被删除后残留引用），统一过滤掉。
	for enemy_config in enemy_configs:
		if enemy_config != null:
			available_enemy_configs.append(enemy_config)

	if available_enemy_configs.is_empty():
		push_warning("Game 场景没有可用的敌人配置资源。")


# 统一配置主场景中的刷怪计时器。
func _configure_enemy_spawn_timer() -> void:
	# 循环触发：每次 timeout 都刷一批敌人，直到结算时被 _stop_world 停止。
	enemy_spawn_timer.one_shot = false
	enemy_spawn_timer.wait_time = _get_current_spawn_interval()

	if not enemy_spawn_timer.timeout.is_connected(_on_enemy_spawn_timer_timeout):
		enemy_spawn_timer.timeout.connect(_on_enemy_spawn_timer_timeout)


# 随着关卡推进动态缩短刷怪间隔，让后期节奏自然加快。
func _update_spawn_interval() -> void:
	var current_interval := _get_current_spawn_interval()
	# 间隔没变化就不用处理（is_equal_approx 兼容浮点抖动）。
	if is_equal_approx(enemy_spawn_timer.wait_time, current_interval):
		return

	enemy_spawn_timer.wait_time = current_interval

	# 如果当前这一轮倒计时比新的间隔还长，就立刻切到更快的节奏。
	if enemy_spawn_timer.is_stopped():
		return

	if enemy_spawn_timer.time_left <= current_interval:
		return

	enemy_spawn_timer.start(current_interval)


# 通过"关卡剩余时间"计算当前刷怪间隔：
# 剩余时间越多（开局）间隔越接近 spawn_interval，越接近倒计时结束越接近 min_spawn_interval。
func _get_current_spawn_interval() -> float:
	# 下限保护：间隔至少 0.1 秒，避免计时器以极小值高频触发。
	var start_interval := maxf(spawn_interval, 0.1)
	# end 不能大于 start：min 保证"后期间隔 <= 开局间隔"（只会越来越快）。
	var end_interval := minf(maxf(min_spawn_interval, 0.1), start_interval)

	# 关卡时长无效（<=0）时直接返回最快间隔（防御除零）。
	if stage_duration <= 0.0:
		return end_interval

	# difficulty_ratio 从 0（开局）线性增长到 1（倒计时结束），
	# lerpf 在 start 与 end 之间按比例插值，形成平滑的加速曲线。
	var difficulty_ratio := 1.0 - clampf(stage_time_left / stage_duration, 0.0, 1.0)
	return lerpf(start_interval, end_interval, difficulty_ratio)


# 开局先刷出一小批敌人，方便立即看到运行效果。
func _spawn_initial_enemies() -> void:
	# 循环尝试 initial_spawn_count 次；一旦失败（如达到上限）提前结束。
	for _spawn_index in range(initial_spawn_count):
		if not _try_spawn_enemy():
			break


# 当前刷怪系统准备完成后再启动定时器。
func _start_enemy_spawn_timer() -> void:
	if not _is_spawn_system_ready():
		return

	enemy_spawn_timer.start()


# 每次计时器触发时，按设定数量尝试刷新敌人。
func _on_enemy_spawn_timer_timeout() -> void:
	for _spawn_index in range(spawn_count_per_tick):
		if not _try_spawn_enemy():
			break


# 尝试生成一个敌人，并自动完成位置和玩家目标初始化。
func _try_spawn_enemy() -> bool:
	# 前置条件：玩家/敌人场景/出生点/配置都可用，且未达到场上数量上限。
	if not _is_spawn_system_ready():
		return false
	if _get_alive_enemy_count() >= max_alive_enemies:
		return false

	var spawn_point := _pick_spawn_point()
	if spawn_point == null:
		return false

	var enemy_config := _pick_enemy_config()
	if enemy_config == null:
		return false

	var enemy_instance := enemy_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("敌人场景实例化失败，请检查 enemy_scene 设置。")
		return false

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_point.global_position
	# setup 同时注入配置与玩家目标，之后敌人自动开始追踪移动。
	enemy_instance.setup(enemy_config, player)

	return true


# 只要玩家、敌人场景、配置和出生点都有效，就允许继续刷怪。
func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and enemy_scene != null
		and not enemy_spawn_points.is_empty()
		and not available_enemy_configs.is_empty()
	)


# 随机挑选一个出生点。
func _pick_spawn_point() -> Marker2D:
	if enemy_spawn_points.is_empty():
		return null

	# randi_range 是闭区间随机索引，保证每个出生点等概率被选中。
	var random_index := random_generator.randi_range(0, enemy_spawn_points.size() - 1)
	return enemy_spawn_points[random_index]


# 随机挑选一个敌人配置。
func _pick_enemy_config() -> EnemyConfig:
	if available_enemy_configs.is_empty():
		return null

	var random_index := random_generator.randi_range(0, available_enemy_configs.size() - 1)
	return available_enemy_configs[random_index]


# 当前场上敌人数只统计 Enemy，避免掉落道具也挂在容器下时影响刷怪上限。
func _get_alive_enemy_count() -> int:
	var alive_enemy_count := 0

	# 掉落道具也是 EnemyContainer 的子节点，但类型不是 Enemy，不计入。
	for child in enemy_container.get_children():
		if child is Enemy:
			alive_enemy_count += 1

	return alive_enemy_count
