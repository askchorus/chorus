import Foundation

/// Lightweight in-app localization. We don't use .strings / String Catalogs because the app
/// is SPM-built and hand-packaged into the .app — wiring .lproj bundles into that is fiddly.
/// Instead `L("key")` looks the string up in `L10nTable` by the current language, which the
/// user picks in Settings (system / 中文 / English) and can switch instantly.

/// The effective language code ("zh" or "en") given the user's setting + system preference.
func currentLang() -> String {
    switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
    case "zh": return "zh"
    case "en": return "en"
    default:
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? "zh" : "en"
    }
}

/// Localized string for `key`. Falls back to English, then the key itself.
func L(_ key: String) -> String {
    let lang = currentLang()
    return L10nTable[key]?[lang] ?? L10nTable[key]?["en"] ?? key
}

/// Localized format string applied to args, e.g. Lf("panel.reload", name).
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Body text for the "all AIs finished" notification. Minimal lines, rotated so a message
/// you see on every broadcast stays fresh instead of feeling robotic. Localized.
func completionNotificationBody() -> String {
    let pool = currentLang() == "zh"
        ? ["都好了", "好了", "都答完了", "答案就绪"]
        : ["All done.", "Ready.", "All in.", "Answers in."]
    return pool.randomElement() ?? pool[0]
}

