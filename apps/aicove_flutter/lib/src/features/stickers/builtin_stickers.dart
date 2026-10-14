import 'sticker_registry.dart';

/// 内置表情包所在的套组 id。
const String builtinStickerPackId = 'builtin_nahida';

/// 内置表情包的套组名。
const String builtinStickerPackName = '纳西妲（内置）';

/// 内置表情包（随应用打包，只读）。用户表情包由 [StickerLibrary] 导入。
const List<Sticker> builtinStickers = [
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_happy_smile',
    path: 'assets/stickers/nahida/happy_smile.png',
    tags: ['开心', '高兴', '快乐'],
    description: '开心微笑',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_sad_cry',
    path: 'assets/stickers/nahida/sad_cry.png',
    tags: ['难过', '伤心', '哭'],
    description: '伤心哭泣',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_angry_pout',
    path: 'assets/stickers/nahida/angry_pout.png',
    tags: ['生气', '哼', '讨厌'],
    description: '生气嘟嘴',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_shocked_gasp',
    path: 'assets/stickers/nahida/shocked_gasp.png',
    tags: ['震惊', '惊讶'],
    description: '震惊惊讶',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_yay_cheer',
    path: 'assets/stickers/nahida/yay_cheer.png',
    tags: ['开心', '太棒了', '耶'],
    description: '欢呼庆祝',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_good_morning_wave',
    path: 'assets/stickers/nahida/good_morning_wave.png',
    tags: ['早安', '早上好'],
    description: '早安招手',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_good_night_sleep',
    path: 'assets/stickers/nahida/good_night_sleep.png',
    tags: ['晚安', '睡觉', '好梦'],
    description: '晚安睡觉',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_bye_bye_wave',
    path: 'assets/stickers/nahida/bye_bye_wave.png',
    tags: ['再见', '拜拜'],
    description: '挥手告别',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_see_you_tomorrow',
    path: 'assets/stickers/nahida/see_you_tomorrow.png',
    tags: ['明天见'],
    description: '明天见',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_im_here_arrival',
    path: 'assets/stickers/nahida/im_here_arrival.png',
    tags: ['来了', '到了'],
    description: '到达现身',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_hug_request',
    path: 'assets/stickers/nahida/hug_request.png',
    tags: ['抱抱', '贴贴'],
    description: '求抱抱',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_thanks_prayer',
    path: 'assets/stickers/nahida/thanks_prayer.png',
    tags: ['谢谢', '感谢'],
    description: '感谢祈祷',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_thumbs_up_like',
    path: 'assets/stickers/nahida/thumbs_up_like.png',
    tags: ['赞', '好的', 'ok'],
    description: '点赞认可',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_received_salute',
    path: 'assets/stickers/nahida/received_salute.png',
    tags: ['收到', '了解'],
    description: '收到敬礼',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_lets_go_start',
    path: 'assets/stickers/nahida/lets_go_start.png',
    tags: ['加油', '冲', '出发'],
    description: '出发开始',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_curious_hmm',
    path: 'assets/stickers/nahida/curious_hmm.png',
    tags: ['嗯', '思考'],
    description: '好奇思考',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_question_confused',
    path: 'assets/stickers/nahida/question_confused.png',
    tags: ['疑惑', '不懂'],
    description: '疑惑不解',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_hungry_drool',
    path: 'assets/stickers/nahida/hungry_drool.png',
    tags: ['饿了', '想吃', '馋'],
    description: '饥饿流口水',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_resting_nap',
    path: 'assets/stickers/nahida/resting_nap.png',
    tags: ['累了', '休息'],
    description: '休息小憩',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_slacking_fish',
    path: 'assets/stickers/nahida/slacking_fish.png',
    tags: ['摸鱼', '偷懒', '躺平'],
    description: '摸鱼偷懒',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_busy_peeking',
    path: 'assets/stickers/nahida/busy_peeking.png',
    tags: ['忙', '稍等'],
    description: '忙碌偷看',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_bush_peek',
    path: 'assets/stickers/nahida/bush_peek.png',
    tags: ['偷看', '悄悄'],
    description: '草丛偷看',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_dendro_reaction',
    path: 'assets/stickers/nahida/dendro_reaction.png',
    tags: ['原神', '草元素'],
    description: '草元素反应',
  ),
  Sticker(
    packId: builtinStickerPackId,
    id: 'nahida_wisdom_glow',
    path: 'assets/stickers/nahida/wisdom_glow.png',
    tags: ['智慧', '懂了', '原来如此'],
    description: '智慧发光',
  ),
];
