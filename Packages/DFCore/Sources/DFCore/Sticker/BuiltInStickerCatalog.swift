import Foundation

/// 内置表情目录（Emoji）。
///
/// 口径：
/// - 只放 Emoji 字符：安装即用、不依赖网络、不需要附件文件；
/// - 每条带人工维护的语义与标签，既是搜索索引，也是 AI 选择表情时的依据；
/// - 静态图与 GIF 不在此目录硬编码（仓库里没有可打包的授权素材），
///   由用户导入或在线库下载后进入 `stickers` 表，避免伪造"内置图片表情"。
public enum BuiltInStickerCatalog {
    /// 内置包名称
    public static let packName = "内置 Emoji"

    /// 单条内置表情定义
    public struct Entry: Sendable, Equatable {
        public var emoji: String
        public var name: String
        public var semantics: String
        public var tags: String

        public init(emoji: String, name: String, semantics: String, tags: String) {
            self.emoji = emoji
            self.name = name
            self.semantics = semantics
            self.tags = tags
        }
    }

    public static let entries: [Entry] = [
        Entry(emoji: "😊", name: "微笑", semantics: "心情不错，轻松友好", tags: "开心,友好,日常"),
        Entry(emoji: "😄", name: "大笑", semantics: "被逗笑，很开心", tags: "开心,笑,正向"),
        Entry(emoji: "🥰", name: "喜欢", semantics: "亲近、喜欢、撒娇", tags: "喜欢,亲近,撒娇"),
        Entry(emoji: "😘", name: "飞吻", semantics: "亲密、调情、亲昵", tags: "亲密,撒娇,喜欢"),
        Entry(emoji: "🤗", name: "抱抱", semantics: "想抱一下，安慰或亲昵", tags: "安慰,亲近,抱"),
        Entry(emoji: "😳", name: "脸红", semantics: "害羞、被说中了", tags: "害羞,尴尬,脸红"),
        Entry(emoji: "😅", name: "尴尬笑", semantics: "有点无奈又想保持礼貌", tags: "尴尬,无奈"),
        Entry(emoji: "😭", name: "大哭", semantics: "难过、委屈，也可能是夸张表达", tags: "难过,委屈,哭"),
        Entry(emoji: "🥲", name: "苦笑", semantics: "强撑着的难过或感动", tags: "难过,感动,苦笑"),
        Entry(emoji: "😞", name: "失落", semantics: "失望、低落", tags: "失落,难过"),
        Entry(emoji: "😤", name: "生气", semantics: "不满、赌气", tags: "生气,不满"),
        Entry(emoji: "😠", name: "恼怒", semantics: "明确的不满", tags: "生气,恼怒"),
        Entry(emoji: "🙄", name: "翻白眼", semantics: "无奈、无语、轻微吐槽", tags: "无语,吐槽,无奈"),
        Entry(emoji: "😑", name: "面无表情", semantics: "不想说话、无奈", tags: "无语,冷漠,无奈"),
        Entry(emoji: "🤔", name: "思考", semantics: "在琢磨、有点怀疑", tags: "思考,疑惑"),
        Entry(emoji: "😯", name: "惊讶", semantics: "意外、被惊到", tags: "惊讶,意外"),
        Entry(emoji: "😱", name: "惊恐", semantics: "被吓到或夸张的震惊", tags: "震惊,夸张"),
        Entry(emoji: "🥺", name: "委屈求", semantics: "撒娇、请求、装可怜", tags: "撒娇,请求,委屈"),
        Entry(emoji: "😏", name: "坏笑", semantics: "调侃、得意", tags: "调侃,得意,坏笑"),
        Entry(emoji: "😜", name: "吐舌", semantics: "开玩笑、调皮", tags: "玩笑,调皮"),
        Entry(emoji: "🤪", name: "搞怪", semantics: "故意搞怪、活跃气氛", tags: "搞怪,玩笑"),
        Entry(emoji: "😂", name: "笑哭", semantics: "笑到不行，常带调侃", tags: "笑,调侃,正向"),
        Entry(emoji: "🤣", name: "笑翻", semantics: "太好笑了", tags: "笑,夸张"),
        Entry(emoji: "👍", name: "赞", semantics: "认可、同意", tags: "认可,同意"),
        Entry(emoji: "👎", name: "反对", semantics: "不认可、拒绝", tags: "拒绝,反对"),
        Entry(emoji: "👌", name: "没问题", semantics: "答应、确认", tags: "确认,答应"),
        Entry(emoji: "🙏", name: "拜托", semantics: "请求、感谢", tags: "请求,感谢"),
        Entry(emoji: "💪", name: "加油", semantics: "鼓励、打气", tags: "鼓励,加油"),
        Entry(emoji: "🤝", name: "握手", semantics: "达成一致、和解", tags: "和解,一致"),
        Entry(emoji: "❤️", name: "爱心", semantics: "喜欢、在意", tags: "喜欢,爱"),
        Entry(emoji: "💔", name: "心碎", semantics: "难过、受伤", tags: "难过,受伤"),
        Entry(emoji: "🔥", name: "火", semantics: "很棒、很燃", tags: "夸赞,热烈"),
        Entry(emoji: "✨", name: "闪光", semantics: "期待、亮眼", tags: "期待,夸赞"),
        Entry(emoji: "🎉", name: "庆祝", semantics: "恭喜、庆祝", tags: "庆祝,恭喜"),
        Entry(emoji: "🌙", name: "月亮", semantics: "夜晚、睡前", tags: "晚安,夜"),
        Entry(emoji: "☀️", name: "太阳", semantics: "早上、天气好", tags: "早安,天气"),
        Entry(emoji: "🍚", name: "吃饭", semantics: "吃饭、投喂", tags: "吃饭,日常"),
        Entry(emoji: "🐟", name: "小鱼", semantics: "大肥鱼的自指符号", tags: "自指,鱼"),
        Entry(emoji: "🫧", name: "泡泡", semantics: "轻松、可爱", tags: "可爱,轻松"),
        Entry(emoji: "😴", name: "困", semantics: "困了、想睡", tags: "困,睡觉"),
        Entry(emoji: "🤐", name: "闭嘴", semantics: "不想说 / 保密", tags: "沉默,保密"),
        Entry(emoji: "🫠", name: "融化", semantics: "被撩到、招架不住", tags: "害羞,撒娇"),
        Entry(emoji: "😮‍💨", name: "叹气", semantics: "疲惫、无奈", tags: "疲惫,无奈"),
        Entry(emoji: "🙃", name: "倒过来", semantics: "反讽、摆烂", tags: "反讽,摆烂")
    ]

    /// 内置表情的稳定 id：由 Emoji 字符派生，重复初始化不会产生重复行
    public static func stickerID(for entry: Entry) -> String {
        "builtin-emoji-" + SHA256.hash(entry.emoji).prefix(16)
    }
}