let L10nTable: [String: [String: String]] = [
    // MARK: Composer + panel chrome (main window)
    "composer.placeholder": [
        "zh": "问所有 AI…    ⌘↩ 发送 · ⌘V 贴图 · @某家 单独问",
        "en": "Ask all AIs…    ⌘↩ send · ⌘V image · @name asks one",
    ],
    "composer.imageAttached": ["zh": "已附加图片", "en": "Image attached"],
    "composer.removeImage": ["zh": "移除已附加的图片", "en": "Remove attached image"],
    "composer.sendHelp": ["zh": "发送给全部 (⌘↩)", "en": "Send to all (⌘↩)"],
    "menu.newChat": ["zh": "新对话", "en": "New chat"],
    "menu.reloadAll": ["zh": "刷新全部", "en": "Reload all"],
    "menu.panels": ["zh": "面板", "en": "Panels"],
    "menu.settings": ["zh": "设置…", "en": "Settings…"],
    "menu.actions": ["zh": "操作", "en": "Actions"],
    "menu.shareCard": ["zh": "生成分享卡片", "en": "Make a share card"],
    "panel.reload": ["zh": "重载 %@", "en": "Reload %@"],

    // MARK: Sheets — summary / share card / stats
    "common.close": ["zh": "关闭", "en": "Close"],
    "common.error": ["zh": "出错", "en": "Error"],
    "summary.button": ["zh": "汇总", "en": "Compare"],
    "layout.help": ["zh": "同时显示几个 AI", "en": "How many AIs to show"],
    "layout.showN": ["zh": "同时显示 %d 个 AI", "en": "Show %d AIs at once"],
    "summary.title": ["zh": "各家回答汇总", "en": "Answers compared"],
    "summary.working": ["zh": "正在综合各家回答…", "en": "Comparing the answers…"],
    "summary.workingHint": [
        "zh": "收集各家回答并交给模型综合，通常需要十几秒",
        "en": "Collecting each answer and handing them to the model — usually 10–30 seconds",
    ],
    "summary.needTwo": [
        "zh": "至少需要两家答完才能对比（现在只抓到 %d 家）。",
        "en": "At least two AIs need to finish before there's anything to compare (only %d so far).",
    ],
    "summary.needAPI": ["zh": "汇总需要一个 API 模型来做综合", "en": "Comparing needs an API model to do the synthesis"],
    "summary.openSettings": ["zh": "打开设置添加…", "en": "Open Settings to add one…"],
    "summary.pickModel": ["zh": "选一个模型，汇总各家 AI 的回答", "en": "Pick a model to compare the answers"],
    "summary.useModel": ["zh": "用 %@ 汇总", "en": "Compare with %@"],
    "summary.help": ["zh": "汇总各家回答：把所有 AI 的回答交给一个模型综合对比",
                     "en": "Compare answers: hand every AI's reply to one model for a side-by-side synthesis"],
    "share.title": ["zh": "分享卡片", "en": "Share card"],
    "share.empty": [
        "zh": "没有可分享的内容\n先广播一个问题，等各家答完再来",
        "en": "Nothing to share yet\nAsk a question first and let the AIs answer",
    ],
    "share.sizeDesktop": ["zh": "电脑版", "en": "Desktop"],
    "share.sizeMobile": ["zh": "手机版", "en": "Mobile"],
    "share.brand": ["zh": "Chorus · 同时问多个 AI", "en": "Chorus · Ask multiple AIs at once"],
    "share.copy": ["zh": "复制图片", "en": "Copy image"],
    "share.copied": ["zh": "已复制", "en": "Copied"],
    "share.save": ["zh": "保存…", "en": "Save…"],
    "stats.title": ["zh": "胜率统计", "en": "Win rate"],
    "stats.range7": ["zh": "7天", "en": "7 days"],
    "stats.range30": ["zh": "30天", "en": "30 days"],
    "stats.rangeAll": ["zh": "全部", "en": "All time"],
    "stats.lowSample": ["zh": "样本少", "en": "Few votes"],
    "stats.empty": [
        "zh": "还没有投票记录。\n广播一个问题，等各家答完，点面板标题栏的奖杯图标选出这轮最佳。",
        "en": "No votes yet.\nAsk a question, wait for the answers, then hit the trophy in a panel's header to pick the best one.",
    ],
    "stats.disclaimer": [
        "zh": "这是「你的口味」随时间的记录，不是模型客观评测；样本太少时别当真。",
        "en": "A record of YOUR taste over time — not an objective benchmark. Don't read much into a small sample.",
    ],

    // MARK: API errors (shown inside API panels)
    "api.err.auth": ["zh": "密钥无效或无权限", "en": "Invalid key or no permission"],
    "api.err.notFound": ["zh": "找不到接口/模型，检查 Base URL 和模型名", "en": "Endpoint or model not found — check the Base URL and model name"],
    "api.err.rateLimit": ["zh": "请求过多/额度不足", "en": "Rate limited or out of quota"],
    "api.err.offline": ["zh": "连不上服务器（本地模型没启动？）", "en": "Can't reach the server (is your local model running?)"],

    // MARK: Panel load failure
    "panel.loadFailed": ["zh": "%@ 加载失败", "en": "%@ failed to load"],
    "panel.loadFailed.hint": [
        "zh": "多为网络或代理问题（该站点在当前线路上不可达）。换个节点后重试。",
        "en": "Usually a network or proxy issue — this site is unreachable on the current route. Switch and retry.",
    ],
    "panel.retry": ["zh": "重试", "en": "Retry"],
    "panel.moreActions": ["zh": "更多操作", "en": "More actions"],
    "panel.moveLeft": ["zh": "左移", "en": "Move left"],
    "panel.moveRight": ["zh": "右移", "en": "Move right"],
    "panel.refreshSite": ["zh": "刷新站点状态（保留登录）", "en": "Refresh site state (stay signed in)"],
    "panel.clearData": ["zh": "清除该站点数据…", "en": "Clear this site's data…"],
    "panel.clearData.title": ["zh": "清除该站点的全部数据？", "en": "Clear all data for this site?"],
    "panel.clearData.message": [
        "zh": "会删除这个 AI 在 Chorus 内的 Cookie、缓存和本地存储——你需要重新登录它。仅在「刷新站点状态」无效时使用。",
        "en": "Deletes this AI's cookies, cache and local storage inside Chorus — you'll have to sign in again. Use this only when “Refresh site state” didn't help.",
    ],
    "panel.clearData.confirm": ["zh": "清除并重新加载", "en": "Clear and reload"],
    "panel.newChat": ["zh": "%@ 新对话", "en": "New chat in %@"],
    "settings.notify.waitAllVisible": ["zh": "等所有显示中的 AI 答完", "en": "Wait for every visible AI"],
    "settings.notify.waitAllVisible.desc": [
        "zh": "通知在当前显示的每个 AI 都答完后发出；增减面板时自动跟随，无需另外维护名单。关闭后可手动指定等待哪几个。",
        "en": "Notify once every AI you currently have on screen has finished. Follows panels as you show or hide them — no separate list to maintain. Turn off to pick specific AIs instead.",
    ],
    "panel.hide": ["zh": "隐藏 %@", "en": "Hide %@"],

    // MARK: Quick input
    "quick.placeholder": [
        "zh": "问所有 AI…",
        "en": "Ask all AIs…",
    ],
    "quick.pronounce": ["zh": "朗读  (⌘L)", "en": "Pronounce  (⌘L)"],
    "quick.mic": ["zh": "语音输入", "en": "Voice input"],
    "quick.micStop": ["zh": "停止录音", "en": "Stop recording"],
    "quick.micDenied": ["zh": "麦克风/语音识别权限被拒——请到系统设置开启", "en": "Mic / speech permission denied — enable it in System Settings"],
    "quick.chipHelp": ["zh": "以「%@：」为前缀发送给所有 AI", "en": "Send to all AIs with “%@: ” prepended"],
    "quick.pastedText": ["zh": "已粘贴长文本（%d 字）", "en": "Pasted text (%d chars)"],
    "quick.notInDict": ["zh": "词典里没有「%@」。", "en": "“%@” isn't in your dictionaries."],
    "quick.askAll": ["zh": "问所有 AI", "en": "Ask all AIs"],
    "quick.googleSearch": ["zh": "在浏览器里 Google 一下", "en": "Open Google search in your browser"],
    "quick.placeholderDirected": ["zh": "问 %@…", "en": "Ask %@…"],

    // MARK: @-mention picker + chip (both composers)
    "mention.chip": ["zh": "只问 %@", "en": "Only %@"],
    "mention.chipRemove": ["zh": "取消，恢复问所有 AI", "en": "Remove — back to asking every AI"],
    "mention.noMatch": ["zh": "没有叫这个名字的 AI", "en": "No AI by that name"],
    "composer.placeholderDirected": ["zh": "问 %@…    ⌘↩ 发送", "en": "Ask %@…    ⌘↩ send"],

    // MARK: Settings — agent bridge
    "settings.section.agent": ["zh": "编程助手接入（实验）", "en": "Coding-agent access (experimental)"],
    "settings.agent.enable": ["zh": "允许本机的 AI 助手向这些面板提问", "en": "Let a local AI agent ask these panels"],
    "settings.agent.desc": [
        "zh": "开启后，Claude Code / Codex 等本机助手可以把问题发给你当前显示的 AI 面板，并拿回各家的原文回答——用的是你自己的订阅，不消耗 API 额度。它问的每一句都会出现在窗口里，你能看到也能叫停；两次提问之间强制至少间隔 30 秒。默认关闭。",
        "en": "Lets a local agent (Claude Code, Codex…) put a question to the AI panels you have open and read back each answer — through your own subscriptions, with no API billing. Everything it asks shows up in the window where you can watch and stop it, and questions are spaced at least 30s apart. Off by default.",
    ],
    "settings.agent.endpoint": ["zh": "本机地址", "en": "Local endpoint"],
    "settings.agent.copyConfig": ["zh": "复制访问令牌", "en": "Copy access token"],
    "settings.agent.tokenHint": [
        "zh": "仅监听本机回环地址，其它设备无法访问。令牌用于让助手证明身份。",
        "en": "Bound to loopback only — nothing on your network can reach it. The token is how the agent identifies itself.",
    ],

    // MARK: Settings — sections
    "settings.section.language": ["zh": "语言", "en": "Language"],
    "settings.section.quickInput": ["zh": "快捷输入", "en": "Quick Input"],
    "settings.section.providers": ["zh": "AI 服务", "en": "AI Providers"],
    "settings.section.quickPrompts": ["zh": "快捷提示", "en": "Quick Prompts"],
    "settings.section.notifications": ["zh": "通知", "en": "Notifications"],
    "settings.section.about": ["zh": "关于 / 反馈", "en": "About / Feedback"],

    // MARK: Settings — about
    "settings.about.hint": ["zh": "用着有问题、有想法，欢迎邮件或微信找我", "en": "Issues or ideas? Reach me by email or WeChat"],
    "settings.about.contact": ["zh": "联系开发者", "en": "Contact developer"],
    "settings.about.wechat": ["zh": "微信", "en": "WeChat"],
    "settings.about.copied": ["zh": "已复制", "en": "Copied"],
    "settings.about.copyWechat": ["zh": "复制微信号", "en": "Copy WeChat ID"],
    "settings.about.version": ["zh": "版本", "en": "Version"],

    // MARK: First-run welcome
    "welcome.title": ["zh": "欢迎使用 Chorus", "en": "Welcome to Chorus"],
    "welcome.subtitle": ["zh": "一句话，同时问多个 AI，回答并排看、好对比", "en": "Ask once — every AI answers, side by side"],
    "welcome.step1.title": ["zh": "登录你的账号", "en": "Sign in to your AIs"],
    "welcome.step1.desc": ["zh": "首次使用，在每个面板登录你常用的 AI（就是平时用的网页版）", "en": "On first use, sign in to each panel with the accounts you already use on the web"],
    "welcome.step2.title": ["zh": "问一次，问所有", "en": "Ask once, ask them all"],
    "welcome.step2.desc": ["zh": "底部输入框打一次字，按 ⌘↩ 同时发给所有 AI", "en": "Type once in the bottom composer, press ⌘↩ to send to every AI"],
    "welcome.step3.title": ["zh": "随时快速发问", "en": "Ask from anywhere"],
    "welcome.step3.desc": ["zh": "在任何 app 里按 %@，唤出快速输入框", "en": "Press %@ in any app to summon the quick input"],
    "welcome.start": ["zh": "开始使用", "en": "Get Started"],
    "welcome.privacy": [
        "zh": "Chorus 直接加载各家官网，用你自己的账号。数据只在你的电脑与 AI 官网之间传输，不经过任何中间服务器。",
        "en": "Chorus loads each AI's official site with your own accounts. Data flows only between your Mac and the AI sites — no middleman server.",
    ],
    "menu.guide": ["zh": "使用指引", "en": "Guide"],

    // MARK: Settings — language
    "settings.language.label": ["zh": "界面语言", "en": "Interface language"],
    "settings.language.system": ["zh": "跟随系统", "en": "System"],

    // MARK: Notifications
    "notif.testTitle": ["zh": "Chorus 测试", "en": "Chorus test"],
    "notif.testBody": ["zh": "看到这条就说明通知正常 ✅", "en": "If you see this, notifications work. ✅"],

    // MARK: Menu bar
    "menubar.idle": ["zh": "都闲着呢", "en": "All idle"],
    "menubar.thinking": ["zh": "%d 个在思考…", "en": "%d thinking…"],
    "menubar.open": ["zh": "打开 Chorus", "en": "Open Chorus"],
    "menubar.quit": ["zh": "退出 Chorus", "en": "Quit Chorus"],
    "menu.checkUpdates": ["zh": "检查更新…", "en": "Check for Updates…"],
    "menu.hide": ["zh": "隐藏 Chorus", "en": "Hide Chorus"],
    "menu.hideOthers": ["zh": "隐藏其他", "en": "Hide Others"],
    "settings.section.menubar": ["zh": "菜单栏", "en": "Menu Bar"],
    "settings.menubar.show": ["zh": "在菜单栏显示图标", "en": "Show menu bar icon"],
    "settings.menubar.desc": [
        "zh": "在菜单栏常驻图标：显示是否有 AI 正在回答，点开可快速新建对话/刷新/打开主窗。开启时，关掉主窗 app 仍留在菜单栏；关闭后，关掉窗口即退出。",
        "en": "Keep an icon in the menu bar: shows whether any AI is responding, with quick actions. When on, closing the window keeps the app alive in the menu bar; when off, closing the window quits.",
    ],

    // MARK: Settings — API models
    "settings.section.apiModels": ["zh": "API 模型", "en": "API Models"],
    "settings.api.desc": [
        "zh": "接入任何 OpenAI 兼容接口（OpenAI / DeepSeek / Groq / OpenRouter / 本地 Ollama 等），和网页 AI 并排。密钥安全存于钥匙串。",
        "en": "Connect any OpenAI-compatible endpoint (OpenAI / DeepSeek / Groq / OpenRouter / local Ollama…) alongside the web AIs. Keys are stored securely in the Keychain.",
    ],
    "settings.api.name": ["zh": "名称", "en": "Name"],
    "settings.api.model": ["zh": "模型", "en": "Model"],
    "settings.api.key": ["zh": "API 密钥（本地模型可留空）", "en": "API key (leave blank for local)"],
    "settings.api.add": ["zh": "添加", "en": "Add"],
    "settings.api.save": ["zh": "保存", "en": "Save"],
    "settings.api.edit": ["zh": "编辑 %@", "en": "Edit %@"],
    "settings.api.cancel": ["zh": "取消", "en": "Cancel"],
    "settings.api.keyEdit": ["zh": "新密钥（留空＝不改）", "en": "New key (blank = keep current)"],
    "settings.api.remove": ["zh": "移除 %@", "en": "Remove %@"],
    "settings.api.presets": ["zh": "快速填充", "en": "Quick fill"],
    "settings.api.local": ["zh": "本地", "en": "local"],
    "api.panel.waiting": ["zh": "我准备好啦，随时问", "en": "Ready when you are…"],
    "api.panel.ask": ["zh": "单独问它…", "en": "Ask just this model…"],
    "api.stop": ["zh": "停止", "en": "Stop"],
    "api.clearConfirm.title": ["zh": "清空这个对话？", "en": "Clear this conversation?"],
    "api.clearConfirm.message": ["zh": "此操作不可撤销——API 面板没有服务器存档。", "en": "This can't be undone — API panels have no server-side history."],
    "api.clearConfirm.clear": ["zh": "清空", "en": "Clear"],
    "common.cancel": ["zh": "取消", "en": "Cancel"],

    // MARK: Settings — minimal mode
    "settings.minimalMode": ["zh": "简洁模式", "en": "Minimal mode"],
    "settings.minimalMode.desc": [
        "zh": "隐藏输入框里的快捷键提示和设置项的说明文字，界面更清爽。",
        "en": "Hide input shortcut hints and the description text under settings for a cleaner look.",
    ],

    // MARK: Settings — appearance
    "settings.section.appearance": ["zh": "外观", "en": "Appearance"],
    "settings.appearance.label": ["zh": "明暗模式", "en": "Theme"],
    "settings.appearance.system": ["zh": "跟随系统", "en": "System"],
    "settings.appearance.light": ["zh": "浅色", "en": "Light"],
    "settings.appearance.dark": ["zh": "深色", "en": "Dark"],
    "settings.appearance.desc": [
        "zh": "切换 Chorus 界面的明暗。跟随系统的 AI 网站也会一起切换；少数有独立主题开关的站点需在站内自行设置。",
        "en": "Switch Chorus between light and dark. AI sites that follow the system theme switch too; a few sites with their own theme toggle must be set inside the site.",
    ],
    "settings.warmWeb": ["zh": "给 AI 网页染上暖色调", "en": "Warm-tint the AI web pages"],
    "settings.warmWeb.desc": [
        "zh": "在各家 AI 网页上叠一层很淡的奶油色，让它们更贴近 Chorus 的暖色外壳。纯外观、本地实现，不影响登录或账号安全；浅色模式下效果最明显。实验功能，觉得不顺眼随时关。",
        "en": "Overlays a faint cream layer on each AI page so they lean toward Chorus's warm shell. Purely cosmetic and local — it never touches your login or account. Most visible in light mode. Experimental; turn it off anytime.",
    ],

    // MARK: Settings — quick input
    "settings.hotkey.label": ["zh": "快捷输入快捷键", "en": "Quick input shortcut"],
    "settings.hotkey.recording": ["zh": "按下组合键…", "en": "Press combo…"],
    "settings.hotkey.reset": ["zh": "重置为 ⌘⇧C", "en": "Reset to ⌘⇧C"],
    "settings.foregroundOnSend": ["zh": "发送后将 Chorus 切到最前", "en": "Bring Chorus to front after sending"],
    "settings.autoPaste": ["zh": "唤出时自动粘贴剪贴板", "en": "Auto-paste clipboard when summoning"],
    "settings.quickInput.desc": [
        "zh": "在任意位置按快捷键唤出悬浮输入框。输入后回车广播给所有可见 AI。⌘V 粘贴图片。",
        "en": "Press the shortcut anywhere to summon a floating input. Type, hit Return to broadcast to all visible AIs. Cmd+V pastes an image.",
    ],

    // MARK: Settings — providers
    "settings.restoreSession": ["zh": "启动时重开上次对话", "en": "Reopen last conversation on launch"],
    "settings.restoreSession.desc": [
        "zh": "开启后，每个面板会重开你上次停留的对话，而不是新建对话。",
        "en": "When on, each panel reopens the conversation you left it on instead of starting a new chat.",
    ],
    "settings.providers.desc": [
        "zh": "用网址添加任意 AI。内置三家针对图片上传做了适配；新增的用通用方式广播文字（多数聊天站点可用）。",
        "en": "Add any AI by its web URL. The three built-ins are tuned for image upload; added ones broadcast text via a generic method (most chat sites work).",
    ],
    "settings.providers.builtin": ["zh": "内置", "en": "Built-in"],
    "settings.providers.quickAdd": ["zh": "快速添加", "en": "Quick add"],
    "settings.providers.name": ["zh": "名称", "en": "Name"],
    "settings.providers.add": ["zh": "添加", "en": "Add"],
    "settings.providers.remove": ["zh": "移除 %@", "en": "Remove %@"],

    // MARK: Settings — notifications
    "settings.notify.picker": ["zh": "全部 AI 完成时提醒", "en": "Alert when all AIs finish"],
    "settings.notify.off": ["zh": "关闭", "en": "Off"],
    "settings.notify.quickOnly": ["zh": "仅快捷输入", "en": "Only from quick input"],
    "settings.notify.always": ["zh": "始终", "en": "Always"],
    "settings.notify.desc": [
        "zh": "当所有可见 AI 都输出完毕时，播放系统提示音并显示横幅。若 Chorus 窗口已在最前则跳过。",
        "en": "Plays the system notification sound and shows a banner when all visible AIs have finished streaming. Skipped if the Chorus window is already in front.",
    ],
    "settings.notify.test": ["zh": "发送测试通知", "en": "Send test notification"],
    "settings.notify.testDesc": ["zh": "点击验证权限/送达是否正常。", "en": "Click to verify permission/delivery is working."],
    "settings.notify.waitFor": ["zh": "提醒前等待这些 AI", "en": "Wait for these AIs before notifying"],
    "settings.notify.waitDesc": [
        "zh": "取消勾选慢/不稳定的 AI（如 Gemini），它们就不会拖住提醒。广播仍会发给它们，回答完成时自然到达。",
        "en": "Uncheck slow/flaky AIs (e.g. Gemini) so they don't block the alert. The broadcast still goes to them; their reply just arrives whenever it finishes.",
    ],

    // MARK: Settings — quick prompts
    "settings.prompts.desc": [
        "zh": "在快捷输入里点一个标签，就以该文字为前缀立即广播。",
        "en": "Tapping a chip in the quick input instantly broadcasts with that text as a prefix.",
    ],
    "settings.prompts.textChips": ["zh": "文字模式标签", "en": "Text-mode chips"],
    "settings.prompts.imageChips": ["zh": "图片模式标签（附加图片时显示）", "en": "Image-mode chips (shown when an image is attached)"],
    "settings.prompts.restore": ["zh": "恢复默认", "en": "Restore defaults"],
    "settings.prompts.addPlaceholder": ["zh": "添加一个提示…", "en": "Add a prompt…"],
    "settings.prompts.add": ["zh": "添加", "en": "Add prompt"],
    "settings.prompts.remove": ["zh": "移除", "en": "Remove"],
]
